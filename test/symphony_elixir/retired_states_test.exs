defmodule SymphonyElixir.RetiredStatesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RetiredStates

  defmodule FakeTracker do
    def fetch_issues_by_states(states) do
      send(self(), {:fetched, states})
      Process.get(:retired_states_result, {:ok, []})
    end
  end

  test "names each ticket still in a retired state loudly, with the move that frees it" do
    stuck = %Issue{id: "issue-1", identifier: "TP-873", state: "Auto Review"}
    Process.put(:retired_states_result, {:ok, [stuck]})

    log = capture_log(fn -> assert RetiredStates.report(tracker: FakeTracker) == [stuck] end)

    assert_received {:fetched, ["Auto Review"]}
    assert log =~ "[error]"
    assert log =~ "TP-873 is still in the retired Auto Review state, which nothing dispatches or moves on"
    assert log =~ "move it by hand to Code Review (its PR is open) or In Progress"
  end

  test "reports nothing when no ticket is left there" do
    assert capture_log(fn -> assert RetiredStates.report(tracker: FakeTracker) == [] end) == ""
  end

  test "a tracker that can't be read is a warning, not a crash" do
    Process.put(:retired_states_result, {:error, :rate_limited})

    log = capture_log(fn -> assert RetiredStates.report(tracker: FakeTracker) == [] end)

    assert log =~ "Could not check for tickets left in a retired state (Auto Review): :rate_limited"
  end

  test "a ticket without an identifier is named by its id" do
    Process.put(:retired_states_result, {:ok, [%{id: "issue-2", state: "Auto Review"}]})

    assert capture_log(fn -> RetiredStates.report(tracker: FakeTracker) end) =~ "issue-2 is still in the retired Auto Review state"
  end
end
