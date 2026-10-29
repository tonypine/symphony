defmodule SymphonyElixir.OrchestratorDispatchShadowTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Dispatch.Shadow
  alias SymphonyElixir.{RunStore, TicketObservation, TicketSignals}

  @linear_at ~U[2026-10-29 09:00:00Z]
  @review_states ["Todo", "In Progress", "Rework", "Code Review"]

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

  test "a state a webhook changed after the poll read is record_newer until the next poll reads it, and dispatch reads the record with source record",
       ctx do
    write_workflow_file!(Workflow.workflow_file_path())
    File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "dispatch:\n  source: record\n  shadow_window: 2\n")
    Cache.clear()

    {_buckets, state} = cycle(%Orchestrator.State{poll_interval_ms: 100}, ctx.repos, [issue(ctx.repo_key, 1)], 0)

    # The operator moves the ticket by hand; the webhook writes the record, the cache still says Todo.
    moved = issue(ctx.repo_key, 1, state: "In Progress", updated_at: DateTime.add(@linear_at, 60))
    {:ok, :updated} = TicketObservation.observe(ctx.repo_key, moved, source: :webhook)

    {{buckets, state}, log} = with_log(fn -> cycle(state, ctx.repos, [moved], 50) end)
    refute log =~ "Dispatch shadow difference"

    # With `record` dispatch reads the record, and the record being newer is no difference.
    assert [%{identifier: "ACME-1", state: "In Progress"}] = buckets.dispatchable
    assert %{window_differences: 0, recent: [], record_newer: %{count: 1, recent: ["ACME-1"]}} = Shadow.summary()

    # The next poll reads the move: nothing is set aside any more, and the count stays.
    {%{dispatchable: [%{state: "In Progress"}]}, _state} = cycle(state, ctx.repos, [moved], 100)
    assert %{cycles_compared: 3, cycles_with_differences: 0, record_newer: %{count: 1}} = Shadow.summary()
  end

  test "TP-1222 replayed: the poll reads Rework, Symphony moves the record to Code Review, and the comparison records no difference",
       ctx do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: @review_states)
    issue_id = "#{ctx.repo_key}-1"
    {_buckets, state} = cycle(%Orchestrator.State{poll_interval_ms: 100}, ctx.repos, [issue(ctx.repo_key, 1, state: "Rework")], 0)

    # Symphony's own move writes the record first, then Linear; the cache still holds the read before it.
    :ok = TicketSignals.record_phase(ctx.repo_key, issue_id, "Code Review")

    log = capture_log(fn -> cycle(state, ctx.repos, [issue(ctx.repo_key, 1, state: "Rework")], 50) end)
    refute log =~ "Dispatch shadow difference"

    summary = Shadow.summary()
    assert %{cycles_compared: 2, cycles_with_differences: 0, window_differences: 0, recent: []} = summary
    assert summary.record_newer == %{count: 1, recent: ["ACME-1"]}
  end

  test "a record whose phase was written before the poll read and still differs is a difference naming the ticket and field", ctx do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: @review_states)
    {_buckets, state} = cycle(%Orchestrator.State{poll_interval_ms: 100}, ctx.repos, [issue(ctx.repo_key, 1, state: "Rework")], 0)

    moved = issue(ctx.repo_key, 1, state: "Code Review", updated_at: DateTime.add(@linear_at, 60))
    {:ok, :updated} = TicketObservation.observe(ctx.repo_key, moved, source: :webhook)

    # The next poll gets a lagging copy (an older updatedAt), so the record keeps the phase it wrote
    # before this read: the two sides really disagree.
    log = capture_log(fn -> cycle(state, ctx.repos, [issue(ctx.repo_key, 1, state: "Rework")], 100) end)
    assert log =~ "issue_identifier=ACME-1 side=both field=state poll=\"Rework\" record=\"Code Review\""

    summary = Shadow.summary()
    assert %{cycles_with_differences: 1, recent: [%{identifier: "ACME-1", side: :both, field: :state}]} = summary
    assert summary.record_newer.count == 0
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
