defmodule SymphonyElixir.WorkspaceRemoteTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.WorkspaceTestSupport

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "/remote/home/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/default/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_repo: "git@github.com:acme/symphony.git",
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "/remote/home/.symphony-remote-workspaces/default/MT-SSH-WS"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "export SYMPHONY_REPO="
      assert trace =~ "acme/symphony"
      assert trace =~ "export SYMPHONY_BRANCH="
      assert trace =~ "auto/MT-SSH-WS"
      assert trace =~ ~r/export SYMPHONY_REMOVE_REASON=\S*cleanup/
      assert trace =~ "export SYMPHONY_ISSUE_STATE="
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  test "remote after_create timeouts are named after the hook and not retried" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-remote-hook-timeout-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      runs_file = Path.join(test_root, "after_create.runs")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_path = "/remote/home/.symphony-remote-workspaces/default/MT-SSH-TIMEOUT"

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      # Stands in for the worker: the first after_create hangs, a second would succeed.
      File.write!(fake_ssh, """
      #!/bin/sh
      case "$*" in
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
        *"remote-setup"*)
          echo run >> #{runs_file}
          if [ "$(wc -l < #{runs_file})" -eq 1 ]; then
            echo "remote setup still resolving"
            sleep 2
          fi
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/home/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-01"],
        hook_after_create_timeout_ms: 1_000,
        hook_after_create: "remote-setup"
      )

      log =
        capture_log(fn ->
          assert {:error, {:workspace_hook_timeout, "after_create", 1_000}} =
                   Workspace.create_for_issue("MT-SSH-TIMEOUT", "worker-01")
        end)

      assert File.read!(runs_file) == "run\n"
      assert log =~ "Workspace hook timed out hook=after_create"
      assert log =~ ~s(worker_host=worker-01 timeout_ms=1000 output_tail="remote setup still resolving")
      refute log =~ "Retrying workspace hook after timeout"
    after
      File.rm_rf(test_root)
    end
  end

  test "remote worktree lifecycle uses host-local repository paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-worktree-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "/remote/home/.symphony-remote-workspaces"
      workspace_repo = "~/primary-clone"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WT"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: workspace_repo,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_remove: "echo before-remove"
      )

      assert :ok = Config.validate!()
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WT", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WT", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "~/primary-clone"
      assert trace =~ "${repo#~/}"
      assert trace =~ "symphony_git_raw() { GIT_CONFIG_GLOBAL="
      assert trace =~ "symphony_git \"$repo\" fetch --upload-pack=git-upload-pack origin"
      assert trace =~ "*\"cannot lock ref\"*) sleep 1; symphony_git \"$repo\" fetch --upload-pack=git-upload-pack origin ;;"
      assert trace =~ "symphony_git \"$repo\" worktree add"
      assert trace =~ "symphony_worktree_lock; branch_owner="
      assert trace =~ "symphony-worktree-add.lock"
      assert trace =~ "trap symphony_worktree_unlock EXIT"
      assert trace =~ "fi; symphony_worktree_unlock"
      assert trace =~ "export SYMPHONY_BRANCH="
      assert trace =~ "auto/MT-SSH-WT"
      assert trace =~ "symphony_configured_repo="
      assert trace =~ "~/primary-clone"
      assert trace =~ "symphony_git \"$symphony_configured_repo\" remote get-url origin"
      refute trace =~ "git -C \"$symphony_configured_repo\" remote get-url"
      assert trace =~ "workspace_worktree_list_failed"
      assert trace =~ "auto/MT-SSH-WT"
      assert trace =~ "symphony_git \"$repo\" worktree remove --force"
      assert trace =~ "workspace_branch_delete_skipped"
      # Only the dispatch refuses an unregistered directory; the removal deletes it.
      assert length(String.split(trace, "workspace_not_registered_worktree")) == 2
      refute trace =~ "git clone"
    after
      File.rm_rf(test_root)
    end
  end

  test "remote worktree creation surfaces missing primary clone errors" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-worktree-missing-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
    end)

    try do
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      echo "workspace_repo_missing: /remote/missing-primary"
      exit 41
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        workspace_strategy: "worktree",
        workspace_repo: "/remote/missing-primary",
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 41, output}} =
               Workspace.create_for_issue("MT-MISSING-REMOTE", "worker-01")

      assert output =~ "workspace_repo_missing: /remote/missing-primary"
    after
      File.rm_rf(test_root)
    end
  end

  test "remote workspace setup rejects an existing symlink at the issue workspace path" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      outside_root = Path.join(ctx.test_root, "outside")
      symlink_path = Path.join([workspace_root, "default", "MT-SYM"])

      File.mkdir_p!(Path.dirname(symlink_path))
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 51, output}} =
               Workspace.create_for_issue("MT-SYM", "worker-01")

      assert output =~ "workspace_symlink_rejected: #{symlink_path}"
      assert {:ok, ^outside_root} = File.read_link(symlink_path)
    end)
  end

  test "remote workspace setup rejects when physical workspace escapes root via a parent symlink" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      outside_root = Path.join(ctx.test_root, "outside")
      parent_link = Path.join(workspace_root, "default")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, parent_link)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 53, output}} =
               Workspace.create_for_issue("MT-OUT", "worker-01")

      assert output =~ "workspace_outside_root:"
      assert output =~ outside_root
      assert output =~ "not under #{workspace_root}"
      refute File.exists?(Path.join(outside_root, "MT-OUT"))
    end)
  end

  test "remote workspace setup does not delete an existing non-directory through a parent symlink" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      outside_root = Path.join(ctx.test_root, "outside")
      parent_link = Path.join(workspace_root, "default")
      escaped_file = Path.join(outside_root, "MT-STALE")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.write!(escaped_file, "keep\n")
      File.ln_s!(outside_root, parent_link)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 53, output}} =
               Workspace.create_for_issue("MT-STALE", "worker-01")

      assert output =~ "workspace_outside_root:"
      assert output =~ outside_root
      assert File.read!(escaped_file) == "keep\n"
    end)
  end

  test "remote workspace setup accepts an existing directory under the root" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      workspace_path = Path.join([workspace_root, "default", "MT-OK"])

      File.mkdir_p!(workspace_path)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-OK", "worker-01")
      assert File.dir?(workspace_path)
    end)
  end

  test "remote workspace setup creates a new directory under the root and returns its canonical path" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      workspace_path = Path.join([workspace_root, "default", "MT-NEW"])

      File.mkdir_p!(workspace_root)
      refute File.exists?(workspace_path)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-NEW", "worker-01")
      assert File.dir?(workspace_path)
    end)
  end

  test "remote workspace setup canonicalizes a symlinked root before returning the workspace" do
    with_real_exec_fake_ssh(fn ctx ->
      actual_root = Path.join(ctx.test_root, "actual-wsroot")
      linked_root = Path.join(ctx.test_root, "linked-wsroot")
      expected_workspace = Path.join([actual_root, "default", "MT-LINK"])

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: linked_root,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:ok, ^expected_workspace} = Workspace.create_for_issue("MT-LINK", "worker-01")
      assert File.dir?(expected_workspace)
    end)
  end

  test "remote workspace setup fails closed when the configured root cannot be created" do
    with_real_exec_fake_ssh(fn ctx ->
      blocking_file = Path.join(ctx.test_root, "not-a-directory")
      workspace_root = Path.join(blocking_file, "wsroot")

      File.write!(blocking_file, "blocks mkdir -p\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 50, output}} =
               Workspace.create_for_issue("MT-BAD-ROOT", "worker-01")

      assert output =~ "workspace_root_unreadable: #{workspace_root}"
    end)
  end

  test "remote after_create that failed runs again on the next run, and not once it has succeeded" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      workspace_path = Path.join([workspace_root, "default", "MT-SSH-AC"])
      pending_marker = Path.join([workspace_root, "default", ".MT-SSH-AC.after_create_pending"])
      runs_file = Path.join(ctx.test_root, "after_create.runs")
      setup_ready = Path.join(ctx.test_root, "setup-ready")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "echo run >> #{runs_file}\ntest -f #{setup_ready}"
      )

      capture_log(fn ->
        assert {:error, {:workspace_hook_failed, "after_create", 1, _output}} =
                 Workspace.create_for_issue("MT-SSH-AC", "worker-01")
      end)

      # The hook's shell left its pid in the marker beside the workspace, and is gone.
      assert File.dir?(workspace_path)
      assert File.read!(pending_marker) =~ ~r/^\d+\n$/

      File.write!(setup_ready, "")

      log =
        capture_log(fn ->
          assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-AC", "worker-01")
        end)

      assert log =~ "Running workspace hook an earlier run left unfinished hook=after_create"
      assert log =~ "worker_host=worker-01"
      assert File.read!(runs_file) == "run\nrun\n"
      refute File.exists?(pending_marker)

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-AC", "worker-01")
      assert File.read!(runs_file) == "run\nrun\n"
    end)
  end

  test "remote after_create whose ssh connection failed before it ran runs on the next run" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      workspace_path = Path.join([workspace_root, "default", "MT-SSH-DROP"])
      pending_marker = Path.join([workspace_root, "default", ".MT-SSH-DROP.after_create_pending"])
      runs_file = Path.join(ctx.test_root, "after_create.runs")
      ssh_down = Path.join(ctx.test_root, "ssh-down")

      # The connection for the hook drops (ssh exits 255) while `ssh-down` exists.
      write_real_exec_fake_ssh!(Path.join(ctx.test_root, "ssh-real"))

      File.write!(Path.join(ctx.test_root, "ssh"), """
      #!/usr/bin/env bash
      case "${@: -1}" in
        *after_create_status*) [ -f #{ssh_down} ] && exit 255 ;;
      esac
      exec #{Path.join(ctx.test_root, "ssh-real")} "$@"
      """)

      File.write!(ssh_down, "")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "echo run >> #{runs_file}"
      )

      capture_log(fn ->
        assert {:error, {:workspace_hook_failed, "after_create", 255, _output}} =
                 Workspace.create_for_issue("MT-SSH-DROP", "worker-01")
      end)

      # The prepare script marked the workspace it created; the hook never ran.
      assert File.dir?(workspace_path)
      assert File.read!(pending_marker) == ""
      refute File.exists?(runs_file)

      File.rm!(ssh_down)

      log =
        capture_log(fn ->
          assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-DROP", "worker-01")
        end)

      assert log =~ "Running workspace hook an earlier run left unfinished hook=after_create"
      assert File.read!(runs_file) == "run\n"
      refute File.exists?(pending_marker)
    end)
  end

  test "remote workspace setup waits for an after_create still running on the worker" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      workspace_path = Path.join([workspace_root, "default", "MT-SSH-BUSY"])
      pending_marker = Path.join([workspace_root, "default", ".MT-SSH-BUSY.after_create_pending"])
      runs_file = Path.join(ctx.test_root, "after_create.runs")

      # A hook an earlier run timed out on, still running: this VM stands in for its shell.
      File.mkdir_p!(workspace_path)
      File.write!(pending_marker, "#{System.pid()}\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"],
        hook_after_create: "echo run >> #{runs_file}"
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 46, output}} =
               Workspace.create_for_issue("MT-SSH-BUSY", "worker-01")

      assert output =~ "workspace_after_create_still_running: pid #{System.pid()}"
      refute File.exists?(runs_file)
      assert File.exists?(pending_marker)
    end)
  end

  test "remote workspace remove rejects parent symlink escape before hook or delete" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      outside_root = Path.join(ctx.test_root, "outside")
      parent_link = Path.join(workspace_root, "default")
      requested_workspace = Path.join([workspace_root, "default", "MT-RM-OUT"])
      escaped_workspace = Path.join(outside_root, "MT-RM-OUT")
      hook_marker = Path.join(ctx.test_root, "before-remove-ran")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(escaped_workspace)
      File.write!(Path.join(escaped_workspace, "keep.txt"), "keep\n")
      File.ln_s!(outside_root, parent_link)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01"],
        hook_before_remove: "printf ran > #{hook_marker}"
      )

      assert {:error, {:workspace_remove_failed, "worker-01", 53, output}, ""} =
               Workspace.remove(requested_workspace, "worker-01")

      assert output =~ "workspace_outside_root:"
      assert output =~ outside_root
      refute File.exists?(hook_marker)
      assert File.read!(Path.join(escaped_workspace, "keep.txt")) == "keep\n"
    end)
  end
end
