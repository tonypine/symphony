defmodule SymphonyElixir.AgentRunnerProgressTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.WorkspaceHead

  @pr_url "https://github.com/example/repo/pull/337"

  defmodule ProgressAgent do
    # Coding-agent stand-in: every turn completes and is reported to the test.
    def start_session(_workspace, _opts), do: {:ok, %{}}

    def run_turn(_session, _prompt, _issue, _opts) do
      count = Application.get_env(:symphony_elixir, :progress_agent_turns, 0) + 1
      Application.put_env(:symphony_elixir, :progress_agent_turns, count)
      send(Application.fetch_env!(:symphony_elixir, :progress_agent_recipient), {:progress_turn, count})
      {:ok, %{session_id: "sess-#{count}"}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule ProgressGitHub do
    # Stands in for GitHub.PullRequest.fetch_ci_status/2 and reports the configured PR head.
    def fetch_ci_status(pr_url, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :progress_agent_recipient), {:pr_head_fetched, pr_url})
      Application.fetch_env!(:symphony_elixir, :progress_pr_head_result)
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :progress_agent_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-rework", checks: []}})

    on_exit(fn ->
      for key <- [
            :progress_agent_recipient,
            :progress_agent_turns,
            :progress_pr_head_result,
            :memory_tracker_update_issue_state_result
          ] do
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    :ok
  end

  test "a Rework run whose new commits are the PR head moves to Auto Review without another turn" do
    run_issue!("Rework", heads: ["sha-old", "sha-rework"])

    assert turns() == 1
    assert_received {:pr_head_fetched, @pr_url}
    assert_received {:memory_tracker_state_update, "issue-progress", "Auto Review"}
  end

  test "with Auto Review off a finished Rework run moves to In Review" do
    run_issue!("Rework", heads: ["sha-old", "sha-rework"], auto_review: nil)

    assert turns() == 1
    assert_received {:memory_tracker_state_update, "issue-progress", "In Review"}
  end

  test "a re-dispatched Rework run whose rework is already pushed moves on after one empty turn" do
    run_issue!("Rework", heads: ["sha-rework"])

    assert turns() == 1
    assert_received {:memory_tracker_state_update, "issue-progress", "Auto Review"}
  end

  test "a Rework run with unresolved review comments on the current head keeps going" do
    assert :ok =
             RunStore.put_pr_review(%{
               repo_key: "default",
               issue_id: "issue-progress",
               issue_identifier: "TP-337",
               pr_url: @pr_url,
               workspace_path: "/tmp",
               status: "rework_requested",
               pending_last_addressed_comment_id: "comment-337",
               pending_reviewer_comments: [%{id: "comment-337", kind: "inline_comment", author: "Reviewer", body: "Rename this."}],
               updated_at: ~U[2026-10-03 12:00:00Z]
             })

    run_issue!("Rework", heads: ["sha-old", "sha-rework", "sha-rework-2"], states: ["Rework", "Done"])

    assert turns() == 2
    refute_received {:pr_head_fetched, _pr_url}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "a Rework run keeps going while its commits are not the PR head or the head is unreadable" do
    for pr_head_result <- [{:ok, %{commit_sha: "sha-old", checks: []}}, {:error, :gh_unavailable}] do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
      Application.delete_env(:symphony_elixir, :progress_agent_turns)

      run_issue!("Rework", heads: ["sha-old", "sha-rework", "sha-rework-2"], states: ["Rework", "Done"])

      assert turns() == 2
      assert_received {:pr_head_fetched, @pr_url}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end
  end

  test "two consecutive empty turns stop the run and park the issue in Backlog" do
    run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5)

    assert turns() == 2
    assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue in Backlog" <> _note}
  end

  test "a turn that adds a commit or follows a state change resets the empty-turn count" do
    run_issue!("In Progress",
      heads: ["sha-1", "sha-1", "sha-2", "sha-2", "sha-2"],
      states: ["In Progress", "In Progress", "In Progress", "Todo", "Done"],
      pr_url: nil,
      max_turns: 5
    )

    assert turns() == 5
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "empty landing turns are left to the Merging CI wait" do
    green = [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: green}})

    run_issue!("Merging", heads: ["sha-same"], states: ["Merging", "Merging", "Done"], max_turns: 5)

    assert turns() == 3
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "a failed state move after a finished rework or an idle park fails the run" do
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})

    assert_raise RuntimeError, ~r/rework_handoff_failed/, fn ->
      run_issue!("Rework", heads: ["sha-old", "sha-rework"])
    end

    Application.delete_env(:symphony_elixir, :progress_agent_turns)

    assert_raise RuntimeError, ~r/idle_park_failed/, fn ->
      run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5)
    end
  end

  # `heads` is the workspace HEAD at run start and after each turn (the last one repeats);
  # `states` is the issue state after each turn (the last one repeats).
  defp run_issue!(state, opts) do
    heads = Keyword.fetch!(opts, :heads)
    states = Keyword.get(opts, :states, [state])
    pr_url = Keyword.get(opts, :pr_url, @pr_url)
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-progress-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "TP-337")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      workspace_root: test_root,
      max_turns: Keyword.get(opts, :max_turns, 3),
      auto_review: Keyword.get(opts, :auto_review, %{enabled: true})
    )

    issue = %Issue{id: "issue-progress", identifier: "TP-337", title: "Leave Rework", state: state, pull_request_url: pr_url}

    try do
      AgentRunner.run(issue, nil,
        workspace_path: workspace,
        agent_module: ProgressAgent,
        github: ProgressGitHub,
        workspace_head_reader: fn ^workspace, nil -> at_turn(heads) end,
        issue_state_fetcher: fn _ids -> {:ok, [%{issue | state: at_turn(states, -1)}]} end,
        issue_enricher: &{:ok, &1}
      )
    after
      File.rm_rf(test_root)
    end
  end

  defp at_turn(values, offset \\ 0) do
    Enum.at(values, turns() + offset) || List.last(values)
  end

  defp turns, do: Application.get_env(:symphony_elixir, :progress_agent_turns, 0)

  test "the workspace HEAD reads from a local git checkout only" do
    root = Path.join(System.tmp_dir!(), "symphony-workspace-head-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)

    try do
      System.cmd("git", ["-C", repo, "init", "-b", "main"])
      assert WorkspaceHead.read(repo, nil) == nil

      File.write!(Path.join(repo, "README.md"), "# test")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial"])
      {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])

      assert WorkspaceHead.read(repo, nil) == String.trim(sha)
      assert WorkspaceHead.read(repo, "worker-1") == nil
      assert WorkspaceHead.read(Path.join(root, "missing"), nil) == nil
    after
      File.rm_rf(root)
    end
  end
end
