defmodule SymphonyElixir.Questions do
  @moduledoc """
  A question to a person on a ticket, whoever asks it: a run, a rule, Symphony or a person. This
  module is the only writer of a question.

  A question lives on the ticket's record (`SymphonyElixir.TicketState`, field `questions`) with who
  asked it (`asked_by`), the step it was asked at, its title, question, why it is asked, what waits
  if nobody answers, its options (each with its label, what it does, what it gains, costs and risks,
  whether it is the recommended one and the protected paths it unlocks), why the recommended option
  is the one to pick, the state a confirmation moves the ticket into (`confirm`, or nil), its state
  (`:open`, `:answered` or `:withdrawn`), its answer and when it was asked or withdrawn.

  `ask/3` checks the question against the writing standard (`SymphonyElixir.DecisionRequest.check/1`,
  which runs `SymphonyElixir.HumanActions.PlainWords.check/1`), puts it on the record and pauses
  the ticket on it (`SymphonyElixir.Pauses`, a `:question` reason naming its id). An open question
  with the same title and text is not asked twice: `ask/3` returns it. `answer/4` and `withdraw/4`
  end it and clear that reason, and only that one.

  Each change records a ledger event (`SymphonyElixir.TicketEvents`): `question.asked`,
  `question.answered` and `question.withdrawn`. The question, the change to the ticket's pause
  (`Pauses.set_change/4`, `Pauses.clear_reason_change/4`) and the events of both are written in one
  store transaction that holds the record's lock (`RunStore.update_ticket_question/4`): the ticket
  is paused on a question exactly while it is open, whatever else writes the record at the same
  time. Nothing calls this module yet: the Needs Decision hold and its `decision.*` events stay
  with `SymphonyElixir.DecisionRequest`.
  """

  alias SymphonyElixir.{DecisionRequest, Pauses, RunStore, TicketEvents, TicketState}
  alias SymphonyElixir.TicketEvents.Event

  @asker_kinds [:run, :rule, :symphony, :person]
  @states [:open, :answered, :withdrawn]
  @scopes [:run, :ticket, :always]
  @symphony %{kind: :symphony, name: "Symphony"}
  @director %{kind: :person, name: "Director"}
  # An answer that names an option by its number: "2" or "option 2".
  @option_number ~r/\A\s*(?:option\s*)?(\d+)\s*\z/i

  @typedoc "A ticket, as `SymphonyElixir.Pauses` names it."
  @type ticket :: {:ticket, String.t(), String.t()}

  @typedoc "Who asked a question: a run (with its id), a rule, Symphony or a person, by name."
  @type asker :: %{kind: :run | :rule | :symphony | :person, name: String.t(), run_id: String.t() | nil}

  @typedoc "Who answered or withdrew a question, by kind and name."
  @type actor :: %{kind: :run | :rule | :symphony | :person, name: String.t()}

  @type option :: %{
          label: String.t(),
          effect: String.t(),
          good: [String.t()],
          cost: [String.t()],
          risk: [String.t()],
          recommended?: boolean(),
          unlocks: [String.t()]
        }

  @typedoc "An answer: the text as given, the option it picked (by number, nil for free text), who, when and for how long."
  @type answer :: %{
          text: String.t(),
          option: pos_integer() | nil,
          by: actor(),
          at: DateTime.t(),
          scope: :run | :ticket | :always
        }

  @type question :: %{
          id: String.t(),
          asked_by: asker(),
          step: String.t() | nil,
          title: String.t(),
          question: String.t(),
          why: String.t(),
          if_unanswered: String.t(),
          options: [option()],
          recommendation_reason: String.t(),
          confirm: String.t() | nil,
          state: :open | :answered | :withdrawn,
          answer: answer() | nil,
          asked_at: DateTime.t(),
          withdrawn: %{reason: String.t(), at: DateTime.t()} | nil
        }

  @typedoc """
  `ask/3`'s options: `asked_by:` (`t:asker/0`, default Symphony), `step:` and `confirm:` (strings),
  and `at:` (a `DateTime`, default now).
  """
  @type ask_opt :: {:asked_by, map()} | {:step, String.t() | nil} | {:confirm, String.t() | nil} | {:at, DateTime.t()}

  @typedoc """
  `answer/4`'s and `withdraw/4`'s options: `by:` (`t:actor/0`; default the Director for an answer,
  Symphony for a withdrawal), `scope:` (an answer's, default `:ticket`) and `at:` (default now).
  """
  @type end_opt :: {:by, map()} | {:scope, :run | :ticket | :always} | {:at, DateTime.t()}

  @doc """
  Asks `request` on `ticket`: the map `SymphonyElixir.DecisionRequest.check/1` takes (title,
  question, why, if_unanswered, recommendation_reason and options, each with its label, effect,
  `recommended`, `tradeoffs` and `unlocks`). A request that misses the writing standard is refused
  with the standard's message. Records `question.asked` and pauses the ticket on the question.
  An open question with the same title and text is returned instead, and nothing is recorded.
  """
  @spec ask(ticket(), map(), [ask_opt()]) :: {:ok, question()} | {:error, term()}
  def ask(ticket, request, opts \\ []) do
    with {:ok, {repo_key, issue_id}} <- ticket(ticket),
         :ok <- check(request),
         {:ok, asked_by} <- asker(Keyword.get(opts, :asked_by, @symphony)),
         {:ok, at} <- at(opts) do
      update(repo_key, issue_id, at, &asked(ticket, &1, &2, new_question(request, asked_by, opts, at)))
    end
  end

  @doc """
  Answers the open question `id` on `ticket` with `answer`: `"2"`, `"option 2"` or the second
  option's label (in any case and spacing) picks the second option; any other text is a free-text
  answer, kept as given. Records `question.answered` and clears the question's pause reason.
  """
  @spec answer(ticket(), String.t(), String.t(), [end_opt()]) :: {:ok, question()} | {:error, term()}
  def answer(ticket, id, answer, opts \\ []) do
    with {:ok, {repo_key, issue_id}} <- ticket(ticket),
         {:ok, text} <- text(answer, :blank_answer),
         {:ok, by} <- actor(Keyword.get(opts, :by, @director)),
         {:ok, scope} <- scope(Keyword.get(opts, :scope, :ticket)),
         {:ok, at} <- at(opts) do
      given = %{text: text, option: nil, by: by, at: at, scope: scope}
      update(repo_key, issue_id, at, &answered(ticket, &1, &2, id, given))
    end
  end

  @doc """
  Withdraws the open question `id` on `ticket`, which nobody answers now, for `reason`. Records
  `question.withdrawn` with the reason, which history keeps, and clears the question's pause reason.
  """
  @spec withdraw(ticket(), String.t(), String.t(), [end_opt()]) :: {:ok, question()} | {:error, term()}
  def withdraw(ticket, id, reason, opts \\ []) do
    with {:ok, {repo_key, issue_id}} <- ticket(ticket),
         {:ok, reason} <- text(reason, :blank_reason),
         {:ok, by} <- actor(Keyword.get(opts, :by, @symphony)),
         {:ok, at} <- at(opts) do
      update(repo_key, issue_id, at, &withdrawn(ticket, &1, &2, id, reason, by, at))
    end
  end

  @doc "The questions on `ticket` still waiting for an answer, in the order they were asked."
  @spec open(ticket()) :: [question()]
  def open(ticket), do: ticket |> questions() |> Enum.filter(&(&1.state == :open))

  @doc "The questions on `ticket` a person answered, in the order they were asked."
  @spec answered(ticket()) :: [question()]
  def answered(ticket), do: ticket |> questions() |> Enum.filter(&(&1.state == :answered))

  @doc "The question `id` on `ticket`, whatever its state, or nil."
  @spec find(ticket(), String.t()) :: question() | nil
  def find(ticket, id), do: ticket |> questions() |> Enum.find(&(&1.id == id))

  @doc "Whether `ticket` has an open question with `request`'s title and question, as `ask/3` would return."
  @spec same_open?(ticket(), map()) :: boolean()
  def same_open?(ticket, request) when is_map(request) do
    key = {line(Map.get(request, :title)), line(Map.get(request, :question))}
    ticket |> open() |> Enum.any?(&({&1.title, &1.question} == key))
  end

  @doc "The questions as stored or given: each a map with a string `id` and a known `state`, once by id; anything else is dropped."
  @spec normalize(term()) :: [question()]
  def normalize(questions) when is_list(questions) do
    for(%{id: id, state: state} = question <- questions, is_binary(id) and state in @states, do: question)
    |> Enum.uniq_by(& &1.id)
  end

  def normalize(_questions), do: []

  # The changes, from the questions and the pause the store read under its lock: pure, as the store
  # may run them more than once.
  defp asked(ticket, questions, pause, question) do
    case Enum.find(questions, &(&1.state == :open and {&1.title, &1.question} == {question.title, question.question})) do
      nil ->
        paused = Pauses.set_change(ticket, pause, reason(question), set_by: Map.take(question.asked_by, [:kind, :name]), at: question.asked_at)
        write(ticket, question, {"question.asked", asked_payload(question), question.asked_at}, paused)

      open ->
        {:ok, open}
    end
  end

  defp answered(ticket, questions, pause, id, given) do
    with {:ok, question} <- open_question(questions, id) do
      number = pick(question.options, given.text)
      question = %{question | state: :answered, answer: %{given | option: number}}

      payload = %{
        question_id: id,
        title: question.title,
        answer: given.text,
        option: number && Enum.at(question.options, number - 1).label,
        option_number: number,
        scope: given.scope,
        by: given.by
      }

      write(ticket, question, {"question.answered", payload, given.at}, unpaused(ticket, pause, id, given.by, given.at))
    end
  end

  defp withdrawn(ticket, questions, pause, id, reason, by, at) do
    with {:ok, question} <- open_question(questions, id) do
      question = %{question | state: :withdrawn, withdrawn: %{reason: reason, at: at}}
      payload = %{question_id: id, title: question.title, reason: reason, by: by}
      write(ticket, question, {"question.withdrawn", payload, at}, unpaused(ticket, pause, id, by, at))
    end
  end

  # The question with its event, and the pause as its change leaves it with that change's events,
  # for the store to write in one transaction.
  defp write({:ticket, repo_key, issue_id}, question, {type, payload, at}, pause_change) do
    with {:ok, event} <- TicketEvents.build(repo_key, issue_id, type, payload, at: at),
         {:ok, pause, pause_events} <- pause_change,
         do: {:write, question, pause, [event | pause_events], question}
  end

  defp unpaused(ticket, pause, id, by, at), do: Pauses.clear_reason_change(ticket, pause, waits_on(id), by: by, at: at)

  defp open_question(questions, id) do
    case Enum.find(questions, &(&1.id == id)) do
      nil -> {:error, :question_not_found}
      %{state: :open} = question -> {:ok, question}
      %{state: state} -> {:error, {:question_not_open, state}}
    end
  end

  # The option an answer names by its number or its label, counted from one; nil for free text.
  defp pick(options, text) do
    case Regex.run(@option_number, text, capture: :all_but_first) do
      [number] -> option_number(String.to_integer(number), length(options))
      nil -> label_number(options, fold(text))
    end
  end

  defp option_number(number, count) when number in 1..count//1, do: number
  defp option_number(_number, _count), do: nil

  defp label_number(options, folded) do
    case Enum.find_index(options, &(fold(&1.label) == folded)) do
      nil -> nil
      index -> index + 1
    end
  end

  defp fold(text), do: text |> line() |> String.downcase()

  defp update(repo_key, issue_id, at, fun) do
    with {:ok, question, events} <- RunStore.update_ticket_question(repo_key, issue_id, at, fun) do
      Enum.each(events, &TicketEvents.notify/1)
      {:ok, question}
    end
  end

  defp reason(question), do: Map.put(waits_on(question.id), :text, "Waiting for your answer: #{question.title}")

  defp waits_on(id), do: %{kind: :question, waits_on: %{question_id: id}}

  defp questions(ticket) do
    with {:ok, {repo_key, issue_id}} <- ticket(ticket),
         record when is_map(record) <- RunStore.get_ticket_state(repo_key, issue_id) do
      TicketState.normalize(record).questions
    else
      _none -> []
    end
  end

  defp new_question(request, asked_by, opts, at) do
    %{
      id: Event.ulid(at),
      asked_by: asked_by,
      step: line(Keyword.get(opts, :step)),
      title: line(request.title),
      question: line(request.question),
      why: String.trim(request.why),
      if_unanswered: String.trim(request.if_unanswered),
      options: Enum.map(request.options, &option/1),
      recommendation_reason: String.trim(request.recommendation_reason),
      confirm: line(Keyword.get(opts, :confirm)),
      state: :open,
      answer: nil,
      asked_at: at,
      withdrawn: nil
    }
  end

  defp option(option) do
    tradeoffs = Map.get(option, :tradeoffs) || []

    %{
      label: line(option.label),
      effect: String.trim(option.effect),
      good: tradeoffs(tradeoffs, "good"),
      cost: tradeoffs(tradeoffs, "cost"),
      risk: tradeoffs(tradeoffs, "risk"),
      recommended?: Map.get(option, :recommended) == true,
      unlocks: Map.get(option, :unlocks) || []
    }
  end

  defp tradeoffs(tradeoffs, kind), do: for(%{kind: ^kind, text: text} <- tradeoffs, do: String.trim(text))

  defp asked_payload(question) do
    question
    |> Map.take([:title, :question, :why, :if_unanswered, :options, :recommendation_reason, :confirm, :step, :asked_by])
    |> Map.put(:question_id, question.id)
  end

  defp check(request) when is_map(request) do
    case DecisionRequest.check(request) do
      :ok -> :ok
      {:error, message} -> {:error, {:invalid_question, message}}
    end
  end

  defp check(request), do: {:error, {:invalid_question, request}}

  defp asker(asker) do
    with {:ok, actor} <- actor(asker),
         run_id when is_nil(run_id) or is_binary(run_id) <- Map.get(asker, :run_id) do
      {:ok, Map.put(actor, :run_id, run_id)}
    else
      _invalid -> {:error, {:invalid_option, :asked_by}}
    end
  end

  defp actor(%{kind: kind, name: name} = actor) when kind in @asker_kinds do
    case line(name) do
      nil -> {:error, {:invalid_actor, actor}}
      name -> {:ok, %{kind: kind, name: name}}
    end
  end

  defp actor(actor), do: {:error, {:invalid_actor, actor}}

  defp scope(scope) when scope in @scopes, do: {:ok, scope}
  defp scope(scope), do: {:error, {:invalid_option, {:scope, scope}}}

  defp at(opts) do
    case Keyword.get_lazy(opts, :at, &DateTime.utc_now/0) do
      %DateTime{} = at -> {:ok, at}
      _at -> {:error, {:invalid_option, :at}}
    end
  end

  defp ticket({:ticket, repo_key, issue_id} = ticket) when is_binary(repo_key) and is_binary(issue_id) do
    if line(repo_key) && line(issue_id), do: {:ok, {repo_key, issue_id}}, else: {:error, {:invalid_subject, ticket}}
  end

  defp ticket(ticket), do: {:error, {:invalid_subject, ticket}}

  defp text(value, error) when is_binary(value) do
    if String.trim(value) == "", do: {:error, error}, else: {:ok, value}
  end

  defp text(_value, error), do: {:error, error}

  # One line: whitespace runs collapse to one space; blank is nil.
  defp line(value) when is_binary(value) do
    case value |> String.split() |> Enum.join(" ") do
      "" -> nil
      line -> line
    end
  end

  defp line(_value), do: nil
end
