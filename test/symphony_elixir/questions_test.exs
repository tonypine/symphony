defmodule SymphonyElixir.QuestionsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, Questions, TicketState}

  @repo_key "repo-a"
  @issue_id "issue-1"
  @ticket {:ticket, @repo_key, @issue_id}
  @at ~U[2026-10-30 04:00:00Z]
  @later ~U[2026-10-30 05:00:00Z]
  @run %{kind: :run, name: "Implementation run 1", run_id: "run-1"}
  @tony %{kind: :person, name: "Tony"}
  @director %{kind: :person, name: "Director"}
  @symphony %{kind: :symphony, name: "Symphony"}
  @dependency %{kind: :ticket, waits_on: %{identifier: "TP-1194"}}

  @request %{
    title: "Ship TP-12 before the release",
    question: "Should TP-12 ship today, before the release goes out?",
    why: "TP-12 is ready. The release goes out tomorrow.",
    if_unanswered: "TP-12 waits and does not ship.",
    recommendation_reason: "Shipping today gives the release a day of use.",
    options: [
      %{
        label: "Ship today",
        effect: "TP-12 merges today.",
        recommended: true,
        tradeoffs: [%{kind: "good", text: "People get it a day early."}, %{kind: "risk", text: "Less time to try it."}]
      },
      %{label: "Wait for the release", effect: "TP-12 merges with the release.", tradeoffs: [%{kind: "cost", text: "A day later."}], unlocks: ["WORKFLOW.md"]},
      %{label: "Drop it", effect: "TP-12 is cancelled."}
    ]
  }

  setup do
    :ok = RunStore.clear()
  end

  defp ask!(title \\ @request.title) do
    {:ok, question} = Questions.ask(@ticket, %{@request | title: title}, asked_by: @run, at: @at)
    question
  end

  defp reasons, do: Enum.map(TicketState.pause_reasons(RunStore.get_ticket_state(@repo_key, @issue_id)), &{&1.kind, &1.waits_on})

  describe "ask/3" do
    test "asking a question puts it on the ticket and pauses the ticket on it, naming the question" do
      assert {:ok, question} = Questions.ask(@ticket, @request, asked_by: @run, step: "Plan the split", confirm: "Merging", at: @at)

      assert %{
               asked_by: @run,
               step: "Plan the split",
               title: "Ship TP-12 before the release",
               question: "Should TP-12 ship today, before the release goes out?",
               why: "TP-12 is ready. The release goes out tomorrow.",
               if_unanswered: "TP-12 waits and does not ship.",
               recommendation_reason: "Shipping today gives the release a day of use.",
               confirm: "Merging",
               state: :open,
               answer: nil,
               asked_at: @at,
               withdrawn: nil
             } = question

      assert [
               %{label: "Ship today", good: ["People get it a day early."], cost: [], risk: ["Less time to try it."], recommended?: true, unlocks: []},
               %{label: "Wait for the release", good: [], cost: ["A day later."], risk: [], recommended?: false, unlocks: ["WORKFLOW.md"]},
               %{label: "Drop it", effect: "TP-12 is cancelled.", recommended?: false}
             ] = question.options

      assert Questions.find(@ticket, question.id) == question
      assert Questions.open(@ticket) == [question]
      assert TicketState.open_questions(RunStore.get_ticket_state(@repo_key, @issue_id)) == [question]
      assert reasons() == [{:question, %{question_id: question.id}}]
      assert Pauses.why(@ticket) == ["Waiting for your answer: Ship TP-12 before the release"]
      assert {:ok, %{set_by: %{kind: :run, name: "Implementation run 1"}}} = Pauses.get(@ticket)

      assert [{"question.asked", asked}, {"pause.set", %{reason: "question", waits_on: waits_on}}] = ticket_events(@repo_key, @issue_id)
      assert waits_on == %{question_id: question.id}
      assert %{question_id: id, title: "Ship TP-12 before the release", confirm: "Merging", step: "Plan the split", asked_by: @run, options: [_, _, _]} = asked
      assert id == question.id

      assert [%{summary: %{title: "Asked you: Ship TP-12 before the release"}}] = RunStore.list_ticket_events(@repo_key, @issue_id, types: ["question.asked"])
    end

    test "Symphony asks by default, and a paused ticket gains the question as a further reason" do
      {:ok, _pause} = Pauses.set(@ticket, @dependency, at: @at)

      assert {:ok, %{asked_by: %{kind: :symphony, name: "Symphony", run_id: nil}, step: nil, confirm: nil} = question} = Questions.ask(@ticket, @request)
      assert reasons() == [{:ticket, %{identifier: "TP-1194"}}, {:question, %{question_id: question.id}}]
      assert ticket_events(@repo_key, @issue_id) |> Enum.map(&elem(&1, 0)) == ["pause.set", "question.asked", "pause.reason_added"]
    end

    test "the same open question asked twice is one question and records nothing the second time" do
      question = ask!()
      events = ticket_events(@repo_key, @issue_id)

      assert Questions.same_open?(@ticket, @request)
      assert Questions.same_open?(@ticket, %{@request | title: "  Ship TP-12   before the release "})
      refute Questions.same_open?(@ticket, %{@request | question: "Should TP-12 ship next week?"})

      assert Questions.ask(@ticket, %{@request | why: "Asked again with other words."}, asked_by: @tony, at: @later) == {:ok, question}
      assert Questions.open(@ticket) == [question]
      assert ticket_events(@repo_key, @issue_id) == events

      {:ok, _answered} = Questions.answer(@ticket, question.id, "1")
      refute Questions.same_open?(@ticket, @request)
      assert %{id: second} = ask!()
      assert second != question.id
      assert Enum.map(Questions.open(@ticket), & &1.id) == [second]
    end

    test "a question that misses the writing standard is refused with the reason, and nothing is recorded" do
      assert {:error, {:invalid_question, message}} = Questions.ask(@ticket, %{@request | why: "The `merge_queue` flag is off."})
      assert message =~ "why"
      assert message =~ "merge_queue"

      assert {:error, {:invalid_question, message}} = Questions.ask(@ticket, %{@request | options: [hd(@request.options)]})
      assert message =~ "`decision.options` must list 2 to 4 options"

      assert Questions.ask(@ticket, :junk) == {:error, {:invalid_question, :junk}}

      refute Pauses.paused?(@ticket)
      assert Questions.open(@ticket) == []
      assert ticket_events(@repo_key, @issue_id) == []
    end

    test "a malformed ticket, asker or time is refused" do
      assert Questions.ask({:ticket, " ", @issue_id}, @request) == {:error, {:invalid_subject, {:ticket, " ", @issue_id}}}
      assert Questions.ask(:symphony, @request) == {:error, {:invalid_subject, :symphony}}
      assert Questions.ask(@ticket, @request, asked_by: %{@run | run_id: 7}) == {:error, {:invalid_option, :asked_by}}
      assert Questions.ask(@ticket, @request, asked_by: %{kind: :robot, name: "R"}) == {:error, {:invalid_option, :asked_by}}
      assert Questions.ask(@ticket, @request, at: "now") == {:error, {:invalid_option, :at}}
      assert ticket_events(@repo_key, @issue_id) == []
    end
  end

  describe "answer/4" do
    test ~s("2", "option 2" and the second option's label all pick the second option) do
      for {answer, title} <- [{"2", "Ship TP-12 now"}, {"option 2", "Ship TP-12 soon"}, {" Option  2 ", "Ship TP-12 later"}, {"wait for  THE release", "Ship TP-12 at last"}] do
        question = ask!(title)

        assert {:ok, %{state: :answered, answer: answered}} = Questions.answer(@ticket, question.id, answer, at: @later)
        assert answered == %{text: answer, option: 2, by: @director, at: @later, scope: :ticket}

        assert [{"question.answered", %{option: "Wait for the release", option_number: 2, answer: ^answer, title: ^title}}] =
                 ticket_events(@repo_key, @issue_id, "question.answered") |> Enum.filter(&(elem(&1, 1).question_id == question.id))
      end
    end

    test "any other text is a free-text answer kept verbatim" do
      for {answer, title} <- [{"  Ship it, but tomorrow morning ", "Ship TP-12 now"}, {"4", "Ship TP-12 soon"}, {"option 0", "Ship TP-12 later"}] do
        question = ask!(title)

        assert {:ok, %{answer: %{text: ^answer, option: nil}}} = Questions.answer(@ticket, question.id, answer, by: @tony, scope: :always)
        assert %{answer: %{by: @tony, scope: :always}} = Questions.find(@ticket, question.id)
      end

      assert [{"question.answered", payload} | _rest] = ticket_events(@repo_key, @issue_id, "question.answered")
      assert payload == %{question_id: payload.question_id, title: "Ship TP-12 now", answer: "  Ship it, but tomorrow morning ", scope: "always", by: @tony}

      assert [%{summary: %{title: "You answered: Ship it, but tomorrow morning"}} | _rest] =
               RunStore.list_ticket_events(@repo_key, @issue_id, types: ["question.answered"])
    end

    test "answering clears the question's pause reason and only that one, and records the answer once" do
      question = ask!()
      {:ok, _pause} = Pauses.add_reason(@ticket, @dependency, at: @at)

      assert {:ok, answered} = Questions.answer(@ticket, question.id, "Ship today", by: @tony, at: @later)
      assert reasons() == [{:ticket, %{identifier: "TP-1194"}}]
      assert Questions.answered(@ticket) == [answered]
      assert Questions.open(@ticket) == []

      assert Questions.answer(@ticket, question.id, "2") == {:error, {:question_not_open, :answered}}
      assert [{"question.answered", %{option: "Ship today", by: @tony}}] = ticket_events(@repo_key, @issue_id, "question.answered")

      assert {"pause.reason_cleared", %{reason: "question", by: @tony}} = List.last(ticket_events(@repo_key, @issue_id))
    end

    test "the question's last reason cleared, the ticket moves again" do
      question = ask!()

      assert {:ok, _answered} = Questions.answer(@ticket, question.id, "1")
      refute Pauses.paused?(@ticket)
      assert {"pause.cleared", %{by: @director}} = List.last(ticket_events(@repo_key, @issue_id))
    end

    test "answering again after a failed clear clears the reason the answered question left behind" do
      question = ask!()
      {:ok, _pause} = Pauses.add_reason(@ticket, @dependency, at: @at)
      {:ok, _answered} = Questions.answer(@ticket, question.id, "1", at: @later)
      # The question's reason put back stands in for a clear that failed once the answer was stored.
      {:ok, _pause} = Pauses.add_reason(@ticket, %{kind: :question, waits_on: %{question_id: question.id}}, at: @later)

      assert Questions.answer(@ticket, question.id, "1", by: @tony, at: @later) == {:error, {:question_not_open, :answered}}
      assert reasons() == [{:ticket, %{identifier: "TP-1194"}}]
      assert [{"question.answered", %{option: "Ship today", by: @director}}] = ticket_events(@repo_key, @issue_id, "question.answered")
      assert {"pause.reason_cleared", %{reason: "question", by: @tony}} = List.last(ticket_events(@repo_key, @issue_id))
    end

    test "a blank answer, an unknown question, a malformed answerer, scope or time is refused" do
      question = ask!()

      assert Questions.answer(@ticket, question.id, "  ") == {:error, :blank_answer}
      assert Questions.answer(@ticket, question.id, nil) == {:error, :blank_answer}
      assert Questions.answer(@ticket, "q-nope", "1") == {:error, :question_not_found}
      assert Questions.answer(@ticket, question.id, "1", by: %{kind: :person, name: " "}) == {:error, {:invalid_actor, %{kind: :person, name: " "}}}
      assert Questions.answer(@ticket, question.id, "1", by: "Tony") == {:error, {:invalid_actor, "Tony"}}
      assert Questions.answer(@ticket, question.id, "1", scope: :forever) == {:error, {:invalid_option, {:scope, :forever}}}
      assert Questions.answer(@ticket, question.id, "1", at: :now) == {:error, {:invalid_option, :at}}
      assert Questions.answer({:ticket, @repo_key, 1}, question.id, "1") == {:error, {:invalid_subject, {:ticket, @repo_key, 1}}}

      assert Questions.open(@ticket) == [question]
      assert ticket_events(@repo_key, @issue_id, "question.answered") == []
    end
  end

  describe "withdraw/4" do
    test "a withdrawn question keeps its reason in history and clears its pause reason" do
      question = ask!()

      assert {:ok, %{state: :withdrawn, withdrawn: %{reason: "TP-12 was cancelled", at: @later}, answer: nil}} =
               Questions.withdraw(@ticket, question.id, "TP-12 was cancelled", at: @later)

      refute Pauses.paused?(@ticket)
      assert Questions.open(@ticket) == []
      assert Questions.answered(@ticket) == []
      assert %{state: :withdrawn, withdrawn: %{reason: "TP-12 was cancelled"}} = Questions.find(@ticket, question.id)

      assert [{"question.withdrawn", %{question_id: id, reason: "TP-12 was cancelled", title: "Ship TP-12 before the release", by: @symphony}}] =
               ticket_events(@repo_key, @issue_id, "question.withdrawn")

      assert id == question.id
      assert [%{summary: %{title: "Question withdrawn: TP-12 was cancelled"}}] = RunStore.list_ticket_events(@repo_key, @issue_id, types: ["question.withdrawn"])

      assert Questions.withdraw(@ticket, question.id, "Again") == {:error, {:question_not_open, :withdrawn}}
      assert Questions.answer(@ticket, question.id, "1") == {:error, {:question_not_open, :withdrawn}}
    end

    test "withdrawing again after a failed clear clears the reason the withdrawn question left behind" do
      question = ask!()
      {:ok, _withdrawn} = Questions.withdraw(@ticket, question.id, "TP-12 was cancelled", at: @later)
      # The question's reason put back stands in for a clear that failed once the withdrawal was stored.
      {:ok, _pause} = Pauses.set(@ticket, %{kind: :question, waits_on: %{question_id: question.id}}, at: @later)

      assert Questions.withdraw(@ticket, question.id, "TP-12 was cancelled", at: @later) == {:error, {:question_not_open, :withdrawn}}
      refute Pauses.paused?(@ticket)
      assert [{"question.withdrawn", %{reason: "TP-12 was cancelled"}}] = ticket_events(@repo_key, @issue_id, "question.withdrawn")
      assert {"pause.cleared", %{by: @symphony}} = List.last(ticket_events(@repo_key, @issue_id))
    end

    test "a blank reason, an unknown question, a malformed withdrawer or time is refused" do
      question = ask!()

      assert Questions.withdraw(@ticket, question.id, " ") == {:error, :blank_reason}
      assert Questions.withdraw(@ticket, "q-nope", "Gone") == {:error, :question_not_found}
      assert Questions.withdraw(@ticket, question.id, "Gone", by: %{kind: :robot, name: "R"}) == {:error, {:invalid_actor, %{kind: :robot, name: "R"}}}
      assert Questions.withdraw(@ticket, question.id, "Gone", at: 1) == {:error, {:invalid_option, :at}}
      assert Questions.withdraw(:symphony, question.id, "Gone") == {:error, {:invalid_subject, :symphony}}
      assert Questions.open(@ticket) == [question]
    end
  end

  describe "reads" do
    test "a ticket with no record, or a malformed ticket, has no questions" do
      assert Questions.open(@ticket) == []
      assert Questions.answered(@ticket) == []
      assert Questions.find(@ticket, "q-1") == nil
      refute Questions.same_open?(@ticket, @request)
      assert Questions.open(:junk) == []
    end

    test "the store refuses a question update for a malformed issue id" do
      unchanged = fn _questions -> {:ok, nil} end
      assert RunStore.update_ticket_question(@repo_key, nil, @at, unchanged) == {:error, :invalid_issue_id}
    end
  end
end
