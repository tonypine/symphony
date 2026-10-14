defmodule SymphonyElixir.RetiredStatesTest do
  # The drain report is one global record, so these tests don't run alongside each other.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RetiredStates

  defmodule FakeTracker do
    def fetch_issues_by_states(states) do
      send(self(), {:fetched, states})
      Process.get(:retired_states_result, {:ok, []})
    end

    def fetch_issue_states_by_ids(ids) do
      send(self(), {:fetched_ids, ids})
      Process.get(:landed_result, {:ok, []})
    end
  end

  setup do
    RetiredStates.reset_for_test()
    on_exit(&RetiredStates.reset_for_test/0)
  end

  test "reads the retired states" do
    assert RetiredStates.states() == ["Auto Review", "In Review", "Human Review"]
  end

  test "names each ticket still in a retired state loudly, with the move that frees it" do
    stuck = %Issue{id: "issue-1", identifier: "TP-873", state: "Auto Review"}
    Process.put(:retired_states_result, {:ok, [stuck]})

    log = capture_log(fn -> assert RetiredStates.report(tracker: FakeTracker, now_ms: 5) == [stuck] end)

    assert_received {:fetched, ["Auto Review", "In Review", "Human Review"]}
    assert log =~ "[error]"
    assert log =~ "TP-873 is still in the retired Auto Review state, waiting on nothing: no path dispatches or moves on from this state"
    assert log =~ "move it by hand to Code Review (its PR is open) or In Progress"

    assert %{stragglers: [%{identifier: "TP-873", wait: :retired}], landed: [], checked_at_ms: 5} =
             RetiredStates.drain_report()
  end

  test "names each ticket left in In Review or Human Review loudly, with what it waits on" do
    issues = [
      %Issue{id: "p", identifier: "TP-1", state: "Human Review", labels: ["Plan"]},
      %Issue{id: "d", identifier: "TP-2", state: "Human Review", labels: []},
      %Issue{id: "n", identifier: "TP-3", state: "In Review", labels: ["Needs Decision"]},
      %Issue{id: "b", identifier: "TP-4", state: "In Review", labels: ["Blocked"]},
      %Issue{id: "s", identifier: "TP-5", state: "In Review", labels: []}
    ]

    Process.put(:retired_states_result, {:ok, issues})
    log = capture_log(fn -> RetiredStates.report(tracker: FakeTracker) end)

    assert log =~ "TP-1 is still in the retired Human Review state, waiting on a parked plan waiting on its review: move it by hand to Plan Review"
    assert log =~ "TP-2 is still in the retired Human Review state, waiting on an open decision for a person"
    assert log =~ "TP-3 is still in the retired In Review state, waiting on an open decision for a person: move it by hand into its phase with a Needs Decision hold"
    assert log =~ "TP-4 is still in the retired In Review state, waiting on blocked QA"
    assert log =~ "TP-5 is still in the retired In Review state, waiting on a supervisor check of its PR"
    assert log =~ "[error]"
    refute log =~ "[warning]"

    assert Enum.map(RetiredStates.drain_report().stragglers, & &1.wait) ==
             [:parked_plan, :open_decision, :open_decision, :blocked_qa, :supervisor_check]
  end

  test "a ticket that leaves the report is logged with where it landed" do
    Process.put(:retired_states_result, {:ok, [%Issue{id: "p", identifier: "TP-1", state: "Human Review", labels: ["plan"]}, %{id: "q", state: "In Review"}]})
    capture_log(fn -> RetiredStates.report(tracker: FakeTracker) end)

    Process.put(:retired_states_result, {:ok, []})
    Process.put(:landed_result, {:ok, [%Issue{id: "p", state: "Plan Review"}]})
    log = capture_log([level: :info], fn -> RetiredStates.report(tracker: FakeTracker) end)

    assert_received {:fetched_ids, ["p", "q"]}
    assert log =~ "TP-1 left the Human Review state for Plan Review; it is off the drain report"
    assert log =~ "q left the In Review state for a state that could not be read"

    assert %{stragglers: [], landed: [%{identifier: "TP-1", from: "Human Review", to: "Plan Review"}, %{id: "q", to: nil}]} =
             RetiredStates.drain_report()
  end

  test "a landing whose state can't be read is still recorded" do
    Process.put(:retired_states_result, {:ok, [%Issue{id: "p", identifier: "TP-1", state: "In Review"}]})
    capture_log(fn -> RetiredStates.report(tracker: FakeTracker) end)

    Process.put(:retired_states_result, {:ok, []})
    Process.put(:landed_result, {:error, :boom})
    capture_log(fn -> RetiredStates.report(tracker: FakeTracker) end)

    assert [%{identifier: "TP-1", to: nil}] = RetiredStates.drain_report().landed
  end

  test "refreshes only once the last report is old enough" do
    capture_log(fn -> assert RetiredStates.refresh_if_due(tracker: FakeTracker, now_ms: 0) == :ok end)
    assert_received {:fetched, _states}

    assert RetiredStates.refresh_if_due(tracker: FakeTracker, now_ms: 1_000) == :ok
    refute_received {:fetched, _states}

    capture_log(fn -> assert RetiredStates.refresh_if_due(tracker: FakeTracker, now_ms: 5 * 60 * 1000) == :ok end)
    assert_received {:fetched, _states}
  end

  test "a refresh logs only the stragglers that are new since the last report" do
    known = %Issue{id: "k", identifier: "TP-10", state: "In Review", labels: []}
    Process.put(:retired_states_result, {:ok, [known]})
    capture_log(fn -> RetiredStates.report(tracker: FakeTracker, now_ms: 0) end)

    assert capture_log(fn -> RetiredStates.refresh_if_due(tracker: FakeTracker, now_ms: 5 * 60 * 1000) end) == ""

    fresh = %Issue{id: "f", identifier: "TP-11", state: "Auto Review", labels: []}
    Process.put(:retired_states_result, {:ok, [known, fresh]})
    log = capture_log(fn -> RetiredStates.refresh_if_due(tracker: FakeTracker, now_ms: 10 * 60 * 1000) end)

    assert log =~ "[error]"
    assert log =~ "TP-11 is still in the retired Auto Review state"
    refute log =~ "TP-10"
  end

  test "refresh_if_due reads the clock when none is given" do
    capture_log(fn -> assert RetiredStates.refresh_if_due(tracker: FakeTracker) == :ok end)
    assert is_integer(RetiredStates.drain_report().checked_at_ms)
  end

  test "reports nothing when no ticket is left there" do
    assert capture_log(fn -> assert RetiredStates.report(tracker: FakeTracker) == [] end) == ""
  end

  test "a tracker that can't be read is a warning, not a crash, and keeps the last report" do
    Process.put(:retired_states_result, {:error, :rate_limited})

    log = capture_log(fn -> assert RetiredStates.report(tracker: FakeTracker) == [] end)

    assert log =~ "Could not check for tickets left in a retired state (Auto Review, In Review, Human Review): :rate_limited"
    assert %{stragglers: [], landed: [], checked_at_ms: checked} = RetiredStates.drain_report()
    assert is_integer(checked)
  end

  test "a failed read waits the full interval before the next one" do
    Process.put(:retired_states_result, {:ok, [%Issue{id: "issue-1", identifier: "TP-1", state: "In Review"}]})
    capture_log(fn -> RetiredStates.report(tracker: FakeTracker, now_ms: 0) end)
    assert_received {:fetched, _states}

    Process.put(:retired_states_result, {:error, :rate_limited})
    capture_log(fn -> RetiredStates.refresh_if_due(tracker: FakeTracker, now_ms: 5 * 60 * 1000) end)
    assert_received {:fetched, _states}
    assert %{stragglers: [%{identifier: "TP-1"}], checked_at_ms: 300_000} = RetiredStates.drain_report()

    assert RetiredStates.refresh_if_due(tracker: FakeTracker, now_ms: 5 * 60 * 1000 + 1_000) == :ok
    refute_received {:fetched, _states}
  end

  test "a ticket without an identifier is named by its id" do
    Process.put(:retired_states_result, {:ok, [%{id: "issue-2", state: "Auto Review"}]})

    assert capture_log(fn -> RetiredStates.report(tracker: FakeTracker) end) =~ "issue-2 is still in the retired Auto Review state"
  end

  test "a ticket without a state waits on a supervisor check" do
    assert {:supervisor_check, _waits_on, _move} = RetiredStates.wait(%{id: "x", state: nil, labels: nil})
  end
end
