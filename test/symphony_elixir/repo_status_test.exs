defmodule SymphonyElixir.RepoStatusTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Repo.FetchLog

  @git_env [
    {"GIT_AUTHOR_NAME", "Symphony Test"},
    {"GIT_AUTHOR_EMAIL", "symphony@example.com"},
    {"GIT_COMMITTER_NAME", "Symphony Test"},
    {"GIT_COMMITTER_EMAIL", "symphony@example.com"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"}
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-repo-status-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  describe "FetchLog" do
    test "keeps the last fetch per repo and returns the result it records" do
      at = ~U[2026-10-04 12:00:00Z]

      assert FetchLog.record("status-a", {:ok, "output"}, at) == {:ok, "output"}
      assert FetchLog.last("status-a") == %{at: at, result: :ok}

      assert FetchLog.record("status-a", {:error, :boom, "fatal: no"}, at) == {:error, :boom, "fatal: no"}
      assert FetchLog.last("status-a") == %{at: at, result: {:error, {:boom, "fatal: no"}}}

      assert FetchLog.record("status-a", {:error, :boom}) == {:error, :boom}
      assert %{result: {:error, :boom}, at: %DateTime{}} = FetchLog.last("status-a")

      assert FetchLog.record(nil, :ok) == :ok
      assert FetchLog.last("status-never") == nil
    end

    test "records nothing and reports no fetch without its server" do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, FetchLog)
      on_exit(fn -> {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, FetchLog) end)

      assert FetchLog.record("status-b", :ok) == :ok
      assert FetchLog.last("status-b") == nil
    end
  end

  describe "WorkflowStore.status/1" do
    test "reports a valid, invalid, missing and fixed workflow", %{root: root} do
      path = Path.join(root, "WORKFLOW.md")
      File.write!(path, "Prompt\n")
      store = start_supervised!({WorkflowStore, name: nil, path: path})

      assert WorkflowStore.status(store) == {:ok, %{path: path, status: :valid, error: nil}}

      capture_log(fn ->
        File.write!(path, "---\nfoo: [\n---\nPrompt\n")
        assert {:ok, %{status: :invalid, error: {:workflow_parse_error, _reason}}} = WorkflowStore.status(store)

        File.rm!(path)
        assert {:ok, %{status: :missing, error: {:missing_workflow_file, ^path, :enoent}}} = WorkflowStore.status(store)
      end)

      # The last good workflow is still served while the file is missing.
      assert {:ok, %{prompt: "Prompt"}} = WorkflowStore.current(store)

      File.write!(path, "Prompt\n")
      assert WorkflowStore.status(store) == {:ok, %{path: path, status: :valid, error: nil}}
    end

    test "reports a store started on a missing file", %{root: root} do
      path = Path.join(root, "MISSING.md")

      store = start_supervised!({WorkflowStore, name: nil, path: path, allow_invalid?: true})

      capture_log(fn ->
        assert {:ok, %{path: ^path, status: :missing}} = WorkflowStore.status(store)
      end)
    end

    test "is unavailable when the store is not running" do
      assert WorkflowStore.status({:via, Registry, {SymphonyElixir.Repo.Registry, {:workflow_store, "nowhere"}}}) == :unavailable
    end
  end

  describe "fetch before dispatch" do
    test "records each local worktree fetch, including a failed one", %{root: root} do
      checkout = checkout!(root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(root, "workspaces"),
        workspace_strategy: "worktree",
        workspace_repo: checkout
      )

      assert {:ok, _workspace} = Workspace.create_for_issue("TP-1")
      assert %{result: :ok} = FetchLog.last("default")

      git!(checkout, ["remote", "set-url", "origin", Path.join(root, "missing.git")])

      capture_log(fn ->
        assert {:error, _reason} = Workspace.create_for_issue("TP-2", nil, "default")
      end)

      assert %{result: {:error, {{:git_failed, ^checkout, ["fetch", "origin"], _status}, output}}} = FetchLog.last("default")
      assert output =~ "missing.git"
    end
  end

  defp checkout!(root) do
    remote = Path.join(root, "remote.git")
    checkout = Path.join(root, "checkout")
    git!(root, ["init", "-q", "--bare", "-b", "main", remote])
    git!(root, ["init", "-q", "-b", "main", checkout])
    File.write!(Path.join(checkout, "README.md"), "readme\n")
    git!(checkout, ["add", "README.md"])
    git!(checkout, ["commit", "-q", "-m", "init"])
    git!(checkout, ["remote", "add", "origin", remote])
    git!(checkout, ["push", "-q", "-u", "origin", "main"])
    checkout
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", ["-C", dir | args], env: @git_env, stderr_to_stdout: true)
    output
  end
end
