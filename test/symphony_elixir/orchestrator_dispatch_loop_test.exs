defmodule SymphonyElixir.OrchestratorDispatchLoopTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CiWait, DispatchLoop, Hold, TicketState}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Inbox.Item

  @repo_key "loop-repo"
  @issue_id "issue-dispatch-loop"
  @identifier "MT-966"

  setup do
    workflow = Workflow.workflow_file_path()

    write_workflow_file!(workflow,
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      repos: [[key: @repo_key, workflow: workflow, team: "Loop"]]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: @issue_id, identifier: @identifier, title: "Loops", state: "In Progress"}
    ])

    on_exit(fn ->
      RunStore.delete_ci_check(@repo_key, @issue_id)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    end)

    :ok
  end

  test "a ticket re-dispatched with no progress is held after the limit, with the reason readable in the Inbox" do
    put_observed_head!("sha-same")

    # The four runs the limit allows went by on the same state and PR head, each ending quietly.
    for n <- 1..4 do
      run = %{kind: :implementation, run_id: "run-#{n}", state: "In Progress", head: "sha-same"}
      :ok = RunStore.record_ticket_dispatch(@repo_key, @issue_id, run)
      :ok = RunStore.record_ticket_dispatch_outcome(@repo_key, @issue_id, "run-#{n}", %{exit: "ended normally", head: "sha-same"})
    end

    log =
      capture_log(fn ->
        pid = start_retry(:LoopHeld)
        state = wait_for_state(pid, &(not MapSet.member?(&1.claimed, @issue_id)))

        refute Map.has_key?(state.running, @issue_id)
        refute Map.has_key?(state.retry_attempts, @issue_id)
      end)

    assert [error_line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "dispatch_loop"))
    assert error_line =~ "[error] Holding issue_id=#{@issue_id} issue_identifier=#{@identifier} instead of dispatching it again"

    record = RunStore.get_ticket_state(@repo_key, @issue_id)
    hold = TicketState.get_hold(record, :blocked)
    assert %{waits_on: %{type: "dispatch_loop", keys: ["implementation"]}, clearing_condition: "when a person unblocks or restarts it"} = hold
    assert hold.reason =~ "dispatch_loop: 4 implementation runs in 10 minutes without a state change, a new PR head or a decision"
    assert hold.reason =~ "ended normally, no new PR head, no handoff signal"
    assert [%{name: "dispatch_loop", details: %{kind: "implementation", count: 4, window_ms: 600_000}} | _rest] = record.signals
    assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}

    # The Inbox, and `/api/v1/state`'s `waiting_on_you` built from it, lists the ticket with the reason.
    node = %{"id" => @issue_id, "identifier" => @identifier, "title" => "Loops", "url" => nil, "state" => %{"name" => "In Progress"}}
    lookups = %{hold: &Hold.get(&1, &2, :blocked)}
    assert %{kind: :blocked, ask: reason} = Item.from_node(node, @repo_key, %Schema{}, lookups)
    assert reason == hold.reason
  end

  test "a ticket under the limit is dispatched, and the run is recorded with its kind, state and PR head" do
    put_observed_head!("sha-now")
    old_run = %{kind: :implementation, run_id: "run-old", state: "In Progress", head: "sha-before"}
    :ok = RunStore.record_ticket_dispatch(@repo_key, @issue_id, old_run)

    capture_log(fn ->
      pid = start_retry(:LoopUnder)
      state = wait_for_state(pid, &Map.has_key?(&1.running, @issue_id))
      run_id = state.running[@issue_id].run_id

      assert [%{kind: "implementation", run_id: ^run_id, state: "In Progress", head: "sha-now", outcome: nil} | _older] =
               RunStore.get_ticket_state(@repo_key, @issue_id).dispatches

      refute Hold.held?(@repo_key, @issue_id, :blocked)
    end)
  end

  test "a lower limit set in the watchdog settings holds sooner" do
    workflow = Workflow.workflow_file_path()

    write_workflow_file!(workflow,
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      repos: [[key: @repo_key, workflow: workflow, team: "Loop"]],
      watchdog: %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 600_000, dispatch_loop_runs: 1}
    )

    :ok = RunStore.record_ticket_dispatch(@repo_key, @issue_id, %{kind: :implementation, run_id: "run-1", state: "In Progress"})

    capture_log(fn ->
      pid = start_retry(:LoopLowLimit)
      wait_for_state(pid, &(not MapSet.member?(&1.claimed, @issue_id)))
    end)

    assert %{reason: "dispatch_loop: 1 implementation run in 10 minutes" <> _rest} = Hold.get(@repo_key, @issue_id, :blocked)
  end

  describe "how a run ends" do
    setup do
      :ok = RunStore.record_ticket_dispatch(@repo_key, @issue_id, %{kind: :implementation, run_id: "run-1", state: "In Progress"})
      :ok
    end

    test "a normal exit is recorded with the PR head the run left" do
      put_observed_head!("sha-pushed")
      down(:DownNormal, :normal)

      assert [%{run_id: "run-1", outcome: %{exit: "ended normally", head: "sha-pushed"}}] =
               RunStore.get_ticket_state(@repo_key, @issue_id).dispatches
    end

    test "a failure is recorded with its reason" do
      down(:DownFailed, :boom)

      assert [%{run_id: "run-1", outcome: %{exit: "failed (:boom)", head: nil}}] =
               RunStore.get_ticket_state(@repo_key, @issue_id).dispatches
    end

    test "a run an unreachable model API stopped counts no attempt" do
      down(:DownUnreachable, {:model_api_unreachable, %{provider: "anthropic", error: "connection refused"}})
      assert RunStore.get_ticket_state(@repo_key, @issue_id).dispatches == []
    end
  end

  describe "an epic review waiting for CI" do
    @sha "26758a2471558f89fc0411dcf1f81aa82c0e1dc4"
    @runs [%{workflow_name: "release", url: "https://github.com/acme/app/actions/runs/1"}, %{workflow_name: "macos", url: nil, id: 2}]

    test "five waits in ten minutes count no run and set no dispatch-loop hold" do
      pid = start_orchestrator(:CiWaitUncounted)

      for n <- 1..5 do
        run = %{kind: :epic_review, run_id: "run-#{n}", state: "Epic Review"}
        :ok = RunStore.record_ticket_dispatch(@repo_key, @issue_id, run)
        send_down(pid, "run-#{n}", "Epic Review", {:ci_pending, %{sha: @sha, runs: @runs}})
        assert %{delay_type: :ci_wait} = :sys.get_state(pid).retry_attempts[@issue_id]
      end

      record = RunStore.get_ticket_state(@repo_key, @issue_id)
      assert record.dispatches == []
      assert [%{name: "ci_wait_started", details: %{sha: @sha}}] = Enum.filter(record.signals, &(&1.name =~ "ci_wait"))

      attempt = %{kind: :epic_review, state: "Epic Review", head: nil}
      assert DispatchLoop.check(record.dispatches, attempt, DispatchLoop.limits(Config.settings!().watchdog), DateTime.utc_now()) == :ok
      refute Hold.held?(@repo_key, @issue_id, :blocked)
    end

    test "a wait that lasted an hour holds the ticket, naming the commit and the workflows still running" do
      started = DateTime.add(DateTime.utc_now(), -61 * 60, :second)
      signal = %{name: "ci_wait_started", details: %{sha: @sha}, at: started}
      :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, signals: [signal]})
      pid = start_orchestrator(:CiWaitHeld)

      log = send_down(pid, "run-1", "Epic Review", {:ci_pending, %{sha: @sha, runs: @runs}})

      state = :sys.get_state(pid)
      refute Map.has_key?(state.retry_attempts, @issue_id)
      refute MapSet.member?(state.claimed, @issue_id)

      hold = Hold.get(@repo_key, @issue_id, :blocked)
      assert %{waits_on: %{type: "ci_wait", keys: [@sha]}, clearing_condition: "when a person unblocks it"} = hold
      assert hold.reason =~ "ci_wait: CI on 26758a247155 was still running after 61 minutes"
      assert hold.reason =~ "Still running: release (https://github.com/acme/app/actions/runs/1), macos (2)"
      assert Hold.unblockable?(hold)
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}
      assert log =~ "[error] Holding #{@identifier} instead of waiting longer for CI: #{hold.reason}"

      # The hold's signal ends that wait: once unblocked, the next wait on the commit starts from zero.
      record = RunStore.get_ticket_state(@repo_key, @issue_id)
      assert [%{name: "ci_wait", details: %{sha: @sha}} | _rest] = record.signals
      assert CiWait.since(record.signals, @sha) == nil
    end

    test "a wait on a newer commit starts again from zero" do
      started = DateTime.add(DateTime.utc_now(), -61 * 60, :second)
      signal = %{name: "ci_wait_started", details: %{sha: "older"}, at: started}
      :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, signals: [signal]})
      pid = start_orchestrator(:CiWaitNewCommit)

      send_down(pid, "run-1", "Epic Review", {:ci_pending, %{sha: @sha, runs: @runs}})

      assert %{delay_type: :ci_wait} = :sys.get_state(pid).retry_attempts[@issue_id]
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      assert [%{name: "ci_wait_started", details: %{sha: @sha}} | _rest] = RunStore.get_ticket_state(@repo_key, @issue_id).signals
    end
  end

  defp put_observed_head!(commit_sha) do
    :ok = RunStore.put_ci_check(%{repo_key: @repo_key, issue_id: @issue_id, status: "watching", last_observed_sha: commit_sha})
  end

  defp start_retry(name) do
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name))
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    retry_token = make_ref()

    retry = %{
      attempt: 1,
      timer_ref: nil,
      retry_token: retry_token,
      due_at_ms: System.monotonic_time(:millisecond),
      identifier: @identifier,
      repo_key: @repo_key,
      delay_type: :continuation
    }

    :sys.replace_state(pid, fn state -> %{state | claimed: MapSet.new([@issue_id]), retry_attempts: %{@issue_id => retry}} end)
    send(pid, {:retry_issue, @issue_id, retry_token})
    pid
  end

  defp down(name, reason), do: name |> start_orchestrator() |> send_down("run-1", "In Progress", reason)

  defp start_orchestrator(name) do
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name))
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  defp send_down(pid, run_id, issue_state, reason) do
    ref = make_ref()

    running_entry = %{
      pid: self(),
      ref: ref,
      run_id: run_id,
      repo_key: @repo_key,
      identifier: @identifier,
      issue: %Issue{id: @issue_id, identifier: @identifier, state: issue_state, repo_key: @repo_key},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state -> %{state | running: %{@issue_id => running_entry}, claimed: MapSet.new([@issue_id])} end)

    capture_log(fn ->
      send(pid, {:DOWN, ref, :process, self(), reason})
      wait_for_state(pid, &(not Map.has_key?(&1.running, @issue_id)))
    end)
  end

  defp wait_for_state(pid, predicate, attempts \\ 100) do
    state = :sys.get_state(pid)

    cond do
      predicate.(state) ->
        state

      attempts == 0 ->
        flunk("timed out waiting for orchestrator state: #{inspect(state)}")

      true ->
        Process.sleep(10)
        wait_for_state(pid, predicate, attempts - 1)
    end
  end
end
