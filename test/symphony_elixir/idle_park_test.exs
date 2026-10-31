defmodule SymphonyElixir.IdleParkTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{DispatchLoop, IdlePark}

  test "a park's move signal is told by its reason" do
    assert IdlePark.signal_reason() == "idle_park"
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

  describe "parked_from/2" do
    test "a ticket out of Backlog was not parked" do
      assert IdlePark.parked_from("In Progress", [park_signal(%{from: "Rework"})]) == :none
      assert IdlePark.parked_from(nil, [park_signal(%{})]) == :none
    end

    test "the newest move signal says whether a park put it in Backlog, and the phase it left" do
      assert IdlePark.parked_from("Backlog", [park_signal(%{from: "Rework"})]) == {:ok, "Rework"}
      assert IdlePark.parked_from(" backlog ", [%{name: "unblocked", details: %{}, at: nil}, park_signal(%{})]) == {:ok, "In Progress"}
      assert IdlePark.parked_from("Backlog", [%{name: "blocked", details: %{"to" => "Backlog", "reason" => "idle_park"}, at: nil}]) == {:ok, "In Progress"}

      moved_by_hand = %{name: "decision returned", details: %{move: "backlog", to: "Backlog"}, at: nil}
      assert IdlePark.parked_from("Backlog", [moved_by_hand, park_signal(%{})]) == :none
      assert IdlePark.parked_from("Backlog", [%{name: "blocked", details: %{to: "Backlog", reason: "other"}, at: nil}]) == :none
      assert IdlePark.parked_from("Backlog", [%{name: "blocked", details: nil, at: nil}]) == :none
      assert IdlePark.parked_from("Backlog", []) == :none
    end
  end

  defp park_signal(extra), do: %{name: "blocked", details: Map.merge(%{to: "Backlog", reason: "idle_park"}, extra), at: nil}
end
