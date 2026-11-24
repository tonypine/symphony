defmodule SymphonyElixir.OrchestratorSlotsTest do
  # TP-1615: a slot belongs to one ticket from its first run until it is done; TP-1624: it keeps it
  # through its waits, and its sub-tickets run through it. Each test walks the
  # orchestrator's own dispatch pass (`dispatch_chosen_issues_for_test/2`), its release of the slots
  # (`release_slots_for_test/3`) and its dispatch order read (`put_dispatch_order_for_test/2`).
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DirectorQueue, Home, Pauses, Situation, TicketState}
  alias SymphonyElixir.Dispatch.Order
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Pauses.Dependencies

  @active_states ["Todo", "In Progress", "Code Review", "QA", "CI Fix", "Merging", "Rework"]
  @since ~U[2026-11-22 07:00:00Z]

  setup do
    :ok = RunStore.clear()
    test_root = Path.join(System.tmp_dir!(), "symphony-slots-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-slots","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-slots","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    on_exit(fn ->
      stop_orchestrator_agent_tasks()
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      RunStore.clear()
      File.rm_rf(test_root)
    end)

    ctx = %{test_root: test_root, fake_claude: fake_claude}
    write_slots_workflow!(ctx)
    ctx
  end

  describe "a ticket holds its slot until it is done" do
    test "with 1 slot, a ticket holding its slot with no live run keeps it in every phase, and no other ticket starts", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      todo = issue("t", "MT-T", "Todo")
      tracked([todo])

      for phase <- ["In Progress", "Code Review", "QA", "CI Fix", "Merging", "Rework"] do
        held = issue("h", "MT-H", phase)
        state = holding(orchestrator_state(1), held)

        # The cycle judges the holder from its candidates: it is one, in its phase, and keeps its slot.
        state = Orchestrator.release_slots_for_test(state, [held, todo], true)
        assert %{identifier: "MT-H", state: ^phase} = state.slot_holders["h"], "#{phase} gave its slot up"
        assert Orchestrator.available_slots_for_test(state) == 0

        dispatched = Orchestrator.dispatch_chosen_issues_for_test([todo], state)
        assert dispatched.running == %{}, "a ticket started while MT-H held the slot in #{phase}"
        assert %{reason: "work slots full"} = dispatched.slot_waiting["t"]
      end
    end

    test "a ticket waiting on a question to the person keeps its slot", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      held = recorded(issue("h", "MT-H", "In Progress"))
      {:ok, _pause} = Pauses.set({:ticket, "default", "h"}, %{kind: :question, waits_on: %{question_id: "q-1"}, text: "Which layout should it use?"})

      state = Orchestrator.release_slots_for_test(holding(orchestrator_state(1), held), [held], true)

      assert Map.has_key?(state.slot_holders, "h")
      refute Orchestrator.should_dispatch_issue_for_test(issue("t", "MT-T", "Todo"), state)
    end

    test "a plan handed to its review waits on the person and keeps its slot, out of the active states", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      plan = recorded(issue("p", "MT-P", "Plan Review"))

      state = Orchestrator.release_slots_for_test(holding(orchestrator_state(1), plan), [], true)

      assert Map.has_key?(state.slot_holders, "p")
    end

    test "a holder whose live run sees its plan moved to Plan Review keeps its slot; a move to Backlog frees it", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)
      plan = issue("p", "MT-P", "In Progress")
      other = issue("o", "MT-O", "In Progress")

      state =
        orchestrator_state(2)
        |> holding(plan)
        |> holding(other)
        |> live_run(plan)
        |> live_run(other)

      reconciled = Orchestrator.reconcile_issue_states_for_test([%{plan | state: "Plan Review"}, %{other | state: "Backlog"}], state)

      refute Map.has_key?(reconciled.running, "p")
      assert Map.has_key?(reconciled.slot_holders, "p")
      refute Map.has_key?(reconciled.slot_holders, "o")
    end

    test "a ticket's first run takes the slot as it is dispatched, before the run's Grooming turn, and the record keeps it", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      first = recorded(issue("a", "MT-A", "Todo"))
      second = recorded(issue("b", "MT-B", "Todo"))
      tracked([first, second])

      # With the slot taken no run starts for the second ticket, so no Grooming turn of its either:
      # Grooming runs inside a dispatched run's task.
      state = Orchestrator.dispatch_chosen_issues_for_test([first, second], orchestrator_state(1))

      assert Map.keys(state.running) == ["a"]
      assert %{identifier: "MT-A", since: %DateTime{} = since} = state.slot_holders["a"]
      refute Map.has_key?(state.slot_holders, "b")
      assert %{reason: "work slots full"} = state.slot_waiting["b"]
      assert %{slot_held_since: ^since} = RunStore.get_ticket_state("a") |> TicketState.normalize()

      # A restart reads the holders from the records.
      assert %{"a" => %{identifier: "MT-A", since: ^since}} = RunStore.slot_holders()
    end
  end

  describe "a ticket gives its slot up" do
    test "when it is done or no longer a candidate, and the freed slot goes to the next ticket", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      next = recorded(issue("t", "MT-T", "Todo"))
      done = recorded(issue("h", "MT-H", "In Progress"))
      :ok = RunStore.put_slot_holder("h", @since)
      tracked([next])

      state = holding(orchestrator_state(1), done)

      # A cold read offers no candidates: it judges nothing.
      assert Orchestrator.release_slots_for_test(state, [next], false).slot_holders == state.slot_holders

      released = Orchestrator.release_slots_for_test(state, [next], true)
      assert released.slot_holders == %{}
      assert RunStore.slot_holders() == %{}

      dispatched = Orchestrator.dispatch_chosen_issues_for_test([next], released)
      assert Map.keys(dispatched.running) == ["t"]
    end

    test "when a person moves it to Backlog", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      backlog = issue("h", "MT-H", "Backlog")

      state = holding(orchestrator_state(1), backlog)
      assert Orchestrator.release_slots_for_test(state, [backlog], true).slot_holders == %{}
    end

    test "when a person stopped it; a run's block report on another ticket keeps it (TP-1624)", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)
      blocked = recorded(issue("b", "MT-B", "In Progress"))
      stopped = recorded(issue("s", "MT-S", "In Progress"))
      block_report!(blocked, "MT-9")
      :ok = Pauses.stop({:ticket, "default", "s"}, DateTime.utc_now())

      state = orchestrator_state(2) |> holding(blocked) |> holding(stopped)
      assert Orchestrator.available_slots_for_test(state) == 0

      released = Orchestrator.release_slots_for_test(state, [blocked, stopped], true)
      assert Map.keys(released.slot_holders) == ["b"]
      assert Orchestrator.available_slots_for_test(released) == 1
    end

    test "never while it waits on its sub-tickets or on a stored dependency of either kind; when it is done (TP-1624)", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 3)
      upstream = recorded(issue("u", "MT-9", "In Progress"))
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "Todo"}]))
      recorded(sub("a", "MT-A", "Todo", "MT-E"))
      done_kind = recorded(issue("d", "MT-D", "In Progress"))
      released_kind = recorded(issue("r", "MT-R", "In Progress"))
      :ok = RunStore.add_dependency("d", "u", :done)
      :ok = RunStore.add_dependency("r", "u", :released)

      state = orchestrator_state(3) |> holding(epic) |> holding(done_kind) |> holding(released_kind)
      kept = Orchestrator.release_slots_for_test(state, [epic, done_kind, released_kind], true)
      assert kept.slot_holders == state.slot_holders
      assert Orchestrator.available_slots_for_test(kept) == 0

      for {issue, gate} <- [{epic, :sub_tickets}, {done_kind, :depends_on}, {released_kind, :depends_on}] do
        assert %{gate: ^gate} = Orchestrator.dispatch_chosen_issues_for_test([issue], kept).dispatch_skipped[issue.id]
      end

      # Done, each gives it up.
      :ok = RunStore.update_ticket_state(upstream.id, %{phase: "Done"})
      done = for issue <- [epic, done_kind, released_kind], do: %{issue | state: "Done"}
      assert Orchestrator.release_slots_for_test(kept, done, true).slot_holders == %{}
    end

    test "the first of the queue held on an unmet dependency takes the free slot with no run, nothing below starts, and its run starts once it is met (TP-1624)", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      upstream = recorded(issue("u", "MT-U", "Code Review"))
      next = recorded(issue("n", "MT-N", "Todo"))
      below = recorded(issue("t", "MT-T", "Todo"))
      :ok = RunStore.add_dependency("n", "u", :done)
      tracked([next, below])

      # The dispatch order reads it so: the head takes its slot in the read's copy only, and the
      # ticket below waits for a slot.
      %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(orchestrator_state(1), [next, below])
      assert %{used: 0, free: 1} = order.slots
      assert [{"MT-N", :held}, {"MT-T", :waits}] = Enum.map(order.entries, &{&1.identifier, &1.outcome})
      assert RunStore.slot_holders() == %{}

      # Unmet: it takes the slot and waits there, with no run; the ticket below waits for a slot.
      held = Orchestrator.dispatch_chosen_issues_for_test([next, below], orchestrator_state(1))
      assert held.running == %{}
      assert %{identifier: "MT-N", since: %DateTime{} = since} = held.slot_holders["n"]
      assert %{slot_held_since: ^since} = RunStore.get_ticket_state("n") |> TicketState.normalize()
      assert %{gate: :depends_on} = held.dispatch_skipped["n"]
      assert %{reason: "work slots full"} = held.slot_waiting["t"]
      assert Orchestrator.available_slots_for_test(held) == 0

      # The cycle keeps it there while it waits.
      held = Orchestrator.release_slots_for_test(held, [next, below], true)
      assert Map.keys(held.slot_holders) == ["n"]

      # Met: its run starts on the slot it holds, with no pause to lift and no read of Linear.
      :ok = RunStore.update_ticket_state(upstream.id, %{phase: "Done"})
      dispatched = Orchestrator.dispatch_chosen_issues_for_test([next, below], held)
      assert Map.keys(dispatched.running) == ["n"]
      assert %{since: ^since} = dispatched.slot_holders["n"]
      assert %{reason: "work slots full"} = dispatched.slot_waiting["t"]
      refute Pauses.paused?({:ticket, "default", "n"})
    end

    test "a ticket held on an unmet dependency below the top takes no free slot; the next ticket that can start does (TP-1624)", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)
      recorded(issue("u", "MT-U", "Code Review"))
      top = recorded(issue("h", "MT-H", "In Progress"))
      next = recorded(issue("n", "MT-N", "Todo"))
      below = recorded(issue("t", "MT-T", "Todo"))
      :ok = RunStore.add_dependency("n", "u", :done)
      tracked([top, next, below])

      dispatched = Orchestrator.dispatch_chosen_issues_for_test([top, next, below], holding(orchestrator_state(2), top))
      refute Map.has_key?(dispatched.slot_holders, "n")
      assert Enum.sort(Map.keys(dispatched.running)) == ["h", "t"]
    end

    test "a ticket whose Linear issue has an open blocker link dispatches, and a reason the retired hold left holds it no longer (TP-1628)", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)

      # The poll's node of MT-L carries an open blocker link to MT-9: the read drops it.
      node = %{
        "id" => "l",
        "identifier" => "MT-L",
        "title" => "Ticket MT-L",
        "description" => "Finish it",
        "priority" => 3,
        "state" => %{"name" => "Todo"},
        "url" => "https://example.org/issues/MT-L",
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => [%{"type" => "blocks", "issue" => %{"id" => "u", "identifier" => "MT-9", "state" => %{"name" => "In Progress"}}}]}
      }

      linked = %{Client.normalize_issue_for_test(node) | repo_key: "default", team: %{key: "Test"}}
      refute Map.has_key?(Map.from_struct(linked), :blocked_by)
      recorded(issue("u", "MT-9", "In Progress"))
      recorded(linked)
      tracked([linked])

      # A reason the retired "Blocked-by links" hold set before the change is cleared by the poll's
      # sweep, and nothing sets one again.
      ticket = {:ticket, "default", "l"}
      {:ok, _pause} = Pauses.set(ticket, Pauses.ticket_reason(:dependency, "MT-9"), set_by: %{kind: :rule, name: "Blocked-by links"})
      assert Orchestrator.sweep_dependencies_for_test("default", [linked], ["Done", "Canceled"]) == 1
      refute Pauses.paused?(ticket)
      assert Orchestrator.sweep_dependencies_for_test("default", [linked], ["Done", "Canceled"]) == 0
      refute Pauses.paused?(ticket)

      # The link has no effect: the ticket takes the free slot, and the dispatch order shows it starting.
      dispatched = Orchestrator.dispatch_chosen_issues_for_test([linked], orchestrator_state(1))
      assert Map.has_key?(dispatched.running, "l")
      refute Map.has_key?(dispatched.dispatch_skipped, "l")
      refute Pauses.paused?(ticket)
    end

    test "a ticket with a live run is judged by its run's end, not by the cycle", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      working = issue("w", "MT-W", "In Progress")
      state = orchestrator_state(1) |> holding(working) |> run(working)

      assert Orchestrator.release_slots_for_test(state, [], true).slot_holders == state.slot_holders
    end
  end

  describe "the slot count" do
    test "with 2 slots and one held, exactly one more ticket starts; a Merging holder takes one of the two", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)
      todos = for n <- 1..3, do: recorded(issue("t#{n}", "MT-#{n}", "Todo"))
      tracked(todos)

      state = holding(orchestrator_state(2), issue("m", "MT-M", "Merging"))
      dispatched = Orchestrator.dispatch_chosen_issues_for_test(todos, state)

      assert Map.keys(dispatched.running) == ["t1"]
      assert Enum.sort(Map.keys(dispatched.slot_holders)) == ["m", "t1"]
      assert Enum.sort(Map.keys(dispatched.slot_waiting)) == ["t2", "t3"]
      assert Orchestrator.available_slots_for_test(dispatched) == 0
    end

    test "lowered below the holders, it evicts nobody and starts no new ticket", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      first = issue("a", "MT-A", "In Progress")
      second = issue("b", "MT-B", "Rework")
      todo = issue("t", "MT-T", "Todo")
      tracked([todo])

      state =
        orchestrator_state(1)
        |> holding(first)
        |> holding(second)
        |> Orchestrator.release_slots_for_test([first, second, todo], true)

      assert Enum.sort(Map.keys(state.slot_holders)) == ["a", "b"]
      assert Orchestrator.available_slots_for_test(state) == 0
      dispatched = Orchestrator.dispatch_chosen_issues_for_test([todo], state)
      refute Map.has_key?(dispatched.running, "t")
    end

    test "two slots start two Todo tickets, and a Merging ticket waits for a slot like any other", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)

      todos = for n <- 1..3, do: recorded(issue("t#{n}", "MT-#{n}", "Todo"))
      tracked(todos)

      # No limit per state: two slots start two Todo tickets.
      dispatched = Orchestrator.dispatch_chosen_issues_for_test(todos, orchestrator_state(2))
      assert Enum.sort(Map.keys(dispatched.running)) == ["t1", "t2"]

      # A Merging ticket waits for a slot like any other: landing has no allowance of its own.
      landing = issue("m", "MT-M", "Merging")
      tracked([landing])
      waits = Orchestrator.dispatch_chosen_issues_for_test([landing], dispatched)
      assert %{reason: "work slots full"} = waits.slot_waiting["m"]
    end
  end

  describe "sub-tickets run through their parent's slot (TP-1624)" do
    test "with 1 slot, an epic's sub-tickets run one after another through its slot, and no other ticket starts until it is done, gaps included", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "Todo"}, {"b", "MT-B", "Todo"}]))
      a = recorded(sub("a", "MT-A", "Todo", "MT-E"))
      b = recorded(sub("b", "MT-B", "Todo", "MT-E"))
      other = recorded(issue("t", "MT-T", "Todo"))
      :ok = RunStore.add_dependency("b", "a", :done)
      tracked([epic, a, b, other])

      # The first sub-ticket starts through the epic's slot; the one that depends on it does not.
      first = Orchestrator.dispatch_chosen_issues_for_test([epic, a, b, other], holding(orchestrator_state(1), epic))
      assert Map.keys(first.running) == ["a"]
      assert %{gate: :sub_tickets} = first.dispatch_skipped["e"]
      assert %{gate: :depends_on} = first.dispatch_skipped["b"]
      assert %{reason: "work slots full"} = first.slot_waiting["t"]
      assert Orchestrator.available_slots_for_test(first) == 0

      # The gap: MT-A is done and the next sub-ticket is not ready yet. The epic keeps its slot, idle.
      # The run it started has ended: its phase writes come before this one.
      stop_orchestrator_agent_tasks()
      :ok = RunStore.update_ticket_state("a", %{phase: "Done"})
      epic = %{epic | sub_issues: [%{id: "a", identifier: "MT-A", state: "Done"}, %{id: "b", identifier: "MT-B", state: "Todo"}]}
      gap = holding(orchestrator_state(1), epic) |> Orchestrator.release_slots_for_test([epic, other], true)
      assert Map.keys(gap.slot_holders) == ["e"]
      gap = Orchestrator.dispatch_chosen_issues_for_test([epic, other], gap)
      assert gap.running == %{}
      assert %{reason: "work slots full"} = gap.slot_waiting["t"]

      # The next sub-ticket starts through the same slot.
      second = Orchestrator.dispatch_chosen_issues_for_test([epic, b, other], gap)
      assert Map.keys(second.running) == ["b"]
      assert %{reason: "work slots full"} = second.slot_waiting["t"]

      # The epic done, its slot goes to the next ticket.
      # The run it started has ended: its phase writes come before this one.
      stop_orchestrator_agent_tasks()
      :ok = RunStore.update_ticket_state("b", %{phase: "Done"})

      done =
        orchestrator_state(1)
        |> holding(epic)
        |> Orchestrator.release_slots_for_test([%{epic | state: "Done"}, other], true)

      assert done.slot_holders == %{}
      assert Map.keys(Orchestrator.dispatch_chosen_issues_for_test([other], done).running) == ["t"]
    end

    test "with 2 slots, an extra slot goes to the epic's next ready sub-ticket; one that depends on an unfinished sibling waits", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "Todo"}, {"b", "MT-B", "Todo"}, {"c", "MT-C", "Todo"}]))
      a = recorded(sub("a", "MT-A", "Todo", "MT-E"))
      b = recorded(sub("b", "MT-B", "Todo", "MT-E"))
      c = recorded(sub("c", "MT-C", "Todo", "MT-E"))
      other = recorded(issue("t", "MT-T", "Todo"))
      :ok = RunStore.add_dependency("c", "a", :released)
      tracked([epic, a, b, c, other])

      state = holding(orchestrator_state(2), epic)
      dispatched = Orchestrator.dispatch_chosen_issues_for_test([epic, a, b, c, other], state)
      assert Enum.sort(Map.keys(dispatched.running)) == ["a", "b"]
      assert %{gate: :depends_on} = dispatched.dispatch_skipped["c"]
      assert %{reason: "work slots full"} = dispatched.slot_waiting["t"]
      assert Orchestrator.available_slots_for_test(dispatched) == 0
    end

    test "an extra slot is free again when the sub-ticket that took it is done, and the epic still holds exactly one", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "Done"}, {"b", "MT-B", "In Progress"}]))
      recorded(sub("a", "MT-A", "Done", "MT-E"))
      b = recorded(sub("b", "MT-B", "In Progress", "MT-E"))
      a = sub("a", "MT-A", "In Progress", "MT-E")

      both = orchestrator_state(2) |> holding(epic) |> holding(a) |> holding(b) |> run(b)
      both = Orchestrator.release_slots_for_test(both, [epic, a, b], true)
      assert Orchestrator.available_slots_for_test(both) == 0

      # MT-A done: its extra slot is free; the epic and MT-B use one.
      freed = Orchestrator.release_slots_for_test(both, [epic, b], true)
      assert Enum.sort(Map.keys(freed.slot_holders)) == ["b", "e"]
      assert Orchestrator.available_slots_for_test(freed) == 1
    end

    test "when the epic at the top has no sub-ticket ready, the extra slot goes to the next ticket down that can start", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)
      recorded(issue("x", "MT-X", "Code Review"))
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "Todo"}]))
      a = recorded(sub("a", "MT-A", "Todo", "MT-E"))
      other = recorded(issue("t", "MT-T", "Todo"))
      :ok = RunStore.add_dependency("a", "x", :done)
      tracked([epic, a, other])

      dispatched = Orchestrator.dispatch_chosen_issues_for_test([epic, a, other], holding(orchestrator_state(2), epic))
      assert Map.keys(dispatched.running) == ["t"]
      assert %{gate: :depends_on} = dispatched.dispatch_skipped["a"]
      refute Map.has_key?(dispatched.slot_holders, "a")
    end

    test "a sub-ticket of a started ticket does not jump ahead of a ticket placed above its parent", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)
      above = recorded(issue("t", "MT-T", "Todo"))
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "In Progress"}, {"b", "MT-B", "Todo"}]))
      a = recorded(sub("a", "MT-A", "In Progress", "MT-E"))
      b = recorded(sub("b", "MT-B", "Todo", "MT-E"))
      tracked([above, epic, a, b])

      state = orchestrator_state(2) |> holding(epic) |> holding(a) |> run(a)
      dispatched = Orchestrator.dispatch_chosen_issues_for_test([b, a, epic, above], state)
      assert Enum.sort(Map.keys(dispatched.running)) == ["a", "t"]
      assert %{reason: "work slots full"} = dispatched.slot_waiting["b"]
    end

    test "a fix ticket filed for a ticket in the middle of its work runs through its slot, and the ticket then continues in its phase", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      working = recorded(issue("p", "MT-P", "In Progress"))
      fix = recorded(sub("f", "MT-9", "Todo", "MT-P"))
      other = recorded(issue("t", "MT-T", "Todo"))
      ticket = {:ticket, "default", "p"}
      {:ok, _pause} = Pauses.set(ticket, Pauses.ticket_reason(:fix_ticket, "MT-9"), set_by: Dependencies.setter(:fix_ticket))
      tracked([working, fix, other])

      # The ticket keeps its slot while it waits on the fix, and the fix starts through it.
      state =
        orchestrator_state(1)
        |> holding(working)
        |> Orchestrator.release_slots_for_test([working, fix, other], true)

      assert Map.keys(state.slot_holders) == ["p"]
      fixing = Orchestrator.dispatch_chosen_issues_for_test([working, fix, other], state)
      assert Map.keys(fixing.running) == ["f"]
      assert %{gate: :paused} = fixing.dispatch_skipped["p"]
      assert %{reason: "work slots full"} = fixing.slot_waiting["t"]

      # The fix done, the pause lifts and the ticket's next run starts in the phase it stopped in, on its slot.
      # The run it started has ended: its phase writes come before this one.
      stop_orchestrator_agent_tasks()
      :ok = RunStore.update_ticket_state("f", %{phase: "Done"})
      Pauses.clear(ticket)
      refute Pauses.paused?(ticket)
      resumed = Orchestrator.dispatch_chosen_issues_for_test([working, other], state)
      assert %{issue: %Issue{state: "In Progress"}} = resumed.running["p"]
      assert %{since: @since} = resumed.slot_holders["p"]
      assert %{reason: "work slots full"} = resumed.slot_waiting["t"]
    end

    test "with 1 slot, the ticket a holder waits on outside its own tree runs through the holder's slot, so neither stalls (TP-1624)", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      blocked = recorded(issue("h", "MT-H", "In Progress"))
      blocker = recorded(issue("b", "MT-8", "Todo"))
      other = recorded(issue("t", "MT-T", "Todo"))
      block_report!(blocked, "MT-8")
      tracked([blocked, blocker, other])

      # The holder keeps its slot and lends it: the top-level ticket its block report names starts on it.
      state =
        orchestrator_state(1)
        |> holding(blocked)
        |> Orchestrator.release_slots_for_test([blocked, blocker, other], true)

      assert Map.keys(state.slot_holders) == ["h"]
      assert Orchestrator.available_slots_for_test(state) == 0

      lent = Orchestrator.dispatch_chosen_issues_for_test([blocked, blocker, other], state)
      assert Map.keys(lent.running) == ["b"]
      assert %{reason: "work slots full"} = lent.slot_waiting["t"]

      # The loan holds while the blocker is in progress: the two read as one used slot.
      lent = Orchestrator.release_slots_for_test(lent, [blocked, blocker, other], true)
      assert Orchestrator.available_slots_for_test(lent) == 0
      assert %{used: 1, free: 0} = Orchestrator.put_dispatch_order_for_test(lent, [blocked, blocker, other]).dispatch_order.slots

      # A stored dependency on a ticket outside its tree, added mid-work, lends the slot the same way.
      stop_orchestrator_agent_tasks()
      :ok = RunStore.update_ticket_state("b", %{phase: "Done"})
      Pauses.clear({:ticket, "default", "h"})
      upstream = recorded(issue("u", "MT-U", "Todo"))
      :ok = RunStore.add_dependency("h", "u", :done)
      tracked([blocked, upstream, other])

      state =
        orchestrator_state(1)
        |> holding(blocked)
        |> Orchestrator.release_slots_for_test([blocked, upstream, other], true)

      depended = Orchestrator.dispatch_chosen_issues_for_test([blocked, upstream, other], state)
      assert Map.keys(depended.running) == ["u"]
      assert %{gate: :depends_on} = depended.dispatch_skipped["h"]
      assert %{reason: "work slots full"} = depended.slot_waiting["t"]
    end
  end

  describe "the reads" do
    test "the dispatch order and Home name each slot's holder and the free slots, and mark in progress exactly the holders", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 3)
      idle = recorded(issue("h", "MT-H", "In Progress"))
      working = recorded(issue("w", "MT-W", "In Progress"))
      todo = recorded(issue("t", "MT-T", "Todo"))
      later = recorded(issue("l", "MT-L", "Todo"))
      issues = [idle, working, todo, later]

      state = orchestrator_state(3) |> holding(idle) |> holding(working) |> run(working)
      %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(state, issues)

      assert %{total: 3, used: 2, free: 1, holders: holders} = order.slots
      assert Enum.map(holders, &{&1.identifier, &1.state, &1.running}) == [{"MT-H", "In Progress", false}, {"MT-W", "In Progress", true}]

      records = RunStore.list_all_ticket_states()
      live = Situation.live_facts(%{running: [%{issue_id: "w", identifier: "MT-W"}], retrying: []})
      read = Order.read(order, records, live)

      flags = read.groups |> Enum.flat_map(& &1.tickets) |> Map.new(&{&1.identifier, &1.in_progress})
      assert flags == %{"MT-H" => true, "MT-W" => true, "MT-T" => false, "MT-L" => false}
      assert read.slots == order.slots

      home = Home.read(order, records, live)
      assert home.slots == order.slots
      assert home.in_progress |> Enum.map(&{&1.identifier, &1.in_progress}) |> Enum.sort() == [{"MT-H", true}, {"MT-W", true}]
      assert Enum.map(home.queue.roots, &{&1.identifier, &1.in_progress}) == [{"MT-T", false}, {"MT-L", false}]

      # Before the first walk there are no slots to read, and nothing is in progress.
      assert %{slots: nil} = Home.read(nil, records, live)
    end

    test "a ticket the dependency gate holds reads, in the dispatch order and Home, as waiting on the ticket it depends on", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      upstream = recorded(issue("u", "MT-U", "Code Review"))
      next = recorded(issue("n", "MT-N", "Todo"))
      :ok = RunStore.add_dependency("n", "u", :done)
      tracked([next])

      # The ticket it depends on holds the one slot, so it takes none.
      dispatched = Orchestrator.dispatch_chosen_issues_for_test([next], holding(orchestrator_state(1), upstream))
      assert dispatched.running == %{}
      refute Map.has_key?(dispatched.slot_holders, "n")
      assert %{gate: :depends_on} = dispatched.dispatch_skipped["n"]

      %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(dispatched, [upstream, next])
      skipped = for {issue_id, skip} <- dispatched.dispatch_skipped, do: Map.put(skip, :issue_id, issue_id)
      live = Situation.live_facts(%{running: [], retrying: [], dispatch_skipped: skipped})
      records = RunStore.list_all_ticket_states()

      blocked = %{kind: "blocked_by_ticket", word: "Blocked by MT-U", cause: "It is in Code Review.", next: "Starts when MT-U lands.", waits_on: %{ticket: "MT-U"}}

      read = Order.read(order, records, live)
      assert %{situation: situation} = read.groups |> Enum.flat_map(& &1.tickets) |> Enum.find(&(&1.identifier == "MT-N"))
      assert Map.take(situation, Map.keys(blocked)) == blocked

      # Home places a root waiting on a ticket in progress after it, from the stored dependency.
      home = Home.read(order, records, live)
      assert %{after: "MT-U", situation: nil} = Enum.find(home.queue.roots, &(&1.identifier == "MT-N"))
    end

    test "a parent and the sub-ticket running through its slot read as one used slot, both in progress (TP-1624)", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "In Progress"}]))
      a = recorded(sub("a", "MT-A", "In Progress", "MT-E"))
      todo = recorded(issue("t", "MT-T", "Todo"))

      state = orchestrator_state(2) |> holding(epic) |> holding(a) |> run(a)
      %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(state, [epic, a, todo])
      assert %{total: 2, used: 1, free: 1, work_used: 1, work_free: 1, holders: holders} = order.slots
      assert holders |> Enum.map(& &1.identifier) |> Enum.sort() == ["MT-A", "MT-E"]

      records = RunStore.list_all_ticket_states()
      live = Situation.live_facts(%{running: [%{issue_id: "a", identifier: "MT-A"}], retrying: []})
      flags = Order.read(order, records, live).groups |> Enum.flat_map(& &1.tickets) |> Map.new(&{&1.identifier, &1.in_progress})
      assert flags == %{"MT-E" => true, "MT-A" => true, "MT-T" => false}

      home = Home.read(order, records, live)
      assert home.slots == order.slots
      assert %{used: 1, free: 1} = home.slots
    end

    test "a PR run takes a slot while it runs, without holding one for a ticket" do
      pr = %{pid: self(), ref: make_ref(), identifier: "MT-PR", repo_key: "default", started_at: @since, run_kind: :pr}
      state = %{orchestrator_state(1) | running: %{"pr" => pr}}

      assert %{used: 1, free: 0, holders: [holder]} = Orchestrator.dispatch_order_slots_for_test(state)
      assert %{issue_id: "pr", identifier: "MT-PR", state: nil, running: true} = holder
    end
  end

  describe "the Director sets the slot count (TP-1629)" do
    test "a raised count applies at once: the next dispatch decision uses it, with no poll or timer", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 1)
      held = recorded(issue("h", "MT-H", "In Progress"))
      next = recorded(issue("t", "MT-T", "Todo"))
      tracked([next])

      state = orchestrator_state(1) |> holding(held) |> Orchestrator.put_dispatch_order_for_test([held, next])
      assert Orchestrator.available_slots_for_test(state) == 0
      assert %{max_total: 1} = state.dispatch_order.slots.concurrency

      # No orchestrator runs under that name: the write answers without one.
      assert {:ok, %{count: 2, slots: nil}} = DirectorQueue.set_slots(2, orchestrator: :no_orchestrator)
      assert {:reply, {:ok, slots}, state} = Orchestrator.handle_call(:slots_changed, {self(), make_ref()}, state)

      assert state.max_concurrent_agents == 2
      assert %{concurrency: %{max_total: 2}, work_free: 1} = slots
      assert state.dispatch_order.slots == slots
      assert Orchestrator.available_slots_for_test(state) == 1
      # The cycle it asks for runs at once, on no timer of the poll's.
      assert_receive {:tick, token}, 100
      assert state.tick_token == token

      dispatched = Orchestrator.dispatch_chosen_issues_for_test([next], state)
      assert Map.keys(dispatched.running) == ["t"]
    end

    test "a count lowered below the tickets in progress stops none, and a freed slot is not refilled until they are under it", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 3)
      [one, two, three] = for n <- 1..3, do: recorded(issue("h#{n}", "MT-H#{n}", "In Progress"))
      next = recorded(issue("t", "MT-T", "Todo"))
      tracked([next])

      state = orchestrator_state(3) |> holding(one) |> holding(two) |> holding(three) |> live_run(one)
      running = state.running

      assert {:ok, %{count: 1}} = DirectorQueue.set_slots(1, orchestrator: :no_orchestrator)
      {:reply, {:ok, _slots}, state} = Orchestrator.handle_call(:slots_changed, {self(), make_ref()}, state)

      # Nothing stops: the run goes on and every ticket keeps its slot.
      assert state.max_concurrent_agents == 1
      assert state.running == running
      assert state.slot_holders |> Map.keys() |> Enum.sort() == ["h1", "h2", "h3"]
      assert Orchestrator.available_slots_for_test(state) == 0

      # MT-H1 is done: two tickets still hold slots, at or above the new count, so MT-T waits.
      state = Orchestrator.release_slots_for_test(%{state | running: %{}}, [two, three, next], true)
      assert state.slot_holders |> Map.keys() |> Enum.sort() == ["h2", "h3"]
      dispatched = Orchestrator.dispatch_chosen_issues_for_test([next], state)
      assert dispatched.running == %{}
      assert %{reason: "work slots full"} = dispatched.slot_waiting["t"]

      # Both done: the one slot is free again and goes to MT-T.
      state = Orchestrator.release_slots_for_test(state, [next], true)
      assert state.slot_holders == %{}
      assert Map.keys(Orchestrator.dispatch_chosen_issues_for_test([next], state).running) == ["t"]
    end
  end

  defp write_slots_workflow!(ctx, overrides \\ []) do
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

  # A run's block report pauses its ticket on the ticket it named, as `SymphonyElixir.TransitionGuard` does.
  defp block_report!(%Issue{id: issue_id}, identifier) do
    {:ok, _pause} = Pauses.set({:ticket, "default", issue_id}, Pauses.ticket_reason(:dependency, identifier), set_by: %{kind: :run, name: "The run"})
  end

  # The ticket's record, which joins the dispatch queue at its end (or at the end of its parent's
  # sub-tickets), in the order written.
  defp recorded(%Issue{} = issue) do
    attrs = %{issue_identifier: issue.identifier, title: issue.title, phase: issue.state, linear_updated_at: DateTime.utc_now(), parent: issue.parent}
    :ok = RunStore.put_ticket_state(TicketState.new("default", issue.id, attrs))
    issue
  end

  # A plan parent whose approved sub-tickets are open waits on them (the `:sub_tickets` gate).
  defp epic(id, identifier, subs) do
    sub_issues =
      for {sub_id, sub_identifier, state} <- subs, do: %{id: sub_id, identifier: sub_identifier, state: state}

    issue(id, identifier, "In Progress", labels: ["plan"], sub_issues: sub_issues)
  end

  defp sub(id, identifier, state, parent), do: issue(id, identifier, state, parent: %{identifier: parent, title: nil, done: 0, total: 1, children: []})

  defp holding(state, %Issue{} = issue) do
    %{state | slot_holders: Map.put(state.slot_holders, issue.id, %{identifier: issue.identifier, state: issue.state, repo_key: "default", since: @since})}
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
      started_at: @since
    }

    %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
  end

  defp live_run(state, %Issue{} = issue) do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    state = run(state, issue)
    %{state | running: Map.update!(state.running, issue.id, &%{&1 | pid: pid, ref: nil})}
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
