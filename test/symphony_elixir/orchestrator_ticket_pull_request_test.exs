defmodule SymphonyElixir.OrchestratorTicketPullRequestTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StatusDashboard.Renderer
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixirWeb.Presenter

  @pr_url "https://github.com/example/repo/pull/1012"

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    :ok
  end

  describe "a running ticket's PR, from Symphony's record" do
    test "shows that PR in the snapshot and /api/v1/state" do
      :ok = TicketPullRequest.record_created(Config.repo_key!(), "issue-running-pr", @pr_url, "auto/MT-1012")
      {name, pid} = start_orchestrator(:RunningRecordedPr)
      put_running(pid, issue("issue-running-pr", "In Progress"))

      assert %{running: [%{pull_request_url: @pr_url}]} = GenServer.call(pid, :snapshot)
      assert %{running: [%{issue_identifier: "MT-1012", pull_request_url: @pr_url}]} = state_payload(name, pid)
    end

    test "shows no PR once that PR closed or merged" do
      for finished <- ["closed", "merged"] do
        :ok = TicketPullRequest.record_created(Config.repo_key!(), "issue-running-pr", @pr_url, "auto/MT-1012")
        :ok = TicketPullRequest.mark_finished(Config.repo_key!(), @pr_url, finished)
        {name, pid} = start_orchestrator(:"RunningFinishedPr#{finished}")
        put_running(pid, issue("issue-running-pr", "In Progress"))

        assert %{running: [%{pull_request_url: nil}]} = GenServer.call(pid, :snapshot)
        assert %{running: [%{pull_request_url: nil}]} = state_payload(name, pid)
        stop_process(pid)
      end
    end

    test "shows no PR when Symphony has no record for the ticket" do
      {name, pid} = start_orchestrator(:RunningNoRecord)
      put_running(pid, issue("issue-running-pr", "In Progress"))

      assert %{running: [%{pull_request_url: nil}]} = GenServer.call(pid, :snapshot)
      assert %{running: [%{pull_request_url: nil}]} = state_payload(name, pid)
    end

    test "keeps a PR URL the run itself reported" do
      :ok = TicketPullRequest.record_created(Config.repo_key!(), "issue-running-pr", @pr_url, "auto/MT-1012")
      :ok = TicketPullRequest.mark_finished(Config.repo_key!(), @pr_url, "closed")
      reported = "https://github.com/example/repo/pull/1013"
      {_name, pid} = start_orchestrator(:RunningReportedPr)
      put_running(pid, issue("issue-running-pr", "In Progress"), %{pull_request_url: reported})

      assert %{running: [%{pull_request_url: ^reported}]} = GenServer.call(pid, :snapshot)
    end
  end

  describe "a watched ticket's PR, from Symphony's record" do
    test "shows that PR in the snapshot, /api/v1/state and the terminal status" do
      watched = issue("issue-watched-pr", "In Review")
      :ok = TicketPullRequest.record_created(Config.repo_key!(), watched.id, @pr_url, "auto/MT-1012")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [watched])
      {name, pid} = start_orchestrator(:WatchedRecordedPr)
      put_completed(pid, watched.id)

      send(pid, :run_poll_cycle)
      snapshot = wait_for_watching(pid)

      assert [%{identifier: "MT-1012", pull_request_url: @pr_url}] = snapshot.watching
      assert %{watching: [%{pull_request_url: @pr_url}]} = state_payload(name, pid)

      rendered = Renderer.format_snapshot_content({:ok, snapshot}, 0.0, 200)
      assert Regex.replace(~r/\e\[[0-9;]*m/, rendered, "") =~ "PR / LINEAR URL"
    end

    test "shows no PR once the recorded PR merged" do
      watched = issue("issue-watched-pr", "In Review")
      :ok = TicketPullRequest.record_created(Config.repo_key!(), watched.id, @pr_url, "auto/MT-1012")
      :ok = TicketPullRequest.mark_finished(Config.repo_key!(), @pr_url, "merged")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [watched])
      {name, pid} = start_orchestrator(:WatchedMergedPr)
      put_completed(pid, watched.id)

      send(pid, :run_poll_cycle)

      assert [%{identifier: "MT-1012", pull_request_url: nil}] = wait_for_watching(pid).watching
      assert %{watching: [%{pull_request_url: nil}]} = state_payload(name, pid)
    end
  end

  defp issue(id, state) do
    %Issue{id: id, identifier: "MT-1012", title: "Recorded PR", state: state, url: "https://linear.app/example/issue/MT-1012"}
  end

  defp start_orchestrator(suffix) do
    name = Module.concat(__MODULE__, suffix)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: stop_process(pid) end)
    {name, pid}
  end

  defp put_running(pid, %Issue{} = issue, extra \\ %{}) do
    entry =
      Map.merge(
        %{
          pid: self(),
          ref: make_ref(),
          run_id: "run-#{issue.id}",
          repo_key: Config.repo_key!(),
          identifier: issue.identifier,
          issue: issue,
          session_id: nil,
          turn_count: 0,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: DateTime.utc_now()
        },
        extra
      )

    :sys.replace_state(pid, fn state ->
      %{state | running: %{issue.id => entry}, claimed: MapSet.put(state.claimed, issue.id)}
    end)
  end

  defp put_completed(pid, issue_id) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | completed: MapSet.put(state.completed, issue_id),
          completed_run_metadata: %{issue_id => %{identifier: "MT-1012", last_ran_at: DateTime.utc_now()}},
          running: %{},
          watching: %{},
          retry_attempts: %{}
      }
    end)
  end

  # `/api/v1/state` reads the snapshot the orchestrator last published.
  defp state_payload(name, pid) do
    send(pid, :publish_snapshot)
    :sys.get_state(pid)
    Presenter.state_payload(name, 1_000)
  end

  defp wait_for_watching(pid) do
    Enum.reduce_while(1..200, nil, fn _attempt, _snapshot ->
      case GenServer.call(pid, :snapshot) do
        %{watching: [_entry]} = snapshot ->
          {:halt, snapshot}

        snapshot ->
          Process.sleep(5)
          {:cont, snapshot}
      end
    end)
  end
end
