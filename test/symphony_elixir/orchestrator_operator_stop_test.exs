defmodule SymphonyElixir.OrchestratorOperatorStopTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Hold, OperatorStop, RunStore, Tracker}

  @active_states ["Todo", "In Progress", "Rework"]

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-operator-stop-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-stop","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-stop","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: @active_states,
      tracker_terminal_states: ["Done", "Canceled", "Duplicate"],
      workspace_root: Path.join(test_root, "workspaces"),
      agent_kind: "claude",
      agent_command: fake_claude,
      max_turns: 1,
      quality_gate: %{enabled: false}
    )

    :ok = RunStore.clear()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      File.rm_rf(test_root)
    end)

    :ok
  end

  test "a stopped ticket still in Todo is skipped on the next dispatch tick, and the stop asks for a poll" do
    issue = issue("stopped", "MT-STOP", "Todo")
    tracked([issue])

    state = stop(running(orchestrator_state(), issue), issue)

    # The stop asked for a poll at once rather than waiting out the interval.
    assert_receive {:tick, token}
    assert token == state.tick_token
    assert state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert %{"stopped" => %{identifier: "MT-STOP", repo_key: "default", state: nil, held: true}} = state.operator_stops
    assert %{reason: "Stopped by you at " <> _} = Hold.get("default", "stopped", :blocked)

    state = Orchestrator.dispatch_chosen_issues_for_test([issue], state)

    assert state.running == %{}
    assert [%{identifier: "MT-STOP", reason: reason}] = snapshot_of(state).dispatch_skipped
    assert reason =~ ~r/^stopped by the operator at \d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC; waiting for the next poll$/
  end

  test "a poll that finds the ticket still active keeps it skipped, and lifting its hold (Restart) dispatches it" do
    issue = issue("stopped", "MT-STOP", "Todo")
    tracked([issue])
    state = stop(running(orchestrator_state(), issue), issue)

    state = poll(state)
    assert %{"stopped" => %{state: "Todo"}} = state.operator_stops

    state = Orchestrator.dispatch_chosen_issues_for_test([issue], state)
    assert state.running == %{}
    assert [%{reason: reason}] = snapshot_of(state).dispatch_skipped
    assert reason =~ "; Unblock or Restart in the Director runs it again"

    # Another poll on the same state changes nothing.
    assert poll(state).operator_stops == state.operator_stops

    # Restart (and Unblock) clear the hold; the ticket dispatches on the next tick, and the next
    # poll drops the mark.
    :ok = Hold.clear("default", "stopped", :blocked)
    dispatched = Orchestrator.dispatch_chosen_issues_for_test([issue], state)
    assert Map.has_key?(dispatched.running, "stopped")

    log = capture_log(fn -> send(self(), {:state, poll(state)}) end)
    assert_received {:state, %{operator_stops: stops}}
    assert stops == %{}
    assert log =~ "Operator stop lifted by a person: issue_id=stopped issue_identifier=MT-STOP"
  end

  test "a poll that finds the ticket terminal clears the mark and its hold, and leaves nothing running" do
    issue = issue("stopped", "MT-STOP", "Todo")
    tracked([issue])
    state = stop(running(orchestrator_state(), issue), issue)

    tracked([%{issue | state: "Duplicate"}])
    state = poll(state)

    assert state.operator_stops == %{}
    refute Hold.held?("default", "stopped", :blocked)
    assert state.running == %{}
  end

  test "a ticket moved on the board after the poll confirmed it, or no longer returned, is cleared" do
    moved = issue("moved", "MT-MOVED", "Todo")
    gone = issue("gone", "MT-GONE", "Todo")
    backlog = issue("backlog", "MT-BACKLOG", "Todo")
    tracked([moved, gone, backlog])

    state = orchestrator_state() |> running(moved) |> running(gone) |> running(backlog)
    state = state |> stop(moved) |> stop(gone) |> stop(backlog)
    state = poll(state)
    assert map_size(state.operator_stops) == 3

    tracked([%{moved | state: "In Progress"}, %{backlog | state: "Backlog"}])
    state = poll(state)

    assert state.operator_stops == %{}
    for issue_id <- ["moved", "gone", "backlog"], do: refute(Hold.held?("default", issue_id, :blocked))
  end

  test "a mark cleared while its hold is still being written has the hold cleared once it lands" do
    issue = issue("stopped", "MT-STOP", "Todo")
    mark = OperatorStop.mark("MT-STOP", "default", DateTime.utc_now())
    :ok = OperatorStop.set_hold("default", "stopped", mark)

    # The poll finds the ticket terminal while the hold write is in flight; that write lands after
    # the mark went, so the hold is cleared once it does.
    ref = make_ref()
    context = %{kind: :operator_stop_hold, issue_ids: ["stopped"], repo_key: "default"}
    in_flight = %{orchestrator_state() | operator_stops: %{"stopped" => mark}, tracker_tasks: %{ref => context}}
    send(self(), {ref, {:tracker_task_result, :ok}})

    state = Orchestrator.apply_operator_stops_result_for_test(in_flight, ["stopped"], {:ok, [%{issue | state: "Done"}]})

    assert state.operator_stops == %{}
    assert state.tracker_tasks == %{}
    refute Hold.held?("default", "stopped", :blocked)
  end

  test "a hold the store refuses leaves the mark in force, and a failed read keeps every mark" do
    mark = OperatorStop.mark("MT-STOP", "default", DateTime.utc_now())
    ref = make_ref()
    context = %{kind: :operator_stop_hold, issue_ids: ["stopped"], repo_key: "default"}
    state = %{orchestrator_state() | operator_stops: %{"stopped" => mark}, tracker_tasks: %{ref => context}}

    log =
      capture_log(fn ->
        {:noreply, state} = Orchestrator.handle_info({ref, {:tracker_task_result, {:error, :boom}}}, state)
        send(self(), {:state, state})
      end)

    assert_received {:state, state}
    assert state.operator_stops == %{"stopped" => mark}
    assert log =~ "Failed to hold a ticket the operator stopped: issue_id=stopped reason=:boom"

    log =
      capture_log(fn ->
        assert Orchestrator.apply_operator_stops_result_for_test(state, ["stopped"], {:error, :linear_down}) == state
      end)

    assert log =~ "Failed to read the tickets the operator stopped; they stay skipped: :linear_down"

    # A mark a person lifted between the poll's start and its result is passed over; no marks, no read.
    lifted = Orchestrator.apply_operator_stops_result_for_test(%{state | operator_stops: %{}}, ["stopped"], {:ok, []})
    assert lifted.operator_stops == %{}
    assert Orchestrator.apply_operator_stops_result_for_test(state, [], {:error, :not_read}) == state
  end

  test "a PR run's stop marks no ticket" do
    issue = %{issue("pr:default:7", "default#7", "Todo") | run_kind: :pr}
    state = stop(running(orchestrator_state(), issue), issue)

    assert state.operator_stops == %{}
    refute_received {:tick, _token}
  end

  test "a Symphony that starts again keeps the marks its store holds, to be confirmed by the next poll" do
    :ok = OperatorStop.set_hold("default", "stopped", OperatorStop.mark("MT-STOP", "default", ~U[2026-10-20 08:41:25Z]))
    name = Module.concat(__MODULE__, :Restarted)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: stop_process(pid) end)

    assert %{"stopped" => %{repo_key: "default", state: nil, held: true}} = :sys.get_state(pid).operator_stops
  end

  defp stop(state, %Issue{} = issue) do
    {:reply, {:ok, %{stopped: true}}, state} =
      Orchestrator.handle_call({:stop_running, issue.identifier}, {self(), make_ref()}, state)

    await_tasks(state)
  end

  defp poll(state) do
    ids = Map.keys(state.operator_stops)
    {:ok, issues} = Tracker.fetch_issue_states_by_ids(ids)
    Orchestrator.apply_operator_stops_result_for_test(state, ids, {:ok, issues})
  end

  # The stop's hold is written in a task whose answer comes to this process, as it would to the
  # orchestrator's.
  defp await_tasks(%{tracker_tasks: tasks} = state) when map_size(tasks) == 0, do: state

  defp await_tasks(%{tracker_tasks: tasks} = state) do
    receive do
      {ref, {:tracker_task_result, _result}} = message when is_map_key(tasks, ref) ->
        {:noreply, state} = Orchestrator.handle_info(message, state)
        await_tasks(state)

      {:DOWN, ref, :process, _pid, _reason} = message when is_map_key(tasks, ref) ->
        {:noreply, state} = Orchestrator.handle_info(message, state)
        await_tasks(state)
    end
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
  end

  defp issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Ticket #{identifier}",
      description: "Finish it",
      state: state,
      priority: 1,
      team: %{key: "Test"},
      labels: [],
      repo_key: "default",
      url: "https://example.org/issues/#{identifier}"
    }
  end

  defp running(state, %Issue{} = issue) do
    worker = spawn(fn -> Process.sleep(:infinity) end)

    entry = %{
      repo_key: "default",
      pid: worker,
      ref: Process.monitor(worker),
      run_id: "run-#{issue.id}",
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      run_profile: %{kind: :implementation, model: nil, effort: nil, provider: "anthropic"},
      session_id: nil,
      turn_count: 0,
      retry_attempt: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      forced: false,
      started_at: DateTime.utc_now()
    }

    %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
  end

  defp orchestrator_state do
    %Orchestrator.State{
      repo_key: "default",
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
