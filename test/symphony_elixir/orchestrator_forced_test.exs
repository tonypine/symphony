defmodule SymphonyElixir.OrchestratorForcedTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Notifications, UsageLimit}

  @active_states ["Todo", "In Progress", "Merging", "Rework", "Auto Review"]
  @anthropic {"anthropic", :all}

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-forced-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-forced","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-forced","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      File.rm_rf(test_root)
    end)

    ctx = %{test_root: test_root, fake_claude: fake_claude}
    write_forced_workflow!(ctx)
    ctx
  end

  describe "the forced allowance" do
    test "with max_total full a forced Todo starts on it, ahead of the queue, and the running agents are untouched", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 2)
      forced = issue("forced-1", "MT-F1", "Todo", forced: true, priority: 4)
      todo = issue("todo-1", "MT-TODO", "Todo", priority: 1)
      tracked([forced, todo])

      state =
        orchestrator_state(2)
        |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)
        |> run(issue("impl-2", "MT-2", "In Progress"), :implementation)

      refute Orchestrator.should_dispatch_issue_for_test(todo, state)
      assert Orchestrator.should_dispatch_issue_for_test(forced, state)

      {state, log} = dispatch_with_log([todo, forced], state)

      assert Enum.sort(Map.keys(state.running)) == ["forced-1", "impl-1", "impl-2"]
      assert %{forced: true} = state.running["forced-1"]
      assert log =~ ~r/Dispatching issue to agent: issue_id=forced-1 .* slot=forced forced=true/
      assert %{reason: "work slots full"} = state.slot_waiting["todo-1"]

      snapshot = snapshot_of(state)
      assert %{forced: true} = Enum.find(snapshot.running, &(&1.issue_id == "forced-1"))
      assert %{forced: false} = Enum.find(snapshot.running, &(&1.issue_id == "impl-1"))
      assert [%{issue_id: "todo-1", forced: false}] = snapshot.slot_waiting
      assert %{epic_lanes: %{shared: %{used: 2}}, finishing: %{used: 0}} = snapshot
    end

    test "a forced run takes no normal slot, and a normal ticket goes out on a free one as a normal run", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      todo = issue("todo-1", "MT-TODO", "Todo")
      tracked([todo])

      state = run(orchestrator_state(1), issue("forced-1", "MT-F1", "In Progress", forced: true), :implementation, forced: true)

      {state, log} = dispatch_with_log([todo], state)

      assert %{forced: false} = state.running["todo-1"]
      assert log =~ ~r/issue_id=todo-1 .* slot=shared forced=false/
    end

    test "a forced Rework ticket and a forced landing start with their normal slots full", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1, finishing_max: 1, forced_max: 2)
      rework = issue("rework-1", "MT-RW", "Rework", forced: true)
      landing = issue("land-2", "MT-LAND-2", "Merging", forced: true)
      tracked([rework, landing])

      state =
        orchestrator_state(1)
        |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)
        |> run(issue("land-1", "MT-LAND-1", "Merging"), :landing)

      state = Orchestrator.dispatch_chosen_issues_for_test([rework, landing], state)

      assert %{forced: true} = state.running["rework-1"]
      assert %{forced: true, run_profile: %{kind: :landing}} = state.running["land-2"]
      assert state.slot_waiting == %{}
      assert %{finishing: %{used: 1}} = snapshot_of(state)
    end

    test "per-state caps leave a forced ticket alone and do not count its run", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 3, max_concurrent_agents_by_state: %{"Todo" => 1})
      forced = issue("forced-1", "MT-F1", "Todo", forced: true)
      todo = issue("todo-1", "MT-TODO", "Todo")
      tracked([forced, todo])

      state = run(orchestrator_state(3), issue("todo-0", "MT-T0", "Todo"), :implementation)
      state = Orchestrator.dispatch_chosen_issues_for_test([forced, todo], state)

      assert %{forced: true} = state.running["forced-1"]
      assert %{reason: "work slots full"} = state.slot_waiting["todo-1"]

      # The forced Todo run does not use up the Todo cap either.
      state = %{state | running: Map.delete(state.running, "todo-0")}
      state = Orchestrator.dispatch_chosen_issues_for_test([todo], state)
      assert %{forced: false} = state.running["todo-1"]
    end

    test "a forced Todo starts while a finish waits for a slot", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 2, finishing_max: 1)
      second_landing = issue("land-2", "MT-LAND-2", "Merging")
      forced = issue("forced-1", "MT-F1", "Todo", forced: true)
      todo = issue("todo-1", "MT-TODO", "Todo")
      tracked([second_landing, forced, todo])

      state = run(orchestrator_state(2), issue("land-1", "MT-LAND-1", "Merging"), :landing)
      state = Orchestrator.dispatch_chosen_issues_for_test([todo, second_landing, forced], state)

      assert Enum.sort(Map.keys(state.running)) == ["forced-1", "land-1"]
      assert %{reason: "finishing slots full"} = state.slot_waiting["land-2"]
      assert %{reason: "MT-LAND-2 (Merging) is waiting for a finishing slot"} = state.slot_waiting["todo-1"]
    end

    test "a second forced ticket waits as queued #2, is noted once, and starts on the allowance when the first ends", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      :ok = Notifications.subscribe()
      first = issue("forced-1", "MT-F1", "In Progress", forced: true)
      second = issue("forced-2", "MT-F2", "Todo", forced: true)
      tracked([second])

      queue = %{
        "forced-1" => queue_entry(first, ~U[2026-10-04 06:00:00Z]),
        "forced-2" => queue_entry(second, ~U[2026-10-04 07:00:00Z])
      }

      state =
        %{orchestrator_state(1) | forced: queue}
        |> run(first, :implementation, forced: true)
        |> run(issue("impl-1", "MT-1", "In Progress"), :implementation)

      {state, log} = dispatch_with_log([second], state)

      refute Map.has_key?(state.running, "forced-2")
      assert %{reason: "queued #2; forced slot taken by MT-F1"} = state.slot_waiting["forced-2"]
      assert log =~ "Forced ticket waiting: issue_id=forced-2 issue_identifier=MT-F2 forced=true forced_max=1 held_by=MT-F1"
      assert_receive {:notification_event, %Notifications.Event{event: "forced_waiting", issue_identifier: "MT-F2", reason: "queued #2; forced slot taken by MT-F1"}}

      snapshot = snapshot_of(state)
      assert [%{issue_id: "forced-2", forced: true}] = snapshot.slot_waiting
      assert [%{issue_id: "forced-1", position: 1}, %{issue_id: "forced-2", position: 2}] = snapshot.forced

      # The next poll leaves it waiting without a second notice.
      {state, log} = dispatch_with_log([second], state)
      refute log =~ "Forced ticket waiting"
      refute_receive {:notification_event, %Notifications.Event{event: "forced_waiting"}}, 50

      # The first forced run ends: the second takes the allowance though the normal slot is still full.
      state = %{state | running: Map.delete(state.running, "forced-1")}
      state = Orchestrator.dispatch_chosen_issues_for_test([second], state)

      assert %{forced: true} = state.running["forced-2"]
      refute MapSet.member?(state.forced_waiting_noted, "forced-2")
    end

    test "a forced ticket past forced_max takes a free normal slot as a normal run", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      second = issue("forced-2", "MT-F2", "Todo", forced: true)
      todo = issue("todo-1", "MT-TODO", "Todo", priority: 1)
      tracked([second, todo])

      state = run(orchestrator_state(1), issue("forced-1", "MT-F1", "In Progress", forced: true), :implementation, forced: true)

      {state, log} = dispatch_with_log([todo, second], state)

      assert %{forced: false} = state.running["forced-2"]
      assert log =~ "Forced ticket waiting: issue_id=forced-2"
      assert log =~ ~r/issue_id=forced-2 .* slot=shared forced=false/
      assert %{reason: "work slots full"} = state.slot_waiting["todo-1"]
    end

    test "forced tickets go first in forced_since order; one not yet queued follows", ctx do
      write_forced_workflow!(ctx, forced_max: 3)
      older = issue("forced-old", "MT-F1", "Todo", forced: true)
      newer = issue("forced-new", "MT-F2", "Merging", forced: true)
      unqueued = issue("forced-unqueued", "MT-F3", "Merging", forced: true)
      landing = issue("land-1", "MT-LAND", "Merging", priority: 1)
      tracked([older, newer, unqueued, landing])

      queue = %{
        "forced-old" => queue_entry(older, ~U[2026-10-04 06:00:00Z]),
        "forced-new" => queue_entry(newer, ~U[2026-10-04 07:00:00Z])
      }

      state = %{orchestrator_state(10) | forced: queue}
      {_state, log} = dispatch_with_log([landing, unqueued, newer, older], state)

      assert dispatch_order(log) == ["forced-old", "forced-new", "forced-unqueued", "land-1"]
    end
  end

  describe "the gates a forced ticket still respects" do
    test "a blocked-by link and a paused usage limit hold it; a headroom hold does not", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      blocked = %{issue("forced-1", "MT-F1", "Todo", forced: true) | blocked_by: [%{id: "b", identifier: "MT-B", state: "In Progress"}]}
      forced = issue("forced-2", "MT-F2", "Todo", forced: true)
      tracked([blocked, forced])

      state = Orchestrator.dispatch_chosen_issues_for_test([blocked], orchestrator_state(1))
      assert state.running == %{}

      paused = %{orchestrator_state(1) | usage_limits: %{@anthropic => hold(:paused)}}
      refute Orchestrator.should_dispatch_issue_for_test(forced, paused)
      headroom = %{paused | usage_limits: %{@anthropic => hold(:headroom)}}
      refute Orchestrator.should_dispatch_issue_for_test(issue("todo-1", "MT-TODO", "Todo"), headroom)

      state = Orchestrator.dispatch_chosen_issues_for_test([forced], headroom)
      assert %{forced: true} = state.running["forced-2"]
    end

    test "on the retry path a forced continuation starts with the slots full, and an operator pause still holds it", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1)
      forced = issue("forced-1", "MT-F1", "In Progress", forced: true)
      tracked([forced])

      full = run(%{orchestrator_state(1) | claimed: MapSet.new(["forced-1"])}, issue("impl-1", "MT-1", "In Progress"), :implementation)
      metadata = %{identifier: "MT-F1", repo_key: "default", continuation: true}
      fetcher = fn ["forced-1"] -> {:ok, [forced]} end

      retry_forced = &Orchestrator.handle_retry_issue_for_test(&1, "forced-1", 1, metadata, fetcher)

      paused = %{full | pause: %{paused: true, reason: "maintenance", paused_at: DateTime.utc_now()}}
      {:noreply, held} = retry_forced.(paused)
      assert %{error: "dispatch paused by operator"} = held.retry_attempts["forced-1"]
      Process.cancel_timer(held.retry_attempts["forced-1"].timer_ref)

      log = capture_log(fn -> send(self(), {:result, retry_forced.(full)}) end)
      assert_received {:result, {:noreply, state}}

      assert %{forced: true, retry_attempt: 1} = state.running["forced-1"]
      assert log =~ ~r/issue_id=forced-1 .* slot=forced forced=true/
    end

    test "a waiting forced retry shows as forced in the snapshot" do
      state = %{
        orchestrator_state(1)
        | forced: %{"forced-1" => queue_entry(issue("forced-1", "MT-F1", "Todo", forced: true), ~U[2026-10-04 06:00:00Z])},
          retry_attempts: %{"forced-1" => %{attempt: 2, due_at_ms: System.monotonic_time(:millisecond), identifier: "MT-F1"}},
          merging_ci_waits: %{
            "land-1" => %{
              identifier: "MT-LAND",
              title: "Land",
              repo_key: nil,
              pull_request_url: nil,
              commit_sha: "abc",
              since: DateTime.utc_now()
            }
          }
      }

      snapshot = snapshot_of(state)
      assert [%{issue_id: "forced-1", forced: true}] = snapshot.retrying
      assert [%{issue_id: "land-1", forced: false}] = snapshot.slot_waiting
    end

    test "a held forced retry is chosen as the usage limit canary", ctx do
      write_forced_workflow!(ctx)
      plain = issue("plain-1", "MT-1", "In Progress", priority: 1)
      forced = issue("forced-1", "MT-2", "Todo", forced: true, priority: 4)

      held = fn issue -> %{attempt: 1, identifier: issue.identifier, title: issue.title, repo_key: "default", usage_limit_key: @anthropic} end

      state = %{
        orchestrator_state(1)
        | usage_limits: %{@anthropic => hold(:paused)},
          retry_attempts: %{"plain-1" => held.(plain), "forced-1" => held.(forced)}
      }

      state = Orchestrator.start_usage_limit_canary_for_test(state, @anthropic, fn _ids -> {:ok, [plain, forced]} end)

      assert %{phase: :canary, canary_issue_id: "forced-1"} = state.usage_limits[@anthropic]
      assert Map.has_key?(state.slot_waiting, "forced-1")
    end
  end

  describe "a poll" do
    test "runs the dispatch pass for a forced ticket while every normal slot is full", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 1, finishing_max: 1, poll_interval_ms: 600_000)
      {pid, _impl, _land} = start_full_orchestrator(ctx, :FullSlots)

      tracked(running_issues() ++ [issue("forced-1", "MT-F1", "Todo", forced: true)])

      log =
        capture_log(fn ->
          send(pid, :run_poll_cycle)
          wait_until(fn -> dispatched?(pid, "forced-1") end)
        end)

      assert log =~ ~r/Dispatching issue to agent: issue_id=forced-1 .* slot=forced forced=true/
    end

    test "dispatches a forced ticket over the daily token budget and keeps the others waiting", ctx do
      write_forced_workflow!(ctx, max_concurrent_agents: 3, max_tokens_per_day: 10, poll_interval_ms: 600_000)
      {pid, _impl, _land} = start_full_orchestrator(ctx, :DailyBudget)
      waiting = %{identifier: "MT-TODO", title: "Ticket MT-TODO", state: "Todo", reason: "work slots full", attempt: 2, since: DateTime.utc_now()}

      :sys.replace_state(pid, fn state ->
        %{state | budget_daily_used: 50, budget_day_started_on: Date.utc_today(), slot_waiting: %{"todo-1" => waiting}}
      end)

      tracked(running_issues() ++ [issue("forced-1", "MT-F1", "Todo", forced: true), issue("todo-1", "MT-TODO", "Todo")])

      log =
        capture_log(fn ->
          send(pid, :run_poll_cycle)
          wait_until(fn -> dispatched?(pid, "forced-1") end)
        end)

      assert log =~ "Daily token budget exhausted daily_used=50 daily_limit=10; dispatched forced ticket anyway: issue_id=forced-1"
      state = :sys.get_state(pid)
      refute Map.has_key?(state.running, "todo-1")
      assert %{attempt: 2} = state.slot_waiting["todo-1"]
    end
  end

  test "a headroom hold lets a forced ticket's run through" do
    entry = hold(:headroom)
    profile = %{provider: "anthropic", model: "claude-opus-5-5", kind: :implementation}

    assert UsageLimit.holds?(entry, profile)
    refute UsageLimit.holds?(entry, Map.put(profile, :forced, true))
    assert UsageLimit.holds?(hold(:paused), Map.put(profile, :forced, true))
  end

  defp start_full_orchestrator(_ctx, name) do
    tracked([])
    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, name))

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    wait_until(fn ->
      state = :sys.get_state(pid)
      poll_idle? = not state.poll_check_in_progress and is_nil(state.repo_poll_task_ref)
      poll_idle? and is_nil(state.startup_workspace_lifecycle_task_ref)
    end)

    [impl, land] = running_issues()

    :sys.replace_state(pid, fn state ->
      state
      |> run(impl, :implementation, pid: spawn_idle())
      |> run(land, :landing, pid: spawn_idle())
      |> Map.put(:repo_poll_due_at_ms, %{})
    end)

    {pid, impl, land}
  end

  defp running_issues, do: [issue("impl-1", "MT-1", "In Progress"), issue("land-1", "MT-LAND", "Merging")]

  defp spawn_idle, do: spawn(fn -> receive do: (:stop -> :ok) end)

  defp dispatched?(pid, issue_id) do
    state = :sys.get_state(pid)
    Map.has_key?(state.running, issue_id) or Map.has_key?(state.retry_attempts, issue_id) or MapSet.member?(state.completed, issue_id)
  end

  defp wait_until(fun, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline, do: flunk("condition not met in time")
      Process.sleep(25)
      do_wait_until(fun, deadline)
    end
  end

  defp hold(phase) do
    now = DateTime.utc_now()

    %{
      provider: "anthropic",
      scope: :all,
      reason: "claude_usage_limit",
      window: "five_hour",
      phase: phase,
      since: now,
      resets_at: DateTime.add(now, 3_600),
      resume_at: DateTime.add(now, 3_600),
      canary_issue_id: nil
    }
  end

  defp queue_entry(%Issue{} = issue, forced_since) do
    %{identifier: issue.identifier, title: issue.title, state: issue.state, repo_key: nil, forced_since: forced_since}
  end

  defp write_forced_workflow!(ctx, overrides \\ []) do
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
    log = capture_log(fn -> send(self(), {:state, Orchestrator.dispatch_chosen_issues_for_test(issues, state)}) end)
    assert_received {:state, state}
    {state, log}
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp dispatch_order(log) do
    ~r/Dispatching issue to agent: issue_id=(\S+)/
    |> Regex.scan(log, capture: :all_but_first)
    |> List.flatten()
  end

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
  end

  defp issue(id, identifier, state, attrs \\ []) do
    {forced?, attrs} = Keyword.pop(attrs, :forced, false)

    struct!(
      %Issue{
        id: id,
        identifier: identifier,
        title: "Ticket #{identifier}",
        description: "Finish it",
        state: state,
        priority: 3,
        team: %{key: "Test"},
        labels: if(forced?, do: ["expedite"], else: []),
        url: "https://example.org/issues/#{identifier}"
      },
      attrs
    )
  end

  defp run(state, %Issue{} = issue, kind, opts \\ []) do
    entry = %{
      pid: Keyword.get(opts, :pid, self()),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_profile: %{kind: kind, model: nil, effort: nil, provider: "anthropic"},
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      forced: Keyword.get(opts, :forced, false),
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
