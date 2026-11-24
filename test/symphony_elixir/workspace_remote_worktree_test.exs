defmodule SymphonyElixir.WorkspaceRemoteWorktreeTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.WorkspaceTestSupport

  test "parallel remote worktree adds of one repo take its lock one at a time" do
    with_real_exec_fake_ssh(fn ctx ->
      primary_repo = Path.join(ctx.test_root, "primary")
      create_primary_repo!(primary_repo, Path.join(ctx.test_root, "origin.git"))
      workspace_root = Path.join(ctx.test_root, "wsroot")
      bin = Path.join(ctx.test_root, "bin")
      adding = Path.join(ctx.test_root, "adding")
      overlaps = Path.join(ctx.test_root, "overlaps")

      # The worker's git notes a `worktree add` of this repo that starts while another is
      # still running, and holds each add open a moment so unserialized ones would overlap.
      # PATH is process-wide, so a `worktree add` another test's process runs in its own
      # repo meanwhile also reaches this git: only adds of this repo count.
      File.mkdir_p!(bin)

      File.write!(Path.join(bin, "git"), """
      #!/bin/sh
      case " $* " in
        *" -C #{primary_repo} worktree add "*)
          # A git that re-runs itself for the same add (a child inheriting this env) is the
          # same add, not a second one.
          if [ -n "${SYMP_TEST_ADD_ACTIVE:-}" ]; then exec #{System.find_executable("git")} "$@"; fi
          export SYMP_TEST_ADD_ACTIVE=1
          mkdir #{adding} 2>/dev/null || echo "overlap pid=$$ args=$*" >> #{overlaps}
          #{System.find_executable("git")} "$@"
          status=$?
          sleep 0.2
          rmdir #{adding} 2>/dev/null
          exit $status
          ;;
      esac
      exec #{System.find_executable("git")} "$@"
      """)

      File.chmod!(Path.join(bin, "git"), 0o755)
      write_real_exec_fake_ssh!(Path.join(ctx.test_root, "ssh"), bin <> ":")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        worker_ssh_hosts: ["worker-01"]
      )

      identifiers = Enum.map(1..3, &"MT-LOCK-#{&1}")

      results =
        identifiers
        |> Enum.map(fn identifier -> Task.async(fn -> Workspace.create_for_issue(identifier, "worker-01") end) end)
        |> Task.await_many(30_000)

      for {identifier, result} <- Enum.zip(identifiers, results) do
        workspace_path = Path.join([workspace_root, "default", identifier])
        assert {:ok, ^workspace_path} = result
        assert String.trim(git!(workspace_path, ["rev-parse", "--abbrev-ref", "HEAD"])) == "auto/#{identifier}"
      end

      refute File.exists?(overlaps), if(File.exists?(overlaps), do: File.read!(overlaps), else: "")
      refute File.exists?(Path.join([primary_repo, ".git", "symphony-worktree-add.lock"]))
    end)
  end

  test "remote worktree add of a repo given relative to the login dir takes the lock in its git dir" do
    with_real_exec_fake_ssh(fn ctx ->
      login_dir = Path.join(ctx.test_root, "home")
      primary_repo = Path.join(login_dir, "primary")
      create_primary_repo!(primary_repo, Path.join(ctx.test_root, "origin.git"))
      workspace_root = Path.join(ctx.test_root, "wsroot")
      workspace_path = Path.join([workspace_root, "default", "MT-LOCK-REL"])
      lock = Path.join([primary_repo, ".git", "symphony-worktree-add.lock"])
      write_real_exec_fake_ssh!(Path.join(ctx.test_root, "ssh"), without_flock_path_prefix!(ctx.test_root), login_dir)

      # This VM stands in for another dispatch's script holding the lock.
      File.mkdir_p!(lock)
      File.write!(Path.join(lock, "pid"), "#{System.pid()}\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: "primary",
        worker_ssh_hosts: ["worker-01"],
        hook_timeout_ms: 4_000
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 47, output}} =
               Workspace.create_for_issue("MT-LOCK-REL", "worker-01")

      assert output =~ "workspace_worktree_lock_timeout: #{lock}"

      File.rm_rf!(lock)

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-LOCK-REL", "worker-01")
      assert String.trim(git!(workspace_path, ["rev-parse", "--abbrev-ref", "HEAD"])) == "auto/MT-LOCK-REL"
      refute File.exists?(lock)
      assert git!(primary_repo, ["status", "--porcelain"]) == ""
    end)
  end

  test "remote before_remove reads the worker repo's origin without the operator's global git config" do
    with_real_exec_fake_ssh(fn ctx ->
      login_dir = Path.join(ctx.test_root, "home")
      primary_repo = Path.join(login_dir, "primary")
      create_primary_repo!(primary_repo, Path.join(ctx.test_root, "origin.git"))
      workspace_root = Path.join(ctx.test_root, "wsroot")
      env_marker = Path.join(ctx.test_root, "before-remove-env.log")
      global_config = Path.join(ctx.test_root, "global.gitconfig")

      # `remote get-url` applies `insteadOf`, so a plain git call would report the rewritten URL.
      File.write!(global_config, """
      [url "git@github.com:operator/"]
        insteadOf = git@github.com:acme/
      """)

      write_real_exec_fake_ssh!(Path.join(ctx.test_root, "ssh"), "", login_dir, global_config)

      # The repo path is relative to the worker's login dir, so the host can't read its origin
      # and the hook's env comes from the worker script's fallback.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: "primary",
        worker_ssh_hosts: ["worker-01"],
        hook_before_remove: "printf '%s\\n' \"$SYMPHONY_REPO\" > \"#{env_marker}\""
      )

      assert {:ok, workspace_path} = Workspace.create_for_issue("MT-RM-ORIGIN", "worker-01")
      git!(primary_repo, ["remote", "set-url", "origin", "git@github.com:acme/symphony.git"])

      assert :ok = Workspace.remove_issue_workspaces("MT-RM-ORIGIN", "worker-01")

      assert File.read!(env_marker) == "acme/symphony\n"
      refute File.exists?(workspace_path)

      trace = File.read!(ctx.trace_file)
      assert trace =~ ~s(symphony_git "$symphony_configured_repo" remote get-url origin)
      refute trace =~ ~s(git -C "$symphony_configured_repo" remote get-url)
    end)
  end

  test "remote worktree add gives up on a repo lock a live process holds" do
    with_real_exec_fake_ssh(fn ctx ->
      primary_repo = Path.join(ctx.test_root, "primary")
      create_primary_repo!(primary_repo, Path.join(ctx.test_root, "origin.git"))
      workspace_root = Path.join(ctx.test_root, "wsroot")
      lock = Path.join([primary_repo, ".git", "symphony-worktree-add.lock"])
      write_real_exec_fake_ssh!(Path.join(ctx.test_root, "ssh"), without_flock_path_prefix!(ctx.test_root))

      # This VM stands in for another dispatch's script holding the lock.
      File.mkdir_p!(lock)
      File.write!(Path.join(lock, "pid"), "#{System.pid()}\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        worker_ssh_hosts: ["worker-01"],
        hook_timeout_ms: 4_000
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 47, output}} =
               Workspace.create_for_issue("MT-LOCK-HELD", "worker-01")

      assert output =~ "workspace_worktree_lock_timeout: "
      assert output =~ "symphony-worktree-add.lock"
      refute File.exists?(Path.join([workspace_root, "default", "MT-LOCK-HELD"]))
      assert File.read!(Path.join(lock, "pid")) == "#{System.pid()}\n"
    end)
  end

  test "remote worktree add takes over a repo lock its dead holder left behind" do
    with_real_exec_fake_ssh(fn ctx ->
      primary_repo = Path.join(ctx.test_root, "primary")
      create_primary_repo!(primary_repo, Path.join(ctx.test_root, "origin.git"))
      workspace_root = Path.join(ctx.test_root, "wsroot")
      workspace_path = Path.join([workspace_root, "default", "MT-LOCK-DEAD"])
      lock = Path.join([primary_repo, ".git", "symphony-worktree-add.lock"])
      write_real_exec_fake_ssh!(Path.join(ctx.test_root, "ssh"), without_flock_path_prefix!(ctx.test_root))

      # A script killed while it held the lock: its pid has exited.
      {dead_pid, 0} = System.cmd("sh", ["-c", "echo $$"])
      File.mkdir_p!(lock)
      File.write!(Path.join(lock, "pid"), dead_pid)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-LOCK-DEAD", "worker-01")
      refute File.exists?(lock)
      refute File.exists?(lock <> ".takeover")
    end)
  end

  @tag :flock
  test "remote worktree add on a host with flock waits for the repo's flock, gives up at the limit and takes it once released" do
    with_real_exec_fake_ssh(fn ctx ->
      primary_repo = Path.join(ctx.test_root, "primary")
      create_primary_repo!(primary_repo, Path.join(ctx.test_root, "origin.git"))
      workspace_root = Path.join(ctx.test_root, "wsroot")
      workspace_path = Path.join([workspace_root, "default", "MT-FLOCK"])
      lock = Path.join([primary_repo, ".git", "symphony-worktree-add.flock"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        worker_ssh_hosts: ["worker-01"],
        hook_timeout_ms: 4_000
      )

      # Another dispatch's script holding the lock.
      holder = hold_flock!(lock)

      assert {:error, {:workspace_prepare_failed, "worker-01", 47, output}} =
               Workspace.create_for_issue("MT-FLOCK", "worker-01")

      assert output =~ "workspace_worktree_lock_timeout: #{lock}"
      refute File.exists?(workspace_path)

      # The holder exits without unlocking: the kernel drops its lock.
      Port.close(holder)

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-FLOCK", "worker-01")
      assert String.trim(git!(workspace_path, ["rev-parse", "--abbrev-ref", "HEAD"])) == "auto/MT-FLOCK"
      refute File.exists?(Path.join([primary_repo, ".git", "symphony-worktree-add.lock"]))

      # The script let the lock go: another process takes it at once.
      hold_flock!(lock) |> Port.close()
    end)
  end

  test "removing a remote workspace whose after_create failed removes its pending marker too" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      workspace_path = Path.join([workspace_root, "default", "MT-SSH-RM"])
      pending_marker = Path.join([workspace_root, "default", ".MT-SSH-RM.after_create_pending"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "exit 3"
      )

      capture_log(fn ->
        assert {:error, {:workspace_hook_failed, "after_create", 3, _output}} =
                 Workspace.create_for_issue("MT-SSH-RM", "worker-01")
      end)

      assert File.exists?(pending_marker)
      assert {:ok, []} = Workspace.remove(workspace_path, "worker-01")
      refute File.exists?(workspace_path)
      refute File.exists?(pending_marker)
    end)
  end

  test "remote worktree after_create that failed runs again on reuse, and removal takes its marker" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      workspace_path = Path.join([workspace_root, "default", "MT-WT-AC"])
      pending_marker = Path.join([workspace_root, "default", ".MT-WT-AC.after_create_pending"])
      setup_ready = Path.join(ctx.test_root, "setup-ready")

      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "test -f #{setup_ready} && echo set-up > setup.txt"
      )

      capture_log(fn ->
        assert {:error, {:workspace_hook_failed, "after_create", 1, _output}} =
                 Workspace.create_for_issue("MT-WT-AC", "worker-01")
      end)

      assert File.exists?(pending_marker)
      File.write!(setup_ready, "")

      capture_log(fn ->
        assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-WT-AC", "worker-01")
      end)

      assert File.read!(Path.join(workspace_path, "setup.txt")) == "set-up\n"
      refute File.exists?(pending_marker)

      File.write!(pending_marker, "")
      assert {:ok, []} = Workspace.remove(workspace_path, "worker-01")
      refute File.exists?(workspace_path)
      refute File.exists?(pending_marker)
    end)
  end

  test "a remote worktree re-created on an agent branch runs after_create on the base branch tree" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      workspace_path = Path.join([workspace_root, "default", "MT-SSH-BASE"])

      create_primary_repo!(primary_repo)
      File.write!(Path.join(primary_repo, "mix.exs"), "base project\n")
      git!(primary_repo, ["add", "mix.exs"])
      git!(primary_repo, ["commit", "-m", "base project"])

      # The agent's branch survives its removed workspace, with its own `mix.exs`.
      git!(primary_repo, ["checkout", "-b", "auto/MT-SSH-BASE"])
      File.write!(Path.join(primary_repo, "mix.exs"), "agent project\n")
      git!(primary_repo, ["commit", "-am", "agent edit"])
      agent_commit = String.trim(git!(primary_repo, ["rev-parse", "HEAD"]))
      git!(primary_repo, ["checkout", "main"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "cat mix.exs > hook.saw"
      )

      capture_log(fn ->
        assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-BASE", "worker-01")
      end)

      assert File.read!(Path.join(workspace_path, "hook.saw")) == "base project\n"
      assert String.trim(git!(workspace_path, ["rev-parse", "HEAD"])) == agent_commit
      assert String.trim(git!(workspace_path, ["branch", "--show-current"])) == "auto/MT-SSH-BASE"
      assert File.read!(Path.join(workspace_path, "mix.exs")) == "agent project\n"
      refute File.exists?(Path.join([workspace_root, "default", ".MT-SSH-BASE.after_create_pending"]))
    end)
  end

  test "a remote PR worktree runs after_create on origin's base branch, not the worker repo's HEAD" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      origin_repo = Path.join(ctx.test_root, "origin.git")
      peer_repo = Path.join(ctx.test_root, "peer")
      workspace_path = Path.join([workspace_root, "default", "PR-77"])

      create_primary_repo!(primary_repo, origin_repo)
      File.write!(Path.join(primary_repo, "mix.exs"), "base project\n")
      git!(primary_repo, ["add", "mix.exs"])
      git!(primary_repo, ["commit", "-m", "base project"])
      git!(primary_repo, ["push", "origin", "main"])

      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      git!(peer_repo, ["checkout", "-b", "feature/pr-head"])
      File.write!(Path.join(peer_repo, "mix.exs"), "agent project\n")
      git!(peer_repo, ["commit", "-am", "agent edit"])
      git!(peer_repo, ["push", "origin", "feature/pr-head"])
      pr_commit = String.trim(git!(peer_repo, ["rev-parse", "HEAD"]))

      # The worker repo's own checkout sits on something else.
      git!(primary_repo, ["fetch", "origin"])
      git!(primary_repo, ["checkout", "-b", "local-work"])
      File.write!(Path.join(primary_repo, "mix.exs"), "local project\n")
      git!(primary_repo, ["commit", "-am", "local work"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "cat mix.exs > hook.saw",
        repos: [%{"key" => "default", "workflow" => Workflow.workflow_file_path(), "team" => "Test", "base_branch" => "main"}]
      )

      issue = %Issue{identifier: "PR-77", workspace_branch: "feature/pr-head", workspace_base_ref: "origin/feature/pr-head"}

      capture_log(fn ->
        assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")
      end)

      assert File.read!(Path.join(workspace_path, "hook.saw")) == "base project\n"
      assert String.trim(git!(workspace_path, ["rev-parse", "HEAD"])) == pr_commit
      assert String.trim(git!(workspace_path, ["branch", "--show-current"])) == "feature/pr-head"
    end)
  end

  test "a remote worktree with changes of its own skips after_create with a warning and keeps its marker" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      workspace_path = Path.join([workspace_root, "default", "MT-SSH-DIRTY"])
      pending_marker = Path.join([workspace_root, "default", ".MT-SSH-DIRTY.after_create_pending"])

      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-DIRTY", "worker-01")
      File.write!(Path.join(workspace_path, "mix.exs"), "uncommitted agent project\n")
      File.write!(pending_marker, "")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "echo ran > hook.saw"
      )

      log =
        capture_log(fn ->
          assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-DIRTY", "worker-01")
        end)

      assert log =~ "Skipping workspace hook: it can't run on the base branch tree hook=after_create"
      assert log =~ "reason=uncommitted_changes"
      refute log =~ "Workspace hook failed"
      refute File.exists?(Path.join(workspace_path, "hook.saw"))
      assert File.read!(Path.join(workspace_path, "mix.exs")) == "uncommitted agent project\n"
      assert File.read!(pending_marker) == ""
    end)
  end

  test "a remote worktree whose base commit can't be resolved skips after_create with a warning" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      workspace_path = Path.join([workspace_root, "default", "MT-SSH-NOBASE"])

      create_primary_repo!(primary_repo)
      git!(primary_repo, ["branch", "auto/MT-SSH-NOBASE"])
      git!(primary_repo, ["checkout", "--orphan", "unborn"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "echo ran > hook.saw"
      )

      log =
        capture_log(fn ->
          assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-NOBASE", "worker-01")
        end)

      assert log =~ "reason=no_base_commit"
      refute File.exists?(Path.join(workspace_path, "hook.saw"))
      assert File.exists?(Path.join([workspace_root, "default", ".MT-SSH-NOBASE.after_create_pending"]))
    end)
  end

  test "a remote worktree after_create fails when the worktree can't go back to its branch" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")

      create_primary_repo!(primary_repo)
      git!(primary_repo, ["branch", "auto/MT-SSH-LOST"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "git branch -D auto/MT-SSH-LOST"
      )

      capture_log(fn ->
        assert {:error, {:workspace_hook_failed, "after_create", 1, _output}} =
                 Workspace.create_for_issue("MT-SSH-LOST", "worker-01")
      end)

      assert File.exists?(Path.join([workspace_root, "default", ".MT-SSH-LOST.after_create_pending"]))
    end)
  end

  test "a remote after_create that exits 47 on its own is a failure, not a skip" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "exit 47"
      )

      log =
        capture_log(fn ->
          assert {:error, {:workspace_hook_failed, "after_create", 47, _output}} =
                   Workspace.create_for_issue("MT-SSH-47", "worker-01")
        end)

      assert log =~ "Workspace hook failed hook=after_create"
      assert File.exists?(Path.join([workspace_root, "default", ".MT-SSH-47.after_create_pending"]))
    end)
  end

  # A worker PATH prefix whose `flock` fails the script's probe, so the script takes its
  # `mkdir` lock even on a host that has util-linux `flock`.
  defp without_flock_path_prefix!(test_root) do
    bin = Path.join(test_root, "no-flock")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "flock"), "#!/bin/sh\nexit 127\n")
    File.chmod!(Path.join(bin, "flock"), 0o755)
    bin <> ":"
  end

  # Holds `lock_file`'s flock in a process of its own until the port closes.
  defp hold_flock!(lock_file) do
    port =
      Port.open({:spawn_executable, System.find_executable("flock")}, [
        :binary,
        args: ["-w", "5", lock_file, "-c", "echo held; exec cat"]
      ])

    assert_receive {^port, {:data, "held\n"}}, 10_000
    port
  end
end
