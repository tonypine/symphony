defmodule SymphonyElixir.RunKindTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunKind

  defp issue(attrs \\ []) do
    struct!(%Issue{id: "issue-1", identifier: "TP-1", title: "Add a thing", state: "In Progress", labels: []}, attrs)
  end

  defp breakdown_parent(attrs) do
    issue(Keyword.merge([labels: ["Breakdown"]], attrs))
  end

  test "lists every kind, including the reserved reviewer, QA and acceptance gate kinds" do
    assert RunKind.kinds() == [
             :implementation,
             :breakdown,
             :close_out,
             :final_verification,
             :rework,
             :landing,
             :ci_fix,
             :review_feedback,
             :pre_push_review,
             :qa,
             :acceptance_gate
           ]

    assert RunKind.names() == Enum.map(RunKind.kinds(), &Atom.to_string/1)
  end

  describe "classify/2" do
    test "defaults to implementation" do
      assert RunKind.classify(issue()) == :implementation
      assert RunKind.classify(issue(state: nil, title: nil)) == :implementation
      assert RunKind.classify(issue(), ci_failure: nil, reviewer_comments: []) == :implementation
    end

    test "a breakdown parent without sub-issues is a breakdown run" do
      assert RunKind.classify(breakdown_parent(sub_issues: [])) == :breakdown
    end

    test "a breakdown parent with open sub-issues stays a breakdown run" do
      parent = breakdown_parent(sub_issues: [%{id: "s1", identifier: "TP-2", state: "Todo"}])

      assert RunKind.classify(parent) == :breakdown
    end

    test "a breakdown parent whose sub-issues are all terminal is a close-out run" do
      parent =
        breakdown_parent(
          sub_issues: [
            %{id: "s1", identifier: "TP-2", state: "Done"},
            %{id: "s2", identifier: "TP-3", state: "Canceled"}
          ]
        )

      assert RunKind.classify(parent) == :close_out
    end

    test "a breakdown parent in Rework is a breakdown run, even with every sub-issue terminal" do
      cancelled = [%{id: "s1", identifier: "TP-2", state: "Canceled"}]
      backlog = [%{id: "s1", identifier: "TP-2", state: "Backlog"}]

      assert RunKind.classify(breakdown_parent(state: "Rework", sub_issues: cancelled)) == :breakdown
      assert RunKind.classify(breakdown_parent(state: " rework ", sub_issues: backlog)) == :breakdown
      assert RunKind.classify(issue(state: "Rework")) == :rework
      refute Issue.replanning?(breakdown_parent(state: nil))
      refute Issue.replanning?(nil)
    end

    test "close-out uses the given terminal states" do
      parent = breakdown_parent(sub_issues: [%{id: "s1", identifier: "TP-2", state: "Shipped"}])

      assert RunKind.classify(parent) == :breakdown
      assert RunKind.classify(parent, terminal_states: ["Shipped"]) == :close_out
    end

    test "a Final verification: title is a final verification run" do
      assert RunKind.classify(issue(title: "Final verification: Run profiles")) == :final_verification
      assert RunKind.classify(issue(title: "  Final verification: Run profiles")) == :final_verification
      assert RunKind.classify(issue(title: "Plan the Final verification: later")) == :implementation
    end

    test "Merging is a landing run and Rework a rework run, whatever the case" do
      assert RunKind.classify(issue(state: "Merging")) == :landing
      assert RunKind.classify(issue(state: " merging ")) == :landing
      assert RunKind.classify(issue(state: "Rework")) == :rework
      assert RunKind.classify(issue(state: "REWORK")) == :rework
    end

    test "a continuation after red CI is a CI fix run" do
      assert RunKind.classify(issue(), ci_failure: %{check: "test"}) == :ci_fix
    end

    test "a continuation after PR review comments is a review feedback run" do
      assert RunKind.classify(issue(), reviewer_comments: [%{body: "Rename this"}]) == :review_feedback
    end
  end

  describe "classify/2 precedence" do
    test "a Final verification: ticket in Rework is still a final verification run" do
      assert RunKind.classify(issue(title: "Final verification: X", state: "Rework")) == :final_verification
    end

    test "a Final verification: ticket with the breakdown label is a final verification run" do
      assert RunKind.classify(breakdown_parent(title: "Final verification: X")) == :final_verification
    end

    test "a breakdown parent in Merging is a parent run, not landing" do
      assert RunKind.classify(breakdown_parent(state: "Merging")) == :breakdown

      closed_out = breakdown_parent(state: "Merging", sub_issues: [%{id: "s1", identifier: "TP-2", state: "Done"}])
      assert RunKind.classify(closed_out) == :close_out
    end

    test "a breakdown parent in Rework is a breakdown run" do
      assert RunKind.classify(breakdown_parent(state: "Rework")) == :breakdown
    end

    test "Merging wins over red CI and review comments" do
      assert RunKind.classify(issue(state: "Merging"), ci_failure: %{}, reviewer_comments: [%{}]) == :landing
    end

    test "Rework wins over red CI and review comments" do
      assert RunKind.classify(issue(state: "Rework"), ci_failure: %{}, reviewer_comments: [%{}]) == :rework
    end

    test "red CI wins over review comments" do
      assert RunKind.classify(issue(), ci_failure: %{}, reviewer_comments: [%{}]) == :ci_fix
    end
  end
end
