defmodule SymphonyElixir.TokenBudgetTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchLoop, Pauses, Questions, RunStore, TicketState, TokenBudget}

  @facts %{name: "MT-40", total_tokens: 100_008_209, limit: 100_000_000, pushed: false, unpushed_commits: 1, changed_files: 58}

  test "compact/1 writes a token count in a few characters" do
    assert TokenBudget.compact(950) == "950"
    assert TokenBudget.compact(12_345) == "12k"
    assert TokenBudget.compact(1_500_000) == "1.5M"
    assert TokenBudget.compact(2_000_000) == "2M"
    assert TokenBudget.compact(100_008_209) == "100M"
    assert TokenBudget.compact(1_200) == "1.2k"
  end

  test "the pause and the run's exit name the spend and the limit" do
    assert TokenBudget.pause_text(100_000_000) == "Its token budget is spent (100M)"
    assert TokenBudget.exit_text(100_008_209, 100_000_000) == "token budget spent (100M tokens of a 100M limit)"
    assert TokenBudget.exit_text(nil, 10) == "token budget spent (a 10 limit)"
  end

  test "the question names the spend, the limit and what the run got done, with the three options" do
    attrs = TokenBudget.question_attrs(@facts)

    assert attrs.title == "MT-40 spent its token budget"
    assert attrs.why =~ "The last run spent 100M tokens, past the limit of 100M tokens a ticket's run may spend."
    assert attrs.why =~ "It pushed nothing to a pull request; its workspace keeps 1 commit not pushed and 58 files changed but not committed."
    assert [%{label: "Give it another budget", recommended: true}, %{label: "Start it over from main"}, %{label: "Keep it paused"}] = attrs.options

    pushed = TokenBudget.question_attrs(%{@facts | total_tokens: nil, pushed: true, unpushed_commits: 2, changed_files: 1})
    assert pushed.why =~ "The last run reached the limit of 100M tokens a ticket's run may spend."
    assert pushed.why =~ "Its pull request has the work it pushed; its workspace keeps 2 commits not pushed and 1 file changed but not committed."

    unread = TokenBudget.question_attrs(%{@facts | unpushed_commits: nil, changed_files: nil})
    assert unread.why =~ ~r/It pushed nothing to a pull request\.$/
  end

  test "asking pauses the ticket on the budget's line, once; Give it another budget is Unblock" do
    on_exit(fn -> RunStore.clear() end)
    ticket = {:ticket, "default", "issue-spent"}

    assert {:ok, question} = TokenBudget.ask(ticket, @facts)
    assert {:ok, %{id: same}} = TokenBudget.ask(ticket, @facts)
    assert same == question.id
    assert Pauses.why(ticket) == ["Its token budget is spent (100M)"]
    assert Questions.held(ticket).id == question.id

    assert {:ok, answered} = Questions.answer(ticket, question.id, "Give it another budget")
    assert DispatchLoop.answer_move(answered) == :unblock
    refute Pauses.paused?(ticket)
    assert DispatchLoop.another_budget_label() in DispatchLoop.unblock_labels()
  end

  test "answered_since?/3 finds an answer given at or after the spent run started" do
    on_exit(fn -> RunStore.clear() end)
    ticket = {:ticket, "default", "issue-answered"}
    {:ok, question} = TokenBudget.ask(ticket, @facts)
    started = DateTime.add(DateTime.utc_now(), -60, :second)

    refute TokenBudget.answered_since?(stored_questions("issue-answered"), "MT-40", started)

    {:ok, _answered} = Questions.answer(ticket, question.id, "Keep it paused")
    questions = stored_questions("issue-answered")

    assert TokenBudget.answered_since?(questions, "MT-40", started)
    assert TokenBudget.answered_since?(questions, "MT-40", nil)
    refute TokenBudget.answered_since?(questions, "MT-40", DateTime.add(DateTime.utc_now(), 3_600, :second))
    refute TokenBudget.answered_since?(questions, "MT-41", started)
  end

  defp stored_questions(issue_id), do: TicketState.normalize(RunStore.get_ticket_state(issue_id)).questions
end
