defmodule SymphonyElixir.OrchestratorUpdateWindowTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pauses

  @t0 ~U[2026-11-21 14:00:00Z]

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-update-window-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_terminal_states: ["Done", "Canceled"],
      workspace_root: Path.join(test_root, "workspaces"),
      max_concurrent_agents: 3,
      quality_gate: %{enabled: false}
    )

    :ok = RunStore.clear()

    on_exit(fn ->
      Pauses.clear(:symphony)
      File.rm_rf(test_root)
    end)

    :ok
  end

  defp at(minutes), do: DateTime.add(@t0, round(minutes * 60), :second)
  defp clock(state, minutes), do: %{state | clock: fn -> at(minutes) end}

  defp ready(state, version) do
    {:reply, reply, state} = Orchestrator.handle_call({:update_ready, version}, {self(), make_ref()}, state)
    {reply, state}
  end

  # What Symphony does when a run ends or a ticket's pause changes: the update decides before any slot is refilled.
  defp resume(state, reason), do: Orchestrator.handle_call({:resume_dispatch, reason}, {self(), make_ref()}, state)

  defp between_turns_step,
    do: %{id: "code", title: "Write the code", mode: "delegated", waiting: :slot, waiter: self(), started_at: at(-1)}

  defp run_ended(state, issue_id) do
    state = %{state | running: Map.delete(state.running, issue_id)}
    {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", issue_id, :changed, [:pause]}, state)
    state
  end

  defp check(state) do
    {:noreply, state} = Orchestrator.handle_info({:ticket_record, "default", "none", :changed, [:pause]}, state)
    state
  end

  defp update_reasons do
    for %{kind: :build, waits_on: %{version: version}} <- symphony_reasons(), do: version
  end

  defp symphony_reasons do
    case Pauses.get(:symphony) do
      {:ok, %{reasons: reasons}} -> Pauses.dispatch_reasons(%{reasons: reasons})
      _none -> []
    end
  end

  defp window(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot.update_window
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "Ticket #{identifier}", description: "Do it", state: state, priority: 3, labels: [], url: "https://example.org/#{identifier}"}
  end

  defp run(state, %Issue{} = issue, started_at, attrs \\ []) do
    entry =
      Map.merge(
        %{
          pid: self(),
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          run_profile: %{kind: :implementation, model: nil, effort: nil, provider: "anthropic"},
          session_id: "sess-#{issue.id}",
          turn_count: 1,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          started_at: started_at
        },
        Map.new(attrs)
      )

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

  defp two_runs(started_at) do
    orchestrator_state()
    |> run(issue("run-1", "TP-1", "In Progress"), started_at)
    |> run(issue("run-2", "TP-2", "In Progress"), started_at)
  end

  test "an update ready while agent runs are active pauses nothing: other tickets keep getting turns until no run is active" do
    state = two_runs(at(-5)) |> clock(0)
    {{:ok, %{version: "0.0.1.1053", phase: :waiting}}, state} = ready(state, "0.0.1.1053")

    assert update_reasons() == []
    assert Orchestrator.should_dispatch_issue_for_test(issue("todo-1", "TP-3", "Todo"), state)
    assert %{version: "0.0.1.1053", phase: :waiting} = window(state)

    # One run ends: another is still active, so dispatch goes on.
    state = state |> clock(4) |> run_ended("run-1")
    assert update_reasons() == []

    # The last one ends: before its slot is refilled Symphony pauses for the update, with nothing in flight.
    state = state |> clock(6) |> run_ended("run-2")
    assert update_reasons() == ["0.0.1.1053"]
    assert %{phase: :holding, holding_since: holding_since} = window(state)
    assert holding_since == at(6)
  end

  test "a run between agent turns does not count: the update holds at once" do
    state =
      orchestrator_state()
      |> run(issue("run-1", "TP-1", "In Progress"), at(-5), step: between_turns_step())
      |> clock(0)

    {{:ok, %{phase: :holding}}, _state} = ready(state, "0.0.1.1053")
    assert update_reasons() == ["0.0.1.1053"]
  end

  # c8 (TP-1590): Conductor runs are not agent runs here; they go on under the hold and never postpone it.
  test "a Conductor run does not count as an agent run: the update holds while one runs, and a Resume opens the gate again" do
    test = self()
    turn = spawn(fn -> SymphonyElixir.ConductorGate.run(fn -> send(test, :entered) && receive(do: (:end -> :ok)) end) end)
    assert_receive :entered
    on_exit(fn -> SymphonyElixir.ConductorGate.reopen() end)

    state = orchestrator_state() |> clock(0)
    {{:ok, %{phase: :holding}}, state} = ready(state, "0.0.1.1053")
    assert update_reasons() == ["0.0.1.1053"]
    assert SymphonyElixir.ConductorGate.handover() == {:wait, 1}

    ref = Process.monitor(turn)
    send(turn, :end)
    assert_receive {:DOWN, ^ref, :process, ^turn, _reason}
    assert SymphonyElixir.ConductorGate.handover() == :ok
    assert SymphonyElixir.ConductorGate.enter() == :closed

    # Cancel Update lifts the update's pause: the handover is called off, and Conductor runs start again.
    {:reply, {:ok, _pause}, _state} = resume(state, {:build, "0.0.1.1053"})
    assert SymphonyElixir.ConductorGate.enter() == :ok
    SymphonyElixir.ConductorGate.leave()
  end

  test "an update never starts holding behind a run that just began, and once it holds no run gets a new turn" do
    state = orchestrator_state() |> run(issue("run-1", "TP-1", "In Progress"), at(-30)) |> clock(0)
    {_reply, state} = ready(state, "0.0.1.1053")

    # Past the wait, but a run began a minute ago: no hold.
    state = state |> run(issue("run-2", "TP-2", "In Progress"), at(15)) |> clock(16) |> check()
    assert update_reasons() == []

    # Once no active run is younger than 3 minutes, dispatch is held so a gap forms.
    state = state |> clock(18) |> check()
    assert update_reasons() == ["0.0.1.1053"]

    # A run that wants its next turn waits for the update; no new run starts before the new build is up.
    {:noreply, state} =
      Orchestrator.handle_info({:run_step, "run-1", {:turn_wanted, self(), %{id: "review", title: "Review", mode: "delegated"}}}, state)

    refute_received {:run_step_turn, "run-1"}
    assert %{step: %{waiting: :pause}} = state.running["run-1"]
  end

  test "several builds published in a row: dispatch is held once, for the newest, and the wait does not start over" do
    state = two_runs(at(-30)) |> clock(0)
    {_reply, state} = ready(state, "0.0.1.1053")
    {_reply, state} = state |> clock(5) |> ready("0.0.1.1054")
    {{:ok, %{version: "0.0.1.1056", ready_at: ready_at}}, state} = state |> clock(10) |> ready("0.0.1.1056")
    assert ready_at == at(0)
    assert update_reasons() == []

    # The wait counts from the first build ready, not the last.
    state = state |> clock(15) |> check()
    assert update_reasons() == ["0.0.1.1056"]

    # A build published during the hold takes over its pause: still one reason, still one hold.
    {{:ok, %{version: "0.0.1.1057", phase: :holding, holding_since: holding_since}}, _state} = state |> clock(16) |> ready("0.0.1.1057")
    assert holding_since == at(15)
    assert update_reasons() == ["0.0.1.1057"]
  end

  test "the hold has a fixed limit: with runs still active it is lifted, and the update holds again after another wait" do
    state = two_runs(at(-30)) |> clock(0)
    {_reply, state} = ready(state, "0.0.1.1053")
    state = state |> clock(15) |> check()
    assert update_reasons() == ["0.0.1.1053"]

    state = state |> clock(24) |> check()
    assert update_reasons() == ["0.0.1.1053"]

    state = state |> clock(25) |> check()
    assert update_reasons() == []
    assert %{phase: :waiting} = window(state)

    state = state |> clock(40) |> check()
    assert update_reasons() == ["0.0.1.1053"]
  end

  test "an update ready is installed in bounded time when slots are always refilled: the hold lets the runs drain" do
    # Every slot is refilled the moment it frees, so there is never a moment with no run active.
    state = two_runs(at(-10)) |> clock(0)
    {_reply, state} = ready(state, "0.0.1.1053")

    state = state |> clock(8) |> run_ended("run-1") |> run(issue("run-3", "TP-3", "In Progress"), at(8))
    state = state |> clock(12) |> run_ended("run-2") |> run(issue("run-4", "TP-4", "In Progress"), at(12))
    assert update_reasons() == []

    # 15 minutes ready and no run younger than 3 minutes: dispatch is held, so the freed slots stay free.
    state = state |> clock(15) |> check()
    assert update_reasons() == ["0.0.1.1053"]

    state = state |> clock(19) |> run_ended("run-3")
    state = state |> clock(21) |> run_ended("run-4")

    # No run left inside the hold's limit: the pause stands with nothing in flight, which is the app's moment to swap.
    assert update_reasons() == ["0.0.1.1053"]
    assert state.running == %{}
    assert %{phase: :holding} = window(state)
  end

  test "a hold nobody came for, with no run left, calls the update off at its limit" do
    {_reply, state} = orchestrator_state() |> clock(0) |> ready("0.0.1.1053")
    assert update_reasons() == ["0.0.1.1053"]

    state = state |> clock(10) |> check()
    assert update_reasons() == []
    assert window(state) == nil
  end

  test "Resume of the update's own reason calls it off; the Director's Resume during a hold sends it back to waiting" do
    {_reply, state} = orchestrator_state() |> clock(0) |> ready("0.0.1.1053")
    {:reply, {:ok, _pause}, state} = resume(state, {:build, "0.0.1.1053"})
    assert window(state) == nil
    assert update_reasons() == []

    state = orchestrator_state() |> run(issue("run-1", "TP-1", "In Progress"), at(-30)) |> clock(0)
    {_reply, state} = ready(state, "0.0.1.1053")
    state = state |> clock(15) |> check()
    assert update_reasons() == ["0.0.1.1053"]

    {:reply, {:ok, _pause}, state} = Orchestrator.handle_call(:resume_dispatch, {self(), make_ref()}, state)
    assert update_reasons() == []
    assert %{phase: :waiting} = window(state)

    # Resume of another version's reason leaves the update ready.
    {:reply, {:ok, _pause}, state} = resume(state, {:build, "0.0.1.1"})
    assert %{version: "0.0.1.1053"} = window(state)
  end

  test "a pause that can't be written leaves the update as it was" do
    # A reason's line is at most 300 characters, so this version's pause is refused.
    long = "0." <> Enum.map_join(1..150, ".", fn _n -> "1" end)

    {{:ok, %{phase: :waiting}}, state} = orchestrator_state() |> clock(0) |> ready(long)
    assert update_reasons() == []
    assert %{phase: :waiting} = window(state)

    state = orchestrator_state() |> run(issue("run-1", "TP-1", "In Progress"), at(-30)) |> clock(0)
    {_reply, state} = ready(state, "0.0.1.1053")
    state = state |> clock(15) |> check()
    assert {{:error, _reason}, state} = state |> clock(16) |> ready(long)
    assert %{version: "0.0.1.1053", phase: :holding} = window(state)
  end

  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  test "the state payload reports the update ready, so the app can show it waiting while dispatch goes on" do
    window = %{version: "0.0.1.1056", phase: :waiting, ready_at: at(0), holding_since: nil}
    {:ok, pid} = SnapshotOrchestrator.start_link(%{running: [], retrying: [], rate_limits: nil, update_window: window})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    payload = SymphonyElixirWeb.Presenter.state_payload(pid, 1_000)
    assert payload.update_window == %{version: "0.0.1.1056", phase: :waiting, ready_at: "2026-11-21T14:00:00Z", holding_since: nil}
    refute payload.pause.paused
  end

  test "update_ready needs a running orchestrator" do
    assert Orchestrator.update_ready(:no_such_orchestrator, "0.0.1.1053") == :unavailable
  end
end
