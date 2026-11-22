defmodule SymphonyElixir.OrchestratorSlotsTest do
  # TP-1615: a slot belongs to one ticket from its first run until it is done. Each test walks the
  # orchestrator's own dispatch pass (`dispatch_chosen_issues_for_test/2`), its release of the slots
  # (`release_slots_for_test/3`) and its dispatch order read (`put_dispatch_order_for_test/2`).
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.Order
  alias SymphonyElixir.{Home, Pauses, Situation, TicketState}

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

    test "when it waits on a blocker, or a person stopped it", ctx do
      write_slots_workflow!(ctx, max_concurrent_agents: 2)
      blocked = recorded(issue("b", "MT-B", "In Progress", blocked_by: [%{id: "id-MT-9", identifier: "MT-9", state: "In Progress"}]))
      stopped = recorded(issue("s", "MT-S", "In Progress"))
      assert Orchestrator.sweep_dependencies_for_test("default", [blocked], ["Done", "Canceled"]) == 1
      :ok = Pauses.stop({:ticket, "default", "s"}, DateTime.utc_now())

      state = orchestrator_state(2) |> holding(blocked) |> holding(stopped)
      assert Orchestrator.available_slots_for_test(state) == 0

      released = Orchestrator.release_slots_for_test(state, [blocked, stopped], true)
      assert released.slot_holders == %{}
      assert Orchestrator.available_slots_for_test(released) == 2
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

    test "finishing_max, the per-state limits and the epic lanes still load and change nothing", ctx do
      write_slots_workflow!(ctx,
        max_concurrent_agents: 2,
        finishing_max: 1,
        max_concurrent_agents_by_state: %{"todo" => 1},
        epic_lanes: 1
      )

      settings = Config.settings!()
      execution = settings.execution
      assert execution.finishing_max == 1
      assert execution.max_concurrent_agents_by_state == %{"todo" => 1}
      assert execution.epic_lanes == 1

      todos = for n <- 1..3, do: recorded(issue("t#{n}", "MT-#{n}", "Todo"))
      tracked(todos)

      # The per-state limit of 1 Todo would have started one; two slots start two.
      dispatched = Orchestrator.dispatch_chosen_issues_for_test(todos, orchestrator_state(2))
      assert Enum.sort(Map.keys(dispatched.running)) == ["t1", "t2"]

      # A Merging ticket waits for a slot like any other: finishing_max gives it none.
      landing = issue("m", "MT-M", "Merging")
      tracked([landing])
      waits = Orchestrator.dispatch_chosen_issues_for_test([landing], dispatched)
      assert %{reason: "work slots full"} = waits.slot_waiting["m"]
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

    test "a PR run takes a slot while it runs, without holding one for a ticket" do
      pr = %{pid: self(), ref: make_ref(), identifier: "MT-PR", repo_key: "default", started_at: @since, run_kind: :pr}
      state = %{orchestrator_state(1) | running: %{"pr" => pr}}

      assert %{used: 1, free: 0, holders: [holder]} = Orchestrator.dispatch_order_slots_for_test(state)
      assert %{issue_id: "pr", identifier: "MT-PR", state: nil, running: true} = holder
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

  # The ticket's record, which joins the dispatch queue at its end, in the order written.
  defp recorded(%Issue{} = issue) do
    :ok = RunStore.put_ticket_state(TicketState.new("default", issue.id, %{issue_identifier: issue.identifier, title: issue.title, phase: issue.state, linear_updated_at: DateTime.utc_now()}))
    issue
  end

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
