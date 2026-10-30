defmodule SymphonyElixir.OrchestratorDispatchSkippedTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{BlockedHold, CiWait, Hold, OperatorStop, Pauses, RunStore, SelfHeal}
  alias SymphonyElixir.PrWatch.Sweep
  alias SymphonyElixir.QaDriver.DevServerLease

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
    {state, log} = dispatch_with_log([medium], %{state | budget_exhausted: MapSet.new(["medium"])})
    assert %{reason: "its token budget is spent (agent.max_tokens_per_issue)"} = state.dispatch_skipped["medium"]
    assert log =~ "issue_identifier=MT-MED state=\"Todo\"; its token budget is spent"
  end

  test "each closed gate names itself" do
    state =
      orchestrator_state()
      |> run(issue("running", "MT-RUN", "In Progress"))
      |> Map.merge(%{
        claimed: MapSet.new(["running", "claimed"]),
        budget_exhausted: MapSet.new(["spent"]),
        merging_ci_waits: %{"landing" => %{commit_sha: "abc1234"}}
      })

    :ok = RunStore.set_ticket_hold("default", "skipped-decision", :needs_decision, %{reason: "Which reading is right?"})
    on_exit(fn -> RunStore.clear_ticket_hold("default", "skipped-decision", :needs_decision) end)
    # Waiting for the running app to include a blocker's fix, as the update hold wrote it on the pause.
    update_reason = %{kind: :build, waits_on: %{pull_request: 5}, text: "Waiting for a Symphony update that includes MT-5's fix"}
    {:ok, _pause} = Pauses.set({:ticket, "default", "update"}, update_reason, set_by: %{kind: :rule, name: "App update hold"})
    on_exit(fn -> Pauses.clear({:ticket, "default", "update"}) end)

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
             "update" => "Waiting for a Symphony update that includes MT-5's fix",
             "landing" => "held in Merging until CI settles on abc1234",
             "running" => "already running",
             "claimed" => "claimed by a retry or a Linear update in flight",
             "spent" => "its token budget is spent (agent.max_tokens_per_issue)"
           }

    # The ticket page shows a passed-over ticket's blockers from the entry (`SymphonyElixir.Connected`).
    assert %{blocked_by: [%{identifier: "MT-B", title: nil, state: "In Progress"}], parent: nil} = state.dispatch_skipped["blocked"].connected
  end

  test "a stopped ticket is skipped with its pause's text, before any hold; a pause on another reason alone gates nothing yet" do
    on_exit(fn -> RunStore.clear() end)
    :ok = OperatorStop.mark("default", "stopped", ~U[2026-10-20 08:41:25Z])
    :ok = Hold.set("default", "stopped", :blocked, %{reason: "Needs a token", waits_on: %{type: "access", keys: []}})
    # A reason the backfill wrote for a dependency hold that cleared since; its writer doesn't clear it yet.
    {:ok, _pause} = Pauses.set({:ticket, "default", "waiting"}, %{kind: :ticket, waits_on: %{identifier: "MT-9"}})

    stopped = issue("stopped", "MT-STOP", "Todo")
    waiting = issue("waiting", "MT-WAIT", "Todo")
    tracked([stopped, waiting])
    state = Orchestrator.dispatch_chosen_issues_for_test([stopped, waiting], orchestrator_state())

    assert Map.has_key?(state.running, "waiting")

    assert [%{identifier: "MT-STOP", reason: "Stopped by you at 2026-10-20 08:41:25 UTC. Unblock runs it again; Restart starts it over from main."}] =
             snapshot_of(state).dispatch_skipped
  end

  test "a ticket held back by its blockers or a Blocked hold is skipped with its pause's text (TP-1234)" do
    on_exit(fn -> RunStore.clear() end)
    blockers = [%{id: "a", identifier: "MT-1", state: "In Progress"}, %{id: "b", identifier: "MT-2", state: "Todo"}]
    for identifier <- ["MT-1", "MT-2"], do: {:ok, _pause} = Pauses.set({:ticket, "default", "blocked"}, Pauses.ticket_reason(:dependency, identifier))

    :ok = Hold.set("default", "fixing", :blocked, %{reason: "waiting on fix ticket MT-9", waits_on: %{type: "fix_ticket", keys: ["MT-9"]}})
    {:ok, _pause} = Pauses.set({:ticket, "default", "fixing"}, Pauses.ticket_reason(:fix_ticket, "MT-9"))

    request = SymphonyElixir.TransitionGuard.block_report_question("MT-ASK")
    {:ok, %{id: question_id}} = SymphonyElixir.Questions.ask({:ticket, "default", "asking"}, request)
    :ok = Hold.set("default", "asking", :blocked, %{reason: "the run reported a block", waits_on: %{type: "access", keys: [], question_id: question_id}})

    # A held ticket with no pause names its hold, as before, and so does one whose pause the backfill
    # gave the hold's own words (an access or CI-wait hold's `:environment` reason).
    :ok = Hold.set("default", "held", :blocked, %{reason: "the run reported a block", waits_on: %{type: "access", keys: []}})
    :ok = Hold.set("default", "waiting", :blocked, %{reason: "ci_wait: CI on abc was still running after 30 minutes", waits_on: %{type: "ci_wait", keys: []}})
    environment = %{kind: :environment, waits_on: %{condition: "ci_wait"}, text: "ci_wait: CI on abc was still running after 30 minutes"}
    {:ok, _pause} = Pauses.set({:ticket, "default", "waiting"}, environment, backfilled: true)

    issues = [
      issue("blocked", "MT-BLOCKED", "Todo", blocked_by: blockers),
      issue("fixing", "MT-FIX", "In Progress"),
      issue("asking", "MT-ASK", "In Progress"),
      issue("held", "MT-HELD", "In Progress"),
      issue("waiting", "MT-WAIT", "In Progress")
    ]

    tracked(issues)
    state = Orchestrator.dispatch_chosen_issues_for_test(issues, orchestrator_state())
    reasons = Map.new(snapshot_of(state).dispatch_skipped, &{&1.identifier, &1.reason})

    assert reasons == %{
             "MT-BLOCKED" => "Waiting for MT-1 to finish; Waiting for MT-2 to finish",
             "MT-FIX" => "Waiting for MT-9 to finish: it fixes what stopped this ticket",
             "MT-ASK" => "Waiting for your answer: The run on MT-ASK cannot continue on its own",
             "MT-HELD" => "on a Blocked hold",
             "MT-WAIT" => "on a Blocked hold"
           }

    # The PR watch sweep labels every one of them by its gate.
    for {identifier, reason} <- reasons do
      line = ~s(Skipping dispatch: issue_id=x issue_identifier=#{identifier} state="In Progress"; #{reason})
      assert {:skipped, "gate: " <> _gate} = Sweep.classify(line)
    end
  end

  test "a ticket waiting on its competing PRs, on CI or on its QA environment is skipped with its pause's text (TP-1250)" do
    on_exit(fn -> RunStore.clear() end)
    competitors = [%{issue_identifier: "MT-1", pr_number: 1, files: ["SPEC.md"]}, %{pr_number: 12, title: "Bump deps", files: ["SPEC.md"]}]

    :ok = Hold.set("default", "landing", :blocked, BlockedHold.landing_attrs(competitors))
    for reason <- BlockedHold.landing_reasons(competitors), do: {:ok, _pause} = Pauses.set({:ticket, "default", "landing"}, reason)

    :ok = Hold.set("default", "ci", :blocked, CiWait.hold_attrs(%{sha: "26758a2471558f89", runs: []}, ~U[2026-10-30 09:00:00Z], ~U[2026-10-30 10:01:00Z]))
    {:ok, _pause} = CiWait.pause("default", "ci", "26758a2471558f89")

    :ok = Hold.set("default", "qa", :blocked, %{reason: "QA blocked after 2 attempt(s): unreachable", waits_on: %{type: "access", keys: []}})
    {:ok, _pause} = Pauses.set({:ticket, "default", "qa"}, SelfHeal.environment_reason("worker_host"))

    issues = [issue("landing", "MT-LAND", "Merging"), issue("ci", "MT-CI", "Epic Review"), issue("qa", "MT-QA", "QA")]

    tracked(issues)
    state = Orchestrator.dispatch_chosen_issues_for_test(issues, orchestrator_state())
    reasons = Map.new(snapshot_of(state).dispatch_skipped, &{&1.identifier, &1.reason})

    assert reasons == %{
             "MT-LAND" => "Waiting for MT-1 to land: it changes the same files; Waiting for PR #12 (Bump deps) to land: it changes the same files",
             "MT-CI" => "Waiting for CI on 26758a247155 to finish",
             "MT-QA" => "The QA machine is not reachable"
           }

    for {identifier, reason} <- reasons do
      line = ~s(Skipping dispatch: issue_id=x issue_identifier=#{identifier} state="QA"; #{reason})
      assert {:skipped, "gate: " <> _gate} = Sweep.classify(line)
    end
  end

  # TP-1125: a QA pass waiting for another pass's dev server port on the QA host is running, but
  # says what it waits for instead of "already running".
  test "a running QA pass that waits for the QA host's dev server port names the ticket holding it" do
    unless GenServer.whereis(DevServerLease), do: start_supervised!(DevServerLease)
    key = {"admin@qa-vm-#{System.unique_integer([:positive])}", 8090}
    {holder, waiter} = {spawn(fn -> Process.sleep(:infinity) end), spawn(fn -> Process.sleep(:infinity) end)}
    on_exit(fn -> Enum.each([holder, waiter], &Process.exit(&1, :kill)) end)

    :ok = DevServerLease.acquire(DevServerLease, key, %{pid: holder, issue_id: "holding-qa", ticket: "MT-1124"})
    test = self()
    waiting = %{pid: waiter, issue_id: "waiting-qa", ticket: "MT-1123"}
    spawn_link(fn -> send(test, DevServerLease.acquire(DevServerLease, key, waiting)) end)
    wait_until_queued("waiting-qa")

    candidates = [issue("waiting-qa", "MT-1123", "In Progress"), issue("holding-qa", "MT-1124", "In Progress")]
    state = orchestrator_state() |> run(Enum.at(candidates, 0)) |> run(Enum.at(candidates, 1))
    state = Orchestrator.dispatch_chosen_issues_for_test(candidates, state)
    {host, 8090} = key

    assert state.dispatch_skipped["waiting-qa"].reason == "waiting for the QA host's dev server port: 8090 on #{host} is held by MT-1124's QA pass"

    assert state.dispatch_skipped["holding-qa"].reason == "already running"

    DevServerLease.release(DevServerLease, holder)
    assert_receive :ok
    DevServerLease.release(DevServerLease, waiter)
  end

  defp wait_until_queued(issue_id, tries \\ 250) do
    cond do
      DevServerLease.waiting(issue_id) -> :ok
      tries > 0 -> Process.sleep(10) && wait_until_queued(issue_id, tries - 1)
      true -> flunk("#{issue_id} never queued for the lease")
    end
  end

  # TP-1019: dispatch reads the issue again by id, and that read carries no repo key. The dispatch's
  # own goes on the refreshed copy, so its holds are read where they are kept.
  test "dispatch reads the issue again under its repo key: a held copy is skipped and nothing is read with no repo key" do
    polled = issue("held", "MT-HELD", "QA")
    unkeyed = %{polled | repo_key: nil}
    fetcher = fn ["held"] -> {:ok, [unkeyed]} end

    # A green head, so the QA ticket's own gate is open and only the hold holds it back.
    SymphonyElixir.PrWatchSupport.put_watch!("default", "held", phase: :qa)
    on_exit(fn -> RunStore.delete_ticket_state("default", "held") end)

    :ok = RunStore.set_ticket_hold("default", "held", :needs_decision, %{reason: "Investigate the qa_environment by hand?"})
    on_exit(fn -> RunStore.clear_ticket_hold("default", "held", :needs_decision) end)

    revalidate = fn -> send(self(), {:result, Orchestrator.revalidate_issue_for_dispatch_for_test(polled, fetcher)}) end
    log = capture_log(revalidate)

    assert_received {:result, {:skip, %Issue{repo_key: "default"}}}
    refute log =~ "with no repo key"

    :ok = RunStore.clear_ticket_hold("default", "held", :needs_decision)
    assert {:ok, %Issue{repo_key: "default"}} = Orchestrator.revalidate_issue_for_dispatch_for_test(polled, fetcher)
  end

  test "a poll pass that dispatches from the unkeyed by-id read logs no missing repo key" do
    standalone = issue("standalone", "MT-888", "Todo")
    unkeyed = %{standalone | repo_key: nil}
    state = %{orchestrator_state() | dispatch_refresh: %{ids: MapSet.new(["standalone"]), result: {:ok, [unkeyed]}}}

    {state, log} = dispatch_with_log([standalone], state)

    assert Map.has_key?(state.running, "standalone")
    refute log =~ "with no repo key"
  end

  test "with several repos, an issue with no repo key is not dispatched and says why", ctx do
    write_skipped_workflow!(ctx,
      repos: [
        [key: "default", workflow: Workflow.workflow_file_path(), team: "Test"],
        [key: "api", workflow: Workflow.workflow_file_path(), team: "API"]
      ]
    )

    unkeyed = issue("unkeyed", "MT-UNKEYED", "Todo", repo_key: nil)

    {state, log} = dispatch_with_log([unkeyed], orchestrator_state())

    refute Map.has_key?(state.running, "unkeyed")
    assert state.dispatch_skipped["unkeyed"].reason == "it has no repo key and several repos are configured, so its holds can't be read"
    refute log =~ "with no repo key;"
    refute Orchestrator.should_dispatch_issue_for_test(unkeyed, orchestrator_state())
    refute Orchestrator.dispatch_revalidated_issue_for_test(unkeyed, true)
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
