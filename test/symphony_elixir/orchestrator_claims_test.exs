defmodule SymphonyElixir.OrchestratorClaimsTest do
  use SymphonyElixir.TestSupport

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
