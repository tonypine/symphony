defmodule SymphonyElixir.OrchestratorPollerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{Orchestrator, RunStore}

  test "a poll result writes each polled ticket's record, and an identical poll writes nothing" do
    repo_key = "observed-#{System.unique_integer([:positive])}"
    repos = [%{name: repo_key, team: "ACME", labels: []}]

    issue = %Issue{
      id: "#{repo_key}-issue",
      identifier: "ACME-71",
      title: "Observed by the poll",
      state: "In Progress",
      labels: ["backend"],
      priority: 1,
      assignee_id: "user-1",
      blocked_by: [%{id: "blocker", identifier: "ACME-70", state: "Todo"}],
      url: "https://linear.app/acme/issue/ACME-71",
      updated_at: ~U[2026-10-29 09:00:00Z]
    }

    state = %Orchestrator.State{poll_interval_ms: 100}

    assert {:ok, %{dispatchable: [%{identifier: "ACME-71"}]}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fn _repo -> {:ok, [issue]} end, 0)

    record = RunStore.get_ticket_state(repo_key, issue.id)

    assert Map.take(record, [:issue_identifier, :phase, :title, :labels, :priority, :assignee, :blockers, :url, :linear_updated_at]) == %{
             issue_identifier: "ACME-71",
             phase: "In Progress",
             title: "Observed by the poll",
             labels: ["backend"],
             priority: 1,
             assignee: "user-1",
             blockers: ["ACME-70"],
             url: "https://linear.app/acme/issue/ACME-71",
             linear_updated_at: ~U[2026-10-29 09:00:00Z]
           }

    assert {:ok, _buckets, _state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fn _repo -> {:ok, [issue]} end, 100)

    assert RunStore.get_ticket_state(repo_key, issue.id) == record
  end

  test "staggered repo poll cache routes cross-repo duplicates to conflicts before dispatch" do
    repos = [
      %{name: "web", team: "ACME", labels: ["web"]},
      %{name: "api", team: "ACME", labels: ["api"]}
    ]

    issue = %Issue{id: "issue-1", identifier: "ACME-1", title: "Shared", state: "Todo"}

    fetcher = fn
      %{name: "web"} ->
        send(self(), {:polled, "web"})
        {:ok, [issue]}

      %{name: "api"} ->
        send(self(), {:polled, "api"})
        {:ok, [issue]}
    end

    state = %Orchestrator.State{poll_interval_ms: 100}

    assert {:ok, %{dispatchable: [], conflicts: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 0)

    assert_receive {:polled, "web"}
    refute_receive {:polled, "api"}, 10
    assert state.repo_poll_due_at_ms == %{"web" => 100, "api" => 50}
    assert Map.has_key?(state.repo_poll_cache, "web")
    refute Map.has_key?(state.repo_poll_cache, "api")

    assert {:ok, %{dispatchable: [], conflicts: [conflict]}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 50)

    assert_receive {:polled, "api"}
    assert conflict.id == "issue-1"
    assert conflict.repo_key == nil
    assert conflict.conflict_repo_keys == ["api", "web"]
    assert state.conflicts["issue-1"].conflict_repo_keys == ["api", "web"]
  end

  test "warmed stagger cache dispatches unique issues with repo metadata" do
    repos = [
      %{name: "web", team: "ACME", labels: ["web"]},
      %{name: "api", team: "ACME", labels: ["api"]}
    ]

    web_issue = %Issue{id: "issue-web", identifier: "ACME-WEB", title: "Web", state: "Todo"}
    api_issue = %Issue{id: "issue-api", identifier: "ACME-API", title: "API", state: "Todo"}

    fetcher = fn
      %{name: "web"} -> {:ok, [web_issue]}
      %{name: "api"} -> {:ok, [api_issue]}
    end

    state = %Orchestrator.State{poll_interval_ms: 100}

    assert {:ok, %{dispatchable: [], conflicts: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 0)

    assert {:ok, %{dispatchable: dispatchable, conflicts: []}, _state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 50)

    assert Enum.map(dispatchable, &{&1.identifier, &1.repo_key}) == [
             {"ACME-API", "api"},
             {"ACME-WEB", "web"}
           ]
  end

  test "poll failure for a warmed repo falls back to cached buckets" do
    repos = [
      %{name: "web", team: "ACME", labels: ["web"]},
      %{name: "api", team: "ACME", labels: ["api"]}
    ]

    web_issue = %Issue{id: "issue-web", identifier: "ACME-WEB", title: "Web", state: "Todo"}
    api_issue = %Issue{id: "issue-api", identifier: "ACME-API", title: "API", state: "Todo"}

    fetcher = fn
      %{name: "api"} ->
        send(self(), {:polled, "api"})
        {:error, :linear_unavailable}
    end

    state = %Orchestrator.State{
      poll_interval_ms: 100,
      repo_poll_due_at_ms: %{"web" => 100, "api" => 50},
      repo_poll_cache: %{
        "web" => %{issues: [web_issue], fetched_at_ms: 0},
        "api" => %{issues: [api_issue], fetched_at_ms: 0}
      }
    }

    assert {:ok, %{dispatchable: dispatchable, conflicts: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 50)

    assert_receive {:polled, "api"}

    assert Enum.map(dispatchable, &{&1.identifier, &1.repo_key}) == [
             {"ACME-API", "api"},
             {"ACME-WEB", "web"}
           ]

    assert state.repo_poll_due_at_ms["api"] == 150
  end

  test "cold poll failures eventually stop starving warmed repos" do
    repos = [
      %{name: "web", team: "ACME", labels: ["web"]},
      %{name: "api", team: "ACME", labels: ["api"]}
    ]

    web_issue = %Issue{id: "issue-web", identifier: "ACME-WEB", title: "Web", state: "Todo"}

    fetcher = fn
      %{name: "web"} ->
        {:ok, [web_issue]}

      %{name: "api"} ->
        {:error, :linear_unavailable}
    end

    state = %Orchestrator.State{poll_interval_ms: 100}

    assert {:ok, %{dispatchable: [], conflicts: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 0)

    assert {:error, :linear_unavailable, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 50)

    assert {:ok, %{dispatchable: [], conflicts: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 100)

    assert {:error, :linear_unavailable, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 150)

    assert {:ok, %{dispatchable: [], conflicts: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 200)

    assert {:ok, %{dispatchable: dispatchable, conflicts: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 250)

    assert Enum.map(dispatchable, &{&1.identifier, &1.repo_key}) == [{"ACME-WEB", "web"}]
    assert state.repo_poll_cache["api"].issues == []
    assert state.repo_poll_due_at_ms["api"] == 350
  end

  test "poll cycle with no due repo rebuilds buckets from cache without fetching" do
    repos = [
      %{name: "web", team: "ACME", labels: ["web"]},
      %{name: "api", team: "ACME", labels: ["api"]}
    ]

    web_issue = %Issue{id: "issue-web", identifier: "ACME-WEB", title: "Web", state: "Todo"}
    api_issue = %Issue{id: "issue-api", identifier: "ACME-API", title: "API", state: "Todo"}

    fetcher = fn repo ->
      send(self(), {:unexpected_poll, repo.name})
      {:error, :polled_too_early}
    end

    state = %Orchestrator.State{
      poll_interval_ms: 100,
      repo_poll_due_at_ms: %{"web" => 100, "api" => 150},
      repo_poll_cache: %{
        "web" => %{issues: [web_issue], fetched_at_ms: 0},
        "api" => %{issues: [api_issue], fetched_at_ms: 0}
      }
    }

    assert {:ok, %{dispatchable: dispatchable, conflicts: []}, returned_state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 75)

    refute_receive {:unexpected_poll, _repo_name}, 10

    assert returned_state.repo_poll_due_at_ms == state.repo_poll_due_at_ms

    assert Enum.map(dispatchable, &{&1.identifier, &1.repo_key}) == [
             {"ACME-API", "api"},
             {"ACME-WEB", "web"}
           ]
  end

  describe "a repo Symphony's own move forces due" do
    @repos [%{name: "web", team: "ACME", labels: ["web"]}, %{name: "api", team: "ACME", labels: ["api"]}]

    defp polling_fetcher do
      test_pid = self()

      fn repo ->
        send(test_pid, {:polled, repo.name})
        {:ok, []}
      end
    end

    defp poll(state, now_ms), do: Orchestrator.poll_candidate_issue_buckets_for_test(state, @repos, polling_fetcher(), now_ms)
    defp force(state, repo_key, now_ms), do: Orchestrator.force_repo_due_for_test(state, repo_key, now_ms)
    defp answer(state, repo_result, now_ms), do: Orchestrator.apply_repo_poll_result_for_test(state, @repos, repo_result, now_ms)

    defp warmed_state do
      state = %Orchestrator.State{poll_interval_ms: 10_000}
      {:ok, _buckets, state} = poll(state, 0)
      {:ok, _buckets, state} = poll(state, 5_000)
      assert_received {:polled, "web"}
      assert_received {:polled, "api"}
      assert state.repo_poll_due_at_ms == %{"web" => 10_000, "api" => 15_000}
      state
    end

    test "is polled on the next tick regardless of its stagger, ahead of a repo already due" do
      state = warmed_state()

      assert {false, state} = force(state, "api", 6_000)
      assert state.repo_poll_due_at_ms["api"] == 6_000

      assert {:ok, _buckets, state} = poll(state, 6_010)
      assert_received {:polled, "api"}
      refute_received {:polled, "web"}
      assert state.repo_poll_due_at_ms == %{"web" => 10_000, "api" => 16_010}

      # web is due at its own time and api forced again at once: the forced repo goes first.
      assert {false, state} = force(state, "api", 10_500)
      assert {:ok, _buckets, state} = poll(state, 10_500)
      assert_received {:polled, "api"}
      refute_received {:polled, "web"}

      assert {:ok, _buckets, _state} = poll(state, 10_510)
      assert_received {:polled, "web"}
    end

    test "three requests within two seconds poll it once; one after the window polls it again" do
      state = warmed_state()

      assert {false, state} = force(state, "web", 6_000)
      assert {true, state} = force(state, "web", 6_500)
      assert {true, state} = force(state, "web", 7_999)

      assert {:ok, _buckets, state} = poll(state, 8_000)
      assert_received {:polled, "web"}

      assert {:ok, _buckets, state} = poll(state, 8_010)
      refute_received {:polled, _repo}

      assert {false, state} = force(state, "web", 8_000)
      assert {:ok, _buckets, _state} = poll(state, 8_020)
      assert_received {:polled, "web"}
    end

    test "a forcing that lands while the repo's poll is in flight keeps it due after that poll" do
      state = warmed_state()

      # The poll task took web at 10_000; the move lands before its answer.
      assert {:ok, _buckets, state} = poll(state, 10_000)
      assert_received {:polled, "web"}
      assert {false, state} = force(state, "web", 10_005)

      assert {:ok, _buckets, state} = answer(state, {"web", {:ok, []}}, 10_000)
      assert state.repo_poll_due_at_ms["web"] == 10_005

      assert {:ok, _buckets, state} = poll(state, 10_010)
      assert_received {:polled, "web"}
      assert state.repo_poll_due_at_ms["web"] == 20_010
    end

    test "the timed cadence is unchanged without a forcing, and a forcing of a repo no longer configured is dropped" do
      state = warmed_state()

      assert {false, state} = force(state, "gone", 6_000)
      assert {false, ^state} = force(state, nil, 6_000)

      assert {:ok, _buckets, state} = poll(state, 9_999)
      refute_received {:polled, _repo}
      assert state.repo_poll_due_at_ms == %{"web" => 10_000, "api" => 15_000}
      assert state.repo_poll_forced == MapSet.new()
      assert state.repo_poll_forced_at_ms == %{}

      assert {:ok, _buckets, _state} = poll(state, 10_000)
      assert_received {:polled, "web"}
      refute_received {:polled, "api"}
    end

    test "a refresh request for a repo forces it due and schedules the tick at once; one with no repo asks for a poll" do
      state = %Orchestrator.State{poll_interval_ms: 10_000}

      assert {:noreply, state} = Orchestrator.handle_cast({:request_refresh, "web", :now}, state)
      assert_receive {:tick, tick_token}
      assert state.tick_token == tick_token
      assert MapSet.member?(state.repo_poll_forced, "web")

      # Within the window the request is already answered: no second tick is scheduled.
      assert {:noreply, ^state} = Orchestrator.handle_cast({:request_refresh, "web", :now}, state)

      fresh = %Orchestrator.State{poll_interval_ms: 10_000}
      assert {:noreply, state} = Orchestrator.handle_cast({:request_refresh, nil, :now}, fresh)
      assert_receive {:tick, tick_token}
      assert state.tick_token == tick_token
      assert state.repo_poll_forced == MapSet.new()
    end
  end
end
