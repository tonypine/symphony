defmodule SymphonyElixir.EpicReviewDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.RunKind
  alias SymphonyElixir.SubIssueWait

  @designed_repo "epic-repo"
  @issue_id "issue-epic-review-dispatch"
  @waiting "Waiting on sub-tickets"

  defp repos do
    [
      [key: @designed_repo, workflow: Workflow.workflow_file_path(), team: "Test", labels: ["epic"]]
    ]
  end

  setup do
    # The poll loop is what dispatches an epic parent: the waiting state is active, and the tick that
    # finds every sub-ticket terminal picks the parent up with no event wiring.
    write_workflow_file!(Workflow.workflow_file_path(), repos: repos())
    SubIssueWait.reset_for_test(@waiting)

    on_exit(fn -> SubIssueWait.reset_for_test(@waiting) end)

    :ok
  end

  defp state, do: %Orchestrator.State{}

  defp designed_settings do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    settings
  end

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
    test "an epic whose sub-tickets are all terminal dispatches from the waiting state as the epic review" do
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
  end

  @sha "b98572e58594a4f0c3b1e2d3c4b5a69788796a5b"

  # `gh` for a base branch at `@sha` whose `release` and `macos` runs are in the status `ci` holds.
  defp gh(ci) do
    fn
      ["api", "repos/acme/app/commits/main" | _rest], _opts ->
        {@sha, 0}

      ["run", "list", "--commit", @sha | _rest], _opts ->
        status = Agent.get(ci, & &1)
        {Jason.encode!(for name <- ["release", "macos"], do: %{"databaseId" => 1, "workflowName" => name, "status" => status, "createdAt" => DateTime.to_iso8601(DateTime.utc_now())}), 0}
    end
  end

  describe "the wait for CI on the base branch before the epic review (TP-1476)" do
    setup do
      :ok = SymphonyElixir.RunStore.clear()
      {:ok, ci} = Agent.start_link(fn -> "in_progress" end)
      defaults = Application.get_env(:symphony_elixir, :main_ci_opts)
      Application.put_env(:symphony_elixir, :main_ci_opts, github_repo: "acme/app", branch: "main", gh_runner: gh(ci))

      on_exit(fn ->
        Application.put_env(:symphony_elixir, :main_ci_opts, defaults)
        SymphonyElixir.RunStore.clear()
      end)

      %{ci: ci}
    end

    test "an epic whose base branch CI is still running is not dispatched; it is listed with the commit and the workflows, and the completion of CI frees it",
         %{ci: ci} do
      parent = epic(@designed_repo, state: "Epic Review")
      todo = %Issue{id: "issue-todo", identifier: "TP-900", title: "Plain", state: "Todo", repo_key: @designed_repo}

      assert [{^parent, @designed_repo}] = Orchestrator.hold_for_main_ci_for_test(state(), [parent, todo], :poll)

      next = Orchestrator.dispatch_chosen_issues_for_test([parent], state())
      refute Map.has_key?(next.running, @issue_id)
      assert %{reason: "Waiting for CI on main at b98572e58594: release, macos still running", rule: nil} = next.dispatch_skipped[@issue_id]
      refute Orchestrator.should_dispatch_issue_for_test(parent, state())

      # A run finishing while another is still going lifts nothing; the last one's completion does.
      assert SymphonyElixir.CiWait.finished(@sha) == []
      Agent.update(ci, fn _status -> "completed" end)
      assert SymphonyElixir.CiWait.finished(@sha) == [@issue_id]
      assert Orchestrator.should_dispatch_issue_for_test(parent, state())

      # The next check finds CI done and holds nothing.
      assert [{^parent, @designed_repo}] = Orchestrator.hold_for_main_ci_for_test(state(), [parent], :poll)
      assert Orchestrator.should_dispatch_issue_for_test(parent, state())
    end

    test "a retry of the epic review checks CI too; another ticket's retry does not" do
      parent = epic(@designed_repo, state: "Epic Review")
      todo = %Issue{id: "issue-todo", identifier: "TP-900", title: "Plain", state: "Todo", repo_key: @designed_repo}

      assert [{^parent, @designed_repo}] = Orchestrator.hold_for_main_ci_for_test(state(), [parent], {:active_retry, parent, 1, %{}})
      refute Orchestrator.should_dispatch_issue_for_test(parent, state())
      assert Orchestrator.hold_for_main_ci_for_test(state(), [todo], {:active_retry, todo, 1, %{}}) == []
    end
  end
end
