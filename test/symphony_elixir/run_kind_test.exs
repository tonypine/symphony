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
  end

  test "classify/2 can return every kind except the reserved ones" do
    designed = %{state_machine: "designed"}

    samples = [
      {:implementation, issue(), []},
      {:breakdown, breakdown_parent(sub_issues: []), []},
      {:close_out, breakdown_parent(sub_issues: [%{id: "s1", identifier: "TP-2", state: "Done"}]), []},
      {:final_verification, issue(title: "Final verification: run profiles"), []},
      {:rework, issue(state: "Rework"), []},
      {:landing, issue(state: "Merging"), []},
      {:code_review, issue(state: "Code Review"), [settings: designed]},
      {:epic_review, breakdown_parent(sub_issues: [%{id: "s1", identifier: "TP-2", state: "Done"}]), [settings: designed]},
      {:ci_fix, issue(), [ci_failure: %{check: "test"}]},
      {:review_feedback, issue(), [reviewer_comments: [%{body: "Rename this"}]]},
      {:qa, issue(state: "QA"), [settings: designed]}
    ]

    for {kind, sample, signals} <- samples do
      assert RunKind.classify(sample, signals) == kind
    end

    assert Enum.map(samples, &elem(&1, 0)) |> Enum.sort() ==
             Enum.sort(RunKind.kinds() -- RunKind.reserved_kinds())
  end

  test "the final-verification title prefix is exposed for callers that build the title" do
    assert RunKind.final_verification_prefix() == "Final verification:"
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

    test "the designed machine's Code Review state is a code review run, whatever the case" do
      designed = %{state_machine: "designed"}

      assert RunKind.classify(issue(state: "Code Review"), settings: designed) == :code_review
      assert RunKind.classify(issue(state: " code review "), settings: designed) == :code_review
    end

    test "the designed machine's QA state is a QA run, whatever the case" do
      designed = %{state_machine: "designed"}

      assert RunKind.classify(issue(state: "QA"), settings: designed) == :qa
      assert RunKind.classify(issue(state: " qa "), settings: designed) == :qa
    end

    test "a designed repo's renamed Code Review state is still a code review run" do
      designed = %{state_machine: "designed", tracker: %{code_review_state: "Peer Review"}}

      assert RunKind.classify(issue(state: "Peer Review"), settings: designed) == :code_review
      assert RunKind.classify(issue(state: " peer review "), settings: designed) == :code_review
      assert RunKind.classify(issue(state: "Code Review"), settings: designed) == :implementation
    end

    test "a designed repo's renamed QA state is still a QA run" do
      designed = %{state_machine: "designed", tracker: %{qa_state: "Verification"}}

      assert RunKind.classify(issue(state: "Verification"), settings: designed) == :qa
      assert RunKind.classify(issue(state: " verification "), settings: designed) == :qa
      assert RunKind.classify(issue(state: "QA"), settings: designed) == :implementation
    end

    test "a designed repo's other states keep the run kind they had" do
      designed = %{state_machine: "designed"}

      assert RunKind.classify(issue(state: "In Progress"), settings: designed) == :implementation
      assert RunKind.classify(issue(state: "Merging"), settings: designed) == :landing
    end

    test "a legacy repo's QA state keeps the run kind it had before" do
      legacy = %{state_machine: "legacy"}
      qa_state = issue(state: "QA")

      assert RunKind.classify(qa_state) == :implementation
      assert RunKind.classify(qa_state, settings: legacy) == :implementation
      assert RunKind.classify(qa_state, settings: legacy, ci_failure: %{check: "test"}) == :ci_fix
    end

    test "a legacy repo's Code Review state keeps the run kind it had before" do
      legacy = %{state_machine: "legacy"}
      in_review = issue(state: "Code Review")

      assert RunKind.classify(in_review) == :implementation
      assert RunKind.classify(in_review, settings: legacy) == :implementation
      assert RunKind.classify(in_review, settings: legacy, ci_failure: %{check: "test"}) == :ci_fix
      assert RunKind.classify(in_review, settings: legacy, reviewer_comments: [%{body: "Rename this"}]) == :review_feedback
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
