defmodule SymphonyElixir.OrchestratorEpicSlotTest do
  # TP-1638: inside an epic that holds a slot, the sub-tickets still to come move and start as the
  # queue's do, with the same refusals; a ticket that finishes in a slot is first in Recently done
  # at once, an epic's next sub-ticket that can start takes the slot the epic keeps, and an ordinary
  # ticket frees its slot for the queue. Each change tells the open streams at once. Each test
  # drives the Director's move (`SymphonyElixir.DirectorQueue.move/3`), the orchestrator's own Start
  # handler (`handle_call/3`), its reconcile of a run's ticket (`reconcile_issue_states_for_test/2`),
  # its release of the slots between runs (`release_slots_for_test/3`) and its dispatch pass, then
  # reads Home (`SymphonyElixir.Home.read/4`) as `GET /api/v1/home` does.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DirectorQueue, Home, Situation, TicketState}
  alias SymphonyElixir.Dispatch.Queue
  alias SymphonyElixirWeb.ObservabilityPubSub

  @active_states ["Todo", "In Progress", "Code Review", "QA", "CI Fix", "Merging", "Rework"]
  @early ~U[2026-11-22 07:00:00Z]
  @late ~U[2026-11-22 09:00:00Z]

  setup do
    :ok = RunStore.clear()
    test_root = Path.join(System.tmp_dir!(), "symphony-epic-slot-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-epic-slot","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-epic-slot","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
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
    write_slots_workflow!(ctx, 1)
    :ok = ObservabilityPubSub.subscribe_queue()
    on_exit(fn -> ObservabilityPubSub.unsubscribe_queue() end)
    ctx
  end

  # An epic that holds slot 1, MT-A in work through it, and MT-B, MT-C and MT-D still to come; MT-D
  # depends on MT-C being done.
  defp epic_in_slot do
    epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "In Progress"}, {"b", "MT-B", "Todo"}, {"c", "MT-C", "Todo"}, {"d", "MT-D", "Todo"}]))
    a = recorded(sub("a", "MT-A", "In Progress", "MT-E"))
    b = recorded(sub("b", "MT-B", "Todo", "MT-E"))
    c = recorded(sub("c", "MT-C", "Todo", "MT-E"))
    d = recorded(sub("d", "MT-D", "Todo", "MT-E"))
    :ok = RunStore.add_dependency("d", "c", :done)
    tracked([epic, a, b, c, d])
    state = orchestrator_state(1) |> holding(epic, 1, @early) |> holding(a, 1, @late) |> live_run(a)
    {state, %{epic: epic, a: a, b: b, c: c, d: d}}
  end

  describe "a move among the sub-tickets still to come of an epic that holds a slot" do
    test "changes their order as in the queue, tells the streams, and the Home read right after gives it on the slot entry" do
      {state, t} = epic_in_slot()
      assert open_sub_tickets(state, t, ["a"]) == ["MT-B", "MT-C", "MT-D"]

      assert {:ok, %{scope: "MT-E", order: ["MT-A", "MT-C", "MT-B", "MT-D"]}} = DirectorQueue.move("MT-C", {:before, "MT-B"}, orchestrator: :no_orchestrator)
      assert_receive {:queue_notice, %{change: "order", issue_identifier: "MT-C"} = notice}
      # The fields a move's notice gave before stay as they were.
      assert notice |> Map.keys() |> Enum.sort() == [:at, :change, :issue_id, :issue_identifier]

      assert order("MT-E") == ["MT-A", "MT-C", "MT-B", "MT-D"]
      assert open_sub_tickets(state, t, ["a"]) == ["MT-C", "MT-B", "MT-D"]
    end

    test "above one it depends on is refused with both tickets named, and the order stays" do
      {state, t} = epic_in_slot()
      before = order("MT-E")

      assert {:error, {:conflict, "MT-D depends on MT-C and must stay below it."}} = DirectorQueue.move("MT-D", {:before, "MT-C"}, orchestrator: :no_orchestrator)
      assert {:error, {:conflict, "MT-D depends on MT-C and must stay below it."}} = DirectorQueue.move("MT-D", :top, orchestrator: :no_orchestrator)
      refute_receive {:queue_notice, _notice}
      assert order("MT-E") == before
      assert open_sub_tickets(state, t, ["a"]) == ["MT-B", "MT-C", "MT-D"]
    end
  end

  describe "a Start of a sub-ticket still to come of an epic that holds a slot" do
    test "gives it the epic's slot; the one in work stops and is first to come, as the Home read right after shows" do
      {state, t} = epic_in_slot()

      {:reply, {:ok, reply}, next} = start(state, t.c)
      assert %{started: true, slot: 1, displaced_issue_identifier: "MT-A"} = reply
      assert Map.keys(next.running) == ["c"]
      assert Enum.sort(Map.keys(next.slot_holders)) == ["c", "e"]
      assert order("MT-E") == ["MT-C", "MT-A", "MT-B", "MT-D"]

      assert_receive {:queue_notice, %{change: "order", by: "start", issue_identifier: "MT-C"}}
      assert_receive {:queue_notice, %{change: "slots", by: "start", issue_identifier: "MT-C", slot: 1, displaced: ["MT-A"]}}
      # The Start's own notice is the only slot notice: its slot taken sends no second one.
      refute_receive {:queue_notice, %{change: "slots"}}

      home = home(next, Map.values(t), ["c"])
      assert %{slot: 1, epic: %{identifier: "MT-E"}, ticket: %{identifier: "MT-C"}} = hd(home.slots.entries)
      assert Enum.map(hd(home.slots.entries).epic.open_sub_tickets, & &1.identifier) == ["MT-A", "MT-B", "MT-D"]
    end

    test "with an unmet dependency of either kind is refused with both tickets named; nothing changes in the slot" do
      {state, t} = epic_in_slot()
      x = recorded(issue("x", "MT-X", "Code Review"))
      :ok = RunStore.add_dependency("b", "x", :released)
      before = order("MT-E")

      assert {:reply, {:error, {:start_refused, "MT-D depends on MT-C and can't start before it is done."}}, ^state} = start(state, t.d)
      assert {:reply, {:error, {:start_refused, "MT-B depends on MT-X and can't start before it is released."}}, ^state} = start(state, t.b)
      refute_receive {:queue_notice, _notice}
      assert order("MT-E") == before
      assert %{"e" => %{slot: 1}, "a" => %{slot: 1}} = RunStore.slot_holders()
      assert open_sub_tickets(state, Map.put(t, :x, x), ["a"]) == ["MT-B", "MT-C", "MT-D"]
    end
  end

  describe "a sub-ticket of an epic that finishes in its slot" do
    test "with a live run: it is first in Recently done at once, and the epic's next sub-ticket that can start takes the same slot" do
      {state, t} = epic_in_slot()
      ran!(t.a)
      flush_ticks()

      done = %{t.a | state: "Done"}
      :ok = RunStore.update_ticket_state("a", %{phase: "Done"})
      state = Orchestrator.reconcile_issue_states_for_test([done], state)

      assert Map.keys(state.slot_holders) == ["e"]
      assert %{"e" => %{slot: 1}} = RunStore.slot_holders()
      assert_receive {:queue_notice, %{change: "slots", by: "done", issue_identifier: "MT-A", slot: 1, freed: false, held_by: "MT-E"}}
      # A cycle runs at once, with no poll.
      assert_receive {:tick, _token}

      home = home(state, Map.values(t), [])
      assert [%{identifier: "MT-A"} | _] = home.recently_done.entries

      state = Orchestrator.dispatch_chosen_issues_for_test([t.epic, t.b, t.c, t.d], state)
      assert Map.keys(state.running) == ["b"]
      assert %{slot: 1} = state.slot_holders["b"]
      assert_receive {:queue_notice, %{change: "slots", by: "pass", issue_identifier: "MT-B", slot: 1, through: "MT-E"}}
      assert %{ticket: %{identifier: "MT-B"}, epic: %{identifier: "MT-E"}} = hd(home(state, Map.values(t), ["b"]).slots.entries)
    end

    test "with none that can start: the epic keeps its slot and no other sub-ticket of it starts", ctx do
      write_slots_workflow!(ctx, 2)
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "In Progress"}, {"b", "MT-B", "Todo"}]))
      a = recorded(sub("a", "MT-A", "In Progress", "MT-E"))
      b = recorded(sub("b", "MT-B", "Todo", "MT-E"))
      x = recorded(issue("x", "MT-X", "Code Review"))
      :ok = RunStore.add_dependency("b", "x", :done)
      tracked([epic, a, b, x])

      state =
        orchestrator_state(2)
        |> holding(epic, 1, @early)
        |> holding(a, 1, @late)
        |> live_run(a)
        |> holding(x, 2, @early)
        |> live_run(x)

      :ok = RunStore.update_ticket_state("a", %{phase: "Done"})
      state = Orchestrator.reconcile_issue_states_for_test([%{a | state: "Done"}], state)
      assert_receive {:queue_notice, %{change: "slots", by: "done", issue_identifier: "MT-A", freed: false, held_by: "MT-E"}}

      state = Orchestrator.dispatch_chosen_issues_for_test([epic, b, x], state)
      assert Map.keys(state.running) == ["x"]
      assert Enum.sort(Map.keys(state.slot_holders)) == ["e", "x"]
      assert %{gate: :depends_on} = state.dispatch_skipped["b"]
      refute_receive {:queue_notice, %{change: "slots", by: "pass"}}
    end

    test "between its runs, offered done or no longer offered: it ends in the slot the same way" do
      {state, t} = epic_in_slot()
      state = %{state | running: %{}, claimed: MapSet.new()}

      # Offered done by the poll.
      ran!(t.a)
      offered = Orchestrator.release_slots_for_test(state, [t.epic, %{t.a | state: "Done"}, t.b, t.c, t.d], true)
      assert Map.keys(offered.slot_holders) == ["e"]
      assert_receive {:queue_notice, %{change: "slots", by: "done", issue_identifier: "MT-A", freed: false, held_by: "MT-E"}}
      assert [%{identifier: "MT-A"} | _] = home(offered, Map.values(t), []).recently_done.entries

      # No longer offered, its record cancelled: it ends, and is not done.
      :ok = RunStore.put_slot_holder("a", @late, 1)
      :ok = RunStore.update_ticket_state("a", %{phase: "Canceled"})
      absent = Orchestrator.release_slots_for_test(state, [t.epic, t.b, t.c, t.d], true)
      assert Map.keys(absent.slot_holders) == ["e"]
      assert_receive {:queue_notice, %{change: "slots", by: "ended", issue_identifier: "MT-A", freed: false, held_by: "MT-E"}}
    end
  end

  describe "an ordinary ticket that finishes in its slot" do
    test "frees the slot for the queue at once: the next ticket takes it, and the streams hear of both" do
      held = recorded(issue("h", "MT-H", "In Progress"))
      next = recorded(issue("t", "MT-T", "Todo"))
      tracked([held, next])
      state = orchestrator_state(1) |> holding(held, 1, @early) |> live_run(held)
      ran!(held)
      flush_ticks()

      :ok = RunStore.update_ticket_state("h", %{phase: "Done"})
      state = Orchestrator.reconcile_issue_states_for_test([%{held | state: "Done"}], state)
      assert state.slot_holders == %{}
      assert RunStore.slot_holders() == %{}
      assert_receive {:queue_notice, %{change: "slots", by: "done", issue_identifier: "MT-H", slot: 1, freed: true} = notice}
      refute Map.has_key?(notice, :held_by)
      assert_receive {:tick, _token}
      assert Orchestrator.available_slots_for_test(state) == 1

      home = home(state, [held, next], [])
      assert [%{identifier: "MT-H"} | _] = home.recently_done.entries
      assert [%{slot: 1, empty: true}] = home.slots.entries

      state = Orchestrator.dispatch_chosen_issues_for_test([next], state)
      assert Map.keys(state.running) == ["t"]
      assert_receive {:queue_notice, %{change: "slots", by: "take", issue_identifier: "MT-T", slot: 1} = taken}
      refute Map.has_key?(taken, :through)
    end

    test "a ticket that holds no slot ends with no slot notice" do
      held = recorded(issue("h", "MT-H", "In Progress"))
      tracked([held])
      state = live_run(orchestrator_state(1), held)
      state = Orchestrator.reconcile_issue_states_for_test([%{held | state: "Done"}], state)
      assert state.running == %{}
      refute_receive {:queue_notice, _notice}
    end
  end

  describe "the Home read keeps its fields" do
    test "every part of the read the app decodes is still there" do
      {state, t} = epic_in_slot()
      home = home(state, Map.values(t), ["a"])
      assert Enum.sort(Map.keys(home)) == [:in_progress, :outside, :queue, :recently_done, :slots]
      assert %{total: 1, used: 1, free: 0, holders: _, entries: [entry]} = home.slots
      assert Enum.sort(Map.keys(entry)) == [:empty, :epic, :since, :slot, :ticket]
      assert %{today: _, week: _} = home.recently_done.counts
    end
  end

  # The open sub-tickets the epic's slot entry gives, in order, from a Home read with `running` live.
  defp open_sub_tickets(state, tickets, running) do
    home = home(state, Map.values(tickets), running)
    Enum.map(hd(home.slots.entries).epic.open_sub_tickets, & &1.identifier)
  end

  defp home(state, issues, running) do
    %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(state, issues)
    live = Situation.live_facts(%{running: Enum.map(running, &%{issue_id: &1, identifier: identifier(&1)}), retrying: []})
    Home.read(order, RunStore.list_all_ticket_states(), live)
  end

  defp identifier(issue_id), do: "MT-" <> String.upcase(issue_id)

  # The ticket's run, stored as a finished one, so its completion is noted on it.
  defp ran!(%Issue{} = issue) do
    :ok =
      RunStore.put_run(%{
        repo_key: "default",
        run_id: "run-#{issue.id}",
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        title: issue.title,
        status: "success",
        started_at: DateTime.utc_now()
      })
  end

  defp flush_ticks do
    receive do
      {:tick, _token} -> flush_ticks()
    after
      0 -> :ok
    end
  end

  defp start(state, %Issue{} = issue), do: Orchestrator.handle_call({:start_issue, issue, nil}, {self(), make_ref()}, state)

  # The identifiers of the queue scope (`nil` for the top level, else the parent's identifier) in order.
  defp order(scope) do
    RunStore.list_all_ticket_states()
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.filter(&(is_binary(&1.sort_key) and is_nil(&1.removed_at) and Queue.scope(&1) == scope))
    |> Enum.sort_by(& &1.sort_key)
    |> Enum.map(& &1.issue_identifier)
  end

  defp write_slots_workflow!(ctx, max_total) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: @active_states,
      tracker_terminal_states: ["Done", "Canceled"],
      workspace_root: Path.join(ctx.test_root, "workspaces"),
      agent_kind: "claude",
      agent_command: ctx.fake_claude,
      max_turns: 1,
      max_concurrent_agents: max_total,
      quality_gate: %{enabled: false}
    )
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  # The ticket's record, which joins the dispatch queue at its end (or at the end of its parent's
  # sub-tickets), in the order written.
  defp recorded(%Issue{} = issue) do
    attrs = %{issue_identifier: issue.identifier, title: issue.title, phase: issue.state, linear_updated_at: DateTime.utc_now(), parent: issue.parent, sub_issues: issue.sub_issues}
    :ok = RunStore.put_ticket_state(TicketState.new("default", issue.id, attrs))
    issue
  end

  defp epic(id, identifier, subs) do
    sub_issues =
      for {sub_id, sub_identifier, state} <- subs, do: %{id: sub_id, identifier: sub_identifier, state: state}

    issue(id, identifier, "In Progress", labels: ["plan"], sub_issues: sub_issues)
  end

  defp sub(id, identifier, state, parent), do: issue(id, identifier, state, parent: %{identifier: parent, title: nil, done: 0, total: 1, children: []})

  # The ticket holds slot `number` since `since`, in the state and on its record.
  defp holding(state, %Issue{} = issue, number, since) do
    :ok = RunStore.put_slot_holder(issue.id, since, number)
    holder = %{identifier: issue.identifier, state: issue.state, repo_key: "default", since: since, slot: number}
    %{state | slot_holders: Map.put(state.slot_holders, issue.id, holder)}
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

  # A live run of the ticket, on a process the stop can end.
  defp live_run(state, %Issue{} = issue) do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    entry = %{
      pid: pid,
      ref: nil,
      repo_key: "default",
      run_id: "run-#{issue.id}",
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      run_profile: %{kind: :implementation, model: nil, effort: nil, provider: "anthropic"},
      session_id: nil,
      turn_count: 0,
      retry_attempt: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: @early
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
