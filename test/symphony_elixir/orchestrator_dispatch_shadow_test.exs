defmodule SymphonyElixir.OrchestratorDispatchShadowTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Dispatch.Shadow
  alias SymphonyElixir.{RunStore, TicketObservation}

  @linear_at ~U[2026-10-29 09:00:00Z]

  setup do
    Shadow.reset()
    on_exit(&Shadow.reset/0)
    repo_key = "shadow-#{System.unique_integer([:positive])}"
    %{repo_key: repo_key, repos: [%{name: repo_key, team: "ACME", labels: []}]}
  end

  defp issue(repo_key, n, attrs \\ []) do
    struct!(
      %Issue{
        id: "#{repo_key}-#{n}",
        identifier: "ACME-#{n}",
        title: "Ticket #{n}",
        state: "Todo",
        priority: 1,
        assignee_id: "user-2",
        url: "https://linear.app/acme/issue/ACME-#{n}",
        updated_at: @linear_at
      },
      attrs
    )
  end

  defp fetcher(issues) do
    fn repo ->
      send(self(), {:polled, repo.name})
      {:ok, issues}
    end
  end

  defp cycle(state, repos, issues, now_ms) do
    assert {:ok, buckets, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher(issues), now_ms)

    {buckets, state}
  end

  test "a cycle with equal sets counts the cycle and no difference, with no Linear read and no store write", ctx do
    issues = [issue(ctx.repo_key, 1), issue(ctx.repo_key, 2, state: "In Progress")]
    {_buckets, state} = cycle(%Orchestrator.State{poll_interval_ms: 100}, ctx.repos, issues, 0)
    assert_receive {:polled, _repo}

    assert %{cycles_compared: 1, cycles_with_differences: 0, window_differences: 0, recent: []} = Shadow.summary()

    # A cycle with no repo due compares from the cache and the store alone: no poll, no write.
    records = RunStore.list_ticket_states(ctx.repo_key)
    {%{dispatchable: dispatchable}, _state} = cycle(state, ctx.repos, issues, 50)
    refute_receive {:polled, _repo}
    assert RunStore.list_ticket_states(ctx.repo_key) == records
    assert Enum.map(dispatchable, & &1.identifier) == ["ACME-1", "ACME-2"]
    assert %{cycles_compared: 2, window_differences: 0} = Shadow.summary()
  end

  test "a record missing a ticket is one difference naming it, on the poll side", ctx do
    issues = [issue(ctx.repo_key, 1), issue(ctx.repo_key, 2)]
    {_buckets, state} = cycle(%Orchestrator.State{poll_interval_ms: 100}, ctx.repos, issues, 0)
    :ok = RunStore.delete_ticket_state(ctx.repo_key, "#{ctx.repo_key}-2")

    log = capture_log(fn -> cycle(state, ctx.repos, issues, 50) end)

    assert log =~ "Dispatch shadow difference: repo_key=#{ctx.repo_key} issue_id=#{ctx.repo_key}-2 issue_identifier=ACME-2 side=poll field=candidate"

    assert %{
             cycles_compared: 2,
             cycles_with_differences: 1,
             window_differences: 1,
             recent: [%{repo_key: repo_key, identifier: "ACME-2", side: :poll, field: :candidate, poll: "Todo", record: nil}]
           } = Shadow.summary()

    assert repo_key == ctx.repo_key
  end

  test "a state a webhook changed is named until the next poll reads it, and dispatch stays on the cache with source record", ctx do
    write_workflow_file!(Workflow.workflow_file_path())
    File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "dispatch:\n  source: record\n  shadow_window: 2\n")
    Cache.clear()

    {_buckets, state} = cycle(%Orchestrator.State{poll_interval_ms: 100}, ctx.repos, [issue(ctx.repo_key, 1)], 0)

    # The operator moves the ticket by hand; the webhook writes the record, the cache still says Todo.
    moved = issue(ctx.repo_key, 1, state: "In Progress", updated_at: DateTime.add(@linear_at, 60))
    {:ok, :updated} = TicketObservation.observe(ctx.repo_key, moved, source: :webhook)

    {{buckets, state}, log} = with_log(fn -> cycle(state, ctx.repos, [moved], 50) end)
    assert log =~ "issue_identifier=ACME-1 side=both field=state poll=\"Todo\" record=\"In Progress\""

    # `record` is accepted and dispatch still reads the cache.
    assert [%{identifier: "ACME-1", state: "Todo"}] = buckets.dispatchable
    assert %{window_differences: 1, recent: [%{identifier: "ACME-1", side: :both, field: :state}]} = Shadow.summary()

    # The next poll reads the move: the difference clears, and the two-cycle window forgets it.
    {%{dispatchable: [%{state: "In Progress"}]}, state} = cycle(state, ctx.repos, [moved], 100)
    assert %{cycles_compared: 3, window_cycles: 2, window_differences: 1} = Shadow.summary()
    cycle(state, ctx.repos, [moved], 150)
    assert %{cycles_compared: 4, cycles_with_differences: 1, window_differences: 0} = Shadow.summary()
  end

  test "a ticket only the record has is a difference on the record side; a repo not polled yet is left out", ctx do
    other_key = "#{ctx.repo_key}-api"
    repos = ctx.repos ++ [%{name: other_key, team: "ACME", labels: ["api"]}]
    {:ok, :updated} = TicketObservation.observe(ctx.repo_key, issue(ctx.repo_key, 3))
    {:ok, :updated} = TicketObservation.observe(other_key, issue(other_key, 4))

    capture_log(fn -> cycle(%Orchestrator.State{poll_interval_ms: 100}, repos, [issue(ctx.repo_key, 1)], 0) end)

    # Only the repo polled is compared; the other's record waits for its first poll.
    assert %{cycles_compared: 1, recent: [%{identifier: "ACME-3", side: :record, field: :candidate, poll: nil, record: "Todo"}]} =
             Shadow.summary()
  end

  test "no cycle is counted when no repo is warm or its records can't be read" do
    repos = [%{name: " ", team: "ACME", labels: []}]
    cycle(%Orchestrator.State{poll_interval_ms: 100}, repos, [], 0)

    assert %{cycles_compared: 0} = Shadow.summary()
  end

  test "with assignee me, the record side counts the viewer the poll already resolved", ctx do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "me")
    issues = [issue(ctx.repo_key, 1)]

    # Without the viewer known, no record counts as assigned.
    capture_log(fn -> cycle(%Orchestrator.State{poll_interval_ms: 100}, ctx.repos, issues, 0) end)
    assert %{window_differences: 1, recent: [%{side: :poll, field: :candidate}]} = Shadow.summary()

    graphql_fun = fn query, _variables ->
      if query =~ "SymphonyLinearViewer",
        do: {:ok, %{"data" => %{"viewer" => %{"id" => "user-2"}}}},
        else: {:ok, %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}
    end

    assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert Client.known_viewer_id() == "user-2"

    Shadow.reset()
    cycle(%Orchestrator.State{poll_interval_ms: 100}, ctx.repos, issues, 0)
    assert %{cycles_compared: 1, window_differences: 0} = Shadow.summary()
  end
end
