defmodule SymphonyElixir.OrchestratorStartSlotTest do
  # TP-1630: a person's Start is a queue move that takes a slot, never one over the count, and a
  # person's Stop frees the slot in the call. Each test drives the orchestrator's own start and stop
  # handlers (`handle_call/3`) over a state whose holders are on the ticket records, as a restart
  # reads them, and walks its dispatch pass (`dispatch_chosen_issues_for_test/2`) for the free slot.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, TicketState}
  alias SymphonyElixir.Dispatch.Queue
  alias SymphonyElixirWeb.ObservabilityPubSub

  @active_states ["Todo", "In Progress", "Code Review", "QA", "CI Fix", "Merging", "Rework"]
  @early ~U[2026-11-22 07:00:00Z]
  @late ~U[2026-11-22 09:00:00Z]

  setup do
    :ok = RunStore.clear()
    test_root = Path.join(System.tmp_dir!(), "symphony-start-slot-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(test_root)

    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-start-slot","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-start-slot","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
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
    write_slots_workflow!(ctx, 2)
    :ok = ObservabilityPubSub.subscribe_queue()
    on_exit(fn -> ObservabilityPubSub.unsubscribe_queue() end)
    ctx
  end

  describe "Start takes a slot" do
    test "with a slot free, the started ticket goes to the front, takes the free slot and runs; nothing stops", ctx do
      write_slots_workflow!(ctx, 2)
      held = recorded(issue("h", "MT-H", "In Progress"))
      queued = recorded(issue("q", "MT-Q", "Todo"))
      started = recorded(issue("s", "MT-S", "In Progress"))
      tracked([held, queued, started])
      state = orchestrator_state(2) |> holding(held, 1, @early) |> live_run(held)

      {:reply, {:ok, reply}, next} = start(state, started)

      assert %{started: true, issue_identifier: "MT-S", slot: 2, run_id: _run_id} = reply
      refute Map.has_key?(reply, :displaced_issue_identifier)
      assert Enum.sort(Map.keys(next.running)) == ["h", "s"]
      assert %{slot: 2} = next.slot_holders["s"]
      assert order(nil) == ["MT-S", "MT-H", "MT-Q"]
      assert Orchestrator.available_slots_for_test(next) == 0
      assert Orchestrator.dispatch_order_slots_for_test(next).used <= 2

      assert_receive {:queue_notice, %{change: "order", by: "start", issue_identifier: "MT-S"}}
      assert_receive {:queue_notice, %{change: "slots", by: "start", slot: 2, displaced: []}}
    end

    test "with no slot free, the run in the slot stops, the started ticket takes it, and the stopped one is number 1 with no slot", ctx do
      write_slots_workflow!(ctx, 1)
      held = recorded(issue("h", "MT-H", "In Progress"))
      queued = recorded(issue("q", "MT-Q", "Todo"))
      started = recorded(issue("s", "MT-S", "In Progress"))
      tracked([held, queued, started])
      state = orchestrator_state(1) |> holding(held, 1, @early) |> live_run(held)
      worker = state.running["h"].pid
      monitor = Process.monitor(worker)

      {:reply, {:ok, reply}, next} = start(state, started)

      assert %{started: true, slot: 1, displaced_issue_identifier: "MT-H"} = reply
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
      assert Map.keys(next.running) == ["s"]
      assert Map.keys(next.slot_holders) == ["s"]
      assert %{"s" => %{slot: 1}} = RunStore.slot_holders()
      assert order(nil) == ["MT-H", "MT-S", "MT-Q"]
      assert Orchestrator.available_slots_for_test(next) == 0
      # No person stopped it: it is not paused, and takes the next free slot like any queued ticket.
      refute Pauses.paused?({:ticket, "default", "h"})

      assert_receive {:queue_notice, %{change: "order", by: "start"}}
      assert_receive {:queue_notice, %{change: "slots", by: "start", slot: 1, displaced: ["MT-H"]}}
    end

    test "taking over an epic's slot stops its sub-ticket too: the sub-ticket heads its epic and the epic is number 1", ctx do
      write_slots_workflow!(ctx, 1)
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "Todo"}, {"b", "MT-B", "Todo"}]))
      b = recorded(sub("b", "MT-B", "Todo", "MT-E"))
      a = recorded(sub("a", "MT-A", "In Progress", "MT-E"))
      started = recorded(issue("s", "MT-S", "In Progress"))
      tracked([epic, a, b, started])
      state = orchestrator_state(1) |> holding(epic, 1, @early) |> holding(a, 1, @late) |> live_run(a)

      {:reply, {:ok, reply}, next} = start(state, started)

      assert %{slot: 1, displaced_issue_identifier: "MT-A"} = reply
      assert Map.keys(next.running) == ["s"]
      assert Map.keys(next.slot_holders) == ["s"]
      assert order(nil) == ["MT-E", "MT-S"]
      assert order("MT-E") == ["MT-A", "MT-B"]
      assert_receive {:queue_notice, %{change: "slots", displaced: ["MT-A", "MT-E"]}}
    end

    test "a sub-ticket started while a sibling works through its epic's slot swaps with it; the sibling comes next", ctx do
      write_slots_workflow!(ctx, 1)
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "In Progress"}, {"b", "MT-B", "Todo"}, {"c", "MT-C", "Todo"}]))
      a = recorded(sub("a", "MT-A", "In Progress", "MT-E"))
      c = recorded(sub("c", "MT-C", "Todo", "MT-E"))
      b = recorded(sub("b", "MT-B", "Todo", "MT-E"))
      tracked([epic, a, b, c])
      state = orchestrator_state(1) |> holding(epic, 1, @early) |> holding(a, 1, @late) |> live_run(a)

      {:reply, {:ok, reply}, next} = start(state, b)

      assert %{slot: 1, displaced_issue_identifier: "MT-A"} = reply
      assert Map.keys(next.running) == ["b"]
      assert Enum.sort(Map.keys(next.slot_holders)) == ["b", "e"]
      assert %{slot: 1} = next.slot_holders["b"]
      assert order("MT-E") == ["MT-B", "MT-A", "MT-C"]
      assert Orchestrator.available_slots_for_test(next) == 0
    end

    test "a sub-ticket whose epic's slot is idle starts through it, and a ticket holding a slot between runs starts in it", ctx do
      write_slots_workflow!(ctx, 1)
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "Todo"}]))
      a = recorded(sub("a", "MT-A", "Todo", "MT-E"))
      tracked([epic, a])

      {:reply, {:ok, reply}, next} = start(holding(orchestrator_state(1), epic, 1, @early), a)
      assert %{slot: 1} = reply
      refute Map.has_key?(reply, :displaced_issue_identifier)
      assert %{slot: 1} = next.slot_holders["a"]

      # A holder between its runs keeps its slot and its place, whatever slot is named.
      stop_orchestrator_agent_tasks()
      :ok = RunStore.clear()
      held = recorded(issue("h", "MT-H", "In Progress"))
      other = recorded(issue("o", "MT-O", "Todo"))
      tracked([held, other])

      {:reply, {:ok, reply}, next} = start(holding(orchestrator_state(1), held, 1, @early), other)
      assert %{displaced_issue_identifier: "MT-H"} = reply
      assert order(nil) == ["MT-H", "MT-O"]

      stop_orchestrator_agent_tasks()
      next = %{next | running: %{}}
      {:reply, {:ok, reply}, again} = start(next, other, 1)
      assert %{slot: 1, started: true} = reply
      assert order(nil) == ["MT-H", "MT-O"]
      assert Map.keys(again.slot_holders) == ["o"]
    end
  end

  describe "Start naming a slot" do
    test "a named slot that is held is taken over even with another free; a named free slot is simply taken", ctx do
      write_slots_workflow!(ctx, 2)
      held = recorded(issue("h", "MT-H", "In Progress"))
      started = recorded(issue("s", "MT-S", "In Progress"))
      other = recorded(issue("o", "MT-O", "Todo"))
      tracked([held, started, other])
      state = orchestrator_state(2) |> holding(held, 1, @early) |> live_run(held)

      {:reply, {:ok, reply}, next} = start(state, started, 1)
      assert %{slot: 1, displaced_issue_identifier: "MT-H"} = reply
      assert Map.keys(next.running) == ["s"]

      {:reply, {:ok, reply}, next} = start(next, other, 2)
      assert %{slot: 2} = reply
      refute Map.has_key?(reply, :displaced_issue_identifier)
      assert Enum.sort(Map.keys(next.running)) == ["o", "s"]
    end

    test "without a named slot and none free, the slot taken most recently is taken over", ctx do
      write_slots_workflow!(ctx, 2)
      old = recorded(issue("old", "MT-OLD", "In Progress"))
      new = recorded(issue("new", "MT-NEW", "In Progress"))
      started = recorded(issue("s", "MT-S", "In Progress"))
      tracked([old, new, started])
      state = orchestrator_state(2) |> holding(old, 1, @early) |> holding(new, 2, @late) |> live_run(old) |> live_run(new)

      {:reply, {:ok, reply}, next} = start(state, started)
      assert %{slot: 2, displaced_issue_identifier: "MT-NEW"} = reply
      assert Enum.sort(Map.keys(next.running)) == ["old", "s"]
      assert order(nil) == ["MT-NEW", "MT-S", "MT-OLD"]
    end

    test "a named slot nobody holds while a pull request's run takes the other is taken by stopping the latest holder", ctx do
      write_slots_workflow!(ctx, 2)
      held = recorded(issue("h", "MT-H", "In Progress"))
      started = recorded(issue("s", "MT-S", "In Progress"))
      tracked([held, started])
      state = orchestrator_state(2) |> holding(held, 1, @early) |> live_run(held) |> pr_run("pr-7")

      {:reply, {:ok, reply}, next} = start(state, started, 2)
      assert %{slot: 2, displaced_issue_identifier: "MT-H"} = reply
      assert Enum.sort(Map.keys(next.running)) == ["pr-7", "s"]
    end

    test "a slot outside the count, or no slot a Start may take, is refused with nothing changed", ctx do
      write_slots_workflow!(ctx, 1)
      started = recorded(issue("s", "MT-S", "In Progress"))
      tracked([started])
      state = pr_run(orchestrator_state(1), "pr-7")

      for slot <- [0, 2] do
        assert {:reply, {:error, {:start_refused, "There is no slot " <> _rest}}, ^state} = start(state, started, slot)
      end

      assert {:reply, {:error, {:start_refused, "Every slot is taken by a run that can't be stopped for it; try again once one ends."}}, ^state} =
               start(state, started)

      refute_receive {:queue_notice, _notice}
    end
  end

  describe "a refused Start" do
    test "keeps StartNow's reasons and changes no slot, no place in the queue and sends no notice", ctx do
      write_slots_workflow!(ctx, 1)
      held = recorded(issue("h", "MT-H", "In Progress"))
      backlog = recorded(issue("b", "MT-B", "Backlog"))
      tracked([held, backlog])
      state = orchestrator_state(1) |> holding(held, 1, @early) |> live_run(held)
      before = order(nil)

      assert {:reply, {:error, {:start_refused, "The ticket is in Backlog; move it to Todo with Move to… first."}}, ^state} = start(state, backlog)
      assert {:reply, {:error, {:start_refused, "A run is already working on it."}}, ^state} = start(state, held)
      assert order(nil) == before
      assert %{"h" => %{slot: 1}} = RunStore.slot_holders()
      refute_receive {:queue_notice, _notice}
    end
  end

  describe "slot numbers" do
    test "a holder's number is stored on its record and read back after a restart; an older holder is numbered then", ctx do
      write_slots_workflow!(ctx, 2)
      first = recorded(issue("a", "MT-A", "Todo"))
      second = recorded(issue("b", "MT-B", "Todo"))
      legacy = recorded(issue("c", "MT-C", "In Progress"))
      tracked([first, second, legacy])

      state = Orchestrator.dispatch_chosen_issues_for_test([first, second], orchestrator_state(2))
      assert %{slot: 1} = state.slot_holders["a"]
      assert %{slot: 2} = state.slot_holders["b"]
      assert %{slot_number: 1} = "a" |> RunStore.get_ticket_state() |> TicketState.normalize()

      # A holder stored before slots had numbers: the restart numbers it and writes the number.
      :ok = RunStore.put_slot_holder("c", @early)
      holders = Orchestrator.hydrate_slot_holders_for_test()
      assert %{"a" => %{slot: 1}, "b" => %{slot: 2}, "c" => %{slot: 3}} = holders
      assert %{slot_number: 3} = "c" |> RunStore.get_ticket_state() |> TicketState.normalize()
      assert Orchestrator.hydrate_slot_holders_for_test() == holders

      # Giving the slot up clears the number with it.
      :ok = RunStore.put_slot_holder("c", nil, 3)
      assert %{slot_held_since: nil, slot_number: nil} = "c" |> RunStore.get_ticket_state() |> TicketState.normalize()
    end
  end

  describe "Stop frees the slot" do
    test "a stop frees the slot in the call; the free slot goes to the started epic's next sub-ticket, then to the queue", ctx do
      write_slots_workflow!(ctx, 2)
      epic = recorded(epic("e", "MT-E", [{"a", "MT-A", "In Progress"}, {"b", "MT-B", "Todo"}]))
      a = recorded(sub("a", "MT-A", "In Progress", "MT-E"))
      b = recorded(sub("b", "MT-B", "Todo", "MT-E"))
      held = recorded(issue("h", "MT-H", "In Progress"))
      next = recorded(issue("t", "MT-T", "Todo"))
      tracked([epic, a, b, held, next])

      state =
        orchestrator_state(2)
        |> holding(epic, 1, @early)
        |> holding(a, 1, @early)
        |> live_run(a)
        |> holding(held, 2, @late)
        |> live_run(held)

      {:reply, {:ok, reply}, state} = stop(state, "MT-H")
      assert %{stopped: true, issue_identifier: "MT-H", slot: 2} = reply
      refute Map.has_key?(state.slot_holders, "h")
      refute Map.has_key?(RunStore.slot_holders(), "h")
      assert Orchestrator.available_slots_for_test(state) == 1
      # A top-level ticket keeps its place.
      assert order(nil) == ["MT-E", "MT-H", "MT-T"]
      assert_receive {:queue_notice, %{change: "slots", by: "stop", issue_identifier: "MT-H", slot: 2}}
      refute_receive {:queue_notice, %{change: "order"}}

      state = Orchestrator.dispatch_chosen_issues_for_test([epic, a, b, next], state)
      assert Enum.sort(Map.keys(state.running)) == ["a", "b"]
      assert %{reason: "work slots full"} = state.slot_waiting["t"]

      # A stopped sub-ticket heads its epic, and the epic is number 1; the slot goes down the queue.
      {:reply, {:ok, %{stopped: true}}, state} = stop(state, "MT-B")
      assert order("MT-E") == ["MT-B", "MT-A"]
      assert hd(order(nil)) == "MT-E"
      assert_receive {:queue_notice, %{change: "order", by: "stop", issue_identifier: "MT-B"}}

      state = Orchestrator.dispatch_chosen_issues_for_test([epic, a, b, next], state)
      assert Enum.sort(Map.keys(state.running)) == ["a", "t"]
    end

    test "a holder with no live run is stopped too: paused, and its slot free in the call", ctx do
      write_slots_workflow!(ctx, 1)
      held = recorded(issue("h", "MT-H", "Code Review"))
      next = recorded(issue("t", "MT-T", "Todo"))
      tracked([held, next])
      state = holding(orchestrator_state(1), held, 1, @early)

      # A stop that is not a person's (the Conductor's, a Director move's) ends a live run only.
      assert {:reply, {:ok, %{stopped: false}}, ^state} = Orchestrator.handle_call({:stop_running, "h"}, {self(), make_ref()}, state)

      {:reply, {:ok, reply}, state} = stop(state, "h")
      assert %{stopped: true, issue_id: "h", issue_identifier: "MT-H", session_id: nil, slot: 1} = reply
      assert state.slot_holders == %{}
      assert {:ok, %{reasons: [%{kind: :person}]}} = Pauses.get({:ticket, "default", "h"})
      assert_receive {:queue_notice, %{change: "slots", by: "stop"}}

      state = Orchestrator.dispatch_chosen_issues_for_test([held, next], state)
      assert Map.keys(state.running) == ["t"]

      assert {:reply, {:ok, %{stopped: false, issue_id: "MT-NONE"}}, _state} = stop(state, "MT-NONE")
    end
  end

  defp start(state, %Issue{} = issue, slot \\ nil) do
    message = if slot, do: {:start_issue, issue, nil, slot}, else: {:start_issue, issue, nil}
    Orchestrator.handle_call(message, {self(), make_ref()}, state)
  end

  defp stop(state, identifier), do: Orchestrator.handle_call({:stop_running, identifier, free_slot: true}, {self(), make_ref()}, state)

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
    attrs = %{issue_identifier: issue.identifier, title: issue.title, phase: issue.state, linear_updated_at: DateTime.utc_now(), parent: issue.parent}
    :ok = RunStore.put_ticket_state(TicketState.new("default", issue.id, attrs))
    issue
  end

  defp epic(id, identifier, subs) do
    sub_issues = for {sub_id, sub_identifier, state} <- subs, do: %{id: sub_id, identifier: sub_identifier, state: state}
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

  # A pull request's run: it takes a slot while it runs and holds no ticket's.
  defp pr_run(state, id) do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pr = %Issue{id: id, identifier: id, title: "PR", state: "In Progress", run_kind: :pr}
    entry = %{pid: pid, ref: nil, repo_key: "default", identifier: id, issue: pr, run_kind: :pr, run_profile: %{kind: :pr}, started_at: @late}
    %{state | running: Map.put(state.running, id, entry)}
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
