defmodule SymphonyElixir.OrchestratorDispatchSkippedTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunStore

  @waiting "Waiting on sub-tickets"
  @active_states ["Todo", "In Progress", "Merging", "Rework", @waiting]

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-dispatch-skipped-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-skipped","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-skipped","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      File.rm_rf(test_root)
    end)

    ctx = %{test_root: test_root, fake_claude: fake_claude}
    write_skipped_workflow!(ctx)
    ctx
  end

  test "with free slots and queued epics that cannot run, a standalone Todo ticket dispatches on the next poll", ctx do
    # The lanes TP-912 reported: max_total 5 with one epic lane, so one epic holds the lane, five
    # wait for it, one has yielded, and four slots are shared.
    write_skipped_workflow!(ctx, max_concurrent_agents: 5, epic_lanes: 1)
    blocked_by = [%{id: "fix", identifier: "MT-99", state: "In Progress"}]
    parts = for n <- 1..6, do: issue("p#{n}", "MT-#{n}1", "Todo", blocked_by: blocked_by)
    epics = for {part, n} <- Enum.with_index(parts, 1), do: epic("e#{n}", "MT-#{n}0", [part])
    fix = issue("fix", "MT-99", "In Progress")
    yielded = epic("ey", "MT-90", [%{id: "y1", identifier: "MT-91", state: "Plan Review"}])
    standalone = issue("standalone", "MT-888", "Todo", priority: 3)
    candidates = epics ++ [yielded, fix, standalone | parts]
    tracked([standalone])

    state = Orchestrator.put_epic_lanes_for_test(%{orchestrator_state() | max_concurrent_agents: nil}, candidates)
    assert {length(state.epic_lanes.lanes), length(state.epic_lanes.queued), length(state.epic_lanes.yielded)} == {1, 5, 1}
    assert state.epic_lanes.shared == 4

    state = Orchestrator.dispatch_chosen_issues_for_test(candidates, run(state, fix))

    assert Map.has_key?(state.running, "standalone")
    # Every candidate passed over says why; the one dispatched does not appear.
    skipped = Map.new(snapshot_of(state).dispatch_skipped, &{&1.identifier, &1.reason})
    refute Map.has_key?(skipped, "MT-888")
    assert skipped["MT-11"] == "blocked by MT-99"
    assert skipped["MT-10"] == "waiting on its sub-tickets"
    assert skipped["MT-99"] == "already running"
  end

  test "a ticket outside tickets.priorities is listed with the filter that holds it, and logged once", ctx do
    write_skipped_workflow!(ctx, tickets: %{priorities: ["urgent", "high"]})
    medium = issue("medium", "MT-MED", "Todo", priority: 3, repo_key: "web")
    unset = issue("unset", "MT-UNSET", "Todo", priority: nil)

    {state, log} = dispatch_with_log([medium, unset], orchestrator_state())

    assert state.running == %{}
    assert state.slot_waiting == %{}

    assert [
             %{issue_id: "medium", identifier: "MT-MED", state: "Todo", repo_key: "web", reason: "priority medium is not in tickets.priorities (urgent, high)", since: since},
             %{identifier: "MT-UNSET", reason: "priority none is not in tickets.priorities (urgent, high)"}
           ] = snapshot_of(state).dispatch_skipped

    assert log =~ "Skipping dispatch: issue_id=medium issue_identifier=MT-MED state=\"Todo\"; priority medium is not in tickets.priorities (urgent, high)"

    # The next poll keeps the entry's `since` and logs nothing new while the reason stays.
    {state, log} = dispatch_with_log([medium], state)
    assert %{since: ^since} = state.dispatch_skipped["medium"]
    refute log =~ "Skipping dispatch"
    refute Map.has_key?(state.dispatch_skipped, "unset")

    # A changed reason is logged again, with a new `since`.
    {state, log} = dispatch_with_log([medium], %{state | setup_failed: %{"medium" => "Todo"}})
    assert %{reason: "workspace setup failed in Todo; it waits for the ticket to change state"} = state.dispatch_skipped["medium"]
    assert log =~ "issue_identifier=MT-MED state=\"Todo\"; workspace setup failed"
  end

  test "each closed gate names itself" do
    state =
      orchestrator_state()
      |> run(issue("running", "MT-RUN", "In Progress"))
      |> Map.merge(%{
        claimed: MapSet.new(["running", "claimed"]),
        budget_exhausted: MapSet.new(["spent"]),
        update_holds: %{"update" => %{reason: "MT-5's fix is not in this build yet"}},
        merging_ci_waits: %{"landing" => %{commit_sha: "abc1234"}}
      })

    :ok = RunStore.set_ticket_hold("default", "skipped-decision", :needs_decision, %{reason: "Which reading is right?"})
    on_exit(fn -> RunStore.clear_ticket_hold("default", "skipped-decision", :needs_decision) end)

    candidates = [
      issue("unassigned", "MT-UNASSIGNED", "Todo", assigned_to_worker: false),
      issue("done", "MT-DONE", "Done"),
      issue("backlog", "MT-BACKLOG", "Backlog"),
      issue("untitled", "MT-UNTITLED", "Todo", title: nil),
      issue("blocked", "MT-BLOCKED", "Todo", blocked_by: [%{id: "b", identifier: "MT-B", state: "In Progress"}, %{id: "c", state: "Todo"}]),
      issue("skipped-decision", "MT-DECISION", "In Progress"),
      issue("update", "MT-UPDATE", "Todo"),
      issue("landing", "MT-LANDING", "Merging"),
      issue("running", "MT-RUN", "In Progress"),
      issue("claimed", "MT-CLAIMED", "Todo"),
      issue("spent", "MT-SPENT", "Todo")
    ]

    state = Orchestrator.dispatch_chosen_issues_for_test(candidates, state)

    assert Map.new(state.dispatch_skipped, fn {issue_id, entry} -> {issue_id, entry.reason} end) == %{
             "unassigned" => "not assigned to this Symphony's worker",
             "done" => "Done is a terminal state",
             "backlog" => "\"Backlog\" is not an active state",
             "untitled" => "Linear returned it without an id, identifier or title",
             "blocked" => "blocked by MT-B, an unnamed ticket",
             "skipped-decision" => "on a Needs Decision hold",
             "update" => "waiting for an app update: MT-5's fix is not in this build yet",
             "landing" => "held in Merging until CI settles on abc1234",
             "running" => "already running",
             "claimed" => "claimed by a retry or a Linear update in flight",
             "spent" => "its token budget is spent (agent.max_tokens_per_issue)"
           }

    # The ticket page shows a passed-over ticket's blockers from the entry (`SymphonyElixir.Connected`).
    assert %{blocked_by: [%{identifier: "MT-B", title: nil, state: "In Progress"}], parent: nil} = state.dispatch_skipped["blocked"].connected
  end

  test "a usage-limit hold and a dispatch that starts nothing are listed too" do
    now = DateTime.utc_now()

    hold = %{
      provider: "anthropic",
      scope: :all,
      reason: "claude_usage_limit",
      window: "five_hour",
      since: now,
      resets_at: DateTime.add(now, 3600),
      resume_at: DateTime.add(now, 3720),
      source: :rate_limit_event,
      phase: :paused,
      issue_identifier: "MT-HELD"
    }

    held = issue("held", "MT-HELD-2", "Todo")
    held_state = %{orchestrator_state() | usage_limits: %{{"anthropic", :all} => hold}}
    state = Orchestrator.dispatch_chosen_issues_for_test([held], held_state)
    assert %{reason: "Claude 5-hour limit reached"} = state.dispatch_skipped["held"]

    # Linear no longer returns the issue when dispatch reads it again.
    tracked([])
    gone = issue("gone", "MT-GONE", "Todo")
    state = Orchestrator.dispatch_chosen_issues_for_test([gone], orchestrator_state())

    assert %{reason: "not started: the issue read again before dispatch was no longer dispatchable, or no worker was free"} =
             state.dispatch_skipped["gone"]
  end

  test "a pause lists every candidate it holds back, with the gate that would hold it anyway first", ctx do
    write_skipped_workflow!(ctx, max_tokens_per_day: 10)
    tracked([])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :PausedOrchestrator))
    on_exit(fn -> stop_process(pid) end)
    wait_until(pid, &(is_nil(&1.repo_poll_task_ref) and not &1.poll_check_in_progress))

    runnable = issue("runnable", "MT-RUNNABLE", "Todo")
    blocked = issue("blocked", "MT-BLOCKED", "Todo", blocked_by: [%{id: "b", identifier: "MT-B", state: "In Progress"}])
    waiting = issue("waiting", "MT-WAITING", "Todo")
    slot_waiting = %{"waiting" => %{identifier: "MT-WAITING", reason: "work slots full", since: DateTime.utc_now()}}
    readiness = %{kind: :poll, issues: [runnable, blocked, waiting]}

    skipped_after = fn pause ->
      ref = make_ref()
      replace = Map.merge(%{dispatch_readiness_tasks: %{ref => readiness}, slot_waiting: slot_waiting}, pause)
      :sys.replace_state(pid, &Map.merge(&1, replace))
      result = %{now_ms: System.monotonic_time(:millisecond), age_gc_result: :skipped, quota: nil}
      send(pid, {ref, {:dispatch_readiness_result, result}})
      state = :sys.get_state(pid)
      assert state.running == %{}
      Map.new(state.dispatch_skipped, fn {issue_id, entry} -> {issue_id, entry.reason} end)
    end

    assert skipped_after.(%{pause: %{paused: true, reason: "operator", paused_at: DateTime.utc_now()}}) == %{
             "runnable" => "dispatch is paused by the operator",
             "blocked" => "blocked by MT-B"
           }

    unpaused = %{paused: false, reason: nil, paused_at: nil}
    quota = %{paused: true, reason: "workspace free space is low"}

    assert %{"runnable" => "new dispatch is paused: workspace free space is low"} =
             skipped_after.(%{pause: unpaused, workspace_lifecycle_quota: quota})

    today = Date.utc_today()
    budget = %{workspace_lifecycle_quota: %{paused: false}, budget_daily_used: 10, budget_day_started_on: today}
    assert %{"runnable" => "the daily token budget is spent (agent.max_tokens_per_day)"} = skipped_after.(budget)
  end

  defp wait_until(pid, predicate) do
    Enum.reduce_while(1..200, nil, fn _attempt, _acc ->
      if predicate.(:sys.get_state(pid)), do: {:halt, :ok}, else: Process.sleep(10) && {:cont, nil}
    end)
  end

  defp write_skipped_workflow!(ctx, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
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

  defp dispatch_with_log(issues, state) do
    dispatch = fn -> send(self(), {:state, Orchestrator.dispatch_chosen_issues_for_test(issues, state)}) end
    log = capture_log([level: :debug], dispatch)
    assert_received {:state, state}
    {state, log}
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
  end

  defp epic(id, identifier, sub_issues) do
    issue(id, identifier, @waiting, labels: ["breakdown"], priority: 2, sub_issues: Enum.map(sub_issues, &Map.take(&1, [:id, :identifier, :state])))
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
        repo_key: "default",
        url: "https://example.org/issues/#{identifier}"
      },
      attrs
    )
  end

  defp run(state, %Issue{} = issue) do
    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_profile: %{kind: :implementation, model: nil, effort: nil, provider: "anthropic"},
      session_id: nil,
      turn_count: 0,
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
