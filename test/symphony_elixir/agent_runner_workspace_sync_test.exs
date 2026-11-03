defmodule SymphonyElixir.AgentRunnerWorkspaceSyncTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketEvents, TicketPullRequest}

  # Coding-agent stand-in: reports the head its workspace stands on when the turn starts.
  defmodule HeadAgent do
    def start_session(workspace, _opts), do: {:ok, %{workspace: workspace}}

    def run_turn(%{workspace: workspace}, _prompt, _issue, _turn_opts) do
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
      send(Application.fetch_env!(:symphony_elixir, :head_agent_recipient), {:turn_on, String.trim(head)})
      {:ok, %{session_id: "sess"}}
    end

    def stop_session(_session), do: :ok
  end

  setup do
    :ok = RunStore.clear()
    Application.put_env(:symphony_elixir, :head_agent_recipient, self())
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-sync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :head_agent_recipient)
      File.rm_rf(test_root)
    end)

    %{test_root: test_root, repo_key: Config.repo_key!()}
  end

  describe "a landing run in Merging" do
    setup ctx do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
        workspace_root: ctx.test_root,
        agent_kind: "claude",
        max_turns: 1
      )

      workspace = Path.join(ctx.test_root, "TP-88")
      {head, pr_head} = behind_pr_workspace!(workspace, "auto/TP-88", 88)
      issue = %Issue{id: "issue-landing-sync", identifier: "TP-88", title: "Land it", state: "Merging"}
      :ok = TicketPullRequest.put(ctx.repo_key, issue.id, %{pr_url: "https://github.com/acme/repo/pull/88"})

      Map.merge(ctx, %{workspace: workspace, head: head, pr_head: pr_head, issue: issue})
    end

    test "stands on the PR's current head before the agent starts", ctx do
      capture_log(fn -> assert :ok = run(ctx) end)

      pr_head = ctx.pr_head
      assert_received {:turn_on, ^pr_head}

      assert [%{payload: %{winner: "pull_request", action: "reset", head: ^pr_head, run_kind: "landing"}}] =
               TicketEvents.query(ctx.issue.id, types: ["workspace.synced"])
    end

    test "never lands from a workspace with local work: the run fails naming it", ctx do
      File.write!(Path.join(ctx.workspace, "notes.txt"), "draft")

      log = capture_log(fn -> assert_raise RuntimeError, ~r/workspace_sync_failed/, fn -> run(ctx) end end)

      assert log =~ "Not starting TP-88's landing: its workspace could not be brought to the PR head"
      refute_received {:turn_on, _head}
      assert git!(ctx.workspace, ["rev-parse", "HEAD"]) == ctx.head
    end
  end

  # A rework whose kept worktree is on the PR's branch is brought to the PR head by the rule, and
  # reused as it is: no base-ref reset, so nothing is set aside under refs/symphony/orphaned.
  describe "a rework on a kept workspace" do
    test "is synced by the rule instead of a base-ref reset", ctx do
      primary = Path.join(ctx.test_root, "primary")
      origin = Path.join(ctx.test_root, "origin.git")
      git!(ctx.test_root, ["init", "-q", "--bare", "-b", "main", origin])
      git!(ctx.test_root, ["clone", "-q", origin, primary])
      commit!(primary, "base")
      git!(primary, ["push", "-q", "origin", "HEAD:refs/heads/main"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["Todo", "In Progress", "Rework"],
        workspace_root: Path.join(ctx.test_root, "workspaces"),
        workspace_strategy: "worktree",
        workspace_repo: primary,
        agent_kind: "claude",
        max_turns: 1
      )

      {:ok, workspace} = SymphonyElixir.PathSafety.canonicalize(Path.join([ctx.test_root, "workspaces", ctx.repo_key, "TP-89"]))
      File.mkdir_p!(Path.dirname(workspace))
      git!(primary, ["worktree", "add", "-q", "-b", "auto/TP-89", workspace, "origin/main"])
      base = git!(workspace, ["rev-parse", "HEAD"])
      pr_head = commit!(workspace, "a person's push")
      git!(workspace, ["push", "-q", "origin", "HEAD:refs/heads/auto/TP-89", "HEAD:refs/pull/89/head"])
      git!(workspace, ["reset", "-q", "--hard", base])

      issue = %Issue{id: "issue-rework-sync", identifier: "TP-89", title: "Rework it", state: "Rework"}
      :ok = TicketPullRequest.put(ctx.repo_key, issue.id, %{pr_url: "https://github.com/acme/repo/pull/89"})

      capture_log(fn ->
        assert :ok =
                 AgentRunner.run(issue, nil,
                   agent_module: HeadAgent,
                   run_id: "run-rework",
                   pr_conflict: %{head_ref: "auto/TP-89", head_sha: pr_head, base_ref: "main"},
                   issue_enricher: &{:ok, &1},
                   issue_state_fetcher: fn _ids -> {:ok, [%{issue | state: "Done"}]} end,
                   leftover_processes: [table: fn -> {:ok, []} end]
                 )
      end)

      assert_received {:turn_on, ^pr_head}
      assert [%{payload: %{winner: "pull_request", action: "reset", run_kind: "rework"}}] = TicketEvents.query(issue.id, types: ["workspace.synced"])
      assert git!(primary, ["for-each-ref", "refs/symphony/orphaned"]) == ""
    end
  end

  defp run(ctx) do
    AgentRunner.run(ctx.issue, nil,
      workspace_path: ctx.workspace,
      agent_module: HeadAgent,
      run_id: "run-#{System.unique_integer([:positive])}",
      issue_enricher: &{:ok, &1},
      issue_state_fetcher: fn _ids -> {:ok, [%{ctx.issue | state: "Done"}]} end,
      leftover_processes: [table: fn -> {:ok, []} end]
    )
  end

  # A workspace at `head` whose PR head on its `origin` (`refs/pull/<number>/head`) is one commit ahead.
  defp behind_pr_workspace!(workspace, branch, number) do
    origin = workspace <> "-origin.git"
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "-q", "-b", branch])
    git!(workspace, ["init", "-q", "--bare", origin])
    git!(workspace, ["remote", "add", "origin", origin])
    head = commit!(workspace, "first")
    pr_head = commit!(workspace, "upkeep merge")
    git!(workspace, ["push", "-q", "origin", "HEAD:refs/heads/#{branch}", "HEAD:refs/pull/#{number}/head"])
    git!(workspace, ["reset", "-q", "--hard", head])
    {head, pr_head}
  end

  defp commit!(dir, message) do
    git!(dir, ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", message])
    git!(dir, ["rev-parse", "HEAD"])
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(output)
  end
end
