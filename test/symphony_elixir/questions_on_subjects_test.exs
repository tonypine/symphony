defmodule SymphonyElixir.QuestionsOnSubjectsTest do
  @moduledoc """
  A Question on Symphony itself or on a repository (TP-1341): the same entity, events and pause
  binding as a ticket's, kept next to its subject's pause with its events on the subject's own
  stream, and listed by the Inbox with no ticket.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Inbox, Pauses, Questions, TicketEvents}
  alias SymphonyElixir.Inbox.{FromRecord, Item}

  @at ~U[2026-11-02 18:00:00Z]
  @later ~U[2026-11-02 18:05:00Z]
  @rule %{kind: :rule, name: "Release build watch"}
  @director %{kind: :person, name: "Director"}
  @repository {:repository, "repo-a"}

  @request %{
    title: "The Symphony release build keeps being cancelled",
    question: "GitHub cancelled the Symphony release build 3 times in a row. Should Symphony rerun it, or wait for a fix?",
    why: "GitHub cancels a build it can't find a machine for.",
    if_unanswered: "The app stays on its current version.",
    recommendation_reason: "A rerun costs nothing.",
    options: [
      %{label: "Rerun the build", effect: "Symphony reruns the build now.", recommended: true, tradeoffs: [%{kind: "good", text: "Nothing to do by hand."}]},
      %{label: "Wait for a fix", effect: "Symphony stops rerunning the build."}
    ]
  }

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
  end

  defp ask!(subject \\ :symphony, opts \\ []) do
    {:ok, question} = Questions.ask(subject, @request, [asked_by: @rule, step: "release_build:abc", at: @at] ++ opts)
    question
  end

  defp types(subject), do: subject |> TicketEvents.query_subject() |> Enum.map(& &1.type)

  describe "a question on Symphony itself" do
    test "is asked, pauses Symphony without stopping dispatch, records question.asked on Symphony's own stream and keeps no ticket record" do
      question = ask!()

      assert %{asked_by: %{kind: :rule, name: "Release build watch", run_id: nil}, step: "release_build:abc", state: :open, asked_at: @at} = question
      assert Questions.open(:symphony) == [question]
      assert Questions.find(:symphony, question.id) == question
      assert Questions.open_on_subjects() == [{:symphony, question}]
      assert Questions.find_open_on_subjects(question.id) == {:symphony, question}
      assert Questions.find_open_on_subjects("q-nope") == nil

      assert {:ok, %{reasons: [%{kind: :question, waits_on: %{question_id: id}, text: text}]} = pause} = Pauses.get(:symphony)
      assert id == question.id
      assert text == "Waiting for your answer: #{@request.title}"
      assert Pauses.dispatch_reasons(pause) == []
      assert %{paused: false} = Pauses.dispatch_status(pause)

      assert [%{type: "question.asked", repo_key: nil, issue_id: "symphony", seq: 1, payload: %{question_id: ^id}}] =
               TicketEvents.query_subject(:symphony)

      assert [%{type: "question.asked"}] = TicketEvents.query_subject(:symphony, open_decisions: true)
      assert RunStore.list_all_ticket_states() == []

      # Asked again while open: the same question, nothing recorded.
      assert {:ok, ^question} = Questions.ask(:symphony, @request, asked_by: @rule, at: @later)
      assert types(:symphony) == ["question.asked"]
    end

    test "is answered by an option, which clears its reason and records question.answered on the same stream" do
      question = ask!()

      assert {:ok, %{state: :answered, answer: %{text: "Rerun the build", option: 1, by: @director}}} =
               Questions.answer(:symphony, question.id, "Rerun the build", at: @later)

      assert Pauses.get(:symphony) == {:ok, nil}
      assert Questions.open_on_subjects() == []
      assert [%{state: :answered}] = Questions.answered(:symphony)
      assert types(:symphony) == ["question.asked", "question.answered"]
      assert TicketEvents.query_subject(:symphony, open_decisions: true) == []
      assert [%{seq: 1}, %{seq: 2, payload: %{option: "Rerun the build", option_number: 1}}] = TicketEvents.query_subject(:symphony)

      assert Questions.answer(:symphony, question.id, "2") == {:error, {:question_not_open, :answered}}
    end

    test "is reopened by the Director's Undo and withdrawn, as a ticket's is" do
      question = ask!()
      {:ok, _answered} = Questions.answer(:symphony, question.id, "Wait for a fix", at: @later)

      assert {:ok, %{state: :open, taken_back: ["Wait for a fix"]}} = Questions.reopen(:symphony, question.id, at: @later)
      assert {:ok, %{reasons: [%{kind: :question}]}} = Pauses.get(:symphony)

      assert {:ok, %{state: :withdrawn, withdrawn: %{reason: "A newer build is watched."}}} =
               Questions.withdraw(:symphony, question.id, "A newer build is watched.", cause: "superseded", by: @rule)

      assert Pauses.get(:symphony) == {:ok, nil}
      assert types(:symphony) == ["question.asked", "question.answered", "question.reopened", "question.withdrawn"]
    end

    test "leaves the Director's own pause of Symphony as it is" do
      {:ok, _pause} = Pauses.set(:symphony, Pauses.dispatch_reason("Holiday"), set_by: @director, at: @at)
      question = ask!()

      assert {:ok, %{reasons: [%{kind: :person}, %{kind: :question}]}} = Pauses.get(:symphony)
      {:ok, _answered} = Questions.answer(:symphony, question.id, "1")
      assert {:ok, %{reasons: [%{kind: :person, text: "Holiday"}]}} = Pauses.get(:symphony)
    end
  end

  describe "a question on a repository" do
    test "pauses that repository and keeps its own stream, apart from Symphony's" do
      question = ask!(@repository)

      assert {:ok, %{reasons: [%{kind: :question}]} = pause} = Pauses.get(@repository)
      assert Pauses.repository_skip_reason(pause) == "the repository is paused: Waiting for your answer: #{@request.title}"
      assert Pauses.get(:symphony) == {:ok, nil}
      assert [%{type: "question.asked", repo_key: "repo-a", issue_id: "repository"}] = TicketEvents.query_subject(@repository)
      assert TicketEvents.query_subject(:symphony) == []

      symphony = ask!()
      assert Questions.open_on_subjects() == [{:symphony, symphony}, {@repository, question}]
    end

    test "a malformed repository is refused, and a store that can't be read lists nothing" do
      assert Questions.ask({:repository, " "}, @request) == {:error, {:invalid_subject, {:repository, " "}}}
      assert Questions.open({:repository, 7}) == []
      nothing = fn _questions, _pause -> {:ok, nil} end
      assert RunStore.update_subject_question({:ticket, "repo-a", "issue-1"}, nothing) == {:error, :invalid_subject}
      assert RunStore.get_subject_questions(:everything) == {:error, :invalid_subject}
      assert RunStore.list_subject_events(:everything, []) == {:error, :invalid_subject}
      assert TicketEvents.query_subject(:everything) == {:error, :invalid_subject}
    end

    test "a change that writes nothing or is refused leaves the store as it was" do
      assert RunStore.update_subject_question(:symphony, fn [], nil -> {:ok, :nothing} end) == {:ok, :nothing, []}
      assert RunStore.update_subject_question(:symphony, fn [], nil -> {:error, :refused} end) == {:error, :refused}
      assert RunStore.get_subject_questions(:symphony) == []
    end
  end

  describe "the Inbox" do
    defp inbox(opts \\ []) do
      Keyword.merge(
        [
          name: {:test, make_ref()},
          records: fn -> [] end,
          settings_fun: fn _repo_key -> {:ok, %Schema{}} end,
          github_repos: %{},
          pull_request: fn url -> flunk("read #{url} from GitHub") end
        ],
        opts
      )
    end

    test "lists an open question on Symphony as an action row with no ticket, and drops it once answered" do
      question = ask!()

      assert [item] = Inbox.items(%{}, inbox())
      assert %{issue_id: nil, identifier: nil, title: "Symphony", repo_key: nil, kind: :action, state: nil, url: nil} = item
      assert %{subject: :symphony} = item
      assert %{ask: "The Symphony release build keeps being cancelled", waiting_since: @at} = item

      assert %{question_id: id, comment_id: nil, confirm: nil, requested_at: @at, options: [rerun, _wait]} = item.review
      assert %{label: "Rerun the build", recommended: true} = rerun

      assert id == question.id
      assert [%{subject: :symphony}] = Inbox.rows(inbox())

      {:ok, _answered} = Questions.answer(:symphony, question.id, "1")
      assert Inbox.items(%{}, inbox()) == []
    end

    test "names a repository's row by the repository, and leaves out a repository the configuration no longer names" do
      ask!(@repository)
      ask!({:repository, "gone"})

      settings_fun = fn
        "gone" -> {:error, :unknown_repo}
        _repo_key -> {:ok, %Schema{}}
      end

      assert [%{title: "repo-a", repo_key: "repo-a", subject: :repository, identifier: nil}] = Inbox.items(%{}, inbox(settings_fun: settings_fun))
    end

    test "FromRecord lists the subject rows it is given beside the tickets', oldest first" do
      question = %{ask!() | asked_at: @later, reopened_at: nil}
      older = %{question | id: "older", asked_at: @at}

      assert [%{review: %{question_id: "older"}}, %{review: %{question_id: id}}] =
               FromRecord.items([], %{}, settings_fun: fn _repo_key -> %Schema{} end, subject_questions: [{:symphony, question}, {@repository, older}])

      assert id == question.id
      assert %{waiting_since: @later} = Item.from_subject_question(:symphony, %{question | reopened_at: @at})
    end
  end
end
