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
end
