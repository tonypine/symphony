defmodule SymphonyElixir.WorkspaceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Repo.Fetcher

  describe "validate/2" do
    test "accepts local paths under the workspace root" do
      test_root = unique_tmp("workspace-validate-local")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join([workspace_root, "default", "RSM-1"])

      try do
        File.mkdir_p!(workspace)
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        assert :ok = Workspace.validate(workspace)
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects local symlink escapes under the workspace root" do
      test_root = unique_tmp("workspace-validate-symlink")
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      workspace = Path.join([workspace_root, "default", "RSM-SYM"])

      try do
        File.mkdir_p!(Path.dirname(workspace))
        File.mkdir_p!(outside_root)
        File.ln_s!(outside_root, workspace)
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        assert {:ok, canonical_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

        assert {:error, {:workspace_symlink_escape, ^workspace, ^canonical_root}} =
                 Workspace.validate(workspace)
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects local paths outside the workspace root" do
      test_root = unique_tmp("workspace-validate-outside")
      workspace_root = Path.join(test_root, "workspaces")
      outside = Path.join(test_root, "outside")

      try do
        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside)
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        assert {:ok, canonical_outside} = SymphonyElixir.PathSafety.canonicalize(outside)
        assert {:ok, canonical_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

        assert {:error, {:workspace_outside_root, ^canonical_outside, ^canonical_root}} =
                 Workspace.validate(outside)
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects invalid remote workspace paths before remote commands" do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_path_unreadable, "   ", :empty}} =
               Workspace.validate("   ", "worker-01")

      assert {:error, {:workspace_path_unreadable, "/remote/work\nspace", :invalid_characters}} =
               Workspace.validate("/remote/work\nspace", "worker-01")

      assert {:error, {:workspace_path_unreadable, "/remote/work" <> <<0>> <> "space", :invalid_characters}} =
               Workspace.validate("/remote/work" <> <<0>> <> "space", "worker-01")

      assert {:error, {:workspace_path_unreadable, "remote/workspaces/default/RSM-1", :relative}} =
               Workspace.validate("remote/workspaces/default/RSM-1", "worker-01")

      assert {:error, {:workspace_path_unreadable, "/remote/workspaces/../outside", :parent_directory_segment}} =
               Workspace.validate("/remote/workspaces/../outside", "worker-01")

      assert {:error, {:workspace_outside_root, "/tmp/outside", "/remote/workspaces"}} =
               Workspace.validate("/tmp/outside", "worker-01")

      assert {:error, {:workspace_equals_root, "/remote/workspaces", "/remote/workspaces"}} =
               Workspace.validate("/remote/workspaces", "worker-01")

      assert :ok = Workspace.validate("/remote/workspaces/default/RSM-1", "worker-01")
    end

    test "rejects remote workspace validation when the configured root uses tilde" do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/workspaces",
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_root_unreadable, "~/workspaces", :relative}} =
               Workspace.validate("/home/symphony/workspaces/default/RSM-1", "worker-01")
    end

    test "rejects remote workspace validation when the configured root is relative" do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "relative/workspaces",
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_root_unreadable, "relative/workspaces", :relative}} =
               Workspace.validate("/relative/workspaces/default/RSM-1", "worker-01")
    end
  end

  test "remote remove rejects paths outside the configured root without invoking ssh" do
    test_root = unique_tmp("workspace-remote-remove-validate")
    previous_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      fake_ssh = Path.join(test_root, "ssh")
      trace_file = Path.join(test_root, "ssh.trace")
      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      printf 'ssh called\\n' >> #{shell_quote(trace_file)}
      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_outside_root, "/tmp/outside", "/remote/workspaces"}, ""} =
               Workspace.remove("/tmp/outside", "worker-01")

      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner rejects explicit workspace paths outside the root and does not invoke before_run" do
    test_root = unique_tmp("agent-runner-workspace-validate")
    workspace_root = Path.join(test_root, "workspaces")
    outside = Path.join(test_root, "outside")
    marker = Path.join(test_root, "before-run.marker")

    try do
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_before_run: "touch #{shell_quote(marker)}"
      )

      issue = %Issue{
        id: "issue-workspace-bypass",
        identifier: "RSM-BYPASS",
        title: "Workspace bypass",
        description: "Reject explicit outside workspace",
        state: "In Progress",
        url: "https://example.org/issues/RSM-BYPASS",
        labels: []
      }

      assert_raise RuntimeError, ~r/workspace_outside_root/, fn ->
        AgentRunner.run(issue, nil,
          workspace_path: outside,
          issue_enricher: fn issue -> {:ok, issue} end
        )
      end

      refute File.exists?(marker)
      refute File.exists?(Path.join([workspace_root, "default", "RSM-BYPASS"]))
    after
      File.rm_rf(test_root)
    end
  end

  test "concurrent worktree creation is idempotent and cleanup removes branch and directory" do
    test_root = unique_tmp("workspace-concurrent-worktree")
    primary_repo = Path.join(test_root, "primary")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      tasks =
        for _ <- 1..2 do
          Task.async(fn -> Workspace.create_for_issue("RSM-CONCURRENT") end)
        end

      results = Enum.map(tasks, &Task.await(&1, 10_000))
      assert [{:ok, workspace}, {:ok, workspace}] = results

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "RSM-CONCURRENT"]))

      assert workspace == expected_workspace
      assert File.dir?(workspace)
      assert git_branch_exists?(primary_repo, "auto/RSM-CONCURRENT")
      assert worktree_count(primary_repo, workspace) == 1

      assert :ok = Workspace.remove_issue_workspaces("RSM-CONCURRENT")
      refute File.exists?(workspace)
      refute git_branch_exists?(primary_repo, "auto/RSM-CONCURRENT")
    after
      File.rm_rf(test_root)
    end
  end

  test "a worktree remove waits while an add of the same repo holds the repo's lock" do
    test_root = unique_tmp("workspace-remove-lock")
    primary_repo = Path.join(test_root, "primary")
    workspace_root = Path.join(test_root, "workspaces")
    added = Path.join(test_root, "added")

    try do
      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      assert {:ok, workspace} = Workspace.create_for_issue("RSM-REMOVE")
      {:ok, key} = SymphonyElixir.PathSafety.canonicalize(Path.join(primary_repo, ".git"))
      test_pid = self()

      # Holds the lock the way a dispatch's `worktree add` does, until the test lets it go.
      adder =
        Task.async(fn ->
          Fetcher.with_lock(primary_repo, fn ->
            git!(primary_repo, ["worktree", "add", "-b", "auto/RSM-ADD", added])
            send(test_pid, :added)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :added, 10_000
      remover = Task.async(fn -> Workspace.remove(workspace) end)
      wait_for_fetcher(&match?(%{^key => {{:lock, _ref}, [{:lock, _from}]}}, &1))

      assert worktree_count(primary_repo, workspace) == 1
      assert git_branch_exists?(primary_repo, "auto/RSM-REMOVE")

      send(adder.pid, :release)
      assert Task.await(adder, 10_000) == :ok
      assert Task.await(remover, 10_000) == {:ok, [workspace]}

      refute File.exists?(workspace)
      refute git_branch_exists?(primary_repo, "auto/RSM-REMOVE")
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree preparations of one repo at once share a single fetch" do
    test_root = unique_tmp("workspace-concurrent-fetch")
    primary_repo = Path.join(test_root, "primary")
    origin_repo = Path.join(test_root, "origin.git")
    bin = Path.join(test_root, "bin")
    uploads = Path.join(test_root, "uploads")
    release = Path.join(test_root, "release")
    workspace_root = Path.join(test_root, "workspaces")
    previous_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      create_primary_repo!(primary_repo)
      git!(test_root, ["clone", "--quiet", "--bare", primary_repo, origin_repo])
      git!(primary_repo, ["remote", "add", "origin", "slowfetch::" <> origin_repo])

      # Each fetch runs this remote helper once, which waits until the test lets it go and then
      # connects git to the origin repo's upload-pack.
      File.mkdir_p!(bin)

      File.write!(Path.join(bin, "git-remote-slowfetch"), """
      #!/bin/sh
      printf 'upload\\n' >> #{shell_quote(uploads)}
      i=0
      while [ ! -f #{shell_quote(release)} ] && [ "$i" -lt 500 ]; do
        sleep 0.02
        i=$((i + 1))
      done
      while read -r line; do
        case "$line" in
          capabilities) printf 'connect\\n\\n' ;;
          "connect git-"*) printf '\\n'; exec git "${line#connect git-}" "$2" ;;
          *) exit 1 ;;
        esac
      done
      """)

      File.chmod!(Path.join(bin, "git-remote-slowfetch"), 0o755)
      System.put_env("PATH", bin <> ":" <> (previous_path || ""))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: true
      )

      tasks = for identifier <- ["RSM-F1", "RSM-F2", "RSM-F3"], do: Task.async(fn -> Workspace.create_for_issue(identifier) end)
      {:ok, fetch_key} = SymphonyElixir.PathSafety.canonicalize(Path.join(primary_repo, ".git"))
      wait_for_fetch_waiters(fetch_key, 3)
      File.write!(release, "")

      assert [{:ok, _workspace1}, {:ok, _workspace2}, {:ok, _workspace3}] = Enum.map(tasks, &Task.await(&1, 10_000))
      assert File.read!(uploads) == "upload\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree excludes the agent skip-comments file from version control" do
    test_root = unique_tmp("workspace-skip-exclude")
    primary_repo = Path.join(test_root, "primary")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      assert {:ok, workspace} = Workspace.create_for_issue("RSM-SKIP")

      assert {_output, 0} =
               Workspace.safe_git(["-C", workspace, "check-ignore", ".symphony-skip-comments.json"])
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree creation and reuse run no filter driver from the repo's local config" do
    test_root = unique_tmp("workspace-filter-driver")
    primary_repo = Path.join(test_root, "primary")
    workspace_root = Path.join(test_root, "workspaces")
    proof = Path.join(test_root, "SYMPHONY_FILTER_PWNED")

    try do
      create_primary_repo!(primary_repo)
      git!(primary_repo, ["checkout", "-b", "agent/filter"])
      File.write!(Path.join(primary_repo, ".gitattributes"), "*.txt filter=evil\n")
      File.write!(Path.join(primary_repo, "notes.txt"), "stored\n")
      git!(primary_repo, ["add", ".gitattributes", "notes.txt"])
      git!(primary_repo, ["commit", "-m", "agent attributes"])
      git!(primary_repo, ["checkout", "main"])

      # The driver an agent's branch picks, set where agents commit: the shared repo's config.
      git!(primary_repo, ["config", "filter.evil.smudge", "touch '#{proof}'; cat"])
      git!(primary_repo, ["config", "filter.evil.clean", "touch '#{proof}'; cat"])
      git!(primary_repo, ["config", "filter.evil.required", "true"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      issue = %Issue{identifier: "RSM-FILTER", workspace_branch: "agent/filter", workspace_base_ref: "agent/filter"}

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "notes.txt")) == "stored\n"
      refute File.exists?(proof)

      # Reusing a dirty worktree backs it up (`status`, `add -A`) before `reset --hard` and `checkout`.
      head = git!(workspace, ["rev-parse", "HEAD"])
      File.write!(Path.join(workspace, "notes.txt"), "agent edit\n")

      assert {:ok, ^workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "notes.txt")) == "stored\n"
      assert git!(workspace, ["show", "refs/symphony/orphaned/#{head}:notes.txt"]) == "agent edit"
      refute File.exists?(proof)

      File.rm!(Path.join(workspace, "notes.txt"))
      assert {_output, 0} = System.cmd("git", ["-C", workspace, "checkout", "--", "notes.txt"], stderr_to_stdout: true)
      assert File.exists?(proof), "plain git runs the driver, so the setup above is a real attack"
    after
      File.rm_rf(test_root)
    end
  end

  defp unique_tmp(name) do
    Path.join(System.tmp_dir!(), "symphony-elixir-#{name}-#{System.unique_integer([:positive])}")
  end

  defp create_primary_repo!(primary_repo) do
    File.mkdir_p!(primary_repo)
    git!(primary_repo, ["init", "-b", "main"])
    git!(primary_repo, ["config", "user.name", "Test User"])
    git!(primary_repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(primary_repo, "README.md"), "initial\n")
    git!(primary_repo, ["add", "README.md"])
    git!(primary_repo, ["commit", "-m", "initial"])
  end

  defp git!(repo, args) do
    case Workspace.safe_git(["-C", repo | args]) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp git_branch_exists?(repo, branch) do
    case Workspace.safe_git(["-C", repo, "rev-parse", "--verify", "refs/heads/#{branch}"]) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp worktree_count(repo, workspace) do
    repo
    |> git!(["worktree", "list", "--porcelain"])
    |> String.split("\n", trim: true)
    |> Enum.count(&(&1 == "worktree #{workspace}"))
  end

  # The fetcher keys a repo by its git common dir.
  defp wait_for_fetch_waiters(key, count, attempts \\ 500) do
    case :sys.get_state(SymphonyElixir.Repo.Fetcher) do
      %{^key => {{:fetch, _ref, waiters}, []}} when length(waiters) == count ->
        :ok

      _fetches when attempts > 0 ->
        Process.sleep(10)
        wait_for_fetch_waiters(key, count, attempts - 1)
    end
  end

  defp wait_for_fetcher(matches, attempts \\ 500) do
    cond do
      matches.(:sys.get_state(Fetcher)) ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        wait_for_fetcher(matches, attempts - 1)
    end
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
