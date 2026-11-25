defmodule SymphonyElixir.WorkspaceWorktreeBranchesTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.WorkspaceTestSupport

  test "worktree strategy rejects existing directories that are not registered worktrees" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-stale-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      stale_workspace = Path.join([workspace_root, "default", "MT-STALE"])

      create_primary_repo!(primary_repo)
      File.mkdir_p!(stale_workspace)
      File.write!(Path.join(stale_workspace, "stale.txt"), "manual directory\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      assert {:ok, expected_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)

      assert {:error, {:workspace_not_registered_worktree, ^expected_workspace}} =
               Workspace.create_for_issue("MT-STALE")

      assert File.read!(Path.join(stale_workspace, "stale.txt")) == "manual directory\n"
      refute git_branch_exists?(primary_repo, "auto/MT-STALE")
    after
      File.rm_rf(test_root)
    end
  end

  test "removing a workspace that is not a registered worktree deletes the directory and its branch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-stale-remove-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      stale_workspace = Path.join([workspace_root, "default", "MT-STALE-RM"])

      create_primary_repo!(primary_repo)
      {_output, 0} = System.cmd("git", ["-C", primary_repo, "branch", "auto/MT-STALE-RM"])
      File.mkdir_p!(stale_workspace)
      File.write!(Path.join(stale_workspace, "stale.txt"), "left by a removal under a live run\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      log = capture_log(fn -> assert :ok = Workspace.remove_issue_workspaces_checked("MT-STALE-RM") end)

      assert log =~ "Removing a workspace that is not a registered worktree"
      refute File.exists?(stale_workspace)
      refute git_branch_exists?(primary_repo, "auto/MT-STALE-RM")
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree registration checks warn when git worktree list fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-list-fail-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "not-git")
      workspace_root = Path.join(test_root, "workspaces")
      stale_workspace = Path.join([workspace_root, "default", "MT-WT-LIST-FAIL"])

      File.mkdir_p!(primary_repo)
      File.mkdir_p!(stale_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      log =
        capture_log(fn ->
          assert {:error, {:workspace_not_registered_worktree, _workspace}} =
                   Workspace.create_for_issue("MT-WT-LIST-FAIL")

          assert {:error, [_reason]} = Workspace.remove_issue_workspaces_checked("MT-WT-LIST-FAIL")
        end)

      assert File.dir?(stale_workspace)

      assert log =~ "Git worktree list failed"
      assert log =~ primary_repo
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree create_for_issue returns a 2-tuple error when git worktree add fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-2tuple-#{System.unique_integer([:positive])}"
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

      issue = %Issue{
        identifier: "MT-BAD-BASE",
        workspace_branch: "auto/MT-BAD-BASE",
        workspace_base_ref: "origin/does-not-exist"
      }

      log =
        capture_log(fn ->
          result = Workspace.create_for_issue(issue)
          assert {:error, reason} = result
          assert tuple_size(result) == 2
          assert match?({:git_failed, _repo, _args, _status}, reason)
        end)

      assert log =~ "Workspace worktree preparation failed"
      assert log =~ "auto/MT-BAD-BASE"
      # git's stderr
      assert log =~ "fatal: invalid reference: origin/does-not-exist"
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy refuses when the requested branch is already checked out elsewhere" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-collision-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      peer_worktree = Path.join(test_root, "peer-worktree")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo)
      git!(primary_repo, ["branch", "auto/MT-COLLIDE"])
      git!(primary_repo, ["worktree", "add", peer_worktree, "auto/MT-COLLIDE"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      issue = %Issue{
        identifier: "PR-COLLIDE",
        workspace_branch: "auto/MT-COLLIDE",
        workspace_base_ref: "auto/MT-COLLIDE"
      }

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "PR-COLLIDE"]))

      assert {:error, {:branch_already_checked_out_elsewhere, branch: "auto/MT-COLLIDE", at: at, requested: ^expected_workspace}} =
               Workspace.create_for_issue(issue)

      assert {:ok, canonical_peer} = SymphonyElixir.PathSafety.canonicalize(peer_worktree)
      assert {:ok, canonical_at} = SymphonyElixir.PathSafety.canonicalize(at)
      assert canonical_at == canonical_peer

      # The collision is detected pre-flight: the requested workspace is not
      # populated with a worktree and the peer worktree is untouched.
      refute File.exists?(Path.join(expected_workspace, ".git"))
      assert File.exists?(peer_worktree)
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy keeps a sibling workspace's branch when it holds local-only work" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-dirty-sibling-#{System.unique_integer([:positive])}"
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

      # The pre-rename workspace still has its PR branch checked out, with an
      # uncommitted edit that releasing the branch must not strand.
      assert {:ok, old_workspace} = Workspace.create_for_issue("TON-219")
      File.write!(Path.join(old_workspace, "wip.txt"), "uncommitted\n")

      issue = %Issue{identifier: "TP-219", workspace_branch: "auto/TON-219"}

      assert {:error, {:branch_already_checked_out_elsewhere, details}} = Workspace.create_for_issue(issue)
      assert details[:branch] == "auto/TON-219"
      assert SymphonyElixir.PathSafety.canonicalize(details[:at]) == {:ok, old_workspace}
      assert String.trim(git!(old_workspace, ["branch", "--show-current"])) == "auto/TON-219"
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy keeps a clean sibling workspace's branch when an active issue owns it" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-active-sibling-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      # Another running issue's clean, pushed worktree has the shared PR branch
      # checked out; detaching it would land that agent's next commit on a
      # detached HEAD.
      assert {:ok, sibling_workspace} = Workspace.create_for_issue("TP-225")
      git!(sibling_workspace, ["push", "origin", "auto/TP-225"])

      issue = %Issue{identifier: "TP-226", workspace_branch: "auto/TP-225"}

      assert {:error, {:branch_already_checked_out_elsewhere, details}} =
               Workspace.create_for_issue(issue, nil, nil, active_workspace_identifiers: ["TP-225"])

      assert details[:branch] == "auto/TP-225"
      assert SymphonyElixir.PathSafety.canonicalize(details[:at]) == {:ok, sibling_workspace}
      assert String.trim(git!(sibling_workspace, ["branch", "--show-current"])) == "auto/TP-225"
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy never detaches a sibling whose issue is open but not running" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-open-sibling-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      # TP-586's clean, pushed worktree has its branch checked out while the usage limit
      # holds it, so no agent owns it right now. Its issue is still open.
      assert {:ok, sibling_workspace} = Workspace.create_for_issue("TP-586")
      git!(sibling_workspace, ["push", "origin", "auto/TP-586"])

      issue = %Issue{id: "issue-381", identifier: "TP-381", workspace_branch: "auto/TP-586"}

      log =
        capture_log(fn ->
          for lookup_result <- [
                {:ok, %Issue{id: "issue-586", identifier: "TP-586", state: "In Progress"}},
                {:ok, %Issue{id: "issue-586", identifier: "TP-586", state: "Rework"}},
                {:ok, %Issue{id: "issue-586", identifier: "TP-586", state: nil}},
                {:error, {:linear_graphql_errors, [%{"message" => "Rate limited"}, "unexpected"]}},
                {:error, :timeout}
              ] do
            lookup = fn identifier ->
              assert identifier == "TP-586"
              lookup_result
            end

            assert {:error, {:branch_already_checked_out_elsewhere, details}} =
                     Workspace.create_for_issue(issue, nil, nil, sibling_issue_lookup: lookup)

            assert details[:branch] == "auto/TP-586"
            assert SymphonyElixir.PathSafety.canonicalize(details[:at]) == {:ok, sibling_workspace}
            assert String.trim(git!(sibling_workspace, ["branch", "--show-current"])) == "auto/TP-586"
          end
        end)

      assert log =~ "Kept workspace branch on sibling worktree; issue lookup failed sibling=TP-586 reason=:timeout"
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy detaches a clean sibling whose issue is terminal, unknown, or this issue" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-closed-sibling-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      for {{sibling, lookup_result}, index} <-
            Enum.with_index([
              {"TP-700", {:ok, %Issue{id: "issue-700", identifier: "TP-700", state: "Done"}}},
              {"TP-701", {:error, :issue_not_found}},
              {"TP-702", {:error, {:linear_graphql_errors, [%{"message" => "Entity not found: Issue"}]}}},
              # The renamed issue's own old workspace resolves to this very issue.
              {"TON-703", {:ok, %Issue{id: "issue-taker-3", identifier: "TP-703", state: "In Progress"}}}
            ]) do
        assert {:ok, sibling_workspace} = Workspace.create_for_issue(sibling)
        git!(sibling_workspace, ["push", "origin", "auto/#{sibling}"])

        issue = %Issue{id: "issue-taker-#{index}", identifier: "TP-71#{index}", workspace_branch: "auto/#{sibling}"}

        lookup = fn ^sibling -> lookup_result end
        assert {:ok, workspace} = Workspace.create_for_issue(issue, nil, nil, sibling_issue_lookup: lookup)

        assert String.trim(git!(workspace, ["branch", "--show-current"])) == "auto/#{sibling}"
        assert String.trim(git!(sibling_workspace, ["branch", "--show-current"])) == ""
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator lists other running and retrying workspaces in the same repo as active siblings" do
    state = %Orchestrator.State{
      repo_key: "default",
      running: %{
        "issue-self" => %{identifier: "TP-226", issue: %Issue{identifier: "TP-226"}, workspace_path: "/ws/default/TON-226"},
        "issue-running" => %{identifier: "TP-225", issue: %Issue{identifier: "TP-225"}, workspace_path: "/ws/default/TON-225"},
        "issue-other-repo" => %{repo_key: "other", identifier: "TP-1", workspace_path: "/ws/other/TP-1"}
      },
      retry_attempts: %{
        "issue-self" => %{identifier: "TP-226", repo_key: "default", workspace_path: "/ws/default/TON-226"},
        "issue-retrying" => %{identifier: "TP-224", repo_key: "default", workspace_path: nil},
        "issue-retrying-other-repo" => %{identifier: "TP-2", repo_key: "other"}
      },
      tracker_tasks: %{
        make_ref() => %{
          kind: :retry_refresh,
          issue_ids: ["issue-refreshing"],
          metadata: %{identifier: "TP-223", repo_key: "default", workspace_path: nil}
        },
        make_ref() => %{kind: :plan_comments, issue_ids: ["issue-parent"], newest: nil}
      }
    }

    identifiers = Orchestrator.sibling_active_workspace_identifiers_for_test(state, "issue-self", "default")

    assert Enum.sort(identifiers) == ["TON-225", "TP-223", "TP-224", "TP-225"]
  end

  test "worktree reuse refuses when the requested branch is already checked out elsewhere" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-reuse-collision-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      peer_repo = Path.join(test_root, "peer")
      peer_worktree = Path.join(test_root, "peer-worktree")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)
      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)

      git!(peer_repo, ["checkout", "-b", "feature/stale-collision"])
      File.write!(Path.join(peer_repo, "stale.txt"), "stale branch\n")
      git!(peer_repo, ["add", "stale.txt"])
      git!(peer_repo, ["commit", "-m", "stale branch"])
      git!(peer_repo, ["push", "origin", "feature/stale-collision"])

      git!(peer_repo, ["checkout", "main"])
      git!(peer_repo, ["checkout", "-b", "feature/reuse-collide"])
      File.write!(Path.join(peer_repo, "collision.txt"), "collision branch\n")
      git!(peer_repo, ["add", "collision.txt"])
      git!(peer_repo, ["commit", "-m", "collision branch"])
      git!(peer_repo, ["push", "origin", "feature/reuse-collide"])

      git!(primary_repo, ["fetch", "origin"])
      git!(primary_repo, ["branch", "feature/reuse-collide", "origin/feature/reuse-collide"])
      git!(primary_repo, ["worktree", "add", peer_worktree, "feature/reuse-collide"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      stale_issue = %Issue{
        identifier: "PR-REUSE-COLLISION",
        workspace_branch: "feature/stale-collision",
        workspace_base_ref: "origin/feature/stale-collision"
      }

      issue = %Issue{
        identifier: "PR-REUSE-COLLISION",
        workspace_branch: "feature/reuse-collide",
        workspace_base_ref: "origin/feature/reuse-collide"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(stale_issue)

      result = Workspace.create_for_issue(issue)

      assert {:error, {:branch_already_checked_out_elsewhere, details}} = result
      assert details[:branch] == "feature/reuse-collide"
      assert details[:requested] == workspace
      at = details[:at]

      assert {:ok, canonical_peer} = SymphonyElixir.PathSafety.canonicalize(peer_worktree)
      assert {:ok, canonical_at} = SymphonyElixir.PathSafety.canonicalize(at)
      assert canonical_at == canonical_peer
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "feature/stale-collision"
    after
      File.rm_rf(test_root)
    end
  end

  test "remote worktree creation maps branch collision script exit to the collision variant" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-worktree-collision-#{System.unique_integer([:positive])}"
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
      workspace_root = "/remote/workspaces"
      workspace_repo = "/remote/primary"
      workspace_path = "/remote/workspaces/default/PR-REMOTE-COLLIDE"
      other_worktree = "/remote/workspaces/default/RSM-OTHER"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      printf 'workspace_branch_already_checked_out_elsewhere\\t%s\\t%s\\t%s\\n' \
        'auto/RSM-OTHER' '#{other_worktree}' '#{workspace_path}'
      exit 45
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: workspace_repo,
        worker_ssh_hosts: ["worker-01"]
      )

      issue = %Issue{
        identifier: "PR-REMOTE-COLLIDE",
        workspace_branch: "auto/RSM-OTHER",
        workspace_base_ref: "origin/auto/RSM-OTHER"
      }

      assert {:error, {:branch_already_checked_out_elsewhere, details}} =
               Workspace.create_for_issue(issue, "worker-01")

      assert details[:branch] == "auto/RSM-OTHER"
      assert details[:at] == other_worktree
      assert details[:requested] == workspace_path
    after
      File.rm_rf(test_root)
    end
  end
end
