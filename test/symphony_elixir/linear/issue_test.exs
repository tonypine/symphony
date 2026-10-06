defmodule SymphonyElixir.Linear.IssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue

  @terminal ["Done", "Canceled"]

  defp parent(label, attrs) do
    struct!(%Issue{id: "p", identifier: "MT-1", title: "Parent", state: "In Progress", labels: [label]}, attrs)
  end

  describe "breakdown_label?/1" do
    test "accepts `plan` and `breakdown`, its older name, ignoring case and surrounding spaces" do
      for label <- ["plan", "Plan", " PLAN ", "breakdown", "Breakdown", " BREAKDOWN "] do
        assert Issue.breakdown_label?(label), "expected #{inspect(label)} to mark a plan parent"
      end

      for label <- ["planning", "plans", "feature", "", nil, :plan] do
        refute Issue.breakdown_label?(label)
      end
    end
  end

  describe "a `plan` parent goes through the same steps as a `breakdown` one" do
    for label <- ["plan", "breakdown"] do
      test "#{label}: plan run, plan review, approval and close-out" do
        label = unquote(label)
        backlog = [%{id: "c1", identifier: "MT-2", state: "Backlog"}, %{id: "c2", identifier: "MT-3", state: "Backlog"}]
        approved = [%{id: "c1", identifier: "MT-2", state: "Todo"}, %{id: "c2", identifier: "MT-3", state: "Backlog"}]
        finished = [%{id: "c1", identifier: "MT-2", state: "Done"}, %{id: "c2", identifier: "MT-3", state: "Canceled"}]

        # New plan: no sub-issues yet.
        new_plan = parent(label, sub_issues: [])
        assert Issue.breakdown?(new_plan)
        refute Issue.unapproved_plan?(new_plan, @terminal)
        refute Issue.waiting_on_sub_issues?(new_plan, @terminal)
        refute Issue.close_out_ready?(new_plan, @terminal)

        # Plan under review: every sub-issue still in Backlog.
        under_review = parent(label, state: "In Review", sub_issues: backlog)
        assert Issue.unapproved_plan?(under_review, @terminal)
        refute Issue.waiting_on_sub_issues?(under_review, @terminal)

        # Approved: a sub-issue left Backlog, so the parent waits.
        waiting = parent(label, state: "Waiting on sub-tickets", sub_issues: approved)
        refute Issue.unapproved_plan?(waiting, @terminal)
        assert Issue.waiting_on_sub_issues?(waiting, @terminal)
        refute Issue.close_out_ready?(waiting, @terminal)

        # Close-out: every sub-issue terminal.
        assert Issue.close_out_ready?(parent(label, state: "Waiting on sub-tickets", sub_issues: finished), @terminal)

        # Re-plan: a human rejected the plan.
        assert Issue.replanning?(parent(label, state: "Rework", sub_issues: approved))
      end
    end

    test "anything but an issue is no parent" do
      refute Issue.breakdown?(nil)
      refute Issue.waiting_on_sub_issues?(nil, @terminal)
      refute Issue.unapproved_plan?(nil, @terminal)
      refute Issue.close_out_ready?(nil, @terminal)
      refute Issue.forced?(nil, nil)
      assert Issue.open_blockers(nil, @terminal) == []
      assert Issue.open_sub_issues(nil, @terminal) == []
    end

    test "a ticket with neither label is no parent" do
      issue = parent("feature", sub_issues: [%{id: "c1", identifier: "MT-2", state: "Todo"}])

      refute Issue.breakdown?(issue)
      refute Issue.waiting_on_sub_issues?(issue, @terminal)
      refute Issue.replanning?(%{issue | state: "Rework"})
    end
  end
end
