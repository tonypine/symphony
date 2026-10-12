defmodule SymphonyElixir.EpicReviewDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.RunKind
  alias SymphonyElixir.SubIssueWait

  @designed_repo "designed-epic"
  @legacy_repo "legacy-epic"
  @issue_id "issue-epic-review-dispatch"
  @waiting "Waiting on sub-tickets"

  defp repos do
    [
      [key: @designed_repo, workflow: Workflow.workflow_file_path(), team: "Test", labels: ["designed"], state_machine: "designed"],
      [key: @legacy_repo, workflow: Workflow.workflow_file_path(), team: "Test", labels: ["legacy"]]
    ]
  end

  setup do
    # The poll loop is what dispatches an epic parent: the waiting state is active, and the tick that
    # finds every sub-ticket terminal picks the parent up with no event wiring. The designed repo is
    # what makes the run an epic review rather than a close-out.
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", repos: repos())
    SubIssueWait.reset_for_test(@waiting)

    on_exit(fn -> SubIssueWait.reset_for_test(@waiting) end)

    :ok
  end

  defp state, do: %Orchestrator.State{}

  defp settings(version) do
    assert {:ok, settings} =
             Schema.parse(%{"tracker" => %{"kind" => "memory"}, "state_machine" => version})

    settings
  end

  defp designed_settings, do: settings("designed")
  defp legacy_settings, do: settings("legacy")

  defp epic(repo_key, attrs \\ %{}) do
    struct!(
      %Issue{
        id: @issue_id,
        identifier: "TP-823",
        title: "Land the epic path",
        state: @waiting,
        labels: ["plan"],
        repo_key: repo_key,
        sub_issues: [%{id: "child-1", identifier: "TP-824", state: "Done"}]
      },
      attrs
    )
  end

  describe "the epic review dispatch gate" do
    test "a designed epic whose sub-tickets are all terminal dispatches from the waiting state as the epic review" do
      parent = epic(@designed_repo)

      assert RunKind.classify(parent, settings: designed_settings()) == :epic_review
      assert Orchestrator.should_dispatch_issue_for_test(parent, state())
    end

    test "an open sub-ticket still holds the parent, and it is not the epic review's ticket yet" do
      held = epic(@designed_repo, sub_issues: [%{id: "child-1", identifier: "TP-824", state: "In Progress"}])

      assert RunKind.classify(held, settings: designed_settings()) == :breakdown
      refute Orchestrator.should_dispatch_issue_for_test(held, state())
    end

    test "a parent the run already moved to Epic Review is picked up again after a restart, exactly once" do
      # The run that entered Epic Review stopped before its verdict: the tick is the recovery sweep,
      # and the review starts again from the state it left the parent in.
      parent = epic(@designed_repo, state: "Epic Review")

      assert RunKind.classify(parent, settings: designed_settings()) == :epic_review
      assert Orchestrator.should_dispatch_issue_for_test(parent, state())

      # While the dispatch's claim or run is live, the next tick does not start a second review.
      refute Orchestrator.should_dispatch_issue_for_test(parent, %Orchestrator.State{claimed: MapSet.new([@issue_id])})
      refute Orchestrator.should_dispatch_issue_for_test(parent, %Orchestrator.State{running: %{@issue_id => %{}}})
    end

    test "a parent planning again is a breakdown, not the epic review" do
      replanning = epic(@designed_repo, state: "Rework")

      assert RunKind.classify(replanning, settings: designed_settings()) == :breakdown
      refute Orchestrator.should_dispatch_issue_for_test(replanning, state())
    end

    test "a legacy repo's parent keeps the close-out run" do
      parent = epic(@legacy_repo)

      assert RunKind.classify(parent, settings: legacy_settings()) == :close_out
      assert Orchestrator.should_dispatch_issue_for_test(parent, state())
    end
  end
end
