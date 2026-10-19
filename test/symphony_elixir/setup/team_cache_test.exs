defmodule SymphonyElixir.Setup.TeamCacheTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Setup.TeamCache

  # Answers every read, or the error a test sets, and tells the test about each request.
  defmodule FakeTracker do
    def team_workflow_states(team), do: answer({:states, team}, [%{id: "s", name: "Todo", team_id: "t", team_key: team}])
    def team_labels(team), do: answer({:labels, team}, [%{id: "l", name: "plan", team_id: nil, team_key: nil}])
    def projects_and_teams, do: answer(:projects_and_teams, %{projects: [], teams: [%{id: "t", key: "TP", name: "Tony Pine"}]})

    defp answer(request, value) do
      send(self(), {:tracker, request})
      Process.get(:fake_tracker_result, {:ok, value})
    end
  end

  setup do
    clock = :counters.new(1, [])
    cache = TeamCache.new(ttl_ms: 100, tracker: FakeTracker, clock: fn -> :counters.get(clock, 1) end)
    {:ok, cache: cache, clock: clock}
  end

  test "a team's states and labels are read once until they expire", %{cache: cache, clock: clock} do
    assert {:ok, [%{team_key: "TP"}]} = TeamCache.states(cache, "TP")
    assert {:ok, [%{name: "plan"}]} = TeamCache.labels(cache, "TP")
    assert {:ok, _states} = TeamCache.states(cache, "TP")
    assert {:ok, _labels} = TeamCache.labels(cache, "TP")
    assert_received {:tracker, {:states, "TP"}}
    assert_received {:tracker, {:labels, "TP"}}
    refute_received {:tracker, _request}

    assert {:ok, _states} = TeamCache.states(cache, "OPS")
    assert_received {:tracker, {:states, "OPS"}}

    :counters.add(clock, 1, 100)
    assert {:ok, _states} = TeamCache.states(cache, "TP")
    assert_received {:tracker, {:states, "TP"}}
  end

  test "the workspace's projects and teams are read once until they expire", %{cache: cache, clock: clock} do
    assert {:ok, %{teams: [%{key: "TP"}]}} = TeamCache.projects_and_teams(cache)
    assert {:ok, _catalog} = TeamCache.projects_and_teams(cache)
    assert_received {:tracker, :projects_and_teams}
    refute_received {:tracker, _request}

    :counters.add(clock, 1, 100)
    assert {:ok, _catalog} = TeamCache.projects_and_teams(cache)
    assert_received {:tracker, :projects_and_teams}
  end

  test "invalidate forgets every team", %{cache: cache} do
    assert {:ok, _states} = TeamCache.states(cache, "TP")
    assert :ok = TeamCache.invalidate(cache)
    assert {:ok, _states} = TeamCache.states(cache, "TP")
    assert_received {:tracker, {:states, "TP"}}
    assert_received {:tracker, {:states, "TP"}}
  end

  test "a failed read is not cached", %{cache: cache} do
    Process.put(:fake_tracker_result, {:error, :timeout})
    assert {:error, :timeout} = TeamCache.labels(cache, "TP")
    Process.delete(:fake_tracker_result)
    assert {:ok, _labels} = TeamCache.labels(cache, "TP")
    assert_received {:tracker, {:labels, "TP"}}
    assert_received {:tracker, {:labels, "TP"}}
  end

  test "delete drops the table", %{cache: cache} do
    assert :ok = TeamCache.delete(cache)
    assert :ets.info(cache.table) == :undefined
  end

  test "the default clock is monotonic" do
    cache = TeamCache.new(ttl_ms: 60_000, tracker: FakeTracker)
    assert {:ok, _states} = TeamCache.states(cache, "TP")
    assert {:ok, _states} = TeamCache.states(cache, "TP")
    assert_received {:tracker, {:states, "TP"}}
    refute_received {:tracker, _request}
  end
end
