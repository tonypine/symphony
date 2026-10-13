defmodule SymphonyElixir.CodeReviewDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.RunStore

  @designed_repo "designed-repo"
  @legacy_repo "legacy-repo"
  @issue_id "issue-code-review-dispatch"

  defp designed_repos do
    [
      [key: @designed_repo, workflow: Workflow.workflow_file_path(), team: "Test", labels: ["designed"], state_machine: "designed"],
      [key: @legacy_repo, workflow: Workflow.workflow_file_path(), team: "Test", labels: ["legacy"]]
    ]
  end

  setup do
    # The reviewer is what a designed repo's Code Review ticket is dispatched to run.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      review_agent: %{enabled: true, kind: "codex", command: "codex app-server"},
      repos: designed_repos()
    )

    for repo <- [@designed_repo, @legacy_repo] do
      RunStore.delete_ticket_state(repo, @issue_id)
      on_exit(fn -> RunStore.delete_ticket_state(repo, @issue_id) end)
    end

    :ok
  end

  defp state, do: %Orchestrator.State{}

  defp issue(repo_key, issue_state, id \\ @issue_id) do
    %Issue{id: id, identifier: "TP-815", title: "Code Review", state: issue_state, repo_key: repo_key}
  end

  defp record_ci!(repo_key, head, status) do
    assert {:ok, :changed} = RunStore.record_ci_state(repo_key, @issue_id, head, status, DateTime.utc_now())
  end

  defp head_signals(repo_key) do
    case RunStore.get_ticket_state(repo_key, @issue_id) do
      %{} = record ->
        record
        |> SymphonyElixir.TicketState.recent_signals(10)
        |> Enum.filter(&(&1.name == "code_review_head_not_green"))

      _none ->
        []
    end
  end

  defp reviewer_disabled_signals(repo_key) do
    case RunStore.get_ticket_state(repo_key, @issue_id) do
      %{} = record ->
        record
        |> SymphonyElixir.TicketState.recent_signals(10)
        |> Enum.filter(&(&1.name == "code_review_reviewer_disabled"))

      _none ->
        []
    end
  end

  describe "the reviewer dispatch gate" do
    test "a designed Code Review ticket dispatches on a green head" do
      record_ci!(@designed_repo, "abc123", "green")

      assert Orchestrator.should_dispatch_issue_for_test(issue(@designed_repo, "Code Review"), state())
    end

    test "a designed Code Review ticket is parked while the head is not green" do
      for status <- ["red", "running", "unknown"] do
        RunStore.delete_ticket_state(@designed_repo, @issue_id)
        record_ci!(@designed_repo, "head-#{status}", status)
        issue = issue(@designed_repo, "Code Review")

        refute Orchestrator.should_dispatch_issue_for_test(issue, state())

        next = Orchestrator.dispatch_chosen_issues_for_test([issue], state())
        refute Map.has_key?(next.running, @issue_id)
      end
    end

    test "a designed Code Review ticket with no recorded CI state is parked" do
      issue = issue(@designed_repo, "Code Review")

      refute Orchestrator.should_dispatch_issue_for_test(issue, state())
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([issue], state()).running, @issue_id)
    end

    test "the no-dispatch event is recorded once per head" do
      record_ci!(@designed_repo, "abc123", "red")
      issue = issue(@designed_repo, "Code Review")

      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([issue], state()).running, @issue_id)
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([issue], state()).running, @issue_id)

      assert [%{details: %{head: "abc123", status: "red"}}] = head_signals(@designed_repo)

      # A new head is a new event.
      record_ci!(@designed_repo, "def456", "red")
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([issue], state()).running, @issue_id)

      heads = head_signals(@designed_repo) |> Enum.map(& &1.details.head)
      assert Enum.sort(heads) == ["abc123", "def456"]
    end

    test "a legacy repo's Code Review ticket keeps dispatching with no CI state" do
      assert Orchestrator.should_dispatch_issue_for_test(issue(@legacy_repo, "Code Review"), state())
      assert head_signals(@legacy_repo) == []
    end

    test "a designed Code Review ticket whose repo has the reviewer off is parked, not approved" do
      # Nothing to review with: the reviewer answers a disabled run with a fabricated approval, so
      # the ticket must never be dispatched, even on a green head.
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", repos: designed_repos())
      record_ci!(@designed_repo, "abc123", "green")
      review_ticket = issue(@designed_repo, "Code Review")

      refute Orchestrator.should_dispatch_issue_for_test(review_ticket, state())
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([review_ticket], state()).running, @issue_id)
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([review_ticket], state()).running, @issue_id)

      # Recorded once for the ticket: the reason is the repo's config, not the head.
      assert [%{name: "code_review_reviewer_disabled"}] = reviewer_disabled_signals(@designed_repo)
      assert head_signals(@designed_repo) == []

      # A legacy repo's Code Review state is untouched by the gate.
      assert Orchestrator.should_dispatch_issue_for_test(issue(@legacy_repo, "Code Review"), state())
    end

    test "a Code Review ticket whose reviewer run is missing is dispatched exactly once" do
      record_ci!(@designed_repo, "abc123", "green")
      issue = issue(@designed_repo, "Code Review")

      # No run under way (say, after a restart): the poll tick picks the reviewer up again.
      assert Orchestrator.should_dispatch_issue_for_test(issue, state())

      # While the dispatch's claim or run is live, the next tick does not dispatch a second one.
      refute Orchestrator.should_dispatch_issue_for_test(issue, %Orchestrator.State{claimed: MapSet.new([@issue_id])})
      refute Orchestrator.should_dispatch_issue_for_test(issue, %Orchestrator.State{running: %{@issue_id => %{}}})
    end
  end

  describe "the post-PR quiet catch-handler" do
    test "never advances a designed repo's quiet run" do
      quiet = %{pull_request_url: "https://github.com/acme/symphony/pull/9"}

      state = %Orchestrator.State{completed_run_metadata: %{@issue_id => quiet}}

      # The designed ticket is not swallowed by the catch-handler; it stays dispatchable.
      assert Orchestrator.should_dispatch_issue_for_test(issue(@designed_repo, "In Progress"), state)
    end

    test "never advances a legacy repo's quiet run either" do
      quiet = %{pull_request_url: "https://github.com/acme/symphony/pull/9"}

      state = %Orchestrator.State{completed_run_metadata: %{@issue_id => quiet}}

      # Quiet is never done: the ticket stays dispatchable so its run is retried.
      assert Orchestrator.should_dispatch_issue_for_test(issue(@legacy_repo, "In Progress"), state)
    end
  end
end
