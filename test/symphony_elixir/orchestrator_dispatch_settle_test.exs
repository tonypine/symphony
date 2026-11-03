defmodule SymphonyElixir.OrchestratorDispatchSettleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.Settle
  alias SymphonyElixir.{Pauses, TicketObservation}

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-settle-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-settle","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-settle","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      quality_gate: %{enabled: false},
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_terminal_states: ["Done", "Canceled"],
      workspace_root: Path.join(test_root, "workspaces"),
      agent_kind: "claude",
      agent_command: fake_claude,
      max_turns: 1
    )

    :ok = RunStore.clear()
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      File.rm_rf(test_root)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result)
      Application.delete_env(:symphony_elixir, :dispatch_settle_ms)
    end)

    :ok
  end

  describe "the first dispatch of a ticket Linear just created" do
    test "waits for its relations: a blocker the next webhook brings holds it" do
      created = new_ticket()
      linear!([created])

      {state, log} = with_log(fn -> Orchestrator.dispatch_chosen_issues_for_test([created], orchestrator_state()) end)
      assert log =~ "Holding the first dispatch of a new ticket for its relations: issue_id=#{created.id}"
      assert state.running == %{} and state.slot_waiting == %{}
      assert Settle.settling?(state.dispatch_settle, created.id)
      refute_received {:memory_tracker_fetch_issue_states_by_ids, _ids}

      # A second candidate pass before the settle ends sets no second timer and reads nothing.
      %{timer: timer} = state.dispatch_settle[created.id]
      state = Orchestrator.dispatch_chosen_issues_for_test([created], state)
      assert %{timer: ^timer} = state.dispatch_settle[created.id]

      # The relation lands in Linear and its webhook changes the ticket's record: the settle ends
      # with a by-id read, which finds the blocker and pauses the ticket on it.
      linear!([%{created | blocked_by: [blocker()]}])
      {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", created.id, :changed, [:blockers]}, state)
      assert_received {:memory_tracker_fetch_issue_states_by_ids, [_id]}
      refute Settle.settling?(state.dispatch_settle, created.id)
      assert Pauses.paused?({:ticket, "default", created.id})

      # The timer it cancelled may still be in the mailbox: it reads nothing more.
      {:noreply, state} = Orchestrator.handle_info({:dispatch_settle, created.id}, state)
      refute_received {:memory_tracker_fetch_issue_states_by_ids, _ids}

      # Settled, the candidate the cycle still holds is revalidated as any other and held.
      {state, log} = with_log(fn -> Orchestrator.dispatch_chosen_issues_for_test([created], state) end)
      refute log =~ "Holding the first dispatch"
      assert state.running == %{} and state.slot_waiting == %{}
    end

    test "with no relation after the settle, dispatches as today" do
      created = new_ticket()
      linear!([created])
      Application.put_env(:symphony_elixir, :dispatch_settle_ms, 50)

      state = capture(fn -> Orchestrator.dispatch_chosen_issues_for_test([created], orchestrator_state()) end)
      assert Settle.settling?(state.dispatch_settle, created.id)
      assert state.dispatch_skipped[created.id].reason == "waiting for its relations: Linear created it a moment ago"

      # The settle's one timer fires and reads the ticket; nothing blocks it, and a cycle is asked for.
      created_id = created.id
      assert_receive {:dispatch_settle, ^created_id}, 1_000
      {:noreply, state} = Orchestrator.handle_info({:dispatch_settle, created_id}, state)
      assert_received {:memory_tracker_fetch_issue_states_by_ids, [^created_id]}
      refute Pauses.paused?({:ticket, "default", created_id})
      assert state.tick_timer_ref != nil or state.cycle_requested

      # The cycle dispatches it: it passes the settle and its revalidation, and its run starts.
      state = capture(fn -> Orchestrator.dispatch_chosen_issues_for_test([created], state) end)
      assert Map.has_key?(state.running, created_id)

      # Its settle timer fired no sooner than the end of the settle, so the dispatch dropped its entry.
      refute Map.has_key?(state.dispatch_settle, created_id)
      stop_runs(state)
    end

    test "a settle read that fails, or finds nothing, settles the ticket for its revalidation" do
      created = new_ticket()
      linear!([])

      state = capture(fn -> Orchestrator.dispatch_chosen_issues_for_test([created], orchestrator_state()) end)
      {{:noreply, state}, log} = with_log(fn -> Orchestrator.handle_info({:dispatch_settle, created.id}, state) end)
      assert log =~ "Settle read of a new ticket found nothing: issue_id=#{created.id}"
      refute Settle.settling?(state.dispatch_settle, created.id)

      other = %{new_ticket() | id: "settle-failed", identifier: "MT-8"}
      Application.put_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result, {:error, :linear_down})
      state = capture(fn -> Orchestrator.dispatch_chosen_issues_for_test([other], state) end)
      {{:noreply, state}, log} = with_log(fn -> Orchestrator.handle_info({:dispatch_settle, other.id}, state) end)
      assert log =~ "Settle read of a new ticket failed: issue_id=#{other.id}: :linear_down"
      refute Settle.settling?(state.dispatch_settle, other.id)
    end

    test "an older ticket, or one with no creation time, dispatches at once" do
      old = %{new_ticket() | created_at: DateTime.add(DateTime.utc_now(), -60, :second)}
      linear!([old])

      state = capture(fn -> Orchestrator.dispatch_chosen_issues_for_test([old], orchestrator_state()) end)
      assert Map.has_key?(state.running, old.id)
      assert state.dispatch_settle == %{}
      stop_runs(state)
    end
  end

  describe "a run in its start window" do
    test "is stopped when a blocker reaches its record, and the ticket holds" do
      ticket = %{new_ticket() | created_at: nil}
      state = running(orchestrator_state(), ticket, nil)

      # A record change with no blocker leaves the start alone.
      {:ok, :updated} = TicketObservation.observe("default", ticket, source: :webhook)
      {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", ticket.id, :changed, [:title]}, state)
      assert Map.has_key?(state.running, ticket.id)

      # The relation's webhook writes the blocker before the agent's first turn: the start stops.
      linked = %{ticket | blocked_by: [blocker()], updated_at: DateTime.add(ticket.updated_at, 1, :second)}
      {:ok, :updated} = TicketObservation.observe("default", linked, source: :webhook)

      {{:noreply, state}, log} =
        with_log(fn -> Orchestrator.handle_info({:ticket_record, "default", ticket.id, :changed, [:blockers]}, state) end)

      assert log =~ "Stopping the start of issue_id=#{ticket.id}"
      assert state.running == %{}
      refute MapSet.member?(state.claimed, ticket.id)
      assert Pauses.paused?({:ticket, "default", ticket.id})
      refute Orchestrator.should_dispatch_issue_for_test(linked, state)
    end

    test "a run whose agent session started finishes its turn; a pause change of a starting run is checked too" do
      ticket = %{new_ticket() | created_at: nil, blocked_by: [blocker()]}
      {:ok, :updated} = TicketObservation.observe("default", ticket, source: :webhook)

      started = running(orchestrator_state(), ticket, "thread-1")
      {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", ticket.id, :changed, [:blockers]}, started)
      assert Map.has_key?(state.running, ticket.id)

      starting = running(orchestrator_state(), ticket, nil)
      {:noreply, state} = capture(fn -> Orchestrator.handle_info({:ticket_record, "default", ticket.id, :changed, [:pause]}, starting) end)
      assert state.running == %{}

      # A starting run of a ticket with no record is left alone.
      unknown = %{ticket | id: "no-record"}
      {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", unknown.id, :changed, [:pause]}, running(orchestrator_state(), unknown, nil))
      assert Map.has_key?(state.running, unknown.id)
    end
  end

  defp capture(fun) do
    capture_log(fn -> send(self(), {:captured, fun.()}) end)
    assert_received {:captured, result}
    result
  end

  defp new_ticket do
    %Issue{
      id: "settle-#{System.unique_integer([:positive])}",
      identifier: "MT-7",
      title: "Created with a blocker",
      state: "Todo",
      priority: 1,
      repo_key: "default",
      url: "https://linear.app/acme/issue/MT-7",
      created_at: DateTime.utc_now(),
      updated_at: DateTime.truncate(DateTime.utc_now(), :second),
      blocked_by: []
    }
  end

  defp blocker, do: %{id: "id-MT-6", identifier: "MT-6", state: "Todo"}

  defp linear!(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp running(state, %Issue{} = issue, session_id) do
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
      session_id: session_id,
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

  # The runs a test started stop with it.
  defp stop_runs(state) do
    for {_issue_id, %{pid: pid}} <- state.running, is_pid(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp orchestrator_state do
    %Orchestrator.State{
      poll_interval_ms: 100,
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
