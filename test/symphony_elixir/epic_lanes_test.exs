defmodule SymphonyElixir.EpicLanesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.EpicLanes
  alias SymphonyElixir.Linear.Issue

  @terminal ["Done", "Canceled"]

  describe "plan/4" do
    test "an epic with a sub-ticket in review and another ready keeps its lane; the rest of max_total is shared" do
      plan = EpicLanes.plan([epic("E1", [{"p1", "In Review"}, {"p2", "Todo"}]), standalone("S1")], 2, nil, @terminal)

      assert [%{identifier: "E1"}] = plan.lanes
      assert plan.shared == 1
      assert plan.queued == []
    end

    test "an epic whose sub-tickets are all in Backlog, done or unknown reserves nothing" do
      candidates = [
        epic("E1", [{"p1", "Backlog"}, {"p2", "Backlog"}]),
        epic("E2", [{"p3", "Done"}, {"p4", "Triage"}, {"p5", nil}]),
        %{epic("E3", [{"p6", "Todo"}]) | labels: []},
        nil
      ]

      plan = EpicLanes.plan(candidates, 2, nil, @terminal)

      assert plan.lanes == []
      assert plan.shared == 2
    end

    test "with more active epics than max_total, the extra epics wait by priority then age" do
      candidates = [
        epic("E-low", [{"a", "Todo"}], priority: 4),
        epic("E-none", [{"b", "Todo"}], priority: nil),
        epic("E-old", [{"c", "Todo"}], priority: 2, created_at: ~U[2026-01-01 00:00:00Z]),
        epic("E-new", [{"d", "Todo"}], priority: 2, created_at: ~U[2026-02-01 00:00:00Z]),
        epic("E-undated", [{"e", "Todo"}], priority: 2)
      ]

      plan = EpicLanes.plan(candidates, 3, nil, @terminal)

      assert Enum.map(plan.lanes, & &1.identifier) == ["E-old", "E-new", "E-undated"]
      assert Enum.map(plan.queued, & &1.identifier) == ["E-low", "E-none"]
      assert plan.shared == 0
    end

    test "epic_lanes caps the lanes and leaves the rest shared" do
      candidates = [epic("E1", [{"a", "Todo"}]), epic("E2", [{"b", "Todo"}])]

      plan = EpicLanes.plan(candidates, 3, 1, @terminal)
      assert [%{identifier: "E1"}] = plan.lanes
      assert [%{identifier: "E2"}] = plan.queued
      assert plan.shared == 2

      assert EpicLanes.plan(candidates, 3, 0, @terminal).lanes == []
      # A lowered max_total caps a larger epic_lanes.
      assert length(EpicLanes.plan(candidates, 1, 5, @terminal).lanes) == 1
    end
  end

  describe "the epic's path" do
    test "takes in sub-tickets at any depth and open blockers, transitively, with how each was reached" do
      candidates = [
        epic("E1", [{"p1", "Todo"}, {"p2", "In Progress"}, {"old", "Done"}]),
        # The next part waits on a blocker outside the epic, which waits on another one.
        ticket("p1", "Todo", blocked_by: [link("B1", "In Progress"), link("gone", "Done"), %{identifier: "no-id"}]),
        ticket("B1", "In Progress", blocked_by: [link("B2", nil)]),
        # An in-flight part with its own sub-ticket, itself blocked by the next part (a cycle).
        ticket("p2", "In Progress", sub_issues: [link("g1", "Todo")]),
        ticket("g1", "Todo", blocked_by: [link("p1", "Todo")])
      ]

      %{lanes: [%{members: members}]} = EpicLanes.plan(candidates, 2, nil, @terminal)

      assert Map.keys(members) |> Enum.sort() == ["B1", "B2", "g1", "p1", "p2"]
      assert %{depth: 1, via: nil} = members["p1"]
      assert %{depth: 2, via: %{relation: "blocks", identifier: "p1"}} = members["B1"]
      assert %{depth: 2, via: %{relation: "sub_ticket_of", identifier: "p2"}} = members["g1"]
      # B2 has no state and was not fetched: it is on the path, but a leaf.
      assert %{depth: 3, state: nil, via: %{relation: "blocks", identifier: "B1"}} = members["B2"]
    end

    test "the lane runs a blocker of the next part from outside the epic instead of idling" do
      candidates = [epic("E1", [{"p1", "Todo"}]), ticket("p1", "Todo", blocked_by: [link("B1", "Todo")]), ticket("B1", "Todo"), standalone("S1")]
      plan = EpicLanes.plan(candidates, 2, 1, @terminal)

      # The shared slot is taken; the blocker still starts, in the epic's lane.
      assert {:lane, %{identifier: "E1"}} = EpicLanes.slot_for(plan, "B1", ["S1"])
      assert EpicLanes.slot_label(plan, "B1", ["S1"]) == "lane:E1"
    end

    test "a grandchild runs in the epic's lane" do
      candidates = [epic("E1", [{"p1", "In Progress"}]), ticket("p1", "In Progress", sub_issues: [link("g1", "Todo")]), ticket("g1", "Todo")]
      plan = EpicLanes.plan(candidates, 1, nil, @terminal)

      assert {:lane, %{identifier: "E1"}} = EpicLanes.slot_for(plan, "g1", [])
    end

    test "a blocker shared by two epics holds one lane, whichever is free first" do
      candidates = [
        epic("E1", [{"p1", "Todo"}, {"p3", "Todo"}]),
        epic("E2", [{"q1", "Todo"}, {"q2", "Todo"}]),
        ticket("p1", "Todo", blocked_by: [link("B1", "Todo")]),
        ticket("q1", "Todo", blocked_by: [link("B1", "Todo")]),
        ticket("B1", "Todo")
      ]

      plan = EpicLanes.plan(candidates, 3, 2, @terminal)

      assert {:lane, %{identifier: "E1"}} = EpicLanes.slot_for(plan, "B1", [])
      assert {:lane, %{identifier: "E2"}} = EpicLanes.slot_for(plan, "B1", ["p3"])

      # Running, it counts once: E2's lane and the shared slot are both still free.
      assert {:lane, %{identifier: "E2"}} = EpicLanes.slot_for(plan, "q2", ["B1"])
      assert EpicLanes.slot_for(plan, "S1", ["B1", "B1"]) == :shared

      # Next to a ticket only E1 can hold, the shared blocker takes E2's lane, until q2 needs it:
      # then the blocker counts as shared.
      assert EpicLanes.slot_for(plan, "S1", ["B1", "p3"]) == :shared
      assert {:lane, %{identifier: "E2"}} = EpicLanes.slot_for(plan, "q2", ["B1", "p3"])

      snapshot = EpicLanes.snapshot(plan, %{"B1" => %{state: "In Progress"}, "p3" => %{state: "In Progress"}})
      assert %{lanes: [%{sub_issue: %{identifier: "p3"}}, %{sub_issue: %{identifier: "B1"}}], shared: %{used: 0}} = snapshot
    end

    test "the snapshot names the ticket a running blocker or sub-ticket serves" do
      candidates = [
        epic("E1", [{"p1", "Todo"}]),
        epic("E2", [{"q1", "In Progress"}]),
        ticket("p1", "Todo", blocked_by: [link("B1", "Todo")]),
        ticket("q1", "In Progress", sub_issues: [link("g1", "Todo")])
      ]

      plan = EpicLanes.plan(candidates, 3, nil, @terminal)

      assert %{
               lanes: [
                 %{status: "running", sub_issue: %{identifier: "B1", state: "In Progress", via: %{relation: "blocks", identifier: "p1"}}},
                 %{status: "running", sub_issue: %{identifier: "g1", state: "Todo", via: %{relation: "sub_ticket_of", identifier: "q1"}}}
               ]
             } = EpicLanes.snapshot(plan, %{"B1" => %{state: "In Progress"}, "g1" => %{}})
    end
  end

  describe "yielding a lane" do
    test "an epic whose only open sub-ticket is in review yields its lane to the shared pool" do
      plan = EpicLanes.plan([epic("E1", [{"p1", "In Review"}, {"p0", "Done"}]), standalone("S1"), standalone("S2")], 2, nil, @terminal)

      assert plan.lanes == []
      assert plan.shared == 2
      assert EpicLanes.slot_for(plan, "S2", ["S1"]) == :shared

      assert %{
               lanes: [%{identifier: "E1", status: "yielded", reason: "Nothing on its path can run: p1 (In Review)", sub_issue: %{identifier: "p1", state: "In Review"}}],
               queued_epics: [],
               shared: %{slots: 2, used: 1}
             } = EpicLanes.snapshot(plan, %{"S1" => %{}})
    end

    test "the next queued epic gets the lane, and the epic takes it back once its sub-ticket returns to Todo" do
      in_review = [epic("E1", [{"p1", "In Review"}], priority: 1), epic("E2", [{"q1", "Todo"}])]
      plan = EpicLanes.plan(in_review, 2, 1, @terminal)

      assert [%{identifier: "E2"}] = plan.lanes
      assert plan.queued == []
      assert [%{identifier: "E1"}] = plan.yielded
      assert {:lane, %{identifier: "E2"}} = EpicLanes.slot_for(plan, "q1", [])

      plan = EpicLanes.plan([epic("E1", [{"p1", "Todo"}], priority: 1), epic("E2", [{"q1", "Todo"}]), ticket("p1", "Todo")], 2, 1, @terminal)

      assert [%{identifier: "E1"}] = plan.lanes
      assert [%{identifier: "E2"}] = plan.queued
      assert plan.yielded == []
      assert {:lane, %{identifier: "E1"}} = EpicLanes.slot_for(plan, "p1", [])
    end

    test "the epic takes a lane back once a new ticket on its path can run" do
      parked = [epic("E1", [{"p1", "In Review"}, {"p2", "Backlog"}]), ticket("p2", "Backlog")]
      assert %{lanes: [], yielded: [%{yield_reason: "Nothing on its path can run: p1 (In Review), p2 (Backlog)"}]} = EpicLanes.plan(parked, 2, nil, @terminal)

      # A human approves part 2.
      approved = [epic("E1", [{"p1", "In Review"}, {"p2", "Todo"}]), ticket("p2", "Todo")]
      assert %{lanes: [%{identifier: "E1"}], yielded: []} = plan = EpicLanes.plan(approved, 2, nil, @terminal)
      assert {:lane, %{identifier: "E1"}} = EpicLanes.slot_for(plan, "p2", ["S1"])
    end

    test "a part blocked by a ticket that waits on a person yields; a blocker Symphony can run keeps the lane" do
      held = [epic("E1", [{"p1", "Todo"}]), ticket("p1", "Todo", blocked_by: [link("B1", "In Review"), link("B2", nil)])]

      assert %{yielded: [%{yield_reason: reason}]} = EpicLanes.plan(held, 2, nil, @terminal)
      assert reason == "Nothing on its path can run: p1 (Todo, blocked by B1, B2), B1 (In Review), B2 (state unknown)"

      for blocker_state <- ["Todo", "In Progress", "Merging"] do
        runnable = [epic("E1", [{"p1", "Todo"}]), ticket("p1", "Todo", blocked_by: [link("B1", blocker_state)])]
        assert %{lanes: [%{identifier: "E1"}], yielded: []} = EpicLanes.plan(runnable, 2, nil, @terminal)
      end
    end

    test "a sub-ticket waiting on its own sub-tickets keeps the lane only while one below it can run" do
      parent = ticket("p1", "Waiting on sub-tickets", sub_issues: [link("g1", "In Review")])
      waiting = [epic("E1", [{"p1", "Waiting on sub-tickets"}]), %{parent | labels: ["breakdown"]}]

      # The sub-ticket is an epic of its own, with the same verdict.
      assert %{lanes: [], yielded: [%{identifier: "E1", yield_reason: reason}, %{identifier: "p1"}]} = EpicLanes.plan(waiting, 2, nil, @terminal)
      assert reason == "Nothing on its path can run: p1 (Waiting on sub-tickets, waiting on its sub-tickets), g1 (In Review)"

      runnable = [epic("E1", [{"p1", "Waiting on sub-tickets"}]), %{parent | labels: ["breakdown"], sub_issues: [link("g1", "Todo")]}]
      assert %{lanes: [%{identifier: "E1"}, %{identifier: "p1"}], yielded: []} = EpicLanes.plan(runnable, 2, nil, @terminal)

      # A rejected plan is broken down again, so a sub-ticket in Rework keeps the lane.
      replanning = [epic("E1", [{"p1", "Rework"}]), %{parent | state: "Rework", labels: ["breakdown"]}]
      assert %{lanes: [%{identifier: "E1"}], yielded: [%{identifier: "p1"}]} = EpicLanes.plan(replanning, 2, nil, @terminal)
    end
  end

  describe "order/3" do
    test "each lane's tickets go nearest first, within their own positions and stage" do
      candidates = [
        epic("E1", [{"p1", "Todo"}, {"p2", "In Progress"}, {"r1", "Rework"}]),
        epic("E2", [{"q1", "Todo"}]),
        ticket("p2", "In Progress", sub_issues: [link("g1", "Todo"), link("g2", "Rework"), link("q1", "Todo")])
      ]

      plan = EpicLanes.plan(candidates, 3, nil, @terminal)
      stage = fn issue -> issue.state end

      # Dispatch order by priority: the grandchildren rank above the next part.
      issues =
        [ticket("g2", "Rework"), ticket("r1", "Rework"), ticket("g1", "Todo"), standalone("S1")] ++
          [:not_an_issue, ticket("q1", "Todo"), ticket("p1", "Todo")]

      assert plan |> EpicLanes.order(issues, stage) |> Enum.map(&ids/1) == ["r1", "g2", "p1", "S1", :not_an_issue, "q1", "g1"]
      assert EpicLanes.order(nil, issues, stage) == issues
    end
  end

  describe "slot_for/3" do
    test "a lane stays reserved for its epic while a standalone takes the shared slot, then runs the next part" do
      # max_total 2: part 1 in review, part 2 blocked by it, one standalone ready.
      plan = EpicLanes.plan([epic("E1", [{"p1", "In Review"}, {"p2", "Todo"}]), standalone("S1")], 2, nil, @terminal)

      assert EpicLanes.slot_for(plan, "S1", []) == :shared
      assert EpicLanes.slot_for(plan, "S2", ["S1"]) == :none
      assert EpicLanes.slot_label(plan, "S1", []) == "shared"

      # Part 1 merges; part 2 starts in the lane even though the shared slot is taken.
      assert {:lane, %{identifier: "E1"}} = EpicLanes.slot_for(plan, "p2", ["S1"])
      assert EpicLanes.slot_label(plan, "p2", ["S1"]) == "lane:E1"
    end

    test "three epics fill max_total 3, leaving nothing for standalone work" do
      candidates = for n <- 1..3, do: epic("E#{n}", [{"p#{n}", "Todo"}])
      plan = EpicLanes.plan(candidates, 3, nil, @terminal)

      assert EpicLanes.slot_for(plan, "S1", []) == :none
      assert {:lane, %{identifier: "E2"}} = EpicLanes.slot_for(plan, "p2", ["p1"])
    end

    test "an epic's parallel siblings use free shared slots once its lane is taken" do
      plan = EpicLanes.plan([epic("E1", [{"a", "Todo"}, {"b", "Todo"}, {"c", "Todo"}])], 3, 1, @terminal)

      assert {:lane, _epic} = EpicLanes.slot_for(plan, "a", [])
      assert EpicLanes.slot_for(plan, "b", ["a"]) == :shared
      assert EpicLanes.slot_for(plan, "c", ["a", "b"]) == :shared
      assert EpicLanes.slot_for(plan, "S1", ["a", "b", "c"]) == :none
    end

    test "a running blocker on two paths leaves the candidate the one lane it can use" do
      # No shared slots: Y blocks a part of both epics; X is a parallel part of E1 only.
      candidates = [
        epic("E1", [{"p1", "Todo"}, {"X", "Todo"}]),
        epic("E2", [{"q1", "Todo"}]),
        ticket("p1", "Todo", blocked_by: [link("Y", "In Progress")]),
        ticket("q1", "Todo", blocked_by: [link("Y", "In Progress")])
      ]

      plan = EpicLanes.plan(candidates, 2, 2, @terminal)

      assert {:lane, %{identifier: "E1"}} = EpicLanes.slot_for(plan, "X", ["Y"])
      assert EpicLanes.slot_for(plan, "S1", ["Y", "X"]) == :none

      snapshot = EpicLanes.snapshot(plan, %{"Y" => %{}, "X" => %{}})
      assert %{lanes: [%{sub_issue: %{identifier: "X"}}, %{sub_issue: %{identifier: "Y"}}], shared: %{used: 0}} = snapshot
    end

    test "the candidate does not take a lane a running ticket needs" do
      # No shared slots: B1 runs in E1's lane, the only one on its path.
      candidates = [
        epic("E1", [{"p1", "Todo"}, {"A1", "Todo"}]),
        ticket("p1", "Todo", blocked_by: [link("B1", "In Progress")])
      ]

      plan = EpicLanes.plan(candidates, 1, 1, @terminal)

      assert EpicLanes.slot_for(plan, "A1", ["B1"]) == :none
    end

    test "with no plan yet every slot is shared" do
      assert EpicLanes.slot_for(nil, "S1", ["x"]) == :shared
      assert EpicLanes.slot_label(nil, "S1", []) == "shared"
    end
  end

  describe "snapshot/2" do
    test "shows each lane's running or awaited part, the queued epics and the shared pool" do
      candidates = [
        epic("E1", [{"p1", "Done"}, {"p2", "In Progress"}]),
        epic("E2", [{"q1", "Todo"}, {"q2", "In Review"}]),
        epic("E3", [{"r1", "Todo"}]),
        epic("E4", [{"s1", "Todo"}])
      ]

      plan = EpicLanes.plan(candidates, 4, 3, @terminal)
      running = %{"p2" => %{identifier: "p2", state: "Merging"}, "S1" => %{identifier: "S1", state: "Todo"}}

      assert %{
               max_total: 4,
               lanes: [
                 %{identifier: "E1", title: "Epic E1", url: "https://linear.test/E1", status: "running", sub_issue: %{identifier: "p2", state: "Merging"}},
                 %{identifier: "E2", status: "waiting", sub_issue: %{identifier: "q2", state: "In Review"}},
                 %{identifier: "E3", status: "waiting", sub_issue: %{identifier: "r1", state: "Todo"}}
               ],
               queued_epics: [%{identifier: "E4"}],
               shared: %{slots: 1, used: 1}
             } = EpicLanes.snapshot(plan, running)
    end

    test "falls back to the sub-ticket's cached state and to no part at all" do
      plan = EpicLanes.plan([epic("E1", [{"p1", "In Progress"}])], 2, nil, @terminal)
      assert %{lanes: [%{sub_issue: %{state: "In Progress"}}]} = EpicLanes.snapshot(plan, %{"p1" => %{}})

      # Every open part finished since the poll: the lane waits for its next sub-ticket.
      emptied = update_in(plan, [:lanes, Access.at(0)], &Map.put(&1, :open_parts, []))
      assert %{lanes: [%{status: "waiting", sub_issue: nil}]} = EpicLanes.snapshot(emptied, %{})
    end

    test "with no plan yet every running agent is shared" do
      assert %{lanes: [], queued_epics: [], shared: %{slots: nil, used: 1}} = EpicLanes.snapshot(nil, %{"x" => %{}})
    end
  end

  defp epic(identifier, parts, opts \\ []) do
    %Issue{
      id: identifier,
      identifier: identifier,
      title: "Epic #{identifier}",
      url: "https://linear.test/#{identifier}",
      state: "Waiting on sub-tickets",
      labels: ["breakdown"],
      priority: Keyword.get(opts, :priority, 2),
      created_at: Keyword.get(opts, :created_at),
      sub_issues: [%{identifier: "no-id"} | Enum.map(parts, fn {id, state} -> %{id: id, identifier: id, state: state} end)]
    }
  end

  defp ticket(id, state, opts \\ []) do
    %Issue{
      id: id,
      identifier: id,
      title: id,
      state: state,
      priority: 2,
      labels: [],
      blocked_by: Keyword.get(opts, :blocked_by, []),
      sub_issues: Keyword.get(opts, :sub_issues, [])
    }
  end

  defp link(id, state), do: %{id: id, identifier: id, state: state}

  defp ids(%Issue{id: id}), do: id
  defp ids(other), do: other

  defp standalone(identifier) do
    %Issue{id: identifier, identifier: identifier, title: identifier, state: "Todo", priority: 2, labels: []}
  end
end
