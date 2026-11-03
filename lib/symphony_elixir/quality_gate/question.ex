defmodule SymphonyElixir.QualityGate.Question do
  @moduledoc """
  The quality gate's clarification, asked as a Question (`SymphonyElixir.Questions`) the Inbox lists
  and the Director's Decide answers, by an option or in the person's own words (TP-1360).

  When the gate holds a ticket for clarification (`SymphonyElixir.QualityGate`, an
  `awaiting_clarification` entry), the orchestrator's gate task asks one Question per round
  (`sync/3`): its title names the ticket and the round, its question carries the gate's score and
  questions in plain words (`SymphonyElixir.HumanActions.PlainWords.scrub/1`), and it is asked by
  the rule "Quality gate" at the step `quality_gate`. Asking it again in the same round returns
  the open one (`Questions.ask/3` matches its title and text), so a poll asks nothing new.

  Its options:

    * "Start it as it is": the gate lets the ticket through at its next scoring, with no new
      score (`QualityGate.evaluate/4`'s `:answers`, `:start`);
    * "Move it to Backlog" (recommended when the person has no answer): the ticket leaves
      dispatch until someone rewrites it and moves it back.

  The person's own words are the answer the gate needs: the gate task reads every answered gate
  Question from the ticket's record (`answers/1`) and the gate adds each to the ticket's comments,
  so its cache key changes, it scores the ticket again at once and the provider reads the answer.

  The Linear path stays: the gate's comment is still posted, and a reply under it changes the
  comment activity the gate keys on. A scoring that ends the round (the ticket passed, was skipped,
  or the gate asks a new round) withdraws the open gate Question (`sync/3`), so nothing pauses the
  ticket on a question nobody needs.
  """

  require Logger

  alias SymphonyElixir.HumanActions.PlainWords
  alias SymphonyElixir.{Questions, RunStore, TicketState}

  @step "quality_gate"
  @asker %{kind: :rule, name: "Quality gate"}
  @start "Start it as it is"
  @backlog "Move it to Backlog"
  @answer_author "Director (Symphony Inbox)"

  @typedoc "An answer to a gate Question, as the gate reads it."
  @type answer :: %{text: String.t(), option: :start | :backlog | nil, at: DateTime.t()}

  @doc "Who a gate answer reads as in the comments the gate scores."
  @spec answer_author() :: String.t()
  def answer_author, do: @answer_author

  @doc """
  The Question for the clarification `entry` (a `QualityGate` `awaiting_clarification` entry): the
  map `Questions.ask/3` takes.
  """
  @spec attrs(map()) :: map()
  def attrs(entry) do
    name = entry.identifier || entry.issue_id
    questions = entry.questions |> Enum.with_index(1) |> Enum.map_join(" ", fn {question, index} -> "#{index}) #{plain(question)}" end)

    %{
      title: "#{name} needs answers before it starts (round #{entry.rounds_asked} of #{entry.max_rounds})",
      question:
        "The quality gate scored #{name} #{entry.score} out of 10, below the #{entry.pass_threshold} it needs to start. " <>
          "It asks: #{questions} Answer them in your own words, or pick an option.",
      why:
        "The quality gate reads each ticket before Symphony starts it, and found #{name} unclear: #{sentence(entry.reason)} " <>
          "Your answer is added to what the gate reads, and it scores #{name} again at once; #{name} starts once it passes. " <>
          "A reply under the gate's comment on the ticket works too.",
      if_unanswered: "#{name} waits and Symphony starts no run on it.",
      recommendation_reason: "Answering in your own words is best; with no answer, Backlog keeps an unclear ticket from starting.",
      options: [
        %{
          label: @start,
          effect: "The quality gate lets #{name} through without scoring it again, and Symphony starts it.",
          recommended: false,
          tradeoffs: [%{kind: "risk", text: "The agent works from a ticket the gate found unclear."}]
        },
        %{
          label: @backlog,
          effect: "Symphony moves #{name} to Backlog, where it waits until someone rewrites it and moves it back.",
          recommended: true,
          move: %{to: "Backlog"}
        }
      ]
    }
  end

  @doc """
  Brings the gate Questions of `ticket` in line with what the gate decided: asks the Question of
  `entry` when the gate holds the ticket for clarification (nil when it does not), and withdraws
  every other open gate Question among `questions` (the ticket's Questions). Best-effort: a store
  refusal is logged, and the Inbox still lists the ticket from the gate's own entry.
  """
  @spec sync(Questions.ticket(), [Questions.question()], map() | nil) :: :ok
  def sync(ticket, questions, entry) do
    current = if entry, do: ask(ticket, entry)

    for %{state: :open, step: @step} = question <- questions, question.title != current do
      withdraw(ticket, question)
    end

    :ok
  end

  defp ask(ticket, entry) do
    attrs = attrs(entry)

    case Questions.ask(ticket, attrs, asked_by: @asker, step: @step, asked_in: Map.get(entry, :state)) do
      {:ok, question} ->
        question.title

      {:error, reason} ->
        Logger.warning("QualityGate could not ask its clarification as a Question issue=#{entry.identifier || entry.issue_id}: #{inspect(reason)}")
        attrs.title
    end
  end

  defp withdraw(ticket, question) do
    reason = "The quality gate scored the ticket again, so these questions are no longer needed."

    with {:error, error} <- Questions.withdraw(ticket, question.id, reason, cause: "superseded") do
      Logger.warning("QualityGate could not withdraw its Question #{question.id}: #{inspect(error)}")
    end
  end

  @doc "The Questions on the record of `ticket`, in the order they were asked; none without a record."
  @spec questions(Questions.ticket()) :: [Questions.question()]
  def questions({:ticket, _repo_key, issue_id}) do
    case RunStore.get_ticket_state(issue_id) do
      record when is_map(record) -> TicketState.normalize(record).questions
      _none -> []
    end
  end

  @doc "The answers among `questions` to gate Questions, in the order they were asked."
  @spec answers([Questions.question()]) :: [answer()]
  def answers(questions) do
    for %{state: :answered, step: @step, answer: %{text: text, at: at} = answer} = question <- questions do
      %{text: text, option: option(question, answer), at: at}
    end
  end

  defp option(question, %{option: number}) when is_integer(number) do
    case Enum.at(question.options, number - 1) do
      %{label: @start} -> :start
      %{label: @backlog} -> :backlog
      _other -> nil
    end
  end

  defp option(_question, _answer), do: nil

  defp plain(text) when is_binary(text), do: PlainWords.scrub(text)
  defp plain(_text), do: ""

  defp sentence(text) do
    plain = plain(text)
    if plain == "" or String.ends_with?(plain, [".", "!", "?"]), do: plain, else: plain <> "."
  end
end
