defmodule SymphonyElixir.QualityGate.QuestionTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{DecisionRequest, Pauses, Questions}
  alias SymphonyElixir.QualityGate.Question

  @issue_id "issue-gate-1"
  @ticket {:ticket, "repo-a", @issue_id}

  setup do
    :ok = RunStore.clear()
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        issue_id: @issue_id,
        identifier: "TP-77",
        state: "Todo",
        score: 5,
        pass_threshold: 6,
        reason: "The `export` step in lib/export.ex is vague",
        questions: ["What does done look like?", "Which file, `lib/export.ex` or another?", "What is out of scope"],
        rounds_asked: 1,
        max_rounds: 2
      },
      overrides
    )
  end

  test "the Question names the ticket and its round, carries the gate's questions in plain words and passes the writing standard" do
    attrs = Question.attrs(entry())

    assert attrs.title == "TP-77 needs answers before it starts (round 1 of 2)"
    assert attrs.question =~ "scored TP-77 5 out of 10, below the 6 it needs to start"
    assert attrs.question =~ "1) What does done look like? 2) Which file, a file or another? 3) What is out of scope"
    assert attrs.why =~ "found TP-77 unclear: The export step in a file is vague. Your answer"
    assert attrs.why =~ "A reply under the gate's comment on the ticket works too."
    assert [%{label: "Start it as it is", recommended: false}, %{label: "Move it to Backlog", recommended: true, move: %{to: "Backlog"}}] = attrs.options
    assert DecisionRequest.check(attrs) == :ok

    # A reason that already ends a sentence keeps it; a missing reason reads as nothing.
    assert Question.attrs(entry(%{reason: "Too vague."})).why =~ "unclear: Too vague. Your answer"
    assert Question.attrs(entry(%{reason: nil, identifier: nil})).title == "#{@issue_id} needs answers before it starts (round 1 of 2)"
  end

  test "sync asks the round's Question once, pausing the ticket on it, and a later round withdraws the earlier one" do
    assert :ok = Question.sync(@ticket, Question.questions(@ticket), entry())
    assert [%{step: "quality_gate", asked_by: %{kind: :rule, name: "Quality gate"}, asked_in: "Todo"} = first] = Questions.open(@ticket)
    assert Pauses.why(@ticket) == ["Waiting for your answer: TP-77 needs answers before it starts (round 1 of 2)"]

    # A poll that finds the same round asks nothing new.
    assert :ok = Question.sync(@ticket, Question.questions(@ticket), entry())
    assert [^first] = Questions.open(@ticket)

    assert :ok = Question.sync(@ticket, Question.questions(@ticket), entry(%{rounds_asked: 2}))
    assert [%{title: "TP-77 needs answers before it starts (round 2 of 2)"}] = Questions.open(@ticket)
    assert %{state: :withdrawn, withdrawn: %{reason: "The quality gate scored the ticket again, so these questions are no longer needed."}} = Questions.find(@ticket, first.id)
  end

  test "a scoring that ends the round withdraws the open gate Question and leaves other Questions alone" do
    :ok = Question.sync(@ticket, [], entry())

    {:ok, other} =
      Questions.ask(@ticket, %{
        title: "Ship TP-77 today",
        question: "Should TP-77 ship today?",
        why: "It is ready.",
        if_unanswered: "TP-77 waits.",
        recommendation_reason: "It is ready.",
        options: [%{label: "Ship", effect: "It ships.", recommended: true}, %{label: "Wait", effect: "It waits."}]
      })

    assert :ok = Question.sync(@ticket, Question.questions(@ticket), nil)
    assert [^other] = Questions.open(@ticket)
  end

  test "answers reads the answered gate Questions: own words, Start it as it is and Move it to Backlog" do
    :ok = Question.sync(@ticket, [], entry())
    [first] = Questions.open(@ticket)
    {:ok, _answered} = Questions.answer(@ticket, first.id, "Done means the nightly export runs.", at: ~U[2026-05-05 04:00:00Z])

    :ok = Question.sync(@ticket, Question.questions(@ticket), entry(%{rounds_asked: 2}))
    [second] = Questions.open(@ticket)
    {:ok, _answered} = Questions.answer(@ticket, second.id, "1", at: ~U[2026-05-05 05:00:00Z])

    assert [
             %{text: "Done means the nightly export runs.", option: nil, at: ~U[2026-05-05 04:00:00Z]},
             %{text: "1", option: :start, at: ~U[2026-05-05 05:00:00Z]}
           ] = Question.answers(Question.questions(@ticket))

    backlog = %{state: :answered, step: "quality_gate", options: Questions.find(@ticket, second.id).options, answer: %{text: "Move it to Backlog", option: 2, at: ~U[2026-05-05 06:00:00Z]}}
    other_option = %{backlog | options: [%{label: "Something else"}], answer: %{backlog.answer | option: 1}}
    assert [%{option: :backlog}, %{option: nil}] = Question.answers([backlog, other_option])
  end

  test "a ticket with no record has no Questions" do
    assert Question.questions({:ticket, "repo-a", "no-such-issue"}) == []
  end

  test "a store refusal is logged and asks nothing" do
    log =
      capture_log(fn ->
        assert :ok = Question.sync({:ticket, "repo-a", 123}, [], entry())
        assert :ok = Question.sync({:ticket, "repo-a", 123}, [%{id: "q-1", state: :open, step: "quality_gate", title: "Old round"}], nil)
      end)

    assert log =~ "QualityGate could not ask its clarification as a Question issue=TP-77"
    assert log =~ "QualityGate could not withdraw its Question q-1"
  end
end
