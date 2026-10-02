defmodule SymphonyElixir.WorkflowSourceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.{Cache, SystemSchema}
  alias SymphonyElixir.{Paths, Workflow, WorkflowSource, Workspace}

  @git_env [
    {"GIT_AUTHOR_NAME", "Symphony Test"},
    {"GIT_AUTHOR_EMAIL", "symphony@example.com"},
    {"GIT_COMMITTER_NAME", "Symphony Test"},
    {"GIT_COMMITTER_EMAIL", "symphony@example.com"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"}
  ]

  setup do
    original_symphony_path = Application.get_env(:symphony_elixir, :symphony_file_path)
    original_state_root = Application.get_env(:symphony_elixir, :state_root_override)
    original_watch = Application.get_env(:symphony_elixir, :config_cache_watch)

    root = Path.join(System.tmp_dir!(), "symphony-workflow-source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Paths.set_state_root(Path.join(root, "state"))
    Application.put_env(:symphony_elixir, :config_cache_watch, false)
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      restore_app_env(:symphony_file_path, original_symphony_path)
      restore_app_env(:state_root_override, original_state_root)
      restore_app_env(:config_cache_watch, original_watch)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "read_path/1" do
    test "reads the local file for workflow_source: local", %{root: root} do
      %{checkout: checkout} = git_repos!(root, "Committed prompt")
      repo = repo(checkout, workflow_source: "local")

      assert WorkflowSource.read_path(repo) == Path.join(checkout, "WORKFLOW.md")
      assert WorkflowSource.refresh(repo) == :skipped
    end

    test "reads the local file when the workflow is not inside a git checkout", %{root: root} do
      dir = Path.join(root, "plain")
      File.mkdir_p!(dir)
      repo = repo(dir)

      assert WorkflowSource.read_path(repo) == Path.join(dir, "WORKFLOW.md")
      assert WorkflowSource.refresh(repo) == :skipped
    end

    test "reads a snapshot under the state root for the default ref source", %{root: root} do
      %{checkout: checkout} = git_repos!(root, "Committed prompt")

      assert WorkflowSource.read_path(repo(checkout)) ==
               Path.join([root, "state", "workflows", "app", "WORKFLOW.md"])
    end
  end

  describe "with the default ref source" do
    test "uncommitted local edits do not reach the run", %{root: root} do
      %{checkout: checkout} = git_repos!(root, "Committed prompt")
      write_symphony!(root, checkout)
      File.write!(Path.join(checkout, "WORKFLOW.md"), "Uncommitted prompt\n")

      assert {:ok, repo} = Config.repo("app")
      assert WorkflowSource.refresh(repo) == :ok
      assert {:ok, %{prompt: "Committed prompt"}} = Config.workflow_for_repo("app")
      assert :ok = Config.validate_repo_workflows()
    end

    test "a change pushed to the base branch takes effect on the next dispatch", %{root: root} do
      %{checkout: checkout, other: other} = git_repos!(root, "First prompt")
      write_symphony!(root, checkout, base_branch: "main")
      {:ok, repo} = Config.repo("app")
      assert WorkflowSource.refresh(repo) == :ok
      assert {:ok, %{prompt: "First prompt"}} = Config.workflow_for_repo("app")

      push_workflow!(other, "Second prompt\n")

      assert {:ok, _workspace} = Workspace.create_for_issue("TP-1", nil, "app")
      assert {:ok, %{prompt: "Second prompt"}} = Config.workflow_for_repo("app")
      assert WorkflowSource.refresh(repo) == :unchanged
    end

    test "skips the fetch when the dispatch already fetched the checkout", %{root: root} do
      %{checkout: checkout, other: other} = git_repos!(root, "First prompt")
      repo = repo(checkout, base_branch: "origin/main")
      assert WorkflowSource.refresh(repo) == :ok

      push_workflow!(other, "Second prompt\n")

      assert WorkflowSource.refresh(repo, fetch: true, fetched_repo: checkout) == :unchanged
      assert WorkflowSource.refresh(repo, fetch: true, fetched_repo: Path.join(root, "elsewhere")) == :ok
      assert File.read!(WorkflowSource.read_path(repo)) == "Second prompt\n"
    end

    test "a failed fetch logs a warning and reads the last fetched ref", %{root: root} do
      %{checkout: checkout} = git_repos!(root, "Committed prompt")
      git!(checkout, ["remote", "set-url", "origin", Path.join(root, "missing.git")])
      repo = repo(checkout, base_branch: "refs/heads/main")

      log =
        capture_log(fn ->
          assert WorkflowSource.refresh(repo, fetch: true) == :ok
        end)

      assert log =~ "Failed to fetch workflow checkout repo=app"
      assert File.read!(WorkflowSource.read_path(repo)) == "Committed prompt\n"
    end

    test "an invalid workflow on the ref keeps the last known good workflow", %{root: root} do
      %{checkout: checkout, other: other} = git_repos!(root, "Good prompt")
      write_symphony!(root, checkout)
      {:ok, repo} = Config.repo("app")
      assert WorkflowSource.refresh(repo) == :ok

      push_workflow!(other, "---\nunknown_key: true\n---\nBad prompt\n")

      log =
        capture_log(fn ->
          assert {:error, _reason} = WorkflowSource.refresh(repo, fetch: true)
        end)

      assert log =~ "Failed to load workflow from ref repo=app"
      assert log =~ "keeping last known good workflow"
      assert {:ok, %{prompt: "Good prompt"}} = Config.workflow_for_repo("app")
    end

    test "a workflow missing on the ref keeps the last known good workflow", %{root: root} do
      %{checkout: checkout, other: other} = git_repos!(root, "Good prompt")
      repo = repo(checkout)
      assert WorkflowSource.refresh(repo) == :ok

      git!(other, ["rm", "-q", "WORKFLOW.md"])
      git!(other, ["commit", "-q", "-m", "drop workflow"])
      git!(other, ["push", "-q", "origin", "main"])

      log =
        capture_log(fn ->
          assert {:error, {:git_failed, ["show", "origin/HEAD:WORKFLOW.md"], _status, _output}} =
                   WorkflowSource.refresh(repo, fetch: true)
        end)

      assert log =~ "Failed to load workflow from ref repo=app"
      assert File.read!(WorkflowSource.read_path(repo)) == "Good prompt\n"
    end

    test "a missing base branch ref is reported", %{root: root} do
      %{checkout: checkout} = git_repos!(root, "Committed prompt")

      capture_log(fn ->
        assert {:error, {:workflow_ref_not_found, ["origin/release"]}} =
                 WorkflowSource.refresh(repo(checkout, base_branch: "release"))
      end)
    end

    test "refresh_all refreshes every configured repo", %{root: root} do
      %{checkout: checkout} = git_repos!(root, "Committed prompt")
      repo = repo(checkout)

      assert WorkflowSource.refresh_all(%SystemSchema{repos: [repo]}) == :ok
      assert File.read!(WorkflowSource.read_path(repo)) == "Committed prompt\n"
    end
  end

  test "rejects an unknown workflow_source" do
    assert {:error, {:invalid_symphony_config, message}} =
             SystemSchema.parse(%{
               "repositories" => [%{"key" => "app", "workflow" => "WORKFLOW.md", "workflow_source" => "remote"}]
             })

    assert message =~ "workflow_source"
  end

  defp repo(dir, attrs \\ []) do
    struct!(SystemSchema.Repo, Keyword.merge([name: "app", workflow: Path.join(dir, "WORKFLOW.md")], attrs))
  end

  defp git_repos!(root, prompt) do
    origin = Path.join(root, "origin.git")
    checkout = Path.join(root, "checkout")
    other = Path.join(root, "other")

    git!(root, ["init", "-q", "--bare", "-b", "main", origin])
    git!(root, ["init", "-q", "-b", "main", checkout])
    git!(checkout, ["remote", "add", "origin", origin])
    File.write!(Path.join(checkout, "WORKFLOW.md"), prompt <> "\n")
    git!(checkout, ["add", "WORKFLOW.md"])
    git!(checkout, ["commit", "-q", "-m", "workflow"])
    git!(checkout, ["push", "-q", "-u", "origin", "main"])
    git!(checkout, ["remote", "set-head", "origin", "main"])
    git!(root, ["clone", "-q", origin, other])

    %{checkout: checkout, other: other}
  end

  defp push_workflow!(clone, content) do
    File.write!(Path.join(clone, "WORKFLOW.md"), content)
    git!(clone, ["commit", "-q", "-am", "update workflow"])
    git!(clone, ["push", "-q", "origin", "main"])
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], env: @git_env, stderr_to_stdout: true)
    output
  end

  defp write_symphony!(root, checkout, attrs \\ []) do
    base_branch = Keyword.get(attrs, :base_branch)
    path = Path.join(root, "symphony.yml")

    File.write!(path, """
    issues:
      provider: memory
    repositories:
      - key: app
        workflow: #{Path.join(checkout, "WORKFLOW.md")}
    #{if base_branch, do: "    base_branch: #{base_branch}", else: ""}
    workspaces:
      root: #{Path.join(root, "workspaces")}
    agent:
      runtime: codex
      command: codex app-server
    """)

    Workflow.set_symphony_file_path(path)
    Cache.clear()
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
