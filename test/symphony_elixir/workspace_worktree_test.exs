defmodule SymphonyElixir.WorkspaceWorktreeTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.WorkspaceTestSupport

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy creates reuses and removes issue worktrees" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      peer_repo = Path.join(test_root, "peer")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)
      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      File.write!(Path.join(peer_repo, "remote.txt"), "remote update\n")
      git!(peer_repo, ["add", "remote.txt"])
      git!(peer_repo, ["commit", "-m", "remote update"])
      git!(peer_repo, ["push", "origin", "main"])
      new_origin_head = git!(peer_repo, ["rev-parse", "HEAD"]) |> String.trim()

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        hook_after_create: "echo after_create >> hook.count"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-WT")

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "MT-WT"]))

      assert workspace == expected_workspace
      assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
      refute File.exists?(Path.join(workspace, "remote.txt"))
      assert String.trim(File.read!(Path.join(workspace, "hook.count"))) == "after_create"
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "auto/MT-WT"
      assert git_branch_exists?(primary_repo, "auto/MT-WT")
      assert String.trim(git!(primary_repo, ["rev-parse", "origin/main"])) == new_origin_head

      File.write!(Path.join(workspace, "README.md"), "local progress\n")
      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-WT")
      assert File.read!(Path.join(workspace, "README.md")) == "local progress\n"
      assert String.trim(File.read!(Path.join(workspace, "hook.count"))) == "after_create"

      assert :ok = Workspace.remove_issue_workspaces("MT-WT")
      refute File.exists?(workspace)
      refute git_branch_exists?(primary_repo, "auto/MT-WT")
    after
      File.rm_rf(test_root)
    end
  end

  test "a worktree re-created on an agent branch runs after_create on the base branch tree" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-base-tree-hook-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)
      File.write!(Path.join(primary_repo, "mix.exs"), "base project\n")
      git!(primary_repo, ["add", "mix.exs"])
      git!(primary_repo, ["commit", "-m", "base project"])
      git!(primary_repo, ["push", "origin", "main"])

      # The agent's branch survives its removed workspace, with its own `mix.exs`.
      git!(primary_repo, ["checkout", "-b", "auto/MT-BASE"])
      File.write!(Path.join(primary_repo, "mix.exs"), "agent project\n")
      git!(primary_repo, ["commit", "-am", "agent edit"])
      agent_commit = String.trim(git!(primary_repo, ["rev-parse", "HEAD"]))
      git!(primary_repo, ["checkout", "main"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        hook_after_create: "cat mix.exs > hook.saw"
      )

      log =
        capture_log(fn ->
          assert {:ok, workspace} = Workspace.create_for_issue("MT-BASE")
          send(self(), {:workspace, workspace})
        end)

      assert_received {:workspace, workspace}
      assert File.read!(Path.join(workspace, "hook.saw")) == "base project\n"
      assert log =~ "Running workspace hook on the base branch tree hook=after_create"
      assert String.trim(git!(workspace, ["rev-parse", "HEAD"])) == agent_commit
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "auto/MT-BASE"
      assert File.read!(Path.join(workspace, "mix.exs")) == "agent project\n"
      refute File.exists?(Path.join([workspace_root, "default", ".MT-BASE.after_create_pending"]))
    after
      File.rm_rf(test_root)
    end
  end

  test "after_create is skipped, with a warning, on an agent branch worktree that has changes of its own" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-dirty-hook-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      pending_marker = Path.join([workspace_root, "default", ".MT-DIRTY.after_create_pending"])

      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-DIRTY")
      configure_git_user!(workspace)
      File.write!(Path.join(workspace, "mix.exs"), "agent project\n")
      git!(workspace, ["add", "mix.exs"])
      git!(workspace, ["commit", "-m", "agent edit"])
      File.write!(Path.join(workspace, "mix.exs"), "uncommitted agent project\n")
      File.write!(pending_marker, "")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        hook_after_create: "echo ran > hook.saw"
      )

      log = capture_log(fn -> assert {:ok, ^workspace} = Workspace.create_for_issue("MT-DIRTY") end)

      assert log =~ "Skipping workspace hook: it can't run on the base branch tree hook=after_create"
      assert log =~ "reason=uncommitted_changes"
      refute File.exists?(Path.join(workspace, "hook.saw"))
      assert File.read!(Path.join(workspace, "mix.exs")) == "uncommitted agent project\n"
      assert File.exists?(pending_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "after_create in a reused worktree doesn't see the ignored files an agent wrote there" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-ignored-hook-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo)
      File.write!(Path.join(primary_repo, ".gitignore"), "/deps/\n/hook.saw\n")
      git!(primary_repo, ["add", ".gitignore"])
      git!(primary_repo, ["commit", "-m", "ignore deps"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      # MT-AHEAD's branch has an agent commit, MT-EVEN's is still at the base commit.
      assert {:ok, ahead} = Workspace.create_for_issue("MT-AHEAD")
      assert {:ok, even} = Workspace.create_for_issue("MT-EVEN")
      configure_git_user!(ahead)
      File.write!(Path.join(ahead, "agent.txt"), "agent\n")
      git!(ahead, ["add", "agent.txt"])
      git!(ahead, ["commit", "-m", "agent edit"])

      for {workspace, identifier} <- [{ahead, "MT-AHEAD"}, {even, "MT-EVEN"}] do
        File.mkdir_p!(Path.join(workspace, "deps/evil"))
        File.write!(Path.join(workspace, "deps/evil/mix.exs"), "agent code\n")
        File.write!(Path.join([workspace_root, "default", ".#{identifier}.after_create_pending"]), "")
      end

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        hook_after_create: "if [ -e deps/evil/mix.exs ]; then echo saw; else echo clean; fi > hook.saw"
      )

      capture_log(fn ->
        assert {:ok, ^ahead} = Workspace.create_for_issue("MT-AHEAD")
        assert {:ok, ^even} = Workspace.create_for_issue("MT-EVEN")
      end)

      for {workspace, identifier} <- [{ahead, "MT-AHEAD"}, {even, "MT-EVEN"}] do
        assert File.read!(Path.join(workspace, "hook.saw")) == "clean\n"
        refute File.exists?(Path.join(workspace, "deps/evil/mix.exs"))
        refute File.exists?(Path.join([workspace_root, "default", ".#{identifier}.after_create_pending"]))
      end

      assert File.read!(Path.join(ahead, "agent.txt")) == "agent\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "an unfinished after_create in a worktree an earlier hook left detached puts it back on its branch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-detached-hook-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      pending_marker = Path.join([workspace_root, "default", ".MT-DETACHED.after_create_pending"])

      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      # A run stopped mid-hook leaves the worktree detached at the base commit.
      assert {:ok, workspace} = Workspace.create_for_issue("MT-DETACHED")
      configure_git_user!(workspace)
      File.write!(Path.join(workspace, "agent.txt"), "agent\n")
      git!(workspace, ["add", "agent.txt"])
      git!(workspace, ["commit", "-m", "agent edit"])
      agent_commit = String.trim(git!(workspace, ["rev-parse", "HEAD"]))
      git!(workspace, ["checkout", "--quiet", "--detach", "main"])
      File.write!(pending_marker, "")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        hook_after_create: "echo ran > hook.saw"
      )

      capture_log(fn -> assert {:ok, ^workspace} = Workspace.create_for_issue("MT-DETACHED") end)

      assert File.read!(Path.join(workspace, "hook.saw")) == "ran\n"
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "auto/MT-DETACHED"
      assert String.trim(git!(workspace, ["rev-parse", "HEAD"])) == agent_commit
      refute File.exists?(pending_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "after_create is skipped, with a warning, on a base tree worktree that has changes of its own" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-even-dirty-hook-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      pending_marker = Path.join([workspace_root, "default", ".MT-EVENDIRTY.after_create_pending"])

      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-EVENDIRTY")
      File.write!(Path.join(workspace, "mix.exs"), "uncommitted agent project\n")
      File.write!(pending_marker, "")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        hook_after_create: "echo ran > hook.saw"
      )

      log = capture_log(fn -> assert {:ok, ^workspace} = Workspace.create_for_issue("MT-EVENDIRTY") end)

      assert log =~ "reason=uncommitted_changes"
      refute File.exists?(Path.join(workspace, "hook.saw"))
      assert File.read!(Path.join(workspace, "mix.exs")) == "uncommitted agent project\n"
      assert File.exists?(pending_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "after_create is skipped, with a warning, when the base branch can't be resolved" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-no-base-hook-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo)
      git!(primary_repo, ["branch", "auto/MT-NOBASE"])
      git!(primary_repo, ["checkout", "--orphan", "unborn"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        hook_after_create: "echo ran > hook.saw"
      )

      log =
        capture_log(fn ->
          assert {:ok, workspace} = Workspace.create_for_issue("MT-NOBASE")
          refute File.exists?(Path.join(workspace, "hook.saw"))
        end)

      assert log =~ "Skipping workspace hook: it can't run on the base branch tree hook=after_create"
      assert log =~ "reason=no_base_commit"
      assert File.exists?(Path.join([workspace_root, "default", ".MT-NOBASE.after_create_pending"]))
    after
      File.rm_rf(test_root)
    end
  end

  test "after_create on the base branch tree fails when the worktree can't go back to its branch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-restore-fail-hook-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo)
      git!(primary_repo, ["checkout", "-b", "auto/MT-LOST"])
      File.write!(Path.join(primary_repo, "agent.txt"), "agent\n")
      git!(primary_repo, ["add", "agent.txt"])
      git!(primary_repo, ["commit", "-m", "agent edit"])
      git!(primary_repo, ["checkout", "main"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false,
        hook_after_create: "git branch -D auto/MT-LOST"
      )

      capture_log(fn ->
        assert {:error, {:git_failed, _workspace, ["checkout", "--quiet", "--force", "auto/MT-LOST"], _status}} =
                 Workspace.create_for_issue("MT-LOST")
      end)

      assert File.exists?(Path.join([workspace_root, "default", ".MT-LOST.after_create_pending"]))
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree removal skips branch deletion when another worktree has the branch checked out" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-checked-out-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      peer_worktree = Path.join(test_root, "peer-worktree")
      stale_workspace = Path.join([workspace_root, "default", "MT-BLOCK"])

      create_primary_repo!(primary_repo)
      git!(primary_repo, ["branch", "auto/MT-BLOCK"])
      git!(primary_repo, ["worktree", "add", peer_worktree, "auto/MT-BLOCK"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      assert {:ok, [^stale_workspace]} = Workspace.remove(stale_workspace)
      assert File.exists?(peer_worktree)
      assert git_branch_exists?(primary_repo, "auto/MT-BLOCK")
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy can skip fetch before dispatch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-no-fetch-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-NO-FETCH")
      assert File.read!(Path.join(workspace, "README.md")) == "initial\n"

      assert :ok = Workspace.remove_issue_workspaces("MT-NO-FETCH")
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy can create a PR workspace from an explicit head ref" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-pr-head-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      peer_repo = Path.join(test_root, "peer")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)
      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      git!(peer_repo, ["checkout", "-b", "feature/pr-head"])
      File.write!(Path.join(peer_repo, "pr.txt"), "from pr branch\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "pr branch"])
      git!(peer_repo, ["push", "origin", "feature/pr-head"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      issue = %Issue{
        identifier: "PR-42",
        workspace_branch: "feature/pr-head",
        workspace_base_ref: "origin/feature/pr-head"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "pr.txt")) == "from pr branch\n"
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "feature/pr-head"
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy resets existing PR branch to explicit head ref" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-pr-reset-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      peer_repo = Path.join(test_root, "peer")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)
      git!(primary_repo, ["checkout", "-b", "feature/pr-reset"])
      File.write!(Path.join(primary_repo, "pr.txt"), "stale local branch\n")
      git!(primary_repo, ["add", "pr.txt"])
      git!(primary_repo, ["commit", "-m", "stale local branch"])
      git!(primary_repo, ["checkout", "main"])

      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      git!(peer_repo, ["checkout", "-b", "feature/pr-reset"])
      File.write!(Path.join(peer_repo, "pr.txt"), "fetched pr head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "pr branch"])
      git!(peer_repo, ["push", "origin", "feature/pr-reset"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      issue = %Issue{
        identifier: "PR-44",
        workspace_branch: "feature/pr-reset",
        workspace_base_ref: "origin/feature/pr-reset"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "pr.txt")) == "fetched pr head\n"
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "feature/pr-reset"
    after
      File.rm_rf(test_root)
    end
  end

  test "redispatch resets reused PR worktree to latest origin head" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-pr-redispatch-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      peer_repo = Path.join(test_root, "peer")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)

      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      git!(peer_repo, ["checkout", "-b", "feature/pr-redispatch"])
      File.write!(Path.join(peer_repo, "pr.txt"), "initial pr head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "initial pr head"])
      git!(peer_repo, ["push", "origin", "feature/pr-redispatch"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      issue = %Issue{
        identifier: "PR-77",
        workspace_branch: "feature/pr-redispatch",
        workspace_base_ref: "origin/feature/pr-redispatch"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "pr.txt")) == "initial pr head\n"
      first_sha = String.trim(git!(workspace, ["rev-parse", "HEAD"]))

      File.write!(Path.join(peer_repo, "pr.txt"), "advanced pr head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "advance pr head"])
      git!(peer_repo, ["push", "origin", "feature/pr-redispatch"])

      assert {:ok, ^workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "pr.txt")) == "advanced pr head\n"
      second_sha = String.trim(git!(workspace, ["rev-parse", "HEAD"]))
      assert first_sha != second_sha
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "feature/pr-redispatch"
    after
      File.rm_rf(test_root)
    end
  end

  test "redispatch switches reused PR worktree from stale branch to requested head branch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-pr-reuse-branch-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      peer_repo = Path.join(test_root, "peer")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)

      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)

      git!(peer_repo, ["checkout", "-b", "feature/stale-reuse"])
      File.write!(Path.join(peer_repo, "stale.txt"), "stale branch\n")
      git!(peer_repo, ["add", "stale.txt"])
      git!(peer_repo, ["commit", "-m", "stale branch"])
      git!(peer_repo, ["push", "origin", "feature/stale-reuse"])

      git!(peer_repo, ["checkout", "main"])
      git!(peer_repo, ["checkout", "-b", "feature/pr-reuse-branch"])
      File.write!(Path.join(peer_repo, "pr.txt"), "requested pr head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "requested pr branch"])
      git!(peer_repo, ["push", "origin", "feature/pr-reuse-branch"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      stale_issue = %Issue{
        identifier: "PR-REUSE-BRANCH",
        workspace_branch: "feature/stale-reuse",
        workspace_base_ref: "origin/feature/stale-reuse"
      }

      issue = %Issue{
        identifier: "PR-REUSE-BRANCH",
        workspace_branch: "feature/pr-reuse-branch",
        workspace_base_ref: "origin/feature/pr-reuse-branch"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(stale_issue)
      assert File.read!(Path.join(workspace, "stale.txt")) == "stale branch\n"
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "feature/stale-reuse"

      assert {:ok, ^workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "pr.txt")) == "requested pr head\n"
      refute File.exists?(Path.join(workspace, "stale.txt"))
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "feature/pr-reuse-branch"

      assert String.trim(git!(workspace, ["rev-parse", "HEAD"])) ==
               String.trim(git!(primary_repo, ["rev-parse", "origin/feature/pr-reuse-branch"]))
    after
      File.rm_rf(test_root)
    end
  end

  test "redispatch backs up a dirty reused PR worktree and resets to head" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-pr-dirty-reset-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      peer_repo = Path.join(test_root, "peer")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)

      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      git!(peer_repo, ["checkout", "-b", "feature/pr-dirty-reset"])
      File.write!(Path.join(peer_repo, "pr.txt"), "initial pr head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "initial pr head"])
      git!(peer_repo, ["push", "origin", "feature/pr-dirty-reset"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      issue = %Issue{
        identifier: "PR-78",
        workspace_branch: "feature/pr-dirty-reset",
        workspace_base_ref: "origin/feature/pr-dirty-reset"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      first_sha = String.trim(git!(workspace, ["rev-parse", "HEAD"]))
      File.write!(Path.join(workspace, "pr.txt"), "dirty local edit\n")

      File.write!(Path.join(peer_repo, "pr.txt"), "advanced pr head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "advance pr head"])
      git!(peer_repo, ["push", "origin", "feature/pr-dirty-reset"])

      assert {:ok, ^workspace} = Workspace.create_for_issue(issue)

      # The reset adopts the advanced remote head instead of failing.
      assert File.read!(Path.join(workspace, "pr.txt")) == "advanced pr head\n"

      assert String.trim(git!(workspace, ["rev-parse", "HEAD"])) ==
               String.trim(git!(workspace, ["rev-parse", "origin/feature/pr-dirty-reset"]))

      # The dropped dirty edit is recoverable from the orphan backup snapshot.
      backup_ref = "refs/symphony/orphaned/#{first_sha}"
      assert String.trim(git!(workspace, ["rev-parse", "#{backup_ref}^"])) == first_sha
      assert String.trim(git!(workspace, ["show", "#{backup_ref}:pr.txt"])) == "dirty local edit"
    after
      File.rm_rf(test_root)
    end
  end

  test "redispatch backs up unpushed commits from a reused PR worktree and resets to head" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-pr-local-commits-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      peer_repo = Path.join(test_root, "peer")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)

      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      git!(peer_repo, ["checkout", "-b", "feature/pr-local-commits"])
      File.write!(Path.join(peer_repo, "pr.txt"), "initial pr head\n")
      git!(peer_repo, ["add", "pr.txt"])
      git!(peer_repo, ["commit", "-m", "initial pr head"])
      git!(peer_repo, ["push", "origin", "feature/pr-local-commits"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      issue = %Issue{
        identifier: "PR-79",
        workspace_branch: "feature/pr-local-commits",
        workspace_base_ref: "origin/feature/pr-local-commits"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      File.write!(Path.join(workspace, "local.txt"), "local commit\n")
      git!(workspace, ["add", "local.txt"])
      git!(workspace, ["commit", "-m", "local commit"])
      local_commit = String.trim(git!(workspace, ["rev-parse", "HEAD"]))

      assert {:ok, ^workspace} = Workspace.create_for_issue(issue)

      # The branch is reset to the remote head, dropping the unpushed commit.
      assert String.trim(git!(workspace, ["rev-parse", "HEAD"])) ==
               String.trim(git!(workspace, ["rev-parse", "origin/feature/pr-local-commits"]))

      refute File.exists?(Path.join(workspace, "local.txt"))

      # The unpushed commit is recoverable from the orphan backup snapshot.
      backup_ref = "refs/symphony/orphaned/#{local_commit}"
      assert String.trim(git!(workspace, ["rev-parse", "#{backup_ref}^"])) == local_commit
      assert String.trim(git!(workspace, ["show", "#{backup_ref}:local.txt"])) == "local commit"
    after
      File.rm_rf(test_root)
    end
  end

  test "redispatch backs up colliding untracked files before resetting a reused PR worktree" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-pr-untracked-collision-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      peer_repo = Path.join(test_root, "peer")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)

      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)

      git!(peer_repo, ["checkout", "-b", "feature/stale-untracked"])
      File.write!(Path.join(peer_repo, "stale.txt"), "stale branch\n")
      git!(peer_repo, ["add", "stale.txt"])
      git!(peer_repo, ["commit", "-m", "stale branch"])
      git!(peer_repo, ["push", "origin", "feature/stale-untracked"])

      git!(peer_repo, ["checkout", "main"])
      git!(peer_repo, ["checkout", "-b", "feature/pr-untracked-collision"])
      File.write!(Path.join(peer_repo, "collision.txt"), "requested pr head\n")
      git!(peer_repo, ["add", "collision.txt"])
      git!(peer_repo, ["commit", "-m", "requested pr branch"])
      git!(peer_repo, ["push", "origin", "feature/pr-untracked-collision"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      stale_issue = %Issue{
        identifier: "PR-UNTRACKED-COLLISION",
        workspace_branch: "feature/stale-untracked",
        workspace_base_ref: "origin/feature/stale-untracked"
      }

      issue = %Issue{
        identifier: "PR-UNTRACKED-COLLISION",
        workspace_branch: "feature/pr-untracked-collision",
        workspace_base_ref: "origin/feature/pr-untracked-collision"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(stale_issue)
      stale_sha = String.trim(git!(workspace, ["rev-parse", "HEAD"]))
      File.write!(Path.join(workspace, "collision.txt"), "stale untracked file\n")

      assert git!(workspace, ["status", "--short", "collision.txt"]) == "?? collision.txt\n"

      assert {:ok, ^workspace} = Workspace.create_for_issue(issue)

      # The reset switches to the requested head and overwrites the colliding
      # untracked file with the tracked PR-head version.
      assert String.trim(git!(workspace, ["branch", "--show-current"])) ==
               "feature/pr-untracked-collision"

      assert File.read!(Path.join(workspace, "collision.txt")) == "requested pr head\n"

      # The clobbered untracked content is recoverable from the orphan backup.
      backup_ref = "refs/symphony/orphaned/#{stale_sha}"

      assert String.trim(git!(workspace, ["show", "#{backup_ref}:collision.txt"])) ==
               "stale untracked file"

      assert String.trim(git!(workspace, ["show", "#{backup_ref}:stale.txt"])) == "stale branch"
    after
      File.rm_rf(test_root)
    end
  end

  test "after_create hook receives PR workspace branch for clone-style workspaces" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-pr-hook-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '%s' \"$SYMPHONY_BRANCH\" > branch.txt"
      )

      issue = %Issue{
        identifier: "PR-43",
        workspace_branch: "feature/pr-hook"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "branch.txt")) == "feature/pr-hook"
    after
      File.rm_rf(test_root)
    end
  end

  test "local hooks run Gradle without a daemon and keep the host's GRADLE_OPTS" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-gradle-hook-#{System.unique_integer([:positive])}"
      )

    previous_gradle_opts = System.get_env("GRADLE_OPTS")
    on_exit(fn -> restore_env("GRADLE_OPTS", previous_gradle_opts) end)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(test_root, "workspaces"),
        hook_after_create: "printf '%s' \"$GRADLE_OPTS\" > gradle_opts.txt"
      )

      System.delete_env("GRADLE_OPTS")
      assert {:ok, workspace} = Workspace.create_for_issue("GRADLE-1")
      assert File.read!(Path.join(workspace, "gradle_opts.txt")) == "-Dorg.gradle.daemon=false"

      System.put_env("GRADLE_OPTS", "-Xmx64m")
      assert {:ok, workspace} = Workspace.create_for_issue("GRADLE-2")
      assert File.read!(Path.join(workspace, "gradle_opts.txt")) == "-Xmx64m -Dorg.gradle.daemon=false"
    after
      File.rm_rf(test_root)
    end
  end

  test "repo-level worktree settings select the matched repo primary clone" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repo-worktree-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "api-primary")
      workflow_dir = Path.join(test_root, "api-workflow")
      workflow_path = Path.join(workflow_dir, "WORKFLOW.md")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo)
      File.mkdir_p!(workflow_dir)

      File.write!(workflow_path, """
      ---
      hooks:
        after_create: echo api > repo-hook.txt
      ---
      API prompt
      """)

      File.write!(Workflow.symphony_file_path(), """
      issues:
        provider: memory
      workspaces:
        root: #{workspace_root}
      execution:
        harnesses:
          codex:
            command: codex app-server
      runs:
        default: {harness: codex, provider: openai, model: gpt-test}
      repositories:
        - key: api
          workflow: #{workflow_path}
          route:
            team: Test
          workspace:
            strategy: worktree
            repo: #{primary_repo}
            fetch_before_dispatch: false
      """)

      issue = %Issue{id: "api-issue", identifier: "API-WT", repo_key: "api"}

      assert :ok = Config.validate!()
      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "api", "API-WT"]))

      assert workspace == expected_workspace
      assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
      assert File.read!(Path.join(workspace, "repo-hook.txt")) == "api\n"
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "auto/API-WT"
      assert git_branch_exists?(primary_repo, "auto/API-WT")

      assert :ok = Workspace.remove_issue_workspaces(issue)
      refute File.exists?(workspace)
      refute git_branch_exists?(primary_repo, "auto/API-WT")
    after
      File.rm_rf(test_root)
    end
  end

  test "new worktree branches off configured base_branch instead of the source repo HEAD" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-base-branch-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      workflow_dir = Path.join(test_root, "workflow")
      workflow_path = Path.join(workflow_dir, "WORKFLOW.md")
      workspace_root = Path.join(test_root, "workspaces")

      # Source clone tracks origin/main, but its HEAD sits on a divergent feature
      # branch carrying an unrelated commit (mirrors a contaminated local checkout).
      create_primary_repo!(primary_repo, origin_repo)
      base_commit = git!(primary_repo, ["rev-parse", "HEAD"])
      git!(primary_repo, ["checkout", "-b", "feature/unrelated"])
      File.write!(Path.join(primary_repo, "unrelated.txt"), "noise\n")
      git!(primary_repo, ["add", "unrelated.txt"])
      git!(primary_repo, ["commit", "-m", "unrelated work"])

      File.mkdir_p!(workflow_dir)
      File.write!(workflow_path, "---\n---\nprompt\n")

      File.write!(Workflow.symphony_file_path(), """
      issues:
        provider: memory
      workspaces:
        root: #{workspace_root}
      execution:
        harnesses:
          codex:
            command: codex app-server
      runs:
        default: {harness: codex, provider: openai, model: gpt-test}
      repositories:
        - key: api
          base_branch: main
          workflow: #{workflow_path}
          route:
            team: Test
          workspace:
            strategy: worktree
            repo: #{primary_repo}
            fetch_before_dispatch: false
      """)

      issue = %Issue{id: "api-issue", identifier: "API-BASE", repo_key: "api"}

      assert :ok = Config.validate!()
      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      # Worktree must start from origin/main, not the feature HEAD.
      assert git!(workspace, ["rev-parse", "HEAD"]) == base_commit
      refute File.exists?(Path.join(workspace, "unrelated.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "six workspaces of one repo prepared at once each get their worktree, with no upstream config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-parallel-worktrees-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      workflow_dir = Path.join(test_root, "workflow")
      workflow_path = Path.join(workflow_dir, "WORKFLOW.md")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)
      File.mkdir_p!(workflow_dir)
      File.write!(workflow_path, "---\n---\nprompt\n")

      File.write!(Workflow.symphony_file_path(), """
      issues:
        provider: memory
      workspaces:
        root: #{workspace_root}
      execution:
        harnesses:
          codex:
            command: codex app-server
      runs:
        default: {harness: codex, provider: openai, model: gpt-test}
      repositories:
        - key: api
          base_branch: main
          workflow: #{workflow_path}
          route:
            team: Test
          workspace:
            strategy: worktree
            repo: #{primary_repo}
            fetch_before_dispatch: false
      """)

      assert :ok = Config.validate!()
      identifiers = for n <- 1..6, do: "API-#{n}"

      log =
        capture_log(fn ->
          results =
            identifiers
            |> Enum.map(fn identifier ->
              Task.async(fn -> Workspace.create_for_issue(%Issue{id: identifier, identifier: identifier, repo_key: "api"}) end)
            end)
            |> Task.await_many(30_000)

          assert Enum.all?(results, &match?({:ok, _workspace}, &1))
        end)

      refute log =~ "worktree preparation failed"
      worktrees = git!(primary_repo, ["worktree", "list", "--porcelain"])

      for identifier <- identifiers do
        assert worktrees =~ "branch refs/heads/auto/#{identifier}\n"
        assert {_output, 1} = System.cmd("git", ["-C", primary_repo, "config", "--get", "branch.auto/#{identifier}.merge"])
      end
    after
      File.rm_rf(test_root)
    end
  end

  describe "local_worktree_dirty_status/1" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "sym_dirty_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      git!(tmp, ["init", "-q", "-b", "main"])
      git!(tmp, ["config", "user.email", "t@t"])
      git!(tmp, ["config", "user.name", "t"])
      File.write!(Path.join(tmp, "f"), "x")
      git!(tmp, ["add", "."])
      git!(tmp, ["commit", "-q", "-m", "init"])

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{repo: tmp}
    end

    test "returns :clean for a clean repo", %{repo: repo} do
      assert SymphonyElixir.Config.local_worktree_dirty_status(repo) == :clean
    end

    test "returns {:dirty, summary} when there are uncommitted changes", %{repo: repo} do
      File.write!(Path.join(repo, "f"), "y")
      assert {:dirty, summary} = SymphonyElixir.Config.local_worktree_dirty_status(repo)
      assert summary =~ "M f"
    end

    test "returns :not_applicable for a non-git path" do
      assert SymphonyElixir.Config.local_worktree_dirty_status("/nonexistent_xyzzy") ==
               :not_applicable
    end
  end
end
