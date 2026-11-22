defmodule SymphonyElixir.Dispatch.SlotsTest do
  # The slot rule's pure parts: which closed gate gives a slot up, which candidates a free slot goes
  # to first, and the slots the reads report.
  use ExUnit.Case, async: true

  alias SymphonyElixir.Dispatch.{Queue, Slots}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses

  describe "releases?/2" do
    test "a ticket gives its slot up when it is no longer a candidate, waits on its sub-tickets or on an app update" do
      refute Slots.releases?(nil, [])
      assert Slots.releases?({"Done is a terminal state", nil, :not_candidate}, [])
      assert Slots.releases?({"not assigned to this Symphony's worker", :not_assigned, nil}, [])
      assert Slots.releases?({"waiting on its sub-tickets", nil, :sub_tickets}, [])
      assert Slots.releases?({"waiting for the app update", nil, :update_hold}, [])
    end

    test "a pause on another ticket or a person's stop gives it up; a question, a decision or anything else keeps it" do
      blocker = Pauses.ticket_reason(:dependency, "MT-9")
      fix = Pauses.ticket_reason(:fix_ticket, "MT-8")
      stop = Pauses.stop_reason(~U[2026-11-22 07:00:00Z])
      question = %{kind: :question, waits_on: %{question_id: "q-1"}, text: "Which layout?"}
      decision = %{kind: :person, waits_on: %{action: "unblock"}, text: "Needs a decision"}
      paused = {"paused", nil, :paused}

      assert Slots.releases?(paused, [blocker])
      assert Slots.releases?(paused, [fix])
      assert Slots.releases?(paused, [stop])
      assert Slots.releases?(paused, [question, blocker])
      # The Conductor stops a run whose ticket it asked the person about: it waits on the person.
      refute Slots.releases?(paused, [question, stop])
      refute Slots.releases?(paused, [question])
      refute Slots.releases?(paused, [decision])
      refute Slots.releases?(paused, :unreadable)

      for gate <- [:watch, :merging_ci, :qa_build, :claimed, :instructions_hold, :replan] do
        refute Slots.releases?({"held", nil, gate}, [blocker])
      end

      refute Slots.releases?({"priority low", :priority, nil}, [])
      refute Slots.releases?({"budget", :token_budget, nil}, [])
    end
  end

  describe "first_ids/3 and Queue.order/3" do
    test "a sub-ticket of a ticket that holds a slot, or whose phase is past Todo, goes first; the rest keep the stored order" do
      held = issue("c1", "MT-C1", parent: "MT-P1")
      started = issue("c2", "MT-C2")
      unstarted = issue("c3", "MT-C3", parent: "MT-P3")
      unknown = issue("c4", "MT-C4", parent: "MT-P4")
      alone = issue("s1", "MT-S1")

      facts = %{
        parents: %{"c2" => "MT-P2"},
        phases: %{"MT-P1" => "Todo", "MT-P2" => "Waiting on sub-tickets", "MT-P3" => " todo ", "MT-P4" => nil}
      }

      first = Slots.first_ids([held, started, unstarted, unknown, alone, :not_an_issue], facts, MapSet.new(["MT-P1"]))
      assert first == MapSet.new(["c1", "c2"])

      positions = %{"s1" => 1, "c3" => 2, "c2" => 3, "c1" => 4}

      assert [alone, unstarted, started, held, unknown, :not_an_issue] |> Queue.order(positions, first) |> Enum.map(&id/1) ==
               ["c2", "c1", "s1", "c3", "c4", :not_an_issue]

      # Unreadable places are no places; no first group is the stored order alone.
      assert [held, alone] |> Queue.order({:error, :down}, MapSet.new(["c1"])) |> Enum.map(&id/1) == ["c1", "s1"]
      assert [held, alone] |> Queue.order(positions) |> Enum.map(&id/1) == ["s1", "c1"]
    end

    test "facts that can't be read put nothing first" do
      assert Slots.first_ids([issue("c1", "MT-C1", parent: "MT-P1")], {:error, :down}, MapSet.new(["MT-P1"])) == MapSet.new()
    end
  end

  describe "read/3 and holder_ids/1" do
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

      assert Slots.holder_ids(read) == MapSet.new(["a", "b", "c"])
      assert Slots.holder_ids(nil) == MapSet.new()
      assert Slots.holder_ids(%{work_free: 1}) == MapSet.new()

      assert %{used: 0, free: 1, holders: []} = Slots.read(1, [], %{})
    end
  end

  defp issue(id, identifier, opts \\ []) do
    parent = Keyword.get(opts, :parent)
    %Issue{id: id, identifier: identifier, state: "Todo", parent: parent && %{identifier: parent, title: nil, done: 0, total: 1, children: []}}
  end

  defp id(%Issue{id: id}), do: id
  defp id(other), do: other
end
