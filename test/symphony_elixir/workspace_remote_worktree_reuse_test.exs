defmodule SymphonyElixir.WorkspaceRemoteWorktreeReuseTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.WorkspaceTestSupport

  test "remote worktree setup rejects an existing symlink at the issue workspace path" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      outside_root = Path.join(ctx.test_root, "outside")
      symlink_path = Path.join([workspace_root, "default", "MT-WT-SYM"])

      create_primary_repo!(primary_repo)
      File.mkdir_p!(Path.dirname(symlink_path))
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 51, output}} =
               Workspace.create_for_issue("MT-WT-SYM", "worker-01")

      assert output =~ "workspace_symlink_rejected: #{symlink_path}"
      assert {:ok, ^outside_root} = File.read_link(symlink_path)
    end)
  end

  test "remote worktree setup rejects when physical workspace escapes root via a parent symlink" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      outside_root = Path.join(ctx.test_root, "outside")
      parent_link = Path.join(workspace_root, "default")

      create_primary_repo!(primary_repo)
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, parent_link)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 53, output}} =
               Workspace.create_for_issue("MT-WT-OUT", "worker-01")

      assert output =~ "workspace_outside_root:"
      assert output =~ outside_root
      assert output =~ "not under #{workspace_root}"
      refute File.exists?(Path.join(outside_root, "MT-WT-OUT"))
    end)
  end

  test "remote worktree setup creates and reuses a registered worktree under the root" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      workspace_path = Path.join([workspace_root, "default", "MT-WT-OK"])

      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-WT-OK", "worker-01")
      assert File.read!(Path.join(workspace_path, "README.md")) == "initial\n"
      assert String.trim(git!(workspace_path, ["branch", "--show-current"])) == "auto/MT-WT-OK"

      File.write!(Path.join(workspace_path, "README.md"), "local progress\n")

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-WT-OK", "worker-01")
      assert File.read!(Path.join(workspace_path, "README.md")) == "local progress\n"
      assert git_branch_exists?(primary_repo, "auto/MT-WT-OK")
    end)
  end

  test "remote worktree creation, reuse and removal run no filter driver or hook from the repo's config" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      workspace_path = Path.join([workspace_root, "default", "MT-WT-FILTER"])
      proof = Path.join(ctx.test_root, "SYMPHONY_FILTER_PWNED")
      hook_proof = Path.join(ctx.test_root, "SYMPHONY_HOOK_PWNED")

      create_primary_repo!(primary_repo)
      git!(primary_repo, ["checkout", "-b", "agent/filter"])
      File.write!(Path.join(primary_repo, ".gitattributes"), "*.txt filter=evil\n*.md filter=included\n")
      File.write!(Path.join(primary_repo, "notes.txt"), "stored\n")
      File.write!(Path.join(primary_repo, "notes.md"), "stored\n")
      git!(primary_repo, ["add", ".gitattributes", "notes.txt", "notes.md"])
      git!(primary_repo, ["commit", "-m", "agent attributes"])
      git!(primary_repo, ["checkout", "main"])

      # Drivers an agent's branch picks, set where agents commit: the shared repo's config, and a
      # file it includes only on the agent's branch, by a path relative to the config.
      git!(primary_repo, ["config", "filter.evil.smudge", "touch '#{proof}'; cat"])
      git!(primary_repo, ["config", "filter.evil.clean", "touch '#{proof}'; cat"])
      git!(primary_repo, ["config", "filter.evil.required", "true"])
      File.write!(Path.join([primary_repo, ".git", "drivers"]), "[filter \"included\"]\n\tsmudge = touch '#{proof}'; cat\n")
      git!(primary_repo, ["config", "includeIf.onbranch:agent/**.path", "drivers"])

      hook = Path.join([primary_repo, ".git", "hooks", "post-checkout"])
      File.write!(hook, "#!/bin/sh\ntouch '#{hook_proof}'\n")
      File.chmod!(hook, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"]
      )

      issue = %Issue{identifier: "MT-WT-FILTER", workspace_branch: "agent/filter", workspace_base_ref: "agent/filter"}

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")
      assert File.read!(Path.join(workspace_path, "notes.txt")) == "stored\n"
      assert File.read!(Path.join(workspace_path, "notes.md")) == "stored\n"
      refute File.exists?(proof)
      refute File.exists?(hook_proof)

      # Reusing a dirty worktree backs it up (`status`, `add -A`) before `reset --hard` and `checkout`.
      head = String.trim(git!(workspace_path, ["rev-parse", "HEAD"]))
      File.write!(Path.join(workspace_path, "notes.txt"), "agent edit\n")

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")
      assert File.read!(Path.join(workspace_path, "notes.txt")) == "stored\n"
      assert git!(workspace_path, ["show", "refs/symphony/orphaned/#{head}:notes.txt"]) == "agent edit\n"
      refute File.exists?(proof)
      refute File.exists?(hook_proof)

      File.rm!(Path.join(workspace_path, "notes.md"))
      assert {_output, 0} = System.cmd("git", ["-C", workspace_path, "checkout", "--", "notes.md"], stderr_to_stdout: true)
      assert File.exists?(proof), "plain git runs the included driver, so the setup above is a real attack"
      File.rm!(proof)

      assert :ok = Workspace.remove_issue_workspaces("MT-WT-FILTER", "worker-01")
      refute File.exists?(workspace_path)
      refute File.exists?(proof)
    end)
  end

  test "remote worktree setup refuses to run git when the repo config names a driver -c can't turn off" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      workspace_path = Path.join([workspace_root, "default", "MT-WT-EQUALS"])

      create_primary_repo!(primary_repo)
      git!(primary_repo, ["config", "filter.a=b.smudge", "cat"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 128, output}} =
               Workspace.create_for_issue("MT-WT-EQUALS", "worker-01")

      assert output =~ ~s(symphony: refusing to run git, the repo config defines filter driver "a=b")
      refute File.exists?(workspace_path)
    end)
  end

  test "remote worktree setup reads no global git config on the worker" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      origin_repo = Path.join(ctx.test_root, "origin.git")
      global_config = Path.join(ctx.test_root, "global.gitconfig")
      upload_pack = Path.join(ctx.test_root, "upload-pack")
      proof = Path.join(ctx.test_root, "SYMPHONY_GLOBAL_CONFIG_READ")
      previous_global = System.get_env("GIT_CONFIG_GLOBAL")
      on_exit(fn -> restore_env("GIT_CONFIG_GLOBAL", previous_global) end)

      create_primary_repo!(primary_repo, origin_repo)
      File.write!(upload_pack, "#!/bin/sh\ntouch '#{proof}'\nexec git upload-pack \"$@\"\n")
      File.chmod!(upload_pack, 0o755)
      File.write!(global_config, "[remote \"origin\"]\n\tuploadpack = #{upload_pack}\n")
      # The worker's script inherits this env through the fake `ssh`.
      System.put_env("GIT_CONFIG_GLOBAL", global_config)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: true,
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-WT-GLOBAL", "worker-01")
      refute File.exists?(proof)

      assert {_output, 0} = System.cmd("git", ["-C", primary_repo, "fetch", "origin"], stderr_to_stdout: true)
      assert File.exists?(proof), "plain git reads the global config, so the setup above is a real attack"
    end)
  end

  test "remote worktree reuse resets an existing PR worktree to explicit base ref" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      origin_repo = Path.join(ctx.test_root, "origin.git")
      peer_repo = Path.join(ctx.test_root, "peer")
      workspace_path = Path.join([workspace_root, "default", "PR-REMOTE-RESET"])

      create_primary_repo!(primary_repo, origin_repo)
      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      git!(peer_repo, ["checkout", "-b", "feature/pr-remote-reset"])
      File.write!(Path.join(peer_repo, "pr.txt"), "initial remote head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "initial remote head"])
      git!(peer_repo, ["push", "origin", "feature/pr-remote-reset"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: true,
        worker_ssh_hosts: ["worker-01"]
      )

      issue = %Issue{
        identifier: "PR-REMOTE-RESET",
        workspace_branch: "feature/pr-remote-reset",
        workspace_base_ref: "origin/feature/pr-remote-reset"
      }

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")
      assert File.read!(Path.join(workspace_path, "pr.txt")) == "initial remote head\n"

      File.write!(Path.join(peer_repo, "pr.txt"), "advanced remote head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "advance remote head"])
      git!(peer_repo, ["push", "origin", "feature/pr-remote-reset"])

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")
      assert File.read!(Path.join(workspace_path, "pr.txt")) == "advanced remote head\n"
      assert String.trim(git!(workspace_path, ["branch", "--show-current"])) == "feature/pr-remote-reset"
    end)
  end

  test "remote worktree reuse switches stale branch to requested PR head branch" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      origin_repo = Path.join(ctx.test_root, "origin.git")
      peer_repo = Path.join(ctx.test_root, "peer")
      workspace_path = Path.join([workspace_root, "default", "PR-REMOTE-BRANCH"])

      create_primary_repo!(primary_repo, origin_repo)
      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)

      git!(peer_repo, ["checkout", "-b", "feature/remote-stale"])
      File.write!(Path.join(peer_repo, "stale.txt"), "stale remote branch\n")
      git!(peer_repo, ["add", "stale.txt"])
      git!(peer_repo, ["commit", "-m", "stale remote branch"])
      git!(peer_repo, ["push", "origin", "feature/remote-stale"])

      git!(peer_repo, ["checkout", "main"])
      git!(peer_repo, ["checkout", "-b", "feature/remote-requested"])
      File.write!(Path.join(peer_repo, "pr.txt"), "requested remote head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "requested remote branch"])
      git!(peer_repo, ["push", "origin", "feature/remote-requested"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: true,
        worker_ssh_hosts: ["worker-01"]
      )

      stale_issue = %Issue{
        identifier: "PR-REMOTE-BRANCH",
        workspace_branch: "feature/remote-stale",
        workspace_base_ref: "origin/feature/remote-stale"
      }

      issue = %Issue{
        identifier: "PR-REMOTE-BRANCH",
        workspace_branch: "feature/remote-requested",
        workspace_base_ref: "origin/feature/remote-requested"
      }

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(stale_issue, "worker-01")
      assert File.read!(Path.join(workspace_path, "stale.txt")) == "stale remote branch\n"
      assert String.trim(git!(workspace_path, ["branch", "--show-current"])) == "feature/remote-stale"

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")
      assert File.read!(Path.join(workspace_path, "pr.txt")) == "requested remote head\n"
      refute File.exists?(Path.join(workspace_path, "stale.txt"))
      assert String.trim(git!(workspace_path, ["branch", "--show-current"])) == "feature/remote-requested"

      assert String.trim(git!(workspace_path, ["rev-parse", "HEAD"])) ==
               String.trim(git!(primary_repo, ["rev-parse", "origin/feature/remote-requested"]))
    end)
  end

  test "remote worktree reuse backs up a dirty explicit-base worktree and resets to head" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      origin_repo = Path.join(ctx.test_root, "origin.git")
      peer_repo = Path.join(ctx.test_root, "peer")
      workspace_path = Path.join([workspace_root, "default", "PR-REMOTE-DIRTY"])

      create_primary_repo!(primary_repo, origin_repo)
      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      git!(peer_repo, ["checkout", "-b", "feature/pr-remote-dirty"])
      File.write!(Path.join(peer_repo, "pr.txt"), "initial remote head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "initial remote head"])
      git!(peer_repo, ["push", "origin", "feature/pr-remote-dirty"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: true,
        worker_ssh_hosts: ["worker-01"]
      )

      issue = %Issue{
        identifier: "PR-REMOTE-DIRTY",
        workspace_branch: "feature/pr-remote-dirty",
        workspace_base_ref: "origin/feature/pr-remote-dirty"
      }

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")
      first_sha = String.trim(git!(workspace_path, ["rev-parse", "HEAD"]))
      File.write!(Path.join(workspace_path, "pr.txt"), "dirty remote edit\n")

      File.write!(Path.join(peer_repo, "pr.txt"), "advanced remote head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "advance remote head"])
      git!(peer_repo, ["push", "origin", "feature/pr-remote-dirty"])

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")

      # The reset adopts the advanced remote head instead of failing.
      assert File.read!(Path.join(workspace_path, "pr.txt")) == "advanced remote head\n"

      assert String.trim(git!(workspace_path, ["rev-parse", "HEAD"])) ==
               String.trim(git!(workspace_path, ["rev-parse", "origin/feature/pr-remote-dirty"]))

      # The dropped dirty edit is recoverable from the orphan backup snapshot.
      backup_ref = "refs/symphony/orphaned/#{first_sha}"
      assert String.trim(git!(workspace_path, ["rev-parse", "#{backup_ref}^"])) == first_sha

      assert String.trim(git!(workspace_path, ["show", "#{backup_ref}:pr.txt"])) ==
               "dirty remote edit"
    end)
  end

  test "remote worktree reuse backs up unpushed commits from an explicit-base worktree and resets to head" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      origin_repo = Path.join(ctx.test_root, "origin.git")
      peer_repo = Path.join(ctx.test_root, "peer")
      workspace_path = Path.join([workspace_root, "default", "PR-REMOTE-LOCAL-COMMITS"])

      create_primary_repo!(primary_repo, origin_repo)
      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      git!(peer_repo, ["checkout", "-b", "feature/pr-remote-local-commits"])
      File.write!(Path.join(peer_repo, "pr.txt"), "initial remote head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "initial remote head"])
      git!(peer_repo, ["push", "origin", "feature/pr-remote-local-commits"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: true,
        worker_ssh_hosts: ["worker-01"]
      )

      issue = %Issue{
        identifier: "PR-REMOTE-LOCAL-COMMITS",
        workspace_branch: "feature/pr-remote-local-commits",
        workspace_base_ref: "origin/feature/pr-remote-local-commits"
      }

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")
      File.write!(Path.join(workspace_path, "local.txt"), "remote local commit\n")
      git!(workspace_path, ["add", "local.txt"])
      git!(workspace_path, ["commit", "-m", "remote local commit"])
      local_commit = String.trim(git!(workspace_path, ["rev-parse", "HEAD"]))

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")

      # The branch is reset to the remote head, dropping the unpushed commit.
      assert String.trim(git!(workspace_path, ["rev-parse", "HEAD"])) ==
               String.trim(git!(workspace_path, ["rev-parse", "origin/feature/pr-remote-local-commits"]))

      refute File.exists?(Path.join(workspace_path, "local.txt"))

      # The unpushed commit is recoverable from the orphan backup snapshot.
      backup_ref = "refs/symphony/orphaned/#{local_commit}"
      assert String.trim(git!(workspace_path, ["rev-parse", "#{backup_ref}^"])) == local_commit

      assert String.trim(git!(workspace_path, ["show", "#{backup_ref}:local.txt"])) ==
               "remote local commit"
    end)
  end

  test "remote worktree reuse backs up colliding untracked files before resetting an explicit-base worktree" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      origin_repo = Path.join(ctx.test_root, "origin.git")
      peer_repo = Path.join(ctx.test_root, "peer")
      workspace_path = Path.join([workspace_root, "default", "PR-REMOTE-UNTRACKED"])

      create_primary_repo!(primary_repo, origin_repo)
      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)

      git!(peer_repo, ["checkout", "-b", "feature/remote-stale-untracked"])
      File.write!(Path.join(peer_repo, "stale.txt"), "stale remote branch\n")
      git!(peer_repo, ["add", "stale.txt"])
      git!(peer_repo, ["commit", "-m", "stale remote branch"])
      git!(peer_repo, ["push", "origin", "feature/remote-stale-untracked"])

      git!(peer_repo, ["checkout", "main"])
      git!(peer_repo, ["checkout", "-b", "feature/remote-untracked-collision"])
      File.write!(Path.join(peer_repo, "collision.txt"), "requested remote head\n")
      git!(peer_repo, ["add", "collision.txt"])
      git!(peer_repo, ["commit", "-m", "requested remote branch"])
      git!(peer_repo, ["push", "origin", "feature/remote-untracked-collision"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: true,
        worker_ssh_hosts: ["worker-01"]
      )

      stale_issue = %Issue{
        identifier: "PR-REMOTE-UNTRACKED",
        workspace_branch: "feature/remote-stale-untracked",
        workspace_base_ref: "origin/feature/remote-stale-untracked"
      }

      issue = %Issue{
        identifier: "PR-REMOTE-UNTRACKED",
        workspace_branch: "feature/remote-untracked-collision",
        workspace_base_ref: "origin/feature/remote-untracked-collision"
      }

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(stale_issue, "worker-01")
      stale_sha = String.trim(git!(workspace_path, ["rev-parse", "HEAD"]))
      File.write!(Path.join(workspace_path, "collision.txt"), "stale untracked file\n")

      assert git!(workspace_path, ["status", "--short", "collision.txt"]) == "?? collision.txt\n"

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01")

      # The reset switches to the requested head and overwrites the colliding
      # untracked file with the tracked PR-head version.
      assert String.trim(git!(workspace_path, ["branch", "--show-current"])) ==
               "feature/remote-untracked-collision"

      assert File.read!(Path.join(workspace_path, "collision.txt")) == "requested remote head\n"

      # The clobbered untracked content is recoverable from the orphan backup.
      backup_ref = "refs/symphony/orphaned/#{stale_sha}"

      assert String.trim(git!(workspace_path, ["show", "#{backup_ref}:collision.txt"])) ==
               "stale untracked file"

      assert String.trim(git!(workspace_path, ["show", "#{backup_ref}:stale.txt"])) ==
               "stale remote branch"
    end)
  end

  test "remote worktree reuse refuses when requested branch is checked out elsewhere" do
    with_real_exec_fake_ssh(fn ctx ->
      workspace_root = Path.join(ctx.test_root, "wsroot")
      primary_repo = Path.join(ctx.test_root, "primary")
      origin_repo = Path.join(ctx.test_root, "origin.git")
      peer_repo = Path.join(ctx.test_root, "peer")
      peer_worktree = Path.join(ctx.test_root, "peer-worktree")
      workspace_path = Path.join([workspace_root, "default", "PR-REMOTE-COLLISION"])

      create_primary_repo!(primary_repo, origin_repo)
      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)

      git!(peer_repo, ["checkout", "-b", "feature/remote-stale-collision"])
      File.write!(Path.join(peer_repo, "stale.txt"), "stale remote branch\n")
      git!(peer_repo, ["add", "stale.txt"])
      git!(peer_repo, ["commit", "-m", "stale remote branch"])
      git!(peer_repo, ["push", "origin", "feature/remote-stale-collision"])

      git!(peer_repo, ["checkout", "main"])
      git!(peer_repo, ["checkout", "-b", "feature/remote-reuse-collide"])
      File.write!(Path.join(peer_repo, "collision.txt"), "collision remote branch\n")
      git!(peer_repo, ["add", "collision.txt"])
      git!(peer_repo, ["commit", "-m", "collision remote branch"])
      git!(peer_repo, ["push", "origin", "feature/remote-reuse-collide"])

      git!(primary_repo, ["fetch", "origin"])
      git!(primary_repo, ["branch", "feature/remote-reuse-collide", "origin/feature/remote-reuse-collide"])
      git!(primary_repo, ["worktree", "add", peer_worktree, "feature/remote-reuse-collide"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: true,
        worker_ssh_hosts: ["worker-01"]
      )

      stale_issue = %Issue{
        identifier: "PR-REMOTE-COLLISION",
        workspace_branch: "feature/remote-stale-collision",
        workspace_base_ref: "origin/feature/remote-stale-collision"
      }

      issue = %Issue{
        identifier: "PR-REMOTE-COLLISION",
        workspace_branch: "feature/remote-reuse-collide",
        workspace_base_ref: "origin/feature/remote-reuse-collide"
      }

      assert {:ok, ^workspace_path} = Workspace.create_for_issue(stale_issue, "worker-01")

      assert {:error, {:branch_already_checked_out_elsewhere, details}} =
               Workspace.create_for_issue(issue, "worker-01")

      assert details[:branch] == "feature/remote-reuse-collide"
      assert details[:at] == peer_worktree
      assert details[:requested] == workspace_path
      assert String.trim(git!(workspace_path, ["branch", "--show-current"])) == "feature/remote-stale-collision"
    end)
  end
end
