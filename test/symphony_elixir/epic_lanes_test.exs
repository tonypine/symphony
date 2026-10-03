defmodule SymphonyElixir.EpicLanesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.EpicLanes
  alias SymphonyElixir.Linear.Issue

  @terminal ["Done", "Canceled"]

  describe "plan/4" do
    test "an epic with a sub-ticket in review keeps its lane; the rest of max_total is shared" do
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

  defp standalone(identifier) do
    %Issue{id: identifier, identifier: identifier, title: identifier, state: "Todo", priority: 2, labels: []}
  end
end
