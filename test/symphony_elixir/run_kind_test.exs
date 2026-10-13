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

  test "lists every kind, including the reserved pre-push reviewer and QA kinds" do
    assert RunKind.kinds() == [
             :implementation,
             :breakdown,
             :close_out,
             :final_verification,
             :rework,
             :landing,
             :code_review,
             :epic_review,
             :ci_fix,
             :review_feedback,
             :pre_push_review,
             :qa
           ]

    assert RunKind.names() == Enum.map(RunKind.kinds(), &Atom.to_string/1)
  end

  test "the moduledoc names exactly the reserved kinds as never returned by classify/2" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(RunKind)

    named = Enum.map_join(RunKind.reserved_kinds(), " and ", &"`#{&1}`")

    assert RunKind.reserved_kinds() == [:pre_push_review]
    assert doc =~ "#{named} is never returned by `classify/2`"
    assert doc =~ "`close_out` and `final_verification` are never returned either"
  end

  test "classify/2 can return every kind except the reserved and retired ones" do
    samples = [
      {:implementation, issue(), []},
      {:breakdown, breakdown_parent(sub_issues: []), []},
      {:rework, issue(state: "Rework"), []},
      {:landing, issue(state: "Merging"), []},
      {:code_review, issue(state: "Code Review"), []},
      {:epic_review, breakdown_parent(sub_issues: [%{id: "s1", identifier: "TP-2", state: "Done"}]), []},
      {:ci_fix, issue(), [ci_failure: %{check: "test"}]},
      {:review_feedback, issue(), [reviewer_comments: [%{body: "Rename this"}]]},
      {:qa, issue(state: "QA"), []}
    ]

    for {kind, sample, signals} <- samples do
      assert RunKind.classify(sample, signals) == kind
    end

    assert Enum.map(samples, &elem(&1, 0)) |> Enum.sort() ==
             Enum.sort(RunKind.kinds() -- (RunKind.reserved_kinds() ++ [:close_out, :final_verification]))
  end

  test "the retired final-verification title prefix is exposed, and recognised on a title" do
    assert RunKind.final_verification_prefix() == "Final verification:"
    assert RunKind.final_verification_title?(issue(title: "  Final verification: Run profiles"))
    refute RunKind.final_verification_title?(issue(title: "Plan the Final verification: later"))
    refute RunKind.final_verification_title?(issue(title: nil))
    refute RunKind.final_verification_title?(nil)
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

    test "a breakdown parent whose sub-issues are all terminal is its epic review" do
      parent =
        breakdown_parent(
          sub_issues: [
            %{id: "s1", identifier: "TP-2", state: "Done"},
            %{id: "s2", identifier: "TP-3", state: "Canceled"}
          ]
        )

      assert RunKind.classify(parent) == :epic_review
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

    test "the epic review uses the given terminal states" do
      parent = breakdown_parent(sub_issues: [%{id: "s1", identifier: "TP-2", state: "Shipped"}])

      assert RunKind.classify(parent) == :breakdown
      assert RunKind.classify(parent, terminal_states: ["Shipped"]) == :epic_review
    end

    test "a Final verification: title names no run kind of its own" do
      assert RunKind.classify(issue(title: "Final verification: Run profiles")) == :implementation
    end

    test "Merging is a landing run and Rework a rework run, whatever the case" do
      assert RunKind.classify(issue(state: "Merging")) == :landing
      assert RunKind.classify(issue(state: " merging ")) == :landing
      assert RunKind.classify(issue(state: "Rework")) == :rework
      assert RunKind.classify(issue(state: "REWORK")) == :rework
    end

    test "the Code Review state is a code review run, whatever the case" do
      assert RunKind.classify(issue(state: "Code Review")) == :code_review
      assert RunKind.classify(issue(state: " code review "), settings: %{}) == :code_review
    end

    test "the QA state is a QA run, whatever the case" do
      assert RunKind.classify(issue(state: "QA")) == :qa
      assert RunKind.classify(issue(state: " qa "), settings: %{}) == :qa
    end

    test "the Epic Review and CI Fix states are their own runs" do
      assert RunKind.classify(issue(state: "Epic Review")) == :epic_review
      assert RunKind.classify(issue(state: "CI Fix")) == :ci_fix
    end

    test "a repo's renamed Code Review state is still a code review run" do
      designed = %{tracker: %{code_review_state: "Peer Review"}}

      assert RunKind.classify(issue(state: "Peer Review"), settings: designed) == :code_review
      assert RunKind.classify(issue(state: " peer review "), settings: designed) == :code_review
      assert RunKind.classify(issue(state: "Code Review"), settings: designed) == :implementation
    end

    test "a repo's renamed QA state is still a QA run" do
      designed = %{tracker: %{qa_state: "Verification"}}

      assert RunKind.classify(issue(state: "Verification"), settings: designed) == :qa
      assert RunKind.classify(issue(state: " verification "), settings: designed) == :qa
      assert RunKind.classify(issue(state: "QA"), settings: designed) == :implementation
    end

    test "the other states keep their run kinds" do
      assert RunKind.classify(issue(state: "In Progress"), settings: %{}) == :implementation
      assert RunKind.classify(issue(state: "Merging"), settings: %{}) == :landing
    end

    test "a continuation after red CI is a CI fix run" do
      assert RunKind.classify(issue(), ci_failure: %{check: "test"}) == :ci_fix
    end

    test "a continuation after PR review comments is a review feedback run" do
      assert RunKind.classify(issue(), reviewer_comments: [%{body: "Rename this"}]) == :review_feedback
    end
  end

  describe "classify/2 precedence" do
    test "a breakdown parent in Merging is a parent run, not landing" do
      assert RunKind.classify(breakdown_parent(state: "Merging")) == :breakdown

      closed_out = breakdown_parent(state: "Merging", sub_issues: [%{id: "s1", identifier: "TP-2", state: "Done"}])
      assert RunKind.classify(closed_out) == :epic_review
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
