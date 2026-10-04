defmodule SymphonyElixir.WorkflowSourceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.{Cache, SystemSchema}
  alias SymphonyElixir.{Paths, Workflow, WorkflowSource, Workspace}
  alias SymphonyElixir.Repo.Status, as: RepoStatus
  alias SymphonyElixir.Repo.Supervisor, as: RepoSupervisor

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
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_primary_repo = Application.get_env(:symphony_elixir, :primary_repo_name)

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
      restore_app_env(:workflow_file_path, original_workflow_path)
      restore_app_env(:primary_repo_name, original_primary_repo)
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
      repo = repo(checkout)

      assert WorkflowSource.read_path(repo) == Path.join(checkout, "WORKFLOW.md")
      assert WorkflowSource.refresh(repo) == :ok

      assert WorkflowSource.read_path(repo) ==
               Path.join([root, "state", "workflows", "app", "WORKFLOW.md"])
    end

    test "reads the local file with a warning in a checkout with no origin", %{root: root} do
      checkout = local_only_checkout!(root, "Local prompt")
      write_symphony!(root, checkout)
      {:ok, repo} = Config.repo("app")

      log =
        capture_log(fn ->
          assert {:error, {:workflow_ref_not_found, _candidates}} = WorkflowSource.refresh(repo)
        end)

      assert log =~ "reading the local workflow file until the ref resolves"
      assert WorkflowSource.read_path(repo) == Path.join(checkout, "WORKFLOW.md")
      assert {:ok, %{prompt: "Local prompt"}} = Config.workflow_for_repo("app")
      assert :ok = Config.validate_repo_workflows()
    end
  end

  describe "once the ref resolves after boot" do
    setup %{root: root} do
      checkout = local_only_checkout!(root, "Local prompt")
      origin = Path.join(root, "origin.git")
      git!(root, ["init", "-q", "--bare", "-b", "main", origin])
      write_symphony!(root, checkout)
      {:ok, repo} = Config.repo("app")
      capture_log(fn -> WorkflowSource.refresh(repo) end)

      add_origin = fn ->
        git!(checkout, ["remote", "add", "origin", origin])
        File.write!(Path.join(checkout, "WORKFLOW.md"), "Committed prompt\n")
        git!(checkout, ["commit", "-q", "-am", "commit prompt"])
        git!(checkout, ["push", "-q", "-u", "origin", "main"])
        git!(checkout, ["remote", "set-head", "origin", "main"])
        File.write!(Path.join(checkout, "WORKFLOW.md"), "Uncommitted prompt\n")
      end

      {:ok, repo: repo, checkout: checkout, add_origin: add_origin}
    end

    test "the primary workflow store switches to the snapshot", %{repo: repo, checkout: checkout, add_origin: add_origin} do
      Application.put_env(:symphony_elixir, :primary_repo_name, "app")
      Workflow.set_workflow_file_path(WorkflowSource.read_path(repo))
      assert Workflow.workflow_file_path() == Path.join(checkout, "WORKFLOW.md")

      add_origin.()

      assert WorkflowSource.refresh(repo) == :ok
      assert Workflow.workflow_file_path() == WorkflowSource.read_path(repo)
      assert {:ok, %{prompt: "Committed prompt"}} = Workflow.load(Workflow.workflow_file_path())
    end

    test "a repo workflow store switches to the snapshot", %{repo: repo, add_origin: add_origin} do
      Application.put_env(:symphony_elixir, :primary_repo_name, "other")
      ensure_repo_registry_started!()
      start_supervised!({RepoSupervisor, repo})
      assert {:ok, %{prompt: "Local prompt"}} = RepoSupervisor.current_workflow("app")

      add_origin.()

      assert WorkflowSource.refresh(repo) == :ok
      assert {:ok, %{prompt: "Committed prompt"}} = RepoSupervisor.current_workflow("app")
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

    test "a warning git prints on stderr stays out of the snapshot", %{root: root} do
      %{checkout: checkout} = git_repos!(root, "Committed prompt")
      repo = repo(checkout)
      with_noisy_git!(root, fn -> assert WorkflowSource.refresh(repo) == :ok end)

      assert File.read!(WorkflowSource.read_path(repo)) == File.read!(Path.join(checkout, "WORKFLOW.md"))
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

    test "an invalid workflow on the ref is reported until the ref loads again, across a restart", %{root: root} do
      %{checkout: checkout, other: other} = git_repos!(root, "Good prompt")
      write_symphony!(root, checkout)
      {:ok, repo} = Config.repo("app")
      assert WorkflowSource.refresh(repo) == :ok
      assert WorkflowSource.ref_error(repo) == nil

      push_workflow!(other, "---\nfoo: [\n---\nBad prompt\n")
      capture_log(fn -> assert {:error, _reason} = WorkflowSource.refresh(repo, fetch: true) end)
      assert {:workflow_parse_error, _reason} = WorkflowSource.ref_error(repo)

      # A restart refreshes without fetching and reads the same broken ref.
      capture_log(fn -> assert WorkflowSource.refresh_all(Config.system!()) == :ok end)

      ensure_repo_registry_started!()
      start_supervised!({RepoSupervisor, repo})
      assert {:ok, %{prompt: "Good prompt"}} = RepoSupervisor.current_workflow("app")

      assert {:ok, [%{workflow: workflow}]} = RepoStatus.list([])
      assert %{found: true, status: "invalid", path: path, error: "WORKFLOW.md on the base branch does not load" <> message} = workflow
      assert path == WorkflowSource.read_path(repo)
      assert message =~ "Symphony keeps the last good workflow: Failed to parse WORKFLOW.md:"

      push_workflow!(other, "Fixed prompt\n")
      assert WorkflowSource.refresh(repo, fetch: true) == :ok
      assert WorkflowSource.ref_error(repo) == nil
      assert {:ok, [%{workflow: %{found: true, status: "valid", error: nil}}]} = RepoStatus.list([])
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

      write_symphony!(root, checkout)
      assert {:ok, [%{workflow: workflow}]} = RepoStatus.list([])
      assert %{found: false, status: "missing", error: message} = workflow

      assert message =~ "keeps the last good workflow: git show origin/HEAD:WORKFLOW.md exited with status 128: fatal: path 'WORKFLOW.md'"
    end

    test "a base branch ref that disappears is reported as a missing workflow", %{root: root} do
      %{checkout: checkout} = git_repos!(root, "Good prompt")
      write_symphony!(root, checkout, base_branch: "main")
      {:ok, repo} = Config.repo("app")
      assert WorkflowSource.refresh(repo) == :ok

      git!(checkout, ["update-ref", "-d", "refs/remotes/origin/main"])
      capture_log(fn -> assert {:error, {:workflow_ref_not_found, ["origin/main"]}} = WorkflowSource.refresh(repo) end)

      assert {:ok, [%{workflow: %{found: false, status: "missing", error: message}}]} = RepoStatus.list([])
      assert message =~ "keeps the last good workflow: no origin/main ref in the checkout"
    end

    test "a ref error with no snapshot to keep, or that does not decode, is not reported", %{root: root} do
      %{checkout: checkout, other: other} = git_repos!(root, "Good prompt")
      repo = repo(checkout)
      assert WorkflowSource.refresh(repo) == :ok

      snapshot = WorkflowSource.read_path(repo)
      push_workflow!(other, "---\nfoo: [\n---\nBad prompt\n")
      capture_log(fn -> WorkflowSource.refresh(repo, fetch: true) end)
      assert WorkflowSource.ref_error(repo) != nil

      File.write!(snapshot <> ".ref-error", "not a term")
      assert WorkflowSource.ref_error(repo) == nil

      File.rm!(snapshot)
      capture_log(fn -> WorkflowSource.refresh(repo) end)
      refute File.exists?(snapshot <> ".ref-error")
      assert WorkflowSource.ref_error(repo) == nil
      assert WorkflowSource.ref_error(repo(checkout, workflow_source: "local")) == nil
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

  describe "load_for_check/1" do
    test "validates the committed workflow, not a broken working copy, without writing the snapshot", %{root: root} do
      %{checkout: checkout} = git_repos!(root, "Committed prompt")
      File.write!(Path.join(checkout, "WORKFLOW.md"), "---\ntracker: [unclosed\n---\nBroken prompt\n")
      write_symphony!(root, checkout)
      {:ok, repo} = Config.repo("app")

      assert {:ok, %{prompt: "Committed prompt"}} = WorkflowSource.load_for_check(repo)
      assert Config.check_repo_workflows() == :ok
      assert WorkflowSource.read_path(repo) == Path.join(checkout, "WORKFLOW.md")
    end

    test "reads a newer ref over a stale snapshot", %{root: root} do
      %{checkout: checkout, other: other} = git_repos!(root, "First prompt")
      repo = repo(checkout)
      assert WorkflowSource.refresh(repo) == :ok

      push_workflow!(other, "Second prompt\n")
      git!(checkout, ["fetch", "-q", "origin"])

      assert {:ok, %{prompt: "Second prompt"}} = WorkflowSource.load_for_check(repo)
      assert File.read!(WorkflowSource.read_path(repo)) == "First prompt\n"
    end

    test "reads the last good snapshot when the workflow on the ref is invalid", %{root: root} do
      %{checkout: checkout, other: other} = git_repos!(root, "Good prompt")
      repo = repo(checkout)
      assert WorkflowSource.refresh(repo) == :ok

      push_workflow!(other, "---\nunknown_key: true\n---\nBad prompt\n")
      git!(checkout, ["fetch", "-q", "origin"])

      assert {:ok, %{prompt: "Good prompt"}} = WorkflowSource.load_for_check(repo)
    end

    test "reads the local file when the ref does not resolve and no snapshot exists", %{root: root} do
      checkout = local_only_checkout!(root, "Local prompt")

      assert {:ok, %{prompt: "Local prompt"}} = WorkflowSource.load_for_check(repo(checkout))
    end

    test "reads the local file for workflow_source: local", %{root: root} do
      %{checkout: checkout} = git_repos!(root, "Committed prompt")
      File.write!(Path.join(checkout, "WORKFLOW.md"), "Local prompt\n")

      assert {:ok, %{prompt: "Local prompt"}} = WorkflowSource.load_for_check(repo(checkout, workflow_source: "local"))
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

  defp local_only_checkout!(root, prompt) do
    checkout = Path.join(root, "local-only")
    File.mkdir_p!(checkout)
    git!(checkout, ["init", "-q", "-b", "main"])
    File.write!(Path.join(checkout, "WORKFLOW.md"), prompt <> "\n")
    git!(checkout, ["add", "WORKFLOW.md"])
    git!(checkout, ["commit", "-q", "-m", "workflow"])
    checkout
  end

  defp ensure_repo_registry_started! do
    unless Process.whereis(SymphonyElixir.Repo.Registry) do
      start_supervised!({Registry, keys: :unique, name: SymphonyElixir.Repo.Registry})
    end

    :ok
  end

  defp push_workflow!(clone, content) do
    File.write!(Path.join(clone, "WORKFLOW.md"), content)
    git!(clone, ["commit", "-q", "-am", "update workflow"])
    git!(clone, ["push", "-q", "origin", "main"])
  end

  # Puts a `git` first on PATH that prints a warning on stderr before running the
  # real git, like the xcrun shim of `/usr/bin/git` in the agent sandbox.
  defp with_noisy_git!(root, fun) do
    bin = Path.join(root, "noisy-bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "git"), """
    #!/bin/sh
    echo "warning: noisy git shim" >&2
    exec "#{System.find_executable("git")}" "$@"
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    original_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
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
