defmodule SymphonyElixir.QaDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.RunStore

  @designed_repo "designed-repo"
  @issue_id "issue-qa-dispatch"

  defp repos do
    [
      [key: @designed_repo, workflow: Workflow.workflow_file_path(), team: "Test", labels: ["designed"]]
    ]
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", repos: repos())

    for repo <- [@designed_repo] do
      RunStore.delete_ticket_state(repo, @issue_id)
      on_exit(fn -> RunStore.delete_ticket_state(repo, @issue_id) end)
    end

    :ok
  end

  defp state, do: %Orchestrator.State{}

  defp issue(repo_key, issue_state) do
    %Issue{id: @issue_id, identifier: "TP-816", title: "QA", state: issue_state, repo_key: repo_key}
  end

  defp record_ci!(repo_key, head, status) do
    assert {:ok, :changed} = RunStore.record_ci_state(repo_key, @issue_id, head, status, DateTime.utc_now())
  end

  defp head_signals(repo_key) do
    case RunStore.get_ticket_state(repo_key, @issue_id) do
      %{} = record ->
        record
        |> SymphonyElixir.TicketState.recent_signals(10)
        |> Enum.filter(&(&1.name == "qa_head_not_green"))

      _none ->
        []
    end
  end

  describe "the QA dispatch gate" do
    test "a designed QA ticket dispatches on a green head" do
      record_ci!(@designed_repo, "abc123", "green")

      assert Orchestrator.should_dispatch_issue_for_test(issue(@designed_repo, "QA"), state())
    end

    test "a designed QA ticket is parked while the head is not green" do
      for status <- ["red", "running", "unknown"] do
        RunStore.delete_ticket_state(@designed_repo, @issue_id)
        record_ci!(@designed_repo, "head-#{status}", status)
        qa_ticket = issue(@designed_repo, "QA")

        refute Orchestrator.should_dispatch_issue_for_test(qa_ticket, state())

        next = Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state())
        refute Map.has_key?(next.running, @issue_id)
      end
    end

    test "a designed QA ticket with no recorded CI state is parked" do
      qa_ticket = issue(@designed_repo, "QA")

      refute Orchestrator.should_dispatch_issue_for_test(qa_ticket, state())
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()).running, @issue_id)
    end

    test "the no-dispatch event is recorded once per head" do
      record_ci!(@designed_repo, "abc123", "red")
      qa_ticket = issue(@designed_repo, "QA")

      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()).running, @issue_id)
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()).running, @issue_id)

      assert [%{details: %{head: "abc123", status: "red"}}] = head_signals(@designed_repo)

      # A new head is a new event.
      record_ci!(@designed_repo, "def456", "red")
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()).running, @issue_id)

      heads = head_signals(@designed_repo) |> Enum.map(& &1.details.head)
      assert Enum.sort(heads) == ["abc123", "def456"]
    end

    test "a Code Review ticket is not held by the QA gate" do
      # The two gates are per-state: a Code Review ticket with no CI state is parked by its own gate
      # (tested in `CodeReviewDispatchTest`) and never records a QA no-dispatch signal.
      issue = issue(@designed_repo, "Code Review")

      refute Orchestrator.should_dispatch_issue_for_test(issue, state())
      assert head_signals(@designed_repo) == []
    end

    test "a QA ticket whose run is missing is dispatched exactly once" do
      record_ci!(@designed_repo, "abc123", "green")
      qa_ticket = issue(@designed_repo, "QA")

      # No run under way (say, after a restart): the poll tick picks the QA run up again.
      assert Orchestrator.should_dispatch_issue_for_test(qa_ticket, state())

      # While the dispatch's claim or run is live, the next tick does not dispatch a second one.
      refute Orchestrator.should_dispatch_issue_for_test(qa_ticket, %Orchestrator.State{claimed: MapSet.new([@issue_id])})
      refute Orchestrator.should_dispatch_issue_for_test(qa_ticket, %Orchestrator.State{running: %{@issue_id => %{}}})
    end
  end
end
