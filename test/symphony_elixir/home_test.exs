defmodule SymphonyElixir.HomeTest do
  # The Home read's two lists from ticket records, the dispatch walk and the live facts: an epic with
  # a ticket in progress, a chain, a fork, a ticket blocked by two, a root behind a Backlog ticket and
  # an empty queue.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Home, Situation}

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  describe "in progress" do
    test "an epic with a ticket in progress holds it, with the epic's counts; a ticket with no epic stands alone" do
      epic =
        record("MT-1", "Waiting on sub-tickets",
          title: "Checkout that survives a reload",
          sub_issues: [link("MT-2", "Done"), link("MT-3", "In Progress"), link("MT-4", "Todo"), link("MT-5", "Backlog"), link("MT-6", "Canceled"), link("MT-7", nil)]
        )

      parent = %{identifier: "MT-1", title: "Checkout"}
      done = record("MT-2", "Done", parent: parent)
      working = record("MT-3", "In Progress", parent: parent)
      next = record("MT-4", "Todo", parent: parent, blockers: [link("MT-3", "In Progress")])
      asking = record("MT-8", "Plan Review", parent: parent)
      alone = record("LONE", "Rework")

      order = walk(["MT-3", "MT-4"])
      live = live(%{running: [%{issue_id: "id-MT-3", run_kind: "implementation", started_at: DateTime.utc_now()}]})

      moves = fn record ->
        send(self(), {:moves, record.issue_identifier})
        %{answer: %{allowed: false, reason: "not waiting on a decision"}, unblock: %{allowed: true, reason: nil}}
      end

      read = Home.read(order, [epic, done, working, next, asking, alone], live, moves: moves)

      assert [%{kind: "epic"} = node, %{kind: "ticket", identifier: "LONE", phase: "Rework", working: false, move: nil}] = read.in_progress

      assert %{identifier: "MT-1", issue_id: "id-MT-1", title: "Checkout that survives a reload", total: 6} = node
      assert node.counts == %{done: 1, in_progress: 1, needs_person: 1, needs_fix: 0, not_started: 3}

      assert [first, second] = node.tickets
      assert %{identifier: "MT-3", working: true, move: nil} = first
      assert %{identifier: "MT-8", working: false} = second
      assert first.situation.kind == "working"
      assert first.since == first.situation.since
      assert second.situation.kind == "waiting_on_you"
      assert second.move == %{name: "unblock", allowed: true, reason: nil}
      assert_received {:moves, "MT-8"}
      refute_received {:moves, "MT-3"}

      assert [%{identifier: "MT-4", after: "MT-3", also_waits_on: [], situation: nil, children: []} = root] = read.queue.roots
      assert root.epic == %{identifier: "MT-1", title: "Checkout that survives a reload"}

      assert read.outside == %{backlog: 0, below_priority: 0, epic: 0, behind: 0}
    end

    test "an epic none of whose tickets is in progress is no node: it counts outside, and its queued tickets name it by the parent's title" do
      epic = record("MT-1", "Todo", sub_issues: [link("MT-2", "Todo")])
      kid = record("MT-2", "Todo", parent: %{identifier: "MT-9", title: "Annual plans"})

      read = Home.read(walk(["MT-1", "MT-2"]), [epic, kid], live())

      assert read.in_progress == []
      assert [%{identifier: "MT-2", epic: %{identifier: "MT-9", title: "Annual plans"}, after: nil}] = read.queue.roots
      assert read.outside.epic == 1
    end

    test "an epic only its tickets' records name is a node with their counts, and a Todo ticket a run works on is in progress" do
      parent = %{identifier: "MT-1", title: "Annual plans"}
      started = record("MT-2", "Todo", parent: parent)
      fixing = record("MT-3", "CI Fix", parent: parent)

      live = live(%{running: [%{issue_id: "id-MT-2", run_kind: "implementation", started_at: DateTime.utc_now()}]})
      read = Home.read(nil, [started, fixing], live)

      assert [%{kind: "epic", identifier: "MT-1", issue_id: nil, title: "Annual plans", total: 2} = node] = read.in_progress
      assert [%{identifier: "MT-2"}, %{identifier: "MT-3"}] = node.tickets
      counts = node.counts

      assert counts == %{done: 0, in_progress: 1, needs_person: 0, needs_fix: 1, not_started: 0}
    end
  end

  describe "the queue" do
    test "a chain steps down, a Done blocker holds nothing back, and a ready root carries its situation" do
      landed = record("MT-0", "Done")
      first = record("MT-1", "Todo", blockers: [link("MT-0", nil)])
      second = record("MT-2", "Todo", blockers: [link("MT-1", "Todo")])
      third = record("MT-3", "Todo", blockers: [link("MT-2", "Todo")])

      read = Home.read(walk(["MT-1", "MT-2", "MT-3"]), [landed, first, second, third], live())

      assert [%{identifier: "MT-1", after: nil, situation: %{kind: _kind}, children: [second_node]}] = read.queue.roots
      assert %{identifier: "MT-2", situation: nil, children: [%{identifier: "MT-3", children: []}]} = second_node
    end

    test "a fork puts both tickets under the one they wait on, in the dispatch order" do
      root = record("MT-1", "Todo")
      left = record("MT-2", "Todo", blockers: [link("MT-1", "Todo")])
      right = record("MT-3", "Todo", blockers: [link("MT-1", "Todo")])

      read = Home.read(walk(["MT-1", "MT-3", "MT-2"]), [root, left, right], live())

      assert [%{identifier: "MT-1", children: [%{identifier: "MT-3"}, %{identifier: "MT-2"}]}] = read.queue.roots
    end

    test "a ticket blocked by two sits once, under the one that lands last, and names the other" do
      first = record("MT-1", "Todo")
      second = record("MT-2", "Todo")
      deeper = record("MT-3", "Todo", blockers: [link("MT-1", "Todo")])
      both = record("MT-4", "Todo", blockers: [link("MT-1", "Todo"), link("MT-2", "Todo")])
      deepest = record("MT-5", "Todo", blockers: [link("MT-2", "Todo"), link("MT-3", "Todo")])
      working = record("MT-6", "In Progress")
      reviewing = record("MT-7", "Code Review")
      waits = record("MT-8", "Todo", blockers: [link("MT-7", "Code Review"), link("MT-6", "In Progress")])
      ready = record("MT-9", "Todo")

      order = walk(["MT-9", "MT-6", "MT-1", "MT-2", "MT-3", "MT-4", "MT-5", "MT-8", "MT-7"])
      read = Home.read(order, [first, second, deeper, both, deepest, working, reviewing, waits, ready], live())

      assert [%{identifier: "MT-9"}, %{identifier: "MT-1"} = one, %{identifier: "MT-2"} = two, %{identifier: "MT-8"} = waiting] = read.queue.roots

      # MT-4 waits on MT-1 and MT-2, the later in the order; MT-5 on MT-2 and MT-3, the deeper.
      assert [%{identifier: "MT-3", children: [%{identifier: "MT-5", also_waits_on: ["MT-2"]}]}] = one.children
      assert [%{identifier: "MT-4", also_waits_on: ["MT-1"], children: []}] = two.children

      # A root that waits on two tickets in progress names the later one in the order.
      assert %{after: "MT-7", also_waits_on: ["MT-6"], situation: nil, children: []} = waiting
      assert Enum.map(read.in_progress, & &1.identifier) == ["MT-6", "MT-7"]
    end

    test "roots that wait on a ticket in progress come after the ready ones, in that ticket's order" do
      early = record("MT-1", "In Progress")
      late = record("MT-2", "In Progress")
      behind_late = record("MT-3", "Todo", blockers: [link("MT-2", "In Progress")])
      behind_early = record("MT-4", "Todo", blockers: [link("MT-1", "In Progress")])
      ready = record("MT-5", "Todo")

      read = Home.read(walk(["MT-1", "MT-2", "MT-3", "MT-4", "MT-5"]), [early, late, behind_late, behind_early, ready], live())

      assert Enum.map(read.queue.roots, &{&1.identifier, &1.after}) == [{"MT-5", nil}, {"MT-4", "MT-1"}, {"MT-3", "MT-2"}]
    end

    test "a cycle of blockers is drawn from its first ticket, each ticket once" do
      one = record("MT-1", "Todo", blockers: [link("MT-2", "Todo")])
      two = record("MT-2", "Todo", blockers: [link("MT-1", "Todo")])

      read = Home.read(walk(["MT-1", "MT-2"]), [one, two], live())

      assert [%{identifier: "MT-1", situation: %{}, children: [%{identifier: "MT-2", children: []}]}] = read.queue.roots
    end

    test "a root behind a Backlog ticket is outside, and so is the ticket behind it; a ticket below the dispatched priority is outside unless forced" do
      backlog = record("MT-1", "Backlog")
      root = record("MT-2", "Todo", blockers: [link("MT-1", "Backlog")])
      next = record("MT-3", "Todo", blockers: [link("MT-2", "Todo")])
      unknown = record("MT-4", "Todo", blockers: [%{id: nil, identifier: "OTHER-1", state: nil}])
      low = record("MT-5", "Todo", priority: 4)
      forced = record("MT-6", "Todo", priority: 4)
      unassigned = record("MT-7", "Todo")
      removed = record("MT-8", "Todo", removed_at: DateTime.utc_now())

      order = %{entries: [entry("MT-2"), entry("MT-3"), entry("MT-4"), entry("MT-5"), Map.put(entry("MT-6"), :forced, true)]}
      read = Home.read(order, [backlog, root, next, unknown, low, forced, unassigned, removed], live(), priority_filter: MapSet.new([1]))

      assert [%{identifier: "MT-6"}] = read.queue.roots
      assert read.in_progress == []
      assert read.outside == %{backlog: 1, below_priority: 1, epic: 0, behind: 3}
    end

    test "an empty queue reads as no roots" do
      assert Home.read(nil, [], live()) == %{in_progress: [], queue: %{roots: []}, outside: %{backlog: 0, below_priority: 0, epic: 0, behind: 0}}
      assert Home.read(%{entries: []}, [record("MT-1", "Done")], live()).queue == %{roots: []}
    end
  end

  defp record(identifier, phase, attrs \\ []) do
    Map.merge(
      %{
        repo_key: "default",
        issue_id: "id-#{identifier}",
        issue_identifier: identifier,
        title: "Ticket #{identifier}",
        phase: phase,
        priority: 1
      },
      Map.new(attrs)
    )
  end

  defp link(identifier, state), do: %{id: "id-#{identifier}", identifier: identifier, state: state}

  defp walk(identifiers), do: %{entries: Enum.map(identifiers, &entry/1)}

  defp entry(identifier), do: %{issue_id: "id-#{identifier}", identifier: identifier, outcome: :held, reason: nil, forced: false}

  defp live(snapshot \\ %{}), do: Situation.live_facts(snapshot)
end
