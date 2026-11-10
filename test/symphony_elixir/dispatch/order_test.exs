defmodule SymphonyElixir.Dispatch.OrderTest do
  # The dispatch order read against what the dispatcher dispatches: a fixture with slots, a blocker, a
  # forced ticket and a pause, walked by the orchestrator (`put_dispatch_order_for_test/2`) and then
  # dispatched by its own pass (`dispatch_chosen_issues_for_test/2`).
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.Order
  alias SymphonyElixir.{Pauses, Situation}

  @active_states ["Todo", "In Progress", "Merging", "Rework"]
  @anthropic {"anthropic", :all}

  setup do
    :ok = RunStore.clear()
    test_root = Path.join(System.tmp_dir!(), "symphony-order-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-order","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-order","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      RunStore.clear()
      File.rm_rf(test_root)
    end)

    ctx = %{test_root: test_root, fake_claude: fake_claude}
    write_order_workflow!(ctx)
    ctx
  end

  describe "the order the dispatcher starts tickets in" do
    test "dispatching one ticket starts the one the read called next; the others say why they wait", ctx do
      write_order_workflow!(ctx, max_concurrent_agents: 1)
      first = issue("a", "MT-A", "Todo", priority: 2)
      second = issue("b", "MT-B", "Todo", priority: 3)
      blocked = issue("c", "MT-C", "Todo", priority: 1, blocked_by: [%{id: "id-MT-9", identifier: "MT-9", state: "In Progress"}])
      issues = [blocked, second, first]
      tracked(issues)
      assert sweep(issues) == 1

      state = orchestrator_state(1)
      %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(state, issues)

      # The pass walks the blocked ticket first, for its priority, and passes over it.
      assert [
               %{identifier: "MT-C", position: nil, outcome: :held, reason: "Waiting for MT-9 to finish" = blocked_reason},
               %{identifier: "MT-A", position: 1, outcome: :starts, starts_now: true, reason: "next: a slot is free", slot: "shared"},
               %{identifier: "MT-B", position: 2, outcome: :waits, starts_now: false, reason: "2nd: behind MT-A", wait: "work slots full"}
             ] = order.entries

      assert %{work_used: 0, work_free: 1, forced_used: 0, concurrency: %{max_total: 1}} = order.slots

      dispatched = Orchestrator.dispatch_chosen_issues_for_test(issues, state)
      assert Map.keys(dispatched.running) == ["a"]
      assert %{reason: "work slots full"} = dispatched.slot_waiting["b"]
      assert dispatched.dispatch_skipped["c"].reason == blocked_reason

      # After the pass, the read of the same cycle has the started ticket working and the next in line.
      %{dispatch_order: after_pass} = Orchestrator.put_dispatch_order_for_test(dispatched, issues)
      assert [%{identifier: "MT-B", position: 1, reason: "next: work slots full"}] = Enum.filter(after_pass.entries, & &1.position)
      assert %{outcome: :running, reason: "already running", slot: "shared"} = Enum.find(after_pass.entries, &(&1.issue_id == "a"))
    end

    test "with slots, a blocker and a forced ticket, the read starts exactly the tickets the pass starts", ctx do
      write_order_workflow!(ctx, max_concurrent_agents: 2)
      forced = issue("f", "MT-F", "Todo", forced: true, priority: 4)
      first = issue("a", "MT-A", "Todo", priority: 1)
      second = issue("b", "MT-B", "Todo", priority: 2)
      third = issue("d", "MT-D", "Todo", priority: 3)
      blocked = issue("c", "MT-C", "Todo", priority: 1, blocked_by: [%{id: "id-MT-9", identifier: "MT-9", state: "Todo"}])
      working = issue("w", "MT-W", "In Progress")
      issues = [third, blocked, second, first, forced, working]
      tracked(issues)
      sweep(issues)

      state = run(orchestrator_state(2), working)
      %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(state, issues)

      assert [
               %{identifier: "MT-F", position: 1, outcome: :starts, forced: true, reason: "forced", slot: "forced"},
               %{identifier: "MT-A", position: 2, outcome: :starts, reason: "2nd: a slot is free"},
               %{identifier: "MT-B", position: 3, outcome: :waits, reason: "3rd: behind MT-A", wait: "work slots full"},
               %{identifier: "MT-D", position: 4, outcome: :waits, reason: "4th: behind MT-B"}
             ] = Enum.filter(order.entries, & &1.position)

      assert %{outcome: :running} = Enum.find(order.entries, &(&1.identifier == "MT-W"))
      assert %{outcome: :held} = Enum.find(order.entries, &(&1.identifier == "MT-C"))

      dispatched = Orchestrator.dispatch_chosen_issues_for_test(issues, state)
      starts = for %{outcome: :starts, issue_id: issue_id} <- order.entries, do: issue_id
      assert Enum.sort(Map.keys(dispatched.running) -- Map.keys(state.running)) == Enum.sort(starts)
      assert %{forced: true} = dispatched.running["f"]
    end

    test "while Symphony is paused every ticket in line reads the pause and keeps its place", ctx do
      write_order_workflow!(ctx, max_concurrent_agents: 2)
      first = issue("a", "MT-A", "Todo", priority: 1)
      second = issue("b", "MT-B", "Todo", priority: 2)
      tracked([first, second])
      {:ok, pause} = Pauses.set(:symphony, Pauses.dispatch_reason("maintenance"))
      reason = Pauses.dispatch_skip_reason(pause)
      assert reason == "dispatch is paused by the operator: maintenance"

      %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(orchestrator_state(2), [second, first])

      assert [
               %{identifier: "MT-A", position: 1, outcome: :paused, reason: ^reason, rule: :symphony_pause},
               %{identifier: "MT-B", position: 2, outcome: :paused, reason: ^reason}
             ] = order.entries
    end

    test "a spent daily budget pauses the line but lets a forced ticket start", ctx do
      write_order_workflow!(ctx, max_concurrent_agents: 2, max_tokens_per_day: 10)
      forced = issue("f", "MT-F", "Todo", forced: true)
      todo = issue("a", "MT-A", "Todo")
      tracked([forced, todo])

      state = %{orchestrator_state(2) | budget_daily_used: 10}
      %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(state, [todo, forced])

      assert [
               %{identifier: "MT-F", position: 1, outcome: :starts, reason: "forced"},
               %{identifier: "MT-A", position: 2, outcome: :paused, rule: :daily_budget, reason: "the daily token budget is spent (agent.max_tokens_per_day)"}
             ] = order.entries
    end

    test "a usage limit holds a ticket out of line with the hold's label", ctx do
      write_order_workflow!(ctx, max_concurrent_agents: 2)
      todo = issue("a", "MT-A", "Todo")
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

      state = %{orchestrator_state(2) | usage_limits: %{@anthropic => hold}}
      %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(state, [todo])

      assert [%{identifier: "MT-A", position: nil, outcome: :held, rule: :usage_limit, reason: reason}] = order.entries
      assert reason == SymphonyElixir.UsageLimit.hold_label(hold)
    end
  end

  describe "place/1 and ordinal/1" do
    test "a place in line reads next, then 2nd, 3rd, 4th, with the teens and the twenties right" do
      assert Enum.map([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111, 112], &Order.ordinal/1) ==
               ~w(next 2nd 3rd 4th 11th 12th 13th 21st 22nd 23rd 101st 111th 112th)
    end

    test "a ticket out of line keeps its reason and has no place" do
      assert [%{position: nil, starts_now: false, wait: nil, reason: "already running"}, %{position: 1, reason: "next: a slot is free"}] =
               Order.place([%{identifier: "MT-1", outcome: :running, reason: "already running"}, %{identifier: "MT-2", outcome: :starts, forced: false, reason: nil}])
    end
  end

  describe "read/3" do
    test "every open ticket is in exactly one group, under its situation's kind, and the line is in order" do
      ticket("a", "MT-A", "Todo")
      ticket("b", "MT-B", "Todo")
      ticket("p", "MT-P", "Plan Review")
      ticket("k", "MT-K", "Backlog")
      ticket("d", "MT-D", "Done")
      ticket("r", "MT-R", "Todo", %{removed_at: DateTime.utc_now()})

      order = %{
        computed_at: ~U[2026-11-09 12:00:00Z],
        slots: %{work_free: 1},
        entries:
          Order.place([
            entry("a", "MT-A", :starts, slot: "shared"),
            entry("b", "MT-B", :waits, reason: "work slots full"),
            entry("x", "MT-X", :held, reason: "priority", rule: :priority)
          ])
      }

      read = Order.read(order, RunStore.list_all_ticket_states(), live())

      assert read.computed_at == "2026-11-09T12:00:00Z"
      assert read.next == "MT-A"
      assert read.slots == %{work_free: 1}
      assert Enum.map(read.queue, &{&1.identifier, &1.position, &1.reason}) == [{"MT-A", 1, "next: a slot is free"}, {"MT-B", 2, "2nd: behind MT-A"}]

      grouped = Enum.flat_map(read.groups, fn group -> Enum.map(group.tickets, &{group.kind, &1.identifier}) end)
      assert Enum.sort(Enum.map(grouped, &elem(&1, 1))) == ~w(MT-A MT-B MT-K MT-P MT-X)
      assert Enum.all?(read.groups, &(&1.count == length(&1.tickets) and &1.kind in Situation.kinds()))
      assert {"waiting_on_you", "MT-P"} in grouped
      assert {"paused_by_rule", "MT-K"} in grouped

      plan = Enum.find(Enum.flat_map(read.groups, & &1.tickets), &(&1.identifier == "MT-P"))
      assert %{outcome: "not_a_candidate", position: nil, state: "Plan Review", rule: nil} = plan
      assert plan.reason == plan.situation.cause

      held = Enum.find(Enum.flat_map(read.groups, & &1.tickets), &(&1.identifier == "MT-X"))
      assert %{outcome: "held", rule: "priority", reason: "priority"} = held
    end

    test "before the first poll cycle the read has no line and still groups every open ticket" do
      ticket("a", "MT-A", "Todo")

      read = Order.read(nil, RunStore.list_all_ticket_states(), live())

      assert %{computed_at: nil, next: nil, slots: nil, queue: []} = read
      assert [%{tickets: [%{identifier: "MT-A", outcome: "not_a_candidate"}]}] = read.groups
    end
  end

  defp live, do: Situation.live_facts(%{running: [], retrying: []})

  defp entry(id, identifier, outcome, fields) do
    base = %{issue_id: id, identifier: identifier, title: identifier, state: "Todo", repo_key: "default", forced: false, rule: nil}
    Map.merge(base, Map.new([outcome: outcome] ++ fields))
  end

  defp ticket(id, identifier, phase, fields \\ %{}) do
    :ok =
      RunStore.put_ticket_state(
        Map.merge(%{repo_key: "default", issue_id: id, issue_identifier: identifier, title: "Ticket #{identifier}", phase: phase, linear_updated_at: DateTime.utc_now()}, fields)
      )
  end

  defp write_order_workflow!(ctx, overrides \\ []) do
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

  defp sweep(issues), do: Orchestrator.sweep_dependencies_for_test("default", issues, Config.settings!().tracker.terminal_states)

  defp issue(id, identifier, state, attrs) do
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

  defp issue(id, identifier, state), do: issue(id, identifier, state, [])

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
