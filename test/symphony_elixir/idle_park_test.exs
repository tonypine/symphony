defmodule SymphonyElixir.IdleParkTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{DispatchLoop, IdlePark}

  test "the hold names the phase the ticket left and is told apart from other holds" do
    hold = IdlePark.hold_attrs("Rework", 2)

    assert hold == %{
             reason: "idle_park: 2 turns in Rework made no new commit and no state change, so Symphony parked it in Backlog",
             clearing_condition: "when a person unblocks or restarts it",
             waits_on: %{type: "idle_park", keys: ["Rework"]}
           }

    assert IdlePark.hold?(hold)
    refute IdlePark.hold?(%{waits_on: %{type: "dispatch_loop", keys: []}})
    refute IdlePark.hold?(nil)
    assert IdlePark.hold_type() == "idle_park"
  end

  test "the question offers Run it again (recommended), Start it over from main and Leave it parked, answered as Unblock, Restart or nothing" do
    request = IdlePark.question_attrs("TP-1248", 2)

    assert request.title == "TP-1248 is parked: its last 2 turns changed nothing"
    assert request.if_unanswered == "TP-1248 stays parked in Backlog and Symphony starts no run on it."
    assert [%{label: "Run it again", recommended: true}, %{label: "Start it over from main"}, %{label: "Leave it parked"}] = request.options

    answered = fn number ->
      DispatchLoop.answer_move(%{state: :answered, answer: %{option: number}, options: request.options})
    end

    assert {answered.(1), answered.(2), answered.(3)} == {:unblock, :restart, :keep}
  end

  describe "parked_from/3" do
    test "a Backlog ticket's park hold names the phase it goes back to, In Progress when it names none" do
      assert IdlePark.parked_from("Backlog", IdlePark.hold_attrs("Rework", 2), []) == {:ok, "Rework"}
      assert IdlePark.parked_from(" backlog ", %{waits_on: %{type: "idle_park", keys: []}}, []) == {:ok, "In Progress"}
    end

    test "a ticket out of Backlog, or held by anything else, was not parked" do
      assert IdlePark.parked_from("In Progress", IdlePark.hold_attrs("In Progress", 2), []) == :none
      assert IdlePark.parked_from(nil, nil, []) == :none
      assert IdlePark.parked_from("Backlog", %{waits_on: %{type: "dispatch_loop", keys: []}}, [park_signal(%{})]) == :none
    end

    test "with no hold, the newest move signal says whether a park put it in Backlog" do
      assert IdlePark.parked_from("Backlog", nil, [park_signal(%{from: "Rework"})]) == {:ok, "Rework"}
      assert IdlePark.parked_from("Backlog", nil, [%{name: "unblocked", details: %{}, at: nil}, park_signal(%{})]) == {:ok, "In Progress"}
      assert IdlePark.parked_from("Backlog", nil, [%{name: "blocked", details: %{"to" => "Backlog", "reason" => "idle_park"}, at: nil}]) == {:ok, "In Progress"}

      moved_by_hand = %{name: "decision returned", details: %{move: "backlog", to: "Backlog"}, at: nil}
      assert IdlePark.parked_from("Backlog", nil, [moved_by_hand, park_signal(%{})]) == :none
      assert IdlePark.parked_from("Backlog", nil, [%{name: "blocked", details: %{to: "Backlog", reason: "other"}, at: nil}]) == :none
      assert IdlePark.parked_from("Backlog", nil, [%{name: "blocked", details: nil, at: nil}]) == :none
      assert IdlePark.parked_from("Backlog", nil, []) == :none
    end
  end

  defp park_signal(extra), do: %{name: "blocked", details: Map.merge(%{to: "Backlog", reason: "idle_park"}, extra), at: nil}
end
