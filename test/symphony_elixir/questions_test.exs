defmodule SymphonyElixir.QuestionsTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Hold, Pauses, Questions, TicketState}
  alias SymphonyElixir.TicketEvents.Brief

  defmodule UnclearableStore do
    def get_ticket_state(repo_key, issue_id), do: SymphonyElixir.RunStore.get_ticket_state(repo_key, issue_id)
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
  end

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
      assert %{request: false, asked_in: nil, unblocks: nil} = question

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

  describe "ask/3 for the backfill" do
    test "an answered question keeps its id, answer and legacy event, pauses nothing, and is recorded once" do
      answer = %{text: "Yes", option: nil, by: @director, at: @at, scope: :ticket}
      request = %{title: "Old title", question: "Old question?", why: "", if_unanswered: "", recommendation_reason: "", options: []}
      opts = [backfilled: true, id: "backfill-1", answer: answer, legacy_event: "event-1", at: @at]

      assert {:ok, %{id: "backfill-1", state: :answered, answer: ^answer, legacy_event: "event-1"}} = Questions.ask(@ticket, request, opts)
      assert {:ok, %{id: "backfill-1"}} = Questions.ask(@ticket, %{request | title: "Other"}, opts)

      assert Questions.answered(@ticket) |> Enum.map(& &1.id) == ["backfill-1"]
      assert reasons() == []

      assert [%{type: "question.asked", idempotency: "backfill:question.asked:backfill-1", payload: payload}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, [])

      assert %{source: "backfill", title: "Old title"} = payload
      refute Map.has_key?(payload, :why)
    end

    test "an open one skips the standard, pauses the ticket on it and marks both events as the backfill's" do
      request = %{@request | why: "Uses `code` words", options: []}

      assert {:ok, %{id: "backfill-2", state: :open, legacy_event: nil}} = Questions.ask(@ticket, request, backfilled: true, id: "backfill-2", at: @at)
      assert reasons() == [{:question, %{question_id: "backfill-2"}}]

      assert [%{type: "question.asked", payload: %{source: "backfill"}}, %{type: "pause.set", payload: %{source: "backfill"}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, [])

      assert {:error, {:invalid_question, _message}} = Questions.ask(@ticket, request, at: @at)
      assert {:error, {:invalid_question, :junk}} = Questions.ask(@ticket, :junk, backfilled: true)
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

    test "a question whose reason something else cleared is answered with no pause change" do
      question = ask!()
      {:ok, nil} = Pauses.clear(@ticket, at: @at)
      events = ticket_events(@repo_key, @issue_id)

      assert {:ok, %{state: :answered}} = Questions.answer(@ticket, question.id, "1", at: @later)
      refute Pauses.paused?(@ticket)
      assert [{"question.answered", %{option: "Ship today"}}] = ticket_events(@repo_key, @issue_id) -- events
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

    test "a blank reason, an unknown question, a malformed withdrawer or time is refused" do
      question = ask!()

      assert Questions.withdraw(@ticket, question.id, " ") == {:error, :blank_reason}
      assert Questions.withdraw(@ticket, "q-nope", "Gone") == {:error, :question_not_found}
      assert Questions.withdraw(@ticket, question.id, "Gone", by: %{kind: :robot, name: "R"}) == {:error, {:invalid_actor, %{kind: :robot, name: "R"}}}
      assert Questions.withdraw(@ticket, question.id, "Gone", at: 1) == {:error, {:invalid_option, :at}}
      assert Questions.withdraw(@ticket, question.id, "Gone", cause: "bored") == {:error, {:invalid_option, {:cause, "bored"}}}
      assert Questions.withdraw(:symphony, question.id, "Gone") == {:error, {:invalid_subject, :symphony}}
      assert Questions.open(@ticket) == [question]
    end
  end

  describe "lapsed?/2 and withdraw_lapsed/3" do
    defmodule Replies do
      def create_reply(issue_id, comment_id, body) do
        send(self(), {:reply, issue_id, comment_id, body})
        Application.get_env(:symphony_elixir, :questions_test_reply, :ok)
      end
    end

    @inbox :questions_test_inbox
    @run_started ~U[2026-10-30 03:30:00Z]
    @run_ended ~U[2026-10-30 04:30:00Z]

    setup do
      on_exit(fn ->
        :persistent_term.erase({SymphonyElixir.Inbox, :items, @inbox})
        Application.delete_env(:symphony_elixir, :questions_test_reply)
      end)
    end

    defp ask_as!(asked_by, title, opts \\ []) do
      {:ok, question} = Questions.ask(@ticket, %{@request | title: title}, [asked_by: asked_by, at: @at] ++ opts)
      question
    end

    defp run_end(fields), do: {:run_ended, Map.merge(%{run_id: "run-1", started_at: @run_started, ended_at: @run_ended, moved_to: "Rework"}, Map.new(fields))}

    test "the rule table: what each ending withdraws" do
      run_asked = ask_as!(%{kind: :run, name: "The run"}, "Pick a layout")
      named_run = ask_as!(@run, "Pick a colour")
      confirmation = ask_as!(@symphony, "Merge TP-12", confirm: "Merging")
      rule_asked = ask_as!(%{kind: :rule, name: "Protected files"}, "Allow the settings file")

      for question <- [run_asked, named_run, confirmation, rule_asked] do
        assert Questions.lapsed?(question, :restart)
        assert Questions.lapsed?(question, :merged)
        assert Questions.lapsed?(question, {:terminal, "Canceled"})
        refute Questions.lapsed?(%{question | state: :answered}, :merged)
      end

      assert Questions.lapsed?(run_asked, :backlog)
      refute Questions.lapsed?(confirmation, :backlog)

      # A run ending withdraws only what it asked, once the ticket moved on.
      assert Questions.lapsed?(run_asked, run_end([]))
      assert Questions.lapsed?(named_run, run_end([]))
      refute Questions.lapsed?(named_run, run_end(run_id: "run-2"))
      refute Questions.lapsed?(run_asked, run_end(moved_to: nil))
      refute Questions.lapsed?(run_asked, run_end(started_at: @later, ended_at: ~U[2026-10-30 06:00:00Z]))
      refute Questions.lapsed?(run_asked, run_end(started_at: nil))
      refute Questions.lapsed?(confirmation, run_end([]))
      refute Questions.lapsed?(rule_asked, run_end([]))
    end

    test "a Restart withdraws a run-asked question with its reason: the pause and the hold clear, and its request is answered" do
      question = ask_as!(%{kind: :run, name: "The run"}, "Pick a layout")
      attrs = %{reason: "Pick a layout", decision: %{title: "Pick a layout", question: question.question, question_id: question.id}}
      :ok = Hold.set(@repo_key, @issue_id, :needs_decision, attrs)
      :persistent_term.put({SymphonyElixir.Inbox, :items, @inbox}, [%{issue_id: @issue_id, review: %{comment_id: "comment-1", question_id: question.id}}])

      assert {:ok, [%{id: id, state: :withdrawn}]} =
               Questions.withdraw_lapsed(@ticket, :restart, inbox: @inbox, replies: Replies)

      assert id == question.id

      assert %{state: :withdrawn, withdrawn: %{reason: "The run that asked was restarted."}} = Questions.find(@ticket, id)
      refute Pauses.paused?(@ticket)
      refute Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert_received {:reply, @issue_id, "comment-1", "## Action withdrawn\n\nThe run that asked was restarted."}

      assert [%{summary: %{title: "Question withdrawn: The run that asked was restarted."}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, types: ["question.withdrawn"])

      # The prompt brief lists it as withdrawn, never as open.
      assert {:ok, %{text: brief}} = Brief.render(@repo_key, @issue_id)
      assert brief =~ "Withdrawn"
      refute brief =~ "Open: it waits"

      # Nothing left to withdraw.
      assert Questions.withdraw_lapsed(@ticket, :restart, inbox: @inbox, replies: Replies) == {:ok, []}
    end

    test "a question a request comment shows keeps what its comment names; the backfill's says nothing (TP-1252)" do
      request = Map.put(@request, :unblocks, "the  release\nnotes")
      {:ok, question} = Questions.ask(@ticket, request, request: true, asked_in: "Code Review", at: @at)
      assert %{request: true, asked_in: "Code Review", unblocks: "the release notes"} = question

      {:ok, backfilled} = Questions.ask(@ticket, %{request | title: "Old"}, backfilled: true, id: "q-old", request: true, at: @at)
      assert backfilled.request == nil
    end

    test "while the pause projector owns the replies, a withdrawal posts none itself (TP-1252)" do
      Application.put_env(:symphony_elixir, :pause_projector, true)
      on_exit(fn -> Application.put_env(:symphony_elixir, :pause_projector, false) end)
      question = ask_as!(@symphony, "Merge TP-12", confirm: "Merging")
      :persistent_term.put({SymphonyElixir.Inbox, :items, @inbox}, [%{issue_id: @issue_id, review: %{comment_id: "c-9", question_id: question.id}}])

      assert {:ok, [_withdrawn]} = Questions.withdraw_lapsed(@ticket, :merged, inbox: @inbox, replies: Replies)
      refute_received {:reply, _issue_id, _comment_id, _body}
      assert %{state: :withdrawn} = Questions.find(@ticket, question.id)
    end

    test "a merge settled withdraws a merge confirmation that was never answered; a refused reply is only logged" do
      Application.put_env(:symphony_elixir, :questions_test_reply, {:error, :linear_down})
      question = ask_as!(@symphony, "Merge TP-12", confirm: "Merging")
      :persistent_term.put({SymphonyElixir.Inbox, :items, @inbox}, [%{issue_id: "other"}, %{issue_id: @issue_id, review: %{decisions: [%{comment_id: "c-9", question_id: question.id}]}}])

      log =
        capture_log(fn ->
          assert {:ok, [_withdrawn]} = Questions.withdraw_lapsed(@ticket, :merged, inbox: @inbox, replies: Replies)
        end)

      assert log =~ "Linear refused its withdrawal reply"
      assert_received {:reply, @issue_id, "c-9", "## Action withdrawn\n\nThe pull request merged before you answered."}
      assert %{state: :withdrawn} = Questions.find(@ticket, question.id)
    end

    test "a question about the ticket itself survives its run ending; the run's own question goes once the ticket moved on" do
      confirmation = ask_as!(@symphony, "Merge TP-12", confirm: "Merging")
      rule_asked = ask_as!(%{kind: :rule, name: "Protected files"}, "Allow the settings file")
      run_asked = ask_as!(@run, "Pick a colour")

      assert {:ok, []} = Questions.withdraw_lapsed(@ticket, run_end(moved_to: nil), inbox: @inbox)
      assert {:ok, [%{id: id}]} = Questions.withdraw_lapsed(@ticket, run_end([]), inbox: @inbox)
      assert id == run_asked.id
      assert %{withdrawn: %{reason: "The run that asked ended and the ticket moved on to Rework."}} = Questions.find(@ticket, id)
      assert Enum.map(Questions.open(@ticket), & &1.id) == [confirmation.id, rule_asked.id]

      # A move to Backlog leaves them too; a cancelled ticket withdraws them.
      assert {:ok, []} = Questions.withdraw_lapsed(@ticket, :backlog, inbox: @inbox)
      assert {:ok, [_, _]} = Questions.withdraw_lapsed(@ticket, {:terminal, "Canceled"}, inbox: @inbox)
      assert %{withdrawn: %{reason: "The ticket was cancelled."}} = Questions.find(@ticket, confirmation.id)
    end

    test "a question a Blocked hold waits on ends with its hold, but a terminal state withdraws it and clears the hold" do
      question = ask_as!(@run, "The run cannot continue")
      :ok = Hold.set(@repo_key, @issue_id, :blocked, %{reason: "the run reported a block", waits_on: %{type: "access", keys: [], question_id: question.id}})

      assert {:ok, []} = Questions.withdraw_lapsed(@ticket, :restart, inbox: @inbox)
      assert Hold.held?(@repo_key, @issue_id, :blocked)

      assert {:ok, [_withdrawn]} = Questions.withdraw_lapsed(@ticket, {:terminal, "Done"}, inbox: @inbox)
      assert %{withdrawn: %{reason: "The ticket moved to Done before you answered."}} = Questions.find(@ticket, question.id)
      refute Hold.held?(@repo_key, @issue_id, :blocked)
    end

    test "a question that holds the ticket outlives its run ending; a Restart withdraws it with its cause (TP-1321)" do
      # A protected-path request the run asked through the Inbox path: a request comment shows it.
      request = ask_as!(@run, "Allow the workflow file", request: true, asked_in: "In Progress")
      # A run's question a Needs Decision hold carries, without a request comment.
      held = ask_as!(@run, "Pick a colour")
      :ok = Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: "Pick a colour", decision: %{title: "Pick a colour", question_id: held.id}})

      refute Questions.lapsed?(request, run_end([]))
      assert {:ok, []} = Questions.withdraw_lapsed(@ticket, run_end(moved_to: "In Progress"), inbox: @inbox)
      assert {:ok, []} = Questions.withdraw_lapsed(@ticket, run_end(run_id: "run-2", moved_to: "Code Review"), inbox: @inbox)
      assert Enum.map(Questions.open(@ticket), & &1.id) == [request.id, held.id]
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)

      assert {:ok, [_, _]} = Questions.withdraw_lapsed(@ticket, :restart, inbox: @inbox)

      assert [%{payload: %{cause: "restarted"}}, %{payload: %{cause: "restarted"}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, types: ["question.withdrawn"])
    end

    test "each withdrawal records why: the ticket moved, or the run that asked ended (TP-1321)" do
      moved = ask_as!(@run, "Pick a layout")
      assert {:ok, [_withdrawn]} = Questions.withdraw_lapsed(@ticket, :backlog, inbox: @inbox)
      ended = ask_as!(@run, "Pick a colour")
      assert {:ok, [_withdrawn]} = Questions.withdraw_lapsed(@ticket, run_end([]), inbox: @inbox)

      causes = for e <- RunStore.list_ticket_events(@repo_key, @issue_id, types: ["question.withdrawn"]), do: {e.payload.question_id, e.payload.cause}
      assert causes == [{moved.id, "ticket_moved"}, {ended.id, "run_ended"}]
    end

    test "a hold that won't clear is logged, and a malformed ticket withdraws nothing" do
      question = ask_as!(%{kind: :run, name: "The run"}, "Pick a layout")
      :ok = Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: "Pick a layout", decision: %{title: "Pick a layout", question_id: question.id}})

      log =
        capture_log(fn ->
          assert {:ok, [_withdrawn]} =
                   Questions.withdraw_lapsed(@ticket, :restart, store: UnclearableStore, inbox: @inbox)
        end)

      assert log =~ "its needs_decision hold did not clear"
      assert Questions.withdraw_lapsed(:junk, :restart) == {:ok, []}
    end
  end

  describe "reopen/3" do
    @reopened ~U[2026-10-30 05:00:05Z]

    test "the Director's Undo takes an answer back: the question is open again and pauses the ticket on it" do
      question = ask!()
      {:ok, _answered} = Questions.answer(@ticket, question.id, "1", at: @later)
      refute Pauses.paused?(@ticket)

      assert {:ok, %{state: :open, answer: nil, reopened_at: @reopened, taken_back: ["1"]}} = Questions.reopen(@ticket, question.id, at: @reopened)
      assert reasons() == [{:question, %{question_id: question.id}}]
      assert [%{id: id}] = Questions.open(@ticket)
      assert id == question.id

      assert [{"question.reopened", %{question_id: ^id, title: "Ship TP-12 before the release", by: @director}}] = ticket_events(@repo_key, @issue_id, "question.reopened")
      assert [%{summary: %{title: "You took back your answer: Ship TP-12 before the release"}}] = RunStore.list_ticket_events(@repo_key, @issue_id, types: ["question.reopened"])

      # Answered again, the answer is a second `question.answered`, and reopened again, a second reopen.
      assert {:ok, %{state: :answered, answer: %{option: 2}}} = Questions.answer(@ticket, id, "2", at: ~U[2026-10-30 05:00:09Z])
      assert [_first, _second] = ticket_events(@repo_key, @issue_id, "question.answered")
      assert {:ok, %{state: :open, taken_back: ["1", "2"]}} = Questions.reopen(@ticket, id, at: ~U[2026-10-30 05:00:12Z])
      assert [_first_reopen, _second_reopen] = ticket_events(@repo_key, @issue_id, "question.reopened")
    end

    test "only an answered question is reopened" do
      question = ask!()

      assert Questions.reopen(@ticket, question.id) == {:error, {:question_not_answered, :open}}
      assert Questions.reopen(@ticket, "q-nope") == {:error, :question_not_found}
      assert Questions.reopen(@ticket, question.id, by: %{kind: :robot, name: "R"}) == {:error, {:invalid_actor, %{kind: :robot, name: "R"}}}
      assert Questions.reopen(@ticket, question.id, at: 1) == {:error, {:invalid_option, :at}}
      assert Questions.reopen(:symphony, question.id) == {:error, {:invalid_subject, :symphony}}
    end
  end

  describe "answers/2" do
    test "an answered question reads in place of the decision recording it, and before it is recorded at the end" do
      answered = ask!()
      {:ok, answered} = Questions.answer(@ticket, answered.id, "Wait for the release", at: @later)
      unrecorded = ask!("Rename the release")
      {:ok, unrecorded} = Questions.answer(@ticket, unrecorded.id, "Spring", at: @later)
      open = ask!("Pick a name")

      legacy = [
        %{key: "c0", title: "Ship TP-12 before the release", answer: "Ship today"},
        %{key: "c1", title: "ship tp-12   before the release", answer: "wait for the"},
        %{key: "c2", title: "Pick a name", answer: "Autumn"},
        %{key: "c3", answer: "?"}
      ]

      assert [
               %{key: "c0"},
               %{key: key, date: ~D[2026-10-30], title: "Ship TP-12 before the release", answer: "Wait for the release"},
               %{key: "c2"},
               %{key: "c3"},
               %{key: last, answer: "Spring"}
             ] = Questions.answers(legacy, [answered, unrecorded, open])

      assert {key, last} == {answered.id, unrecorded.id}
      assert Questions.answers([%{title: "Rename the release", answer: ""}], [unrecorded]) |> length() == 2
      assert Questions.answers([], []) == []
    end

    test "a decision recording an answer the Director took back reads as nothing, whether the question is open again or answered anew" do
      question = ask!()
      {:ok, _answered} = Questions.answer(@ticket, question.id, "Ship today", at: @later)
      {:ok, reopened} = Questions.reopen(@ticket, question.id, at: ~U[2026-10-30 05:00:05Z])

      recorded = %{key: "c0", title: "Ship TP-12 before the release", answer: "Ship today"}
      asked_again = %{key: "c1", title: "Ship TP-12 before the release", answer: "Ship today"}
      other = %{key: "c2", title: "Pick a name", answer: "Autumn"}

      # Open again: the taken-back answer's decision is gone, once; the same answer recorded again
      # (the question asked a second time) and any other decision still read.
      assert Questions.answers([recorded, other], [reopened]) == [other]
      assert Questions.answers([recorded, asked_again], [reopened]) == [asked_again]

      # Stored before Undo: a question with no taken-back answers drops nothing.
      assert Questions.answers([recorded], [Map.delete(reopened, :taken_back)]) == [recorded]

      # Answered anew: the new answer reads, the decision of the old one doesn't.
      {:ok, answered} = Questions.answer(@ticket, question.id, "Wait for the release", at: ~U[2026-10-30 05:00:09Z])
      assert [%{key: key, answer: "Wait for the release"}] = Questions.answers([recorded], [answered])
      assert key == question.id

      # Answered anew with the same words: the one decision reads as the answer.
      {:ok, _reopened} = Questions.reopen(@ticket, question.id, at: ~U[2026-10-30 05:00:12Z])
      {:ok, same} = Questions.answer(@ticket, question.id, "Ship today", at: ~U[2026-10-30 05:00:15Z])
      assert [%{key: ^key, answer: "Ship today"}] = Questions.answers([recorded], [same])
    end
  end

  describe "one step" do
    test "the ticket is paused on exactly its open questions, whatever asks, answers and withdraws at once" do
      first = ask!()
      second = ask!("Ship TP-12 at last")
      {:ok, _pause} = Pauses.add_reason(@ticket, @dependency, at: @at)

      # The same question asked again while one answer and one withdrawal land: each ask returns the
      # open question or, once the first is answered, asks it anew.
      writes =
        [{:answer, first.id}, {:withdraw, second.id}] ++ for(n <- 1..8, do: {:ask, n})

      writes
      |> Task.async_stream(
        fn
          {:answer, id} -> Questions.answer(@ticket, id, "2")
          {:withdraw, id} -> Questions.withdraw(@ticket, id, "TP-12 was cancelled")
          {:ask, _n} -> Questions.ask(@ticket, @request)
        end,
        max_concurrency: length(writes),
        ordered: false
      )
      |> Enum.each(fn {:ok, result} -> assert {:ok, _question} = result end)

      open = Questions.open(@ticket)
      assert length(open) <= 1
      assert reasons() == [{:ticket, %{identifier: "TP-1194"}} | Enum.map(open, &{:question, %{question_id: &1.id}})]
      record = RunStore.get_ticket_state(@repo_key, @issue_id)
      assert [%{state: :answered}, %{state: :withdrawn} | _asked_anew] = record.questions
    end

    test "asking an open question again writes nothing, so it never puts back a reason cleared since" do
      question = ask!()
      # The pause cleared stands in for an answer's clear landing between the repeated ask's read and
      # any write it would make after it.
      {:ok, nil} = Pauses.clear(@ticket, at: @at)
      events = ticket_events(@repo_key, @issue_id)

      assert Questions.ask(@ticket, @request, at: @later) == {:ok, question}
      refute Pauses.paused?(@ticket)
      assert ticket_events(@repo_key, @issue_id) == events
    end

    test "the store writes a question with its pause and their events together, or nothing" do
      question = ask!()
      record = RunStore.get_ticket_state(@repo_key, @issue_id)
      events = ticket_events(@repo_key, @issue_id)

      refuse = fn [^question], %{reasons: [%{kind: :question}]} -> {:error, :refused} end
      assert RunStore.update_ticket_question(@repo_key, @issue_id, @later, refuse) == {:error, :refused}

      assert RunStore.get_ticket_state(@repo_key, @issue_id) == record
      assert ticket_events(@repo_key, @issue_id) == events
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
      unchanged = fn _questions, _pause -> {:ok, nil} end
      assert RunStore.update_ticket_question(@repo_key, nil, @at, unchanged) == {:error, :invalid_issue_id}
    end
  end
end
