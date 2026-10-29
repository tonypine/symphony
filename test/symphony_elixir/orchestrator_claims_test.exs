defmodule SymphonyElixir.OrchestratorClaimsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TicketObservation

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-claims-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(test_root, "workspaces"),
      quality_gate: %{enabled: false},
      tracker_active_states: ["Todo", "In Progress", "Rework"]
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      File.rm_rf(test_root)
    end)

    :ok
  end

  test "a retry whose dispatch finds the issue parked releases the claim, so the next poll can dispatch it" do
    parked = issue("issue-parked", "MT-PARK", "Backlog")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [parked])
    state = %{orchestrator_state() | claimed: MapSet.new([parked.id])}

    # The retry's own refresh still sees the issue active; the dispatch refresh sees it parked.
    log =
      capture_log(fn ->
        assert {:noreply, state} =
                 Orchestrator.handle_retry_issue_for_test(state, parked.id, 1, %{identifier: parked.identifier}, fn _ids ->
                   {:ok, [%{parked | state: "In Progress"}]}
                 end)

        send(self(), {:state, state})
      end)

    assert_received {:state, state}
    assert log =~ "Skipping stale dispatch after issue refresh"
    assert state.claimed == MapSet.new()
    assert state.retry_attempts == %{}
    assert state.running == %{}

    todo = %{parked | state: "Todo"}
    refute Orchestrator.should_dispatch_issue_for_test(todo, %{state | claimed: MapSet.new([parked.id])})
    assert Orchestrator.should_dispatch_issue_for_test(todo, state)
  end

  test "a retry whose dispatch finds the issue gone releases the claim" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    gone = issue("issue-gone", "MT-GONE", "In Progress")
    state = %{orchestrator_state() | claimed: MapSet.new([gone.id])}

    log =
      capture_log(fn ->
        assert {:noreply, state} =
                 Orchestrator.handle_retry_issue_for_test(state, gone.id, 1, %{identifier: gone.identifier}, fn _ids -> {:ok, [gone]} end)

        send(self(), {:state, state})
      end)

    assert_received {:state, state}
    assert log =~ "Skipping dispatch; issue no longer active or visible"
    assert state.claimed == MapSet.new()
  end

  test "a poll dispatch that finds the issue stale leaves claims alone" do
    parked = issue("issue-poll-parked", "MT-POLL", "Backlog")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [parked])

    candidates = [%{parked | state: "Todo"}]
    state = orchestrator_state()
    capture_log(fn -> send(self(), {:state, Orchestrator.dispatch_chosen_issues_for_test(candidates, state)}) end)

    assert_received {:state, state}
    assert state.claimed == MapSet.new()
    assert state.running == %{}
  end

  test "the poll releases an orphaned claim and logs it, keeping every claim that is still held" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :SweepOrchestrator))

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    :sys.get_state(pid)
    gated = issue("issue-gated", "MT-GATED", "In Progress")
    readying = issue("issue-readying", "MT-READY", "In Progress")
    timer_ref = Process.send_after(self(), :never, 60_000)
    on_exit(fn -> Process.cancel_timer(timer_ref) end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | claimed: MapSet.new(["issue-orphan", "issue-retrying", "issue-waiting", gated.id, readying.id]),
          retry_attempts: %{"issue-retrying" => %{attempt: 1, timer_ref: timer_ref, retry_token: make_ref(), due_at_ms: 0}},
          slot_waiting: %{
            "issue-waiting" => %{attempt: 1, identifier: "MT-WAIT", title: "Waiting", state: "Todo", reason: "no available orchestrator slots", since: DateTime.utc_now()}
          },
          quality_gate_tasks: %{make_ref() => {:active_retry, gated, 1, %{}}, make_ref() => :poll},
          dispatch_readiness_tasks: %{make_ref() => %{kind: {:active_retry, readying, 1, %{}}, issues: [readying]}}
      }
    end)

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)
        wait_until(fn -> not MapSet.member?(:sys.get_state(pid).claimed, "issue-orphan") end)
      end)

    assert log =~ "Releasing orphaned claim with no running agent, retry or slot wait: issue_id=issue-orphan"
    assert :sys.get_state(pid).claimed == MapSet.new(["issue-retrying", "issue-waiting", gated.id, readying.id])
    assert Orchestrator.snapshot(Module.concat(__MODULE__, :SweepOrchestrator), 5_000).claimed == Enum.sort(["issue-retrying", "issue-waiting", gated.id, readying.id])
  end

  test "the poll keeps the claims of Linear tasks that hold them until they answer" do
    refreshing = issue("issue-refreshing", "MT-REFRESH", "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :TrackerTaskOrchestrator))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_states_sleep_ms)

      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    wait_until(fn ->
      state = :sys.get_state(pid)
      is_nil(state.repo_poll_task_ref) and not state.poll_check_in_progress
    end)

    # The retry's refresh waits on Linear far longer than the test.
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_states_sleep_ms, 60_000)
    token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | retry_attempts: %{refreshing.id => %{attempt: 1, retry_token: token, identifier: refreshing.identifier, repo_key: Config.repo_key!()}},
          claimed: MapSet.new([refreshing.id, "issue-blocking", "issue-commenting", "issue-orphan"]),
          tracker_tasks: %{
            make_ref() => %{kind: :blocked_hold, issue_ids: ["issue-blocking"]},
            make_ref() => %{kind: :comment, issue_ids: ["issue-commenting"]}
          }
      }
    end)

    tasks_before = Task.Supervisor.children(SymphonyElixir.TaskSupervisor)
    send(pid, {:retry_issue, refreshing.id, token})
    :sys.get_state(pid)
    [refresh_task] = Task.Supervisor.children(SymphonyElixir.TaskSupervisor) -- tasks_before
    on_exit(fn -> Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, refresh_task) end)
    assert Enum.any?(Map.values(:sys.get_state(pid).tracker_tasks), &match?(%{kind: :retry_refresh, issue_ids: ["issue-refreshing"]}, &1))
    assert :sys.get_state(pid).retry_attempts == %{}

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)
        wait_until(fn -> not MapSet.member?(:sys.get_state(pid).claimed, "issue-orphan") end)
      end)

    assert log =~ "Releasing orphaned claim with no running agent, retry or slot wait: issue_id=issue-orphan"
    assert log =~ "Releasing orphaned claim with no running agent, retry or slot wait: issue_id=issue-commenting"
    refute log =~ "issue_id=issue-refreshing"
    refute log =~ "issue_id=issue-blocking"
    assert :sys.get_state(pid).claimed == MapSet.new([refreshing.id, "issue-blocking"])
  end

  test "a running ticket moved by hand has its record updated by the next tick's by-id read, before the repo poll" do
    moved = %{issue("issue-moved", "MT-MOVED", "Rework") | updated_at: ~U[2026-10-29 10:00:00Z]}
    {:ok, :updated} = TicketObservation.observe("default", %{moved | state: "In Progress", updated_at: ~U[2026-10-29 09:00:00Z]})
    pid = start_orchestrator!(:MovedOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [moved])
    agent_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(agent_pid, :kill) end)
    not_due = System.monotonic_time(:millisecond) + 3_600_000

    :sys.replace_state(pid, fn state ->
      running = %{
        pid: agent_pid,
        ref: nil,
        identifier: moved.identifier,
        issue: %{moved | state: "In Progress"},
        repo_key: "default",
        started_at: DateTime.utc_now()
      }

      %{state | running: %{moved.id => running}, claimed: MapSet.new([moved.id]), repo_poll_due_at_ms: %{"default" => not_due}}
    end)

    TicketObservation.reset()
    send(pid, :run_poll_cycle)
    wait_until(fn -> RunStore.get_ticket_state("default", moved.id).phase == "Rework" end)
    assert :sys.get_state(pid).repo_poll_due_at_ms["default"] == not_due

    # An older by-id answer than the record holds is dropped: the record keeps the newer fact.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{moved | state: "Todo", updated_at: ~U[2026-10-29 09:30:00Z]}])
    send(pid, :run_poll_cycle)
    wait_until(fn -> TicketObservation.summary().stale >= 1 end)
    wait_until_idle(pid)

    record = RunStore.get_ticket_state("default", moved.id)
    assert {record.phase, record.linear_updated_at} == {"Rework", ~U[2026-10-29 10:00:00Z]}
    :sys.replace_state(pid, &%{&1 | running: %{}, claimed: MapSet.new()})
  end

  test "the dispatch prefetch writes what it read into the candidates' records" do
    parked = %{issue("issue-prefetch-parked", "MT-PREFETCH", "Backlog") | updated_at: ~U[2026-10-29 10:00:00Z]}
    pid = start_orchestrator!(:PrefetchOrchestrator)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [parked])

    # The repo poll is not due; its cache still holds the ticket in Todo, so dispatch reads it again.
    :sys.replace_state(pid, fn state ->
      cached = %{issues: [%{parked | state: "Todo", updated_at: ~U[2026-10-29 09:00:00Z]}], fetched_at_ms: System.monotonic_time(:millisecond)}
      not_due = System.monotonic_time(:millisecond) + 3_600_000
      %{state | repo_poll_due_at_ms: %{"default" => not_due}, repo_poll_cache: %{"default" => cached}}
    end)

    capture_log(fn ->
      send(pid, :run_poll_cycle)
      wait_until(fn -> match?(%{phase: "Backlog"}, RunStore.get_ticket_state("default", parked.id)) end)
    end)

    assert :sys.get_state(pid).running == %{}
  end

  test "the revalidation before a start writes what it read into the ticket's record" do
    parked = %{issue("issue-revalidated", "MT-REVALIDATED", "Backlog") | updated_at: ~U[2026-10-29 10:00:00Z]}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [parked])

    candidates = [%{parked | state: "Todo"}]
    state = orchestrator_state()
    capture_log(fn -> send(self(), {:state, Orchestrator.dispatch_chosen_issues_for_test(candidates, state)}) end)

    assert_received {:state, %{running: running}}
    assert running == %{}
    assert %{phase: "Backlog", issue_identifier: "MT-REVALIDATED"} = RunStore.get_ticket_state("default", parked.id)
  end

  # Started with no issues in Linear, so its first poll dispatches nothing.
  defp start_orchestrator!(name) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name))

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    wait_until_idle(pid)
    pid
  end

  defp wait_until_idle(pid) do
    wait_until(fn ->
      state = :sys.get_state(pid)
      idle? = is_nil(state.repo_poll_task_ref) and not state.poll_check_in_progress
      idle? and state.dispatch_readiness_tasks == %{} and state.tracker_tasks == %{}
    end)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end

  defp issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Claims #{identifier}",
      state: state,
      team: %{key: "Test"},
      labels: [],
      assigned_to_worker: true,
      url: "https://example.org/issues/#{identifier}"
    }
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
