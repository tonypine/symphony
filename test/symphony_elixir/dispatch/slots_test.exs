defmodule SymphonyElixir.Dispatch.SlotsTest do
  # The slot rule's pure parts: which closed gate gives a slot up, which ticket a sub-ticket runs
  # through and the slots they use, and the slots the reads report.
  use ExUnit.Case, async: true

  alias SymphonyElixir.Dispatch.Slots
  alias SymphonyElixir.Pauses

  describe "held?/1" do
    test "a ticket holds a slot when its record says since when, and a record without it or no record holds none" do
      assert Slots.held?(%{issue_id: "i-1", slot_held_since: ~U[2026-11-23 10:00:00Z]})
      refute Slots.held?(%{issue_id: "i-1", slot_held_since: nil})
      refute Slots.held?(%{issue_id: "i-1"})
      refute Slots.held?(nil)
    end

    test "it reads the record the orchestrator writes when it gives the slot and takes it back" do
      record = SymphonyElixir.TicketState.new("default", "i-1", %{slot_held_since: ~U[2026-11-23 10:00:00Z]})
      assert Slots.held?(record)
      refute Slots.held?(%{record | slot_held_since: nil})
    end
  end

  describe "releases?/2" do
    test "a ticket gives its slot up when it is no longer a candidate; it keeps it while it waits on its sub-tickets, a stored dependency or an app update (TP-1624)" do
      refute Slots.releases?(nil, [])
      assert Slots.releases?({"Done is a terminal state", nil, :not_candidate}, [])
      assert Slots.releases?({"not assigned to this Symphony's worker", :not_assigned, nil}, [])
      refute Slots.releases?({"waiting for MT-9 to be done", nil, :depends_on}, [])
      refute Slots.releases?({"waiting for MT-9 to be released", nil, :depends_on}, [])
      refute Slots.releases?({"waiting on its sub-tickets", nil, :sub_tickets}, [])
      refute Slots.releases?({"waiting for the app update", nil, :update_hold}, [])
    end

    test "a person's stop gives it up; a pause on another ticket, a question, a decision or anything else keeps it" do
      blocker = Pauses.ticket_reason(:dependency, "MT-9")
      fix = Pauses.ticket_reason(:fix_ticket, "MT-8")
      stop = Pauses.stop_reason(~U[2026-11-22 07:00:00Z])
      question = %{kind: :question, waits_on: %{question_id: "q-1"}, text: "Which layout?"}
      # A wait on the person that is not a stop (a stop is the one `unblock` reason a ticket carries).
      restart = %{kind: :person, waits_on: %{action: "restart"}, text: "Restart starts it over from main"}
      paused = {"paused", nil, :paused}

      assert Slots.releases?(paused, [stop])
      assert Slots.releases?(paused, [blocker, stop])
      refute Slots.releases?(paused, [blocker])
      refute Slots.releases?(paused, [fix])
      refute Slots.releases?(paused, [question, blocker])
      # The Conductor stops a run whose ticket it asked the person about: it waits on the person.
      refute Slots.releases?(paused, [question, stop])
      refute Slots.releases?(paused, [question])
      refute Slots.releases?(paused, [restart])
      refute Slots.releases?(paused, :unreadable)

      for gate <- [:watch, :merging_ci, :qa_build, :claimed, :instructions_hold, :replan] do
        refute Slots.releases?({"held", nil, gate}, [blocker])
      end

      refute Slots.releases?({"priority low", :priority, nil}, [])
      refute Slots.releases?({"budget", :token_budget, nil}, [])
    end
  end

  describe "waits_in_slot?/1" do
    test "a wait on a stored dependency or on the ticket's sub-tickets lets the first of the queue wait in the slot; nothing else does" do
      assert Slots.waits_in_slot?({"waiting for MT-9 to be done", nil, :depends_on})
      assert Slots.waits_in_slot?({"waiting on its sub-tickets", nil, :sub_tickets})
      refute Slots.waits_in_slot?({"paused", nil, :paused})
      refute Slots.waits_in_slot?({"priority low", :priority, nil})
      refute Slots.waits_in_slot?(nil)
    end
  end

  describe "through/3, used/2 and cost/3" do
    # An epic E with sub-tickets A and B, and A's own sub-ticket A1; T stands alone.
    @parents %{"a" => "e", "b" => "e", "a1" => "a"}

    test "a sub-ticket runs through its nearest ancestor in progress" do
      assert Slots.through("a1", MapSet.new(["e", "a"]), @parents) == "a"
      assert Slots.through("a1", MapSet.new(["e"]), @parents) == "e"
      assert Slots.through("a", MapSet.new(["t"]), @parents) == nil
      assert Slots.through("t", MapSet.new(["e"]), @parents) == nil
      # A parent cycle gives no ancestors.
      assert Slots.through("x", MapSet.new(["y"]), %{"x" => "y", "y" => "x"}) == nil
    end

    test "a parent and its first sub-ticket in progress use one slot; each further sub-ticket in progress one more" do
      assert Slots.used([], @parents) == 0
      assert Slots.used(["e"], @parents) == 1
      assert Slots.used(["e", "a"], @parents) == 1
      assert Slots.used(["e", "a", "b"], @parents) == 2
      assert Slots.used(["e", "a", "a1"], @parents) == 1
      assert Slots.used(["e", "a", "b", "t"], @parents) == 3
      # A sub-ticket whose parent holds no slot uses its own.
      assert Slots.used(["a", "b"], @parents) == 2
      assert Slots.used(["x", "y"], %{"x" => "y", "y" => "x"}) == 2
    end

    test "starting costs nothing in progress or through a parent's free slot, else one" do
      assert Slots.cost("e", ["e"], @parents) == 0
      assert Slots.cost("a", ["e"], @parents) == 0
      assert Slots.cost("b", ["e", "a"], @parents) == 1
      assert Slots.cost("t", ["e"], @parents) == 1
      assert Slots.cost("a", [], @parents) == 1
    end

    test "a leaf two levels down runs through the top ticket's slot when the parent between them holds none (TP-1632)" do
      # Epic E, its split sub-ticket M (holds no slot), M's leaves L1 and L2.
      parents = %{"m" => "e", "l1" => "m", "l2" => "m"}

      assert Slots.through("l1", MapSet.new(["e"]), parents) == "e"
      assert Slots.cost("l1", ["e"], parents) == 0
      assert Slots.used(["e", "l1"], parents) == 1
      assert Slots.cost("l2", ["e", "l1"], parents) == 1
      assert Slots.used(["e", "l1", "l2"], parents) == 2
      assert Slots.owner("l1", ["e", "l1"], parents) == "e"
      assert Slots.working_through("e", ["e", "l1", "l2"], parents) == ["e", "l1", "l2"]
    end
  end

  describe "read/4 and holder_ids/1" do
    test "the slots read names the count, the used and free slots and the holders, the longest held first, with the keys clients read" do
      holders = [
        %{issue_id: "b", identifier: "MT-B", state: "Merging", repo_key: "default", since: ~U[2026-11-22 08:00:00Z], running: false},
        %{issue_id: "a", identifier: "MT-A", state: "In Progress", repo_key: "default", since: ~U[2026-11-22 07:00:00Z], running: true},
        %{issue_id: "c", identifier: "MT-C", state: "Todo", repo_key: "default", since: nil, running: true}
      ]

      read = Slots.read(2, holders, %{max_total: 2, finishing_max: 0})

      assert %{total: 2, used: 3, free: 0, work_used: 3, work_free: 0, concurrency: %{max_total: 2}} = read
      assert Enum.map(read.holders, & &1.identifier) == ["MT-A", "MT-B", "MT-C"]
      assert read.finishing == %{slots: 0, used: 0, running: []}
      assert %{lanes: [], queued_epics: [], shared: %{used: 3}} = read.epic_lanes

      assert Slots.holder_ids(read) == %{"a" => true, "b" => true, "c" => true}
      assert Slots.holder_ids(nil) == %{}
      assert Slots.holder_ids(%{work_free: 1}) == %{}

      assert %{used: 0, free: 1, holders: []} = Slots.read(1, [], %{})

      # A parent and the sub-ticket running through its slot are two holders and one used slot.
      assert %{used: 1, free: 1, work_used: 1, work_free: 1, holders: [_, _]} = Slots.read(2, Enum.take(holders, 2), %{}, 1)
    end
  end

  describe "slot numbers (TP-1630)" do
    test "free_number/1 is the lowest number from 1 that none taken uses" do
      assert Slots.free_number([]) == 1
      assert Slots.free_number([1, 2]) == 3
      assert Slots.free_number([2, 3]) == 1
      assert Slots.free_number(MapSet.new([1, 3])) == 2
    end

    test "number_holders/1 numbers the holders stored without one, in the order they took their slots" do
      holders = %{
        "late" => %{since: ~U[2026-11-23 12:00:00Z], slot: nil},
        "numbered" => %{since: ~U[2026-11-23 09:00:00Z], slot: 1},
        "early" => %{since: ~U[2026-11-23 10:00:00Z]},
        "unknown" => %{since: nil, slot: nil}
      }

      assert Slots.number_holders(holders) == %{"early" => 2, "late" => 3, "unknown" => 4}
      assert Slots.number_holders(%{"numbered" => %{since: nil, slot: 1}}) == %{}
    end

    test "takeover/1 picks the slot taken most recently, one of unknown time last, and nil for none" do
      owners = [{"old", ~U[2026-11-23 09:00:00Z]}, {"new", ~U[2026-11-23 11:00:00Z]}, {"unknown", nil}]
      assert Slots.takeover(owners) == "new"
      assert Slots.takeover([{"unknown", nil}]) == "unknown"
      assert Slots.takeover([]) == nil
    end

    test "owner/3 climbs to the ticket whose own slot it is, and working_through/3 lists everyone in it" do
      parents = %{"a" => "e", "a1" => "a", "b" => "e"}
      in_progress = MapSet.new(["e", "a", "a1", "t"])

      assert Slots.owner("a1", in_progress, parents) == "e"
      assert Slots.owner("b", in_progress, parents) == "e"
      assert Slots.owner("t", in_progress, parents) == "t"
      assert Slots.working_through("e", in_progress, parents) == ["a", "a1", "e"]
      assert Slots.working_through("t", in_progress, parents) == ["t"]
      assert Slots.working_through("a", in_progress, parents) == ["a", "a1"]
      assert Slots.ancestors("a1", parents) == ["a", "e"]
      assert Slots.ancestors("x", %{"x" => "y", "y" => "x"}) == []
    end

    test "read/4 keeps each holder's slot number" do
      holder = %{issue_id: "i-1", identifier: "MT-1", state: "In Progress", repo_key: "default", since: nil, slot: 2, running: false}
      assert %{holders: [%{slot: 2}]} = Slots.read(2, [holder], %{})
    end
  end
end
