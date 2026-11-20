defmodule SymphonyElixir.SignInHold do
  @moduledoc """
  The person's side of a hold on an agent that cannot sign in to its model API
  (`SymphonyElixir.UsageLimit.sign_in_failed?/1`).

  The hold itself is the usage-limit hold's: new runs of the provider wait, a probe on a backoff
  checks the sign-in, and the held runs start by themselves once it works. A person is asked only
  once the hold has lasted `execution.usage_limit.sign_in_ask_after_seconds`: one question on
  Symphony itself (`SymphonyElixir.Questions`, subject `:symphony`), so the Inbox shows it once for
  the whole factory rather than once per ticket. It quotes the provider's message and recommends
  signing in again. Answering "I signed in again" checks the hold at once, as Try Now does
  (`SymphonyElixir.Orchestrator.try_usage_limit_now/1`); "Keep waiting" leaves the probe to its
  backoff. The question is asked once per hold (its `step` names the hold and its `since`) and is
  withdrawn when the hold lifts (`withdraw/2`).
  """

  alias SymphonyElixir.HumanActions.PlainWords
  alias SymphonyElixir.{Questions, UsageLimit}

  @step_prefix "sign_in:"
  @asked_by %{kind: :symphony, name: "Symphony"}
  @signed_in_again "I signed in again"

  @doc """
  Asks a person once when `entry` is a sign-in hold that has lasted at least
  `config.sign_in_ask_after_seconds` by `now`. Returns `:asked` when it asked, `:not_due` when the
  hold is not a sign-in hold, is younger than that or was asked about already, and `{:error, reason}`
  when the question could not be asked. `opts[:questions]` replaces `SymphonyElixir.Questions`.
  """
  @spec maybe_ask(map(), DateTime.t(), map(), keyword()) :: :asked | :not_due | {:error, term()}
  def maybe_ask(entry, %DateTime{} = now, config, opts \\ []) when is_map(entry) do
    questions = Keyword.get(opts, :questions, Questions)

    if due?(entry, now, config) and not asked?(questions, step(entry)) do
      case questions.ask(:symphony, request(entry, now), asked_by: @asked_by, step: step(entry)) do
        {:ok, _question} -> :asked
        {:error, reason} -> {:error, reason}
      end
    else
      :not_due
    end
  end

  @doc "Whether `entry` is a sign-in hold that has lasted `config.sign_in_ask_after_seconds` by `now`."
  @spec due?(map(), DateTime.t(), map()) :: boolean()
  def due?(entry, %DateTime{} = now, config) do
    UsageLimit.sign_in_failed?(entry) and match?(%DateTime{}, Map.get(entry, :since)) and
      DateTime.diff(now, entry.since) >= config.sign_in_ask_after_seconds
  end

  @doc """
  Withdraws the open sign-in questions for `entry`'s hold once it lifted: a sign-in works again.
  Returns how many it withdrew. `opts[:questions]` replaces `SymphonyElixir.Questions`.
  """
  @spec withdraw(map(), keyword()) :: non_neg_integer()
  def withdraw(entry, opts \\ []) when is_map(entry) do
    questions = Keyword.get(opts, :questions, Questions)
    condition = UsageLimit.condition(entry)

    :symphony
    |> questions.open()
    |> Enum.filter(&(condition_of(&1) == condition))
    |> Enum.count(fn question ->
      reason = "A sign-in to #{provider_name(entry)} works again, and the waiting runs have started."
      match?({:ok, _question}, questions.withdraw(:symphony, question.id, reason, cause: "hold_cleared"))
    end)
  end

  @doc """
  What answering a sign-in question does: "I signed in again" checks the hold the question names at
  once (`try_now` is `SymphonyElixir.Orchestrator.try_usage_limit_now/1`), any other answer nothing.
  A question that is not a sign-in question is `:ignored`.
  """
  @spec answered(map(), (String.t() -> term())) :: :checked | :waiting | :ignored
  def answered(question, try_now) when is_map(question) and is_function(try_now, 1) do
    case condition_of(question) do
      nil ->
        :ignored

      condition ->
        if Questions.option_label(question) == @signed_in_again do
          try_now.(condition)
          :checked
        else
          :waiting
        end
    end
  end

  @doc "The hold condition a sign-in question names (`usage_limit:anthropic:all`), nil for any other question."
  @spec condition_of(map()) :: String.t() | nil
  def condition_of(%{step: @step_prefix <> rest}) do
    case String.split(rest, ":", parts: 2) do
      [_since, condition] when condition != "" -> condition
      _other -> nil
    end
  end

  def condition_of(_question), do: nil

  defp step(entry), do: "#{@step_prefix}#{DateTime.to_unix(entry.since)}:#{UsageLimit.condition(entry)}"

  defp asked?(questions, step) do
    Enum.any?(questions.open(:symphony) ++ questions.answered(:symphony), &(&1.step == step))
  end

  defp request(entry, now) do
    name = provider_name(entry)
    minutes = div(DateTime.diff(now, entry.since), 60)
    message = entry |> Map.get(:error) |> message()

    %{
      title: "Agents can't sign in to #{name}",
      question:
        "No agent has been able to sign in to #{name} since #{clock(entry.since)}, #{minutes} minutes ago, so no new run on #{name} starts. " <>
          "Can you sign in to #{name} again on the computer Symphony runs on?",
      why:
        "#{name} refused every new agent with: #{message} " <>
          "Symphony keeps new runs on #{name} waiting and tries the sign-in again by itself every few minutes. " <>
          "No attempt of any ticket is counted while it waits.",
      if_unanswered: "New runs on #{name} keep waiting, and Symphony keeps trying the sign-in by itself. They start on their own once it works.",
      recommendation_reason: "A refused sign-in that lasts this long rarely clears by itself, and signing in again usually fixes it.",
      options: [
        %{
          label: @signed_in_again,
          effect: "Symphony tries the sign-in at once with one waiting run. If it works, every waiting run starts.",
          recommended: true
        },
        %{
          label: "Keep waiting",
          effect: "Symphony keeps trying the sign-in on its own schedule, and the waiting runs start by themselves once it works."
        }
      ]
    }
  end

  defp message(error) when is_binary(error) and error != "" do
    text = PlainWords.scrub(error)
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  defp message(_error), do: "a refused sign-in."

  defp provider_name(entry), do: UsageLimit.provider_name(Map.get(entry, :provider))

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M UTC")
end
