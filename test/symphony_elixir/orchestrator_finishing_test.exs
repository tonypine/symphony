defmodule SymphonyElixir.OrchestratorFinishingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TicketState

  @active_states ["Todo", "In Progress", "Merging", "Rework", "Waiting on sub-tickets"]

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-finishing-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-finishing","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-finishing","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    on_exit(fn ->
      stop_orchestrator_agent_tasks()
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      File.rm_rf(test_root)
    end)

    ctx = %{test_root: test_root, fake_claude: fake_claude}
    write_finishing_workflow!(ctx)
    ctx
  end

  test "TP-1615: a ticket moved to Merging gets no allowance of its own: with both slots taken by implementation work it waits", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2)
    landing = issue("land-1", "MT-LAND", "Merging")
    tracked([landing])

    state =
      orchestrator_state(2)
      |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)
      |> run(issue("impl-2", "MT-2", "In Progress"), :implementation)

    refute Orchestrator.should_dispatch_issue_for_test(landing, state)

    state = Orchestrator.dispatch_chosen_issues_for_test([landing], state)

    assert Enum.sort(Map.keys(state.running)) == ["impl-1", "impl-2"]
    assert %{reason: "work slots full", state: "Merging"} = state.slot_waiting["land-1"]
    snapshot = snapshot_of(state)
    assert %{finishing: %{slots: 0, used: 0, running: []}} = snapshot
    assert %{concurrency: %{max_total: 2, finishing_max: 0}} = snapshot
  end

  test "TP-1615: a Merging ticket that holds its slot lands on it, and holds no Todo back", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2)
    second_landing = issue("land-2", "MT-LAND-2", "Merging")
    todo = issue("todo-1", "MT-TODO", "Todo", priority: 1)
    tracked([second_landing, todo])
    # The Todo ticket holds the earlier place, so the walk reaches it before the landing.
    queued!([todo, second_landing])

    # MT-LAND-2 holds its slot from its earlier runs, with no run now: it lands on it.
    state = %{run(orchestrator_state(2), issue("land-1", "MT-LAND-1", "Merging"), :landing) | slot_holders: %{"land-2" => holder("MT-LAND-2", "Merging")}}

    log =
      capture_log(fn ->
        dispatched = Orchestrator.dispatch_chosen_issues_for_test([todo, second_landing, :not_an_issue], state)
        send(self(), {:state, dispatched})
      end)

    assert_received {:state, state}

    # Two slots: MT-LAND-1's run and MT-LAND-2's hold. The Todo waits behind them, and MT-LAND-2 lands.
    assert Enum.sort(Map.keys(state.running)) == ["land-1", "land-2"]
    assert %{reason: "work slots full", state: "Todo"} = state.slot_waiting["todo-1"]
    assert dispatch_order(log) == ["land-2"]
  end

  test "a Merging ticket held for CI neither lands nor waits for a slot, and a Todo still starts", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2)
    held = issue("land-1", "MT-HELD", "Merging")
    todo = issue("todo-1", "MT-TODO", "Todo")
    tracked([held, todo])

    hold = %{
      identifier: "MT-HELD",
      title: "Ticket MT-HELD",
      repo_key: nil,
      pull_request_url: "https://github.com/acme/repo/pull/1",
      commit_sha: "abc123",
      since: DateTime.utc_now()
    }

    state = %{orchestrator_state(2) | merging_ci_waits: %{"land-1" => hold}}

    refute Orchestrator.should_dispatch_issue_for_test(held, state)

    state = Orchestrator.dispatch_chosen_issues_for_test([held, todo], state)

    assert Map.keys(state.running) == ["todo-1"]
    assert state.slot_waiting == %{}

    assert [%{issue_id: "land-1", state: "Merging", reason: "waiting for CI on abc123", attempt: nil}] =
             state |> snapshot_of() |> Map.fetch!(:slot_waiting)
  end

  test "with GitHub auto-merge on, a Merging ticket with a PR takes no slot and no agent", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2, pr_review_mode: "polling")
    landing = issue("land-1", "MT-LAND", "Merging", repo_key: Config.repo_key!())
    :ok = SymphonyElixir.TicketPullRequest.record_created(landing.repo_key, landing.id, "https://github.com/acme/repo/pull/1", "auto/MT-LAND")
    todo = issue("todo-1", "MT-TODO", "Todo")
    tracked([landing, todo])

    refute Orchestrator.should_dispatch_issue_for_test(landing, orchestrator_state(2))
    refute Orchestrator.dispatch_revalidated_issue_for_test(landing, false)
    refute Orchestrator.dispatch_revalidated_issue_for_test(landing, true)

    state = Orchestrator.dispatch_chosen_issues_for_test([landing, todo], orchestrator_state(2))

    assert Map.keys(state.running) == ["todo-1"]
    assert state.slot_waiting == %{}

    # The PR watcher armed auto-merge and waits on CI (R32): still no agent.
    wait = %{rule: "R32", kind: :wait, reason: "Checks are running on PR #1: auto-merge lands it when they pass", owner: :ci}

    SymphonyElixir.PrWatchSupport.put_watch!("default", "land-1",
      identifier: "MT-LAND",
      phase: :merging,
      head_sha: "abc1234def",
      facts: %{auto_merge: :armed, ci: :pending},
      decision: wait
    )

    refute Orchestrator.should_dispatch_issue_for_test(landing, orchestrator_state(2))

    assert [%{issue_identifier: "MT-LAND", state: "armed", head_sha: "abc1234def", status: "Checks are running on PR #1: auto-merge lands it when they pass"}] =
             snapshot_of(state).auto_merge

    # Branch protection held the PR past the merge wait (R31): the landing agent runs.
    SymphonyElixir.PrWatchSupport.update_watch!("default", "land-1", &%{&1 | decision: %{rule: "R31", kind: :land_agent, reason: "Branch protection"}})

    state = Orchestrator.dispatch_chosen_issues_for_test([landing], %{state | running: %{}})
    assert %{run_profile: %{kind: :landing}} = state.running["land-1"]
  end

  test "with GitHub auto-merge on, a Merging ticket without a PR waits for a person instead of a landing agent", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2, pr_review_mode: "polling")
    landing = issue("land-1", "MT-LAND", "Merging")
    tracked([landing])

    # Not read yet: it waits for the watcher.
    refute Orchestrator.should_dispatch_issue_for_test(landing, orchestrator_state(2))

    # The watcher found no PR and asks a person (R6): still no landing agent.
    SymphonyElixir.PrWatchSupport.put_watch!("default", "land-1",
      identifier: "MT-LAND",
      phase: :merging,
      facts: %{pr: :missing},
      decision: %{rule: "R6", kind: :decision, reason: "The ticket is in Merging with no PR"}
    )

    refute Orchestrator.should_dispatch_issue_for_test(landing, orchestrator_state(2))
  end

  test "a free slot goes to the first ticket of the stored queue, though the ones behind it are urgent, older or further on", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 1)
    first = issue("low-1", "MT-LOW", "Todo", priority: 4, created_at: ~U[2026-03-01 00:00:00Z])
    urgent = issue("urgent-1", "MT-URGENT", "Todo", priority: 1, created_at: ~U[2026-02-01 00:00:00Z])
    resume = issue("resume-1", "MT-RESUME", "In Progress", priority: 1, created_at: ~U[2026-01-01 00:00:00Z])
    tracked([first, urgent, resume])
    queued!([first, urgent, resume])

    state = Orchestrator.dispatch_chosen_issues_for_test([resume, urgent, first], orchestrator_state(1))

    assert Map.keys(state.running) == ["low-1"]
    assert %{reason: "work slots full"} = state.slot_waiting["urgent-1"]
    assert %{reason: "work slots full"} = state.slot_waiting["resume-1"]
  end

  test "a ticket the gates hold keeps its place in the queue, and is taken before the ones behind it once it can start", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 1, tickets: %{priorities: ["urgent", "high"]})
    parked = issue("parked-1", "MT-PARKED", "Backlog", priority: 1)
    low = issue("low-1", "MT-LOW", "Todo", priority: 4)
    next = issue("next-1", "MT-NEXT", "Todo", priority: 2)
    last = issue("last-1", "MT-LAST", "Todo", priority: 2)
    tracked([parked, low, next, last])
    queued!([parked, low, next, last])
    places = Map.take(RunStore.queue_places(), ["parked-1", "low-1", "next-1", "last-1"])

    # In Backlog, the first ticket cannot start; below the priority filter, the second is never started.
    state = Orchestrator.dispatch_chosen_issues_for_test([last, next, low, parked], orchestrator_state(1))

    assert Map.keys(state.running) == ["next-1"]
    assert %{reason: "work slots full"} = state.slot_waiting["last-1"]
    refute Map.has_key?(state.slot_waiting, "low-1")
    refute Map.has_key?(state.slot_waiting, "parked-1")
    assert Map.take(RunStore.queue_places(), Map.keys(places)) == places

    # Moved to Todo, it goes before the tickets behind it.
    :ok = RunStore.update_ticket_state("parked-1", %{phase: "Todo"})
    issues = [last, next, low, %{parked | state: "Todo"}]
    tracked(issues)
    state = Orchestrator.dispatch_chosen_issues_for_test(issues, orchestrator_state(1))

    assert Map.keys(state.running) == ["parked-1"]
    assert Map.take(RunStore.queue_places(), Map.keys(places)) == places
  end

  test "a retry waiting for a slot keeps attempt 1 and starts on the first poll after a slot frees", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 1)
    waiting = issue("wait-1", "MT-WAIT", "In Progress")
    tracked([waiting])
    full = run(%{orchestrator_state(1) | claimed: MapSet.new(["wait-1"])}, issue("impl-1", "MT-1", "In Progress"), :implementation)
    metadata = %{identifier: "MT-WAIT", repo_key: "default"}

    {:noreply, state} = Orchestrator.handle_retry_issue_for_test(full, "wait-1", 1, metadata, fn ["wait-1"] -> {:ok, [waiting]} end)

    assert %{attempt: 1, reason: "no available orchestrator slots"} = state.slot_waiting["wait-1"]
    assert state.retry_attempts == %{}
    refute MapSet.member?(state.claimed, "wait-1")

    # Polls while the slot is still taken leave it waiting, attempt unchanged.
    state = Orchestrator.dispatch_chosen_issues_for_test([waiting], state)
    assert %{attempt: 1, reason: "work slots full"} = state.slot_waiting["wait-1"]
    assert state.retry_attempts == %{}

    state = Orchestrator.dispatch_chosen_issues_for_test([waiting], %{state | running: %{}})

    assert %{retry_attempt: 1} = state.running["wait-1"]
    assert state.slot_waiting == %{}
  end

  test "a retry deferred behind a dispatch readiness task waits for a slot without backoff", ctx do
    write_finishing_workflow!(ctx, poll_interval_ms: 600_000)
    tracked([issue("wait-1", "MT-WAIT", "In Progress")])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :Readiness))
    on_exit(fn -> if Process.alive?(pid), do: stop_process(pid) end)

    token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | dispatch_readiness_tasks: %{make_ref() => %{kind: :poll, issues: []}},
          retry_attempts: %{"wait-1" => %{attempt: 3, retry_token: token, identifier: "MT-WAIT", repo_key: "default"}},
          claimed: MapSet.new(["wait-1"])
      }
    end)

    send(pid, {:retry_issue, "wait-1", token})
    # The retry reads its issue again in a task first.
    state = Enum.find(Stream.repeatedly(fn -> Process.sleep(5) && :sys.get_state(pid) end), &(&1.tracker_tasks == %{}))

    assert %{attempt: 3, reason: "dispatch readiness task already in flight"} = state.slot_waiting["wait-1"]
    assert state.retry_attempts == %{}
    refute MapSet.member?(state.claimed, "wait-1")
  end

  test "TP-1624: a free slot follows the stored queue order, a started ticket's sub-ticket gets no place in front", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 2)
    standalone = issue("s1", "MT-S1", "Todo", priority: 1)
    other = issue("o1", "MT-O1", "Todo", priority: 1)
    child = issue("c1", "MT-C1", "Todo", priority: 4, parent: %{identifier: "MT-P1", title: "Epic", done: 0, total: 2, children: []})
    tracked([standalone, other, child])
    # The unrelated tickets joined the queue first, the sub-ticket last.
    queued!([standalone, other, child])

    # MT-P1 has started: it holds a slot, with no run now.
    state = %{orchestrator_state(2) | slot_holders: %{"p1" => holder("MT-P1", "In Progress")}}
    order = state |> Orchestrator.put_dispatch_order_for_test([standalone, other, child]) |> Map.fetch!(:dispatch_order)
    assert [%{identifier: "MT-S1", outcome: :starts}, %{identifier: "MT-O1", outcome: :waits}, %{identifier: "MT-C1", outcome: :waits}] = Enum.filter(order.entries, & &1.position)

    log = capture_log(fn -> send(self(), {:state, dispatch(state, [standalone, other, child])}) end)
    assert_received {:state, state}

    assert dispatch_order(log) == ["s1"]
    assert %{reason: "work slots full"} = state.slot_waiting["o1"]
  end

  test "TP-1622: the pass walks an epic's sub-tickets inside its place, in their own key order, before a later top-level ticket", ctx do
    write_finishing_workflow!(ctx, max_concurrent_agents: 1)
    epic = %{identifier: "MT-E", title: "Epic", done: 0, total: 2, children: []}
    later = issue("later-1", "MT-LATER", "Todo", priority: 1)
    sub_1 = issue("sub-1", "MT-S1", "Todo", priority: 4, parent: epic)
    sub_2 = issue("sub-2", "MT-S2", "Todo", priority: 4, parent: epic)
    tracked([later, sub_1, sub_2])

    # The epic (not started) joined first, the later ticket next, its sub-tickets last; then the
    # second sub-ticket is moved before the first among its siblings.
    :ok = RunStore.put_ticket_state(TicketState.new(Config.repo_key!(), "epic-1", %{issue_identifier: "MT-E", phase: "Backlog"}))
    queued!([later])

    for sub <- [sub_1, sub_2] do
      attrs = %{issue_identifier: sub.identifier, phase: sub.state, priority: sub.priority, parent: sub.parent}
      :ok = RunStore.put_ticket_state(TicketState.new(Config.repo_key!(), sub.id, attrs))
    end

    :ok = RunStore.move_in_queue("sub-2", :top)

    state = orchestrator_state(1)
    order = state |> Orchestrator.put_dispatch_order_for_test([later, sub_1, sub_2]) |> Map.fetch!(:dispatch_order)
    assert [%{identifier: "MT-S2", outcome: :starts}, %{identifier: "MT-S1", outcome: :waits}, %{identifier: "MT-LATER", outcome: :waits}] = Enum.filter(order.entries, & &1.position)

    log = capture_log(fn -> send(self(), {:state, dispatch(state, [later, sub_1, sub_2])}) end)
    assert_received {:state, state}
    assert dispatch_order(log) == ["sub-2"]
    assert %{reason: "work slots full"} = state.slot_waiting["later-1"]
  end

  test "TP-1615: a landing run takes a plain slot, and the lane and finishing snapshot keys stay, empty" do
    state = run(orchestrator_state(1), issue("land-1", "MT-LAND", "Merging"), :landing)

    refute Orchestrator.should_dispatch_issue_for_test(issue("todo-1", "MT-TODO", "Todo"), state)
    snapshot = snapshot_of(state)
    assert %{epic_lanes: %{lanes: [], queued_epics: [], shared: %{used: 1}}} = snapshot
    assert %{finishing: %{slots: 0, used: 0}} = snapshot
  end

  describe "a run ending while issues wait for a slot" do
    test "runs dispatch right away", ctx do
      {pid, ref} = start_with_waiting_run(ctx, poll_check_in_progress: false)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      state = :sys.get_state(pid)

      assert is_integer(state.next_poll_due_at_ms)
      assert state.next_poll_due_at_ms <= System.monotonic_time(:millisecond) + 100
    end

    test "joins a poll already in progress", ctx do
      {pid, ref} = start_with_waiting_run(ctx, poll_check_in_progress: true)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      state = :sys.get_state(pid)

      assert state.next_poll_due_at_ms == nil
    end
  end

  describe "a run ending with nothing waiting for a slot" do
    test "TP-1615: leaves the next poll where it is, and its ticket keeps its slot with no live run", ctx do
      holders = %{"land-1" => holder("MT-LAND", "Merging")}
      {pid, ref} = start_with_waiting_run(ctx, poll_check_in_progress: false, slot_waiting: %{}, slot_holders: holders)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      state = :sys.get_state(pid)

      assert state.next_poll_due_at_ms == nil
      refute Map.has_key?(state.running, "land-1")
      assert %{identifier: "MT-LAND"} = state.slot_holders["land-1"]
      assert Orchestrator.available_slots_for_test(%{state | max_concurrent_agents: 1}) == 0
    end
  end

  defp holder(identifier, phase), do: %{identifier: identifier, state: phase, repo_key: "default", since: ~U[2026-11-22 07:00:00Z]}

  defp start_with_waiting_run(ctx, opts) do
    write_finishing_workflow!(ctx, poll_interval_ms: 600_000)
    tracked([])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "Down#{System.unique_integer([:positive])}"))
    on_exit(fn -> if Process.alive?(pid), do: stop_process(pid) end)

    ref = make_ref()
    running = issue("land-1", "MT-LAND", "Merging")
    waiting = %{identifier: "MT-WAIT", state: "Merging", reason: "work slots full", since: DateTime.utc_now()}

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        (run(state, running, :landing)
         |> put_in([Access.key(:running), "land-1", :ref], ref))
        | slot_waiting: Keyword.get(opts, :slot_waiting, %{"wait-1" => waiting}),
          slot_holders: Keyword.get(opts, :slot_holders, %{}),
          poll_check_in_progress: Keyword.fetch!(opts, :poll_check_in_progress),
          next_poll_due_at_ms: nil,
          tick_timer_ref: nil,
          tick_token: nil
      }
    end)

    {pid, ref}
  end

  defp write_finishing_workflow!(ctx, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_active_states: @active_states,
          tracker_terminal_states: ["Done", "Canceled"],
          workspace_root: Path.join(ctx.test_root, "workspaces"),
          agent_kind: "claude",
          agent_command: ctx.fake_claude,
          max_turns: 1,
          quality_gate: %{enabled: false}
        ],
        overrides
      )
    )
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  # Each ticket's record, written in the order given: each joins the dispatch queue at its end.
  defp queued!(issues) do
    for issue <- issues do
      attrs = %{issue_identifier: issue.identifier, phase: issue.state, priority: issue.priority, created_at: issue.created_at}
      :ok = RunStore.put_ticket_state(TicketState.new(Config.repo_key!(), issue.id, attrs))
    end

    :ok
  end

  defp dispatch_order(log) do
    ~r/Dispatching issue to agent: issue_id=(\S+)/
    |> Regex.scan(log, capture: :all_but_first)
    |> List.flatten()
  end

  defp dispatch(state, issues), do: Orchestrator.dispatch_chosen_issues_for_test(issues, state)

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
  end

  defp issue(id, identifier, state, attrs \\ []) do
    struct!(
      %Issue{
        id: id,
        identifier: identifier,
        title: "Ticket #{identifier}",
        description: "Finish it",
        state: state,
        priority: 3,
        team: %{key: "Test"},
        labels: [],
        url: "https://example.org/issues/#{identifier}"
      },
      attrs
    )
  end

  defp run(state, %Issue{} = issue, kind) do
    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_profile: %{kind: kind, model: nil, effort: nil, provider: "anthropic"},
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
  end

  defp orchestrator_state(max_total) do
    %Orchestrator.State{
      repo_key: "default",
      max_concurrent_agents: max_total,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
