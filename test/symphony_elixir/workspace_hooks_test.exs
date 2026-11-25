defmodule SymphonyElixir.WorkspaceHooksTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.WorkspaceTestSupport
  alias SymphonyElixir.Config.Schema

  test "workspace age GC removes stale workspaces while protecting active identifiers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-age-gc-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      stale_workspace = Path.join([workspace_root, "default", "MT-STALE"])
      protected_workspace = Path.join([workspace_root, "default", "MT-RUNNING"])
      recent_workspace = Path.join([workspace_root, "default", "MT-RECENT"])
      other_repo_workspace = Path.join([workspace_root, "other", "MT-OTHER-STALE"])

      Enum.each([stale_workspace, protected_workspace, recent_workspace, other_repo_workspace], &File.mkdir_p!/1)
      old_timestamp = {{2026, 1, 1}, {0, 0, 0}}
      File.touch!(stale_workspace, old_timestamp)
      File.touch!(protected_workspace, old_timestamp)
      File.touch!(other_repo_workspace, old_timestamp)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_lifecycle: %{max_age_days: 14}
      )

      now = DateTime.new!(~D[2026-01-20], ~T[00:00:00], "Etc/UTC")

      assert {:ok, actions} = Workspace.reclaim_stale_workspaces(["MT-RUNNING"], now)

      assert Enum.any?(actions, &match?(%{identifier: "MT-STALE", action: :deleted, reason: :age_gc}, &1))
      refute File.exists?(stale_workspace)
      assert File.exists?(protected_workspace)
      assert File.exists?(recent_workspace)
      assert File.exists?(other_repo_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "startup orphan sweep can delete untracked workspace directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-orphan-sweep-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      tracked_workspace = Path.join([workspace_root, "default", "MT-TRACKED"])
      orphan_workspace = Path.join([workspace_root, "default", "MT-ORPHAN"])
      other_repo_orphan = Path.join([workspace_root, "other", "MT-ORPHAN"])

      File.mkdir_p!(tracked_workspace)
      File.mkdir_p!(orphan_workspace)
      File.mkdir_p!(other_repo_orphan)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_lifecycle: %{orphan_action: "delete"}
      )

      assert {:ok, actions} = Workspace.sweep_orphan_workspaces(["MT-TRACKED"])

      assert Enum.any?(actions, &match?(%{identifier: "MT-ORPHAN", action: :deleted, reason: :orphan}, &1))
      assert File.exists?(tracked_workspace)
      refute File.exists?(orphan_workspace)
      assert File.exists?(other_repo_orphan)

      assert {:ok, other_actions} = Workspace.sweep_orphan_workspaces("other", [])
      assert Enum.any?(other_actions, &match?(%{repo_key: "other", identifier: "MT-ORPHAN", action: :deleted, reason: :orphan}, &1))
      refute File.exists?(other_repo_orphan)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(Path.dirname(first_workspace)) == "default"
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join([workspace_root, "default", "MT-STALE"])
      File.mkdir_p!(Path.dirname(stale_workspace))
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join([workspace_root, "default", "MT-SYM"])

      File.mkdir_p!(Path.dirname(symlink_path))
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([actual_root, "default", "MT-LINK"]))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace retries an after_create hook that times out once, in the workspace it left" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-workspace-hook-retry-#{System.unique_integer([:positive])}")
    runs_file = Path.join(test_root, "after_create.runs")

    try do
      File.mkdir_p!(test_root)

      # The first try prints 25 lines, leaves a file behind, starts a background
      # job and hangs; the second needs that file and finishes at once.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(test_root, "workspaces"),
        hook_after_create_timeout_ms: 1_000,
        hook_after_create: """
        echo run >> #{runs_file}
        if [ "$(wc -l < #{runs_file})" -eq 1 ]; then
          i=1
          while [ $i -le 25 ]; do echo "progress line $i"; i=$((i + 1)); done
          echo partial > partial.txt
          (sleep 2; echo late > late-background.txt) &
          sleep 2
          echo late > late.txt
        fi
        test -f partial.txt
        """
      )

      log =
        capture_log(fn ->
          assert {:ok, workspace} = Workspace.create_for_issue("MT-RETRY")
          assert File.read!(runs_file) == "run\nrun\n"
          refute File.exists?(Path.join(Path.dirname(workspace), ".MT-RETRY.after_create_pending"))

          # The timed-out shell and its background job were stopped, so neither got
          # past its sleep.
          Process.sleep(1_500)
          refute File.exists?(Path.join(workspace, "late.txt"))
          refute File.exists?(Path.join(workspace, "late-background.txt"))
        end)

      assert log =~ "Workspace hook timed out hook=after_create"
      assert log =~ "timeout_ms=1000"
      assert log =~ "Retrying workspace hook after timeout hook=after_create"
      assert log =~ ~s(output_tail="progress line 6\\nprogress line 7)
      assert log =~ ~s(progress line 25")
      refute log =~ "progress line 5\\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace fails when after_create times out on its retry too, and the next run runs it again" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join([workspace_root, "default", "MT-TIMEOUT"])
    pending_marker = Path.join([workspace_root, "default", ".MT-TIMEOUT.after_create_pending"])
    runs_file = Path.join(test_root, "after_create.runs")

    try do
      File.mkdir_p!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create_timeout_ms: 200,
        hook_after_create: "echo run >> #{runs_file}; echo partial > partial.txt; sleep 2"
      )

      log =
        capture_log(fn ->
          assert {:error, {:workspace_hook_timeout, "after_create", 200}} =
                   Workspace.create_for_issue("MT-TIMEOUT")
        end)

      assert File.read!(runs_file) == "run\nrun\n"
      assert File.read!(Path.join(workspace, "partial.txt")) == "partial\n"
      assert File.exists?(pending_marker)
      assert log =~ "timeout_ms=200 output_tail="

      # The next run finds the workspace but runs the unfinished hook again in it.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo run >> #{runs_file}; test -f partial.txt"
      )

      log =
        capture_log(fn ->
          assert {:ok, reused_workspace} = Workspace.create_for_issue("MT-TIMEOUT")
          assert Path.basename(reused_workspace) == "MT-TIMEOUT"
        end)

      assert File.read!(runs_file) == "run\nrun\nrun\n"
      refute File.exists?(pending_marker)
      assert log =~ "Running workspace hook an earlier run left unfinished hook=after_create"

      # Once it has succeeded, a reused workspace doesn't run it again.
      assert {:ok, _workspace} = Workspace.create_for_issue("MT-TIMEOUT")
      assert File.read!(runs_file) == "run\nrun\nrun\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "removing a workspace whose after_create failed removes its pending marker too" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-elixir-workspace-hook-marker-#{System.unique_integer([:positive])}")
    pending_marker = Path.join([workspace_root, "default", ".MT-MARKER.after_create_pending"])

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "exit 3"
      )

      capture_log(fn ->
        assert {:error, {:workspace_hook_failed, "after_create", 3, _output}} = Workspace.create_for_issue("MT-MARKER")
      end)

      assert File.exists?(pending_marker)

      assert {:ok, _removed_paths} = Workspace.remove(Path.join([workspace_root, "default", "MT-MARKER"]))
      refute File.exists?(pending_marker)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "the workspace sweep does not take an after_create pending marker for a workspace" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-elixir-workspace-hook-sweep-#{System.unique_integer([:positive])}")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "exit 3"
      )

      capture_log(fn ->
        assert {:error, {:workspace_hook_failed, "after_create", 3, _output}} = Workspace.create_for_issue("MT-SWEEP")
      end)

      assert File.exists?(Path.join([workspace_root, "default", ".MT-SWEEP.after_create_pending"]))
      assert {:ok, [%{name: "MT-SWEEP"}]} = Workspace.local_workspace_entries()
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace reports each hook run to on_hook, with the hook's timeout" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-elixir-workspace-on-hook-#{System.unique_integer([:positive])}")
    test_pid = self()
    on_hook = &send(test_pid, {:hook, &1})

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "true",
        hook_before_run: "true"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-ON-HOOK", nil, nil, on_hook: on_hook)
      assert_received {:hook, {:started, "after_create", 600_000}}
      assert_received {:hook, {:finished, "after_create"}}

      assert :ok = Workspace.run_before_run_hook(workspace, "MT-ON-HOOK", nil, on_hook: on_hook)
      assert_received {:hook, {:started, "before_run", 60_000}}
      assert_received {:hook, {:finished, "before_run"}}
    after
      File.rm_rf(workspace_root)
    end
  end

  test "a run stopped while after_create runs stops the hook and what it started" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-workspace-hook-owner-exit-#{System.unique_integer([:positive])}")
    started_file = Path.join(test_root, "started")

    try do
      File.mkdir_p!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(test_root, "workspaces"),
        hook_after_create: """
        (sleep 2; echo late > #{test_root}/late-background.txt) &
        touch #{started_file}
        sleep 2
        echo late > #{test_root}/late.txt
        """
      )

      capture_log(fn ->
        run = spawn(fn -> Workspace.create_for_issue("MT-STOPPED") end)
        assert wait_for_file(started_file, 5_000)
        Process.exit(run, :kill)

        # Both would have written by now had they outlived the run.
        Process.sleep(2_500)
      end)

      refute File.exists?(Path.join(test_root, "late.txt"))
      refute File.exists?(Path.join(test_root, "late-background.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "after_create gets ten minutes, or a longer hooks.timeout_ms, unless after_create_timeout_ms is set" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Config.settings!().hooks.after_create_timeout_ms == nil
    assert Schema.Hooks.after_create_timeout_ms(Config.settings!().hooks) == 600_000

    write_workflow_file!(Workflow.workflow_file_path(), hook_timeout_ms: 900_000)
    assert Schema.Hooks.after_create_timeout_ms(Config.settings!().hooks) == 900_000

    write_workflow_file!(Workflow.workflow_file_path(), hook_timeout_ms: 900_000, hook_after_create_timeout_ms: 120_000)
    assert Schema.Hooks.after_create_timeout_ms(Config.settings!().hooks) == 120_000

    write_workflow_file!(Workflow.workflow_file_path(), hook_after_create_timeout_ms: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "after_create_timeout_ms"
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join([workspace_root, "default", "MT-608"])
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join([workspace_root, "default", "S_1"])
      untouched_workspace = Path.join([workspace_root, "default", "OTHER-#{System.unique_integer([:positive])}"])

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "local before_remove hook receives canonical repo and branch env from worktree settings" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-before-remove-env-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      marker = Path.join(test_root, "before_remove_env.log")

      create_primary_repo!(primary_repo)
      git!(primary_repo, ["remote", "add", "origin", "git@github.com:acme/symphony.git"])
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        hook_before_remove: "printf '%s\\n%s\\n' \"$SYMPHONY_REPO\" \"$SYMPHONY_BRANCH\" > \"#{marker}\""
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOK-ENV")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOK-ENV")
      refute File.exists?(workspace)
      assert File.read!(marker) == "acme/symphony\nauto/MT-HOOK-ENV\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "run hooks receive verification port env when provided" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-verification-env-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: "printf '%s' \"$SYMPHONY_VERIFICATION_PORT\" > before-port.txt",
        hook_after_run: "printf '%s' \"$SYMPHONY_VERIFICATION_PORT\" > after-port.txt"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-PORT-ENV")
      env = [{"SYMPHONY_VERIFICATION_PORT", "4077"}]

      assert :ok = Workspace.run_before_run_hook(workspace, "MT-PORT-ENV", nil, env: env)
      assert :ok = Workspace.run_after_run_hook(workspace, "MT-PORT-ENV", nil, env: env)

      assert File.read!(Path.join(workspace, "before-port.txt")) == "4077"
      assert File.read!(Path.join(workspace, "after-port.txt")) == "4077"
    after
      File.rm_rf(test_root)
    end
  end

  test "before_remove hook receives canonical repo and branch env" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-before-remove-env-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      env_marker = Path.join(test_root, "before-remove-env.log")

      create_primary_repo!(primary_repo)
      git!(primary_repo, ["remote", "add", "origin", "git@github.com:acme/symphony.git"])

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        hook_before_remove: "printf '%s\\n%s\\n' \"$SYMPHONY_REPO\" \"$SYMPHONY_BRANCH\" > \"#{env_marker}\""
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOK-ENV")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOK-ENV")

      assert File.read!(env_marker) == "acme/symphony\nauto/MT-HOOK-ENV\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "before_remove hook receives the removal reason and the issue state" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-before-remove-reason-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      marker = Path.join(test_root, "before-remove-reason.log")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "printf '%s|%s\\n' \"$SYMPHONY_REMOVE_REASON\" \"$SYMPHONY_ISSUE_STATE\" >> \"#{marker}\""
      )

      removals = [
        %{id: "issue-done", identifier: "MT-REASON", remove_reason: :terminal, state: "Done"},
        %{id: "issue-stop", identifier: "MT-REASON", remove_reason: :stop},
        "MT-REASON"
      ]

      for removal <- removals do
        assert {:ok, _workspace} = Workspace.create_for_issue("MT-REASON")
        assert :ok = Workspace.remove_issue_workspaces(removal)
      end

      assert File.read!(marker) == "terminal|Done\nstop|\ncleanup|\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "run hooks use repo_key option for identifier-only context" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-repo-key-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      api_repo = Path.join(test_root, "api")
      primary_marker = Path.join(test_root, "primary-after.log")
      api_marker = Path.join(test_root, "api-after.log")

      File.mkdir_p!(workspace)
      File.mkdir_p!(api_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        hook_after_run: "printf primary > #{primary_marker}",
        repos: [
          %{
            "name" => "default",
            "path" => Path.dirname(Workflow.workflow_file_path()),
            "workflow" => Path.basename(Workflow.workflow_file_path()),
            "team" => "Test",
            "default" => true
          },
          %{
            "name" => "api",
            "path" => api_repo,
            "workflow" => "WORKFLOW.md",
            "team" => "Test",
            "labels" => ["api"]
          }
        ]
      )

      File.write!(Path.join(api_repo, "WORKFLOW.md"), """
      ---
      hooks:
        after_run: printf api > #{api_marker}
      ---
      API prompt
      """)

      assert :ok = Workspace.run_after_run_hook(workspace, "MT-API", nil, repo_key: "api")

      assert File.read!(api_marker) == "api"
      refute File.exists?(primary_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace cleanup logs removal failures while keeping fire-and-forget API" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-remove-log-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.write!(Path.join(outside_workspace, "marker.txt"), "keep\n")
      escape_workspace = Path.join([workspace_root, "default", "MT-ESCAPE"])
      File.mkdir_p!(Path.dirname(escape_workspace))
      File.ln_s!(outside_workspace, escape_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      log =
        capture_log(fn ->
          assert :ok = Workspace.remove_issue_workspaces("MT-ESCAPE")
        end)

      assert log =~ "Workspace removal failed"
      assert log =~ "issue_identifier=MT-ESCAPE"
      assert log =~ "workspace_outside_root"
      assert File.exists?(Path.join(outside_workspace, "marker.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1",
        hook_timeout_ms: 10
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  defp wait_for_file(path, timeout_ms) do
    cond do
      File.exists?(path) ->
        true

      timeout_ms <= 0 ->
        false

      true ->
        Process.sleep(20)
        wait_for_file(path, timeout_ms - 20)
    end
  end
end
