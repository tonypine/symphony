defmodule SymphonyElixir.SignInHoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DirectorMoves, Questions, SignInHold}

  @since ~U[2026-11-13 09:46:00Z]
  @config %{sign_in_ask_after_seconds: 1800}
  @message "Failed to authenticate. API Error: 403 Attention Required! | Cloudflare"

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp hold(attrs \\ %{}) do
    Map.merge(
      %{
        provider: "anthropic",
        scope: :all,
        reason: "model_api_sign_in_failed",
        source: :api_unreachable,
        error: @message,
        since: @since,
        resume_at: DateTime.add(@since, 900),
        phase: :paused
      },
      attrs
    )
  end

  defp sign_in_questions, do: Enum.filter(Questions.open(:symphony), &match?("sign_in:" <> _, &1.step))

  defmodule RefusingQuestions do
    def open(:symphony), do: []
    def answered(:symphony), do: []
    def ask(:symphony, _request, _opts), do: {:error, :store_down}
  end

  test "asks no one before the configured time, nor about a hold of another cause" do
    assert SignInHold.maybe_ask(hold(), DateTime.add(@since, 1799), @config) == :not_due
    assert SignInHold.maybe_ask(hold(%{reason: "model_api_unreachable"}), DateTime.add(@since, 3600), @config) == :not_due
    assert SignInHold.maybe_ask(hold(%{since: nil}), DateTime.add(@since, 3600), @config) == :not_due
    assert sign_in_questions() == []
  end

  test "once the hold lasted the configured time, asks once on Symphony itself with the message and sign in again" do
    now = DateTime.add(@since, 1800)
    assert SignInHold.maybe_ask(hold(), now, @config) == :asked

    assert [question] = sign_in_questions()
    assert question.title == "Agents can't sign in to Claude"
    assert question.question =~ "since 09:46 UTC, 30 minutes ago"
    assert question.why =~ "Failed to authenticate. API Error: 403 Attention Required!"
    assert [%{label: "I signed in again", recommended: true}, %{label: "Keep waiting"}] = question.options
    assert SignInHold.condition_of(question) == "usage_limit:anthropic:all"

    # Later refusals of the same hold ask nothing more, answered or not.
    assert SignInHold.maybe_ask(hold(), DateTime.add(now, 600), @config) == :not_due
    assert {:ok, _answered} = Questions.answer(:symphony, question.id, "Keep waiting")
    assert SignInHold.maybe_ask(hold(), DateTime.add(now, 1200), @config) == :not_due
    assert sign_in_questions() == []
  end

  test "a hold with no message still asks in words" do
    assert SignInHold.maybe_ask(hold(%{error: nil}), DateTime.add(@since, 3600), @config) == :asked
    assert [%{why: why}] = sign_in_questions()
    assert why =~ "refused every new agent with: a refused sign-in."
  end

  test "a question that can't be asked is an error" do
    assert SignInHold.maybe_ask(hold(), DateTime.add(@since, 3600), @config, questions: RefusingQuestions) == {:error, :store_down}
  end

  test "withdraws the hold's open question once it lifts, and no other" do
    :asked = SignInHold.maybe_ask(hold(), DateTime.add(@since, 1800), @config)
    :asked = SignInHold.maybe_ask(hold(%{provider: "openai"}), DateTime.add(@since, 1800), @config)

    assert SignInHold.withdraw(hold()) == 1
    assert [%{step: step}] = sign_in_questions()
    assert step =~ "usage_limit:openai:all"
    assert SignInHold.withdraw(hold()) == 0
  end

  test "I signed in again checks the hold at once; Keep waiting leaves it to its backoff" do
    :asked = SignInHold.maybe_ask(hold(), DateTime.add(@since, 1800), @config)
    [question] = sign_in_questions()
    test_pid = self()
    try_now = fn condition -> send(test_pid, {:try_now, condition}) end

    assert {:ok, %{move: "decide", answered: true}} =
             DirectorMoves.decide_subject(%{question_id: question.id, picks: [%{question: question.title, answer: "I signed in again"}]}, try_usage_limit_now: try_now)

    assert_received {:try_now, "usage_limit:anthropic:all"}

    {:ok, answered} = Questions.reopen(:symphony, question.id)
    {:ok, answered} = Questions.answer(:symphony, answered.id, "Keep waiting")
    assert SignInHold.answered(answered, try_now) == :waiting
    refute_received {:try_now, _condition}
  end

  test "names the hold only of a sign-in question" do
    assert SignInHold.condition_of(%{step: "release_build:abc"}) == nil
    assert SignInHold.condition_of(%{step: "sign_in:123"}) == nil
    assert SignInHold.condition_of(%{step: nil}) == nil
    assert SignInHold.answered(%{step: "report:run-1"}, fn _condition -> flunk("no check") end) == :ignored
  end
end
