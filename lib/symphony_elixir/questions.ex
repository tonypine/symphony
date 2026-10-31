defmodule SymphonyElixir.Questions do
  @moduledoc """
  A question to a person on a ticket, whoever asks it: a run, a rule, Symphony or a person. This
  module is the only writer of a question.

  A question lives on the ticket's record (`SymphonyElixir.TicketState`, field `questions`) with who
  asked it (`asked_by`), the step it was asked at, its title, question, why it is asked, what waits
  if nobody answers, its options (each with its label, what it does, what it gains, costs and risks,
  whether it is the recommended one and the protected paths it unlocks), why the recommended option
  is the one to pick, the state a confirmation moves the ticket into (`confirm`, or nil), what it
  unblocks (`unblocks`, or nil), whether a request comment shows it in Linear (`request`: nil for a
  question asked before it said, `SymphonyElixir.Pauses.Projector`), the phase it was asked in
  (`asked_in`), its state
  (`:open`, `:answered` or `:withdrawn`), its answer and when it was asked or withdrawn.

  `ask/3` checks the question against the writing standard (`SymphonyElixir.DecisionRequest.check/1`,
  which runs `SymphonyElixir.HumanActions.PlainWords.check/1`), puts it on the record and pauses
  the ticket on it (`SymphonyElixir.Pauses`, a `:question` reason naming its id). An open question
  with the same title and text is not asked twice: `ask/3` returns it. `answer/4` and `withdraw/4`
  end it and clear that reason, and only that one. `reopen/3` takes an answer back (the Director's
  Undo, `SymphonyElixir.DirectorMoves.undo/2`): the question is open again, stamped `reopened_at`
  with the answer kept in `taken_back`, and pauses the ticket on it again.

  Each change records a ledger event (`SymphonyElixir.TicketEvents`): `question.asked`,
  `question.answered`, `question.withdrawn` and `question.reopened`. The question, the change to the ticket's pause
  (`Pauses.set_change/4`, `Pauses.clear_reason_change/4`) and the events of both are written in one
  store transaction that holds the record's lock (`RunStore.update_ticket_question/4`): the ticket
  is paused on a question exactly while it is open, whatever else writes the record at the same
  time.

  Once a change to a question commits, the ticket's labels and Decisions section are projected from
  the record (`SymphonyElixir.Pauses.Projector.project_now/2`).

  `answers/2` reads the ticket's answers the way the PR watcher reads them: each answered question
  as a decision entry, then the decisions recorded before questions carried them.

  `ask/3` with `backfilled: true` records a question the backfill from the holds and decisions
  finds (`SymphonyElixir.Pauses.Backfill`): it was asked before, so the writing standard is not
  checked again, and it keeps the `id:` the backfill gives it, an `answer:` when it was answered
  (stored answered, with no pause reason: the answer's `decision.recorded` event records it, and
  `legacy_event:` names that event) and its `question.asked` event carries `source: "backfill"`.
  A question whose id the record already holds is returned and nothing is recorded.

  `withdraw_lapsed/3` withdraws the open questions nobody needs any more once what they belonged to
  ended (`lapsed?/2`'s rule table): a Restart, a move to Backlog, a run that asked ending after the
  ticket moved on, a merge settled, a terminal state. Each keeps its reason in plain words, and the
  projections follow as `linear_withdraw_human_action` makes them: the hold that carried it clears
  and the `## Action withdrawn` reply goes under its request.
  """

  require Logger

  alias SymphonyElixir.{
    DecisionRequest,
    DispatchLoop,
    Hold,
    Pauses,
    RunStore,
    TicketEvents,
    TicketState,
    Tracker,
    TransitionGuard
  }

  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.TicketEvents.Event

  @asker_kinds [:run, :rule, :symphony, :person]
  @states [:open, :answered, :withdrawn]
  @scopes [:run, :ticket, :always]
  @symphony %{kind: :symphony, name: "Symphony"}
  @director %{kind: :person, name: "Director"}
  # What a field of a stored question reads as when the question was stored before it existed.
  @question_defaults %{
    asked_by: %{kind: :symphony, name: "Symphony", run_id: nil},
    step: nil,
    title: nil,
    question: nil,
    why: nil,
    if_unanswered: nil,
    options: [],
    recommendation_reason: nil,
    confirm: nil,
    unblocks: nil,
    request: nil,
    asked_in: nil,
    answer: nil,
    asked_at: nil,
    withdrawn: nil,
    legacy_event: nil,
    reopened_at: nil,
    taken_back: []
  }
  @option_defaults %{label: "", effect: "", good: [], cost: [], risk: [], recommended?: false, unlocks: []}
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
          why: String.t() | nil,
          if_unanswered: String.t() | nil,
          options: [option()],
          recommendation_reason: String.t() | nil,
          confirm: String.t() | nil,
          unblocks: String.t() | nil,
          request: boolean() | nil,
          asked_in: String.t() | nil,
          state: :open | :answered | :withdrawn,
          answer: answer() | nil,
          asked_at: DateTime.t(),
          withdrawn: %{reason: String.t(), at: DateTime.t()} | nil,
          legacy_event: String.t() | nil,
          reopened_at: DateTime.t() | nil,
          taken_back: [String.t()]
        }

  @typedoc """
  `ask/3`'s options: `asked_by:` (`t:asker/0`, default Symphony), `step:` and `confirm:` (strings),
  `request: true` when a `## Decision needed:` comment shows the question in Linear
  (`SymphonyElixir.DecisionRequest.ask/4`), `asked_in:` (the phase it was asked in, which that comment
  names) and `at:` (a `DateTime`, default now); for the backfill only, `backfilled: true` with `id:`,
  `answer:` and `legacy_event:` (see the module doc).
  """
  @type ask_opt ::
          {:asked_by, map()}
          | {:step, String.t() | nil}
          | {:confirm, String.t() | nil}
          | {:request, boolean()}
          | {:asked_in, String.t() | nil}
          | {:at, DateTime.t()}
          | {:backfilled, boolean()}
          | {:id, String.t()}
          | {:answer, answer()}
          | {:legacy_event, String.t() | nil}

  @typedoc """
  `answer/4`'s and `withdraw/4`'s options: `by:` (`t:actor/0`; default the Director for an answer,
  Symphony for a withdrawal), `scope:` (an answer's, default `:ticket`), `cause:` (a withdrawal's,
  `t:cause/0`, which its `question.withdrawn` event records) and `at:` (default now).
  """
  @type end_opt :: {:by, map()} | {:scope, :run | :ticket | :always} | {:cause, cause()} | {:at, DateTime.t()}

  @typedoc """
  Why a question was withdrawn, as its `question.withdrawn` event records it: the ticket moved on
  (Backlog, a merge, a terminal state), it was restarted, the hold it was asked with cleared, the
  one who asked withdrew it as not needed, or the run that asked ended (only a question that holds
  nothing, `withdraw_lapsed/3`).
  """
  @type cause :: String.t()

  @causes ~w(ticket_moved restarted hold_cleared superseded run_ended)

  @typedoc """
  What ended what a question belonged to (`lapsed?/2`): a Restart, a move to Backlog, a merge
  settled, the ticket entering the terminal state it names, or a run ending (its id, when it started
  and ended, and the phase the ticket is in once it ended, `nil` when the ticket stayed where the
  run started).
  """
  @type lapse :: :restart | :backlog | :merged | {:terminal, String.t()} | {:run_ended, ended_run()}

  @typedoc "A run that ended, as `lapsed?/2` reads it."
  @type ended_run :: %{
          run_id: String.t() | nil,
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t(),
          moved_to: String.t() | nil
        }

  @doc """
  Asks `request` on `ticket`: the map `SymphonyElixir.DecisionRequest.check/1` takes (title,
  question, why, if_unanswered, recommendation_reason and options, each with its label, effect,
  `recommended`, `tradeoffs` and `unlocks`). A request that misses the writing standard is refused
  with the standard's message. Records `question.asked` and pauses the ticket on the question.
  An open question with the same title and text is returned instead, and nothing is recorded.
  """
  @spec ask(ticket(), map(), [ask_opt()]) :: {:ok, question()} | {:error, term()}
  def ask(ticket, request, opts \\ []) do
    backfilled? = Keyword.get(opts, :backfilled) == true

    with {:ok, {repo_key, issue_id}} <- ticket(ticket),
         :ok <- check(request, backfilled?),
         {:ok, asked_by} <- asker(Keyword.get(opts, :asked_by, @symphony)),
         {:ok, at} <- at(opts) do
      update(repo_key, issue_id, at, &asked(ticket, &1, &2, new_question(request, asked_by, opts, at), backfilled?))
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
  `question.withdrawn` with the reason, which history keeps, and `opts[:cause]` (`t:cause/0`) when
  given, and clears the question's pause reason.
  """
  @spec withdraw(ticket(), String.t(), String.t(), [end_opt()]) :: {:ok, question()} | {:error, term()}
  def withdraw(ticket, id, reason, opts \\ []) do
    with {:ok, {repo_key, issue_id}} <- ticket(ticket),
         {:ok, reason} <- text(reason, :blank_reason),
         {:ok, cause} <- cause(Keyword.get(opts, :cause)),
         {:ok, by} <- actor(Keyword.get(opts, :by, @symphony)),
         {:ok, at} <- at(opts) do
      update(repo_key, issue_id, at, &withdrawn(ticket, &1, &2, id, {reason, cause}, by, at))
    end
  end

  @doc """
  Reopens the question `id` on `ticket` that a person answered: the answer is taken back (the
  Director's Undo), the question is open again with `reopened_at` stamped, and the ticket pauses on
  it again. Records `question.reopened`. A question not answered is refused.
  """
  @spec reopen(ticket(), String.t(), [end_opt()]) :: {:ok, question()} | {:error, term()}
  def reopen(ticket, id, opts \\ []) do
    with {:ok, {repo_key, issue_id}} <- ticket(ticket),
         {:ok, by} <- actor(Keyword.get(opts, :by, @director)),
         {:ok, at} <- at(opts) do
      update(repo_key, issue_id, at, &reopened(ticket, &1, &2, id, by, at))
    end
  end

  @doc """
  Whether the open `question` lapsed with `lapse`, so nobody needs its answer any more:

    * a Restart ends every question: the run that asked is over and the pull request is closed;
    * a move to Backlog ends the questions a run asked, as it stops the run;
    * a run ending ends the questions it asked (by its id when the question names one, else asked
      while it ran), once the ticket moved to another phase; a question Symphony, a rule or a
      person asked is about the ticket itself, such as a merge confirmation, and outlives any run;
      so does a question a request comment shows (`request: true`, the agent's
      `linear_request_human_action`: a protected-path authorization, a plan's choice): the run
      ended because it asked, and the question holds the ticket until it is answered or the hold
      ends for another reason (TP-1321);
    * a merge settled and a terminal state end every question.

  A question no longer open lapses with nothing.
  """
  @spec lapsed?(question(), lapse()) :: boolean()
  def lapsed?(question, lapse), do: lapse_reason(question, lapse) != nil

  @doc """
  Withdraws the open questions on `ticket` that lapsed with `lapse` (`lapsed?/2`), each with its
  reason in plain words, and makes the projections follow: the Needs Decision hold that carried it
  clears (`SymphonyElixir.Hold.clear/4`), and the `## Action withdrawn` reply goes under its request
  comment: the pause projector posts it from the Question (`SymphonyElixir.Pauses.Projector`), or,
  while it does not own the comments, this function does when the Inbox lists the request. A
  question Unblock answers (`held/1`: a run's block report, a dispatch loop) is decided by Unblock
  and Restart, so only a merge or a terminal state withdraws it here. It and a question a Needs
  Decision hold carries hold the ticket, so a run ending never withdraws them. Each withdrawal records its `t:cause/0`. Best-effort: a hold or a reply that fails is logged, and the
  Inbox's next read reconciles the hold. Returns the questions withdrawn.

  `opts[:store]` and `opts[:tracker]` override the run store and the tracker the holds are read and
  written through, and `opts[:replies]` the tracker the reply is posted with (default
  `SymphonyElixir.Tracker`). The reply goes under the request comment the ticket's record names.
  """
  @spec withdraw_lapsed(ticket(), lapse(), keyword()) :: {:ok, [question()]}
  def withdraw_lapsed(ticket, lapse, opts \\ []) do
    # The hold's question first: `held/1`'s contract narrows `ticket`, and a malformed one still withdraws nothing.
    deciding = held_question(ticket, :needs_decision, opts)
    blocked = with %{id: id} <- held(ticket), do: id
    holding = [deciding, blocked]

    withdrawn =
      for question <- open(ticket),
          final?(lapse) or question.id != blocked,
          not (run_ended?(lapse) and question.id in holding),
          reason <- List.wrap(lapse_reason(question, lapse)),
          {:ok, withdrawn} <- [withdraw(ticket, question.id, reason, cause: lapse_cause(lapse))] do
        project_withdrawal(ticket, withdrawn, reason, opts)
        withdrawn
      end

    {:ok, withdrawn}
  end

  defp lapse_reason(%{state: :open} = question, lapse), do: open_lapse_reason(question, lapse)
  defp lapse_reason(_question, _lapse), do: nil

  defp open_lapse_reason(question, :restart) do
    if run_asked?(question),
      do: "The run that asked was restarted.",
      else: "The ticket was restarted from main and its pull request closed."
  end

  defp open_lapse_reason(question, :backlog) do
    if run_asked?(question), do: "The ticket was moved to Backlog, which stopped the run that asked."
  end

  defp open_lapse_reason(_question, :merged), do: "The pull request merged before you answered."

  defp open_lapse_reason(_question, {:terminal, state}) do
    if String.downcase(state) in ["canceled", "cancelled"],
      do: "The ticket was cancelled.",
      else: "The ticket moved to #{state} before you answered."
  end

  defp open_lapse_reason(question, {:run_ended, %{moved_to: to} = run}) when is_binary(to) do
    if run_asked?(question) and question.request != true and asked_in?(question, run), do: "The run that asked ended and the ticket moved on to #{to}."
  end

  defp open_lapse_reason(_question, {:run_ended, _run}), do: nil

  defp run_asked?(question), do: question.asked_by.kind == :run

  # The run that asked: the one the question names, else the one running when it was asked.
  defp asked_in?(question, run) do
    case Map.get(question.asked_by, :run_id) do
      id when is_binary(id) -> id == run.run_id
      nil -> during?(question.asked_at, run)
    end
  end

  defp during?(at, %{started_at: %DateTime{} = started, ended_at: ended}),
    do: DateTime.compare(at, started) != :lt and DateTime.compare(at, ended) != :gt

  defp during?(_at, _run), do: false

  defp final?(lapse), do: lapse == :merged or match?({:terminal, _state}, lapse)

  defp run_ended?(lapse), do: match?({:run_ended, _run}, lapse)

  defp lapse_cause(:restart), do: "restarted"
  defp lapse_cause({:run_ended, _run}), do: "run_ended"
  defp lapse_cause(_moved), do: "ticket_moved"

  # The question the ticket's hold of `kind` carries, or nil.
  defp held_question({:ticket, repo_key, issue_id}, kind, opts) do
    case Hold.get(repo_key, issue_id, kind, Keyword.take(opts, [:store])) do
      %{decision: %{question_id: id}} -> id
      _none -> nil
    end
  end

  defp held_question(_ticket, _kind, _opts), do: nil

  defp project_withdrawal({:ticket, repo_key, issue_id}, question, reason, opts) do
    hold_opts = Keyword.take(opts, [:store, :tracker])

    if get_in(Hold.get(repo_key, issue_id, :needs_decision, hold_opts) || %{}, [:decision, :question_id]) == question.id do
      with {:error, error} <- Hold.clear(repo_key, issue_id, :needs_decision, hold_opts) do
        Logger.warning("Withdrew question #{question.id} on issue_id=#{issue_id}; its needs_decision hold did not clear: #{inspect(error)}")
      end
    end

    # The pause projector posts the reply from the withdrawn Question when it owns the comments.
    if not Projector.owns?(), do: reply_withdrawn(issue_id, request_comment_id(repo_key, issue_id, question.id), reason, opts)
  end

  defp reply_withdrawn(_issue_id, nil, _reason, _opts), do: :ok

  defp reply_withdrawn(issue_id, comment_id, reason, opts) do
    with {:error, error} <- Keyword.get(opts, :replies, Tracker).create_reply(issue_id, comment_id, Request.render_withdrawal(reason)) do
      Logger.warning("Withdrew a question on issue_id=#{issue_id}; Linear refused its withdrawal reply: #{inspect(error)}")
    end
  end

  # The request comment the pause projector wrote or found for the question, as the ticket's record
  # keeps it: no Linear read.
  defp request_comment_id(repo_key, issue_id, question_id) do
    case RunStore.get_ticket_state(repo_key, issue_id) do
      %{projected: %{comments: %{^question_id => %{comment: comment_id}}}} -> comment_id
      _none -> nil
    end
  end

  @doc """
  The answers on a ticket's record as the PR watcher reads them: the legacy `decisions` in their
  order, each one an answered question in `questions` also gives (the same title and answer: a
  Decide records both) read as that question's entry, then the answered questions no decision
  records yet, in the order they were asked. An answered question reads as a decision entry: its
  title, question and answer text, keyed by its id. So an answer reads as soon as it is given, and
  once only. A decision recording an answer the Director took back (`reopen/3`) reads as nothing:
  the Decisions entry stays, but the answer no longer counts.
  """
  @spec answers([map()], [question()]) :: [map()]
  def answers(decisions, questions) when is_list(decisions) and is_list(questions) do
    answered =
      for %{state: :answered, answer: %{text: text}} = question <- questions do
        %{key: question.id, date: DateTime.to_date(question.answer.at), title: question.title, question: question.question, answer: text}
      end

    taken_back = for question <- questions, text <- taken_back(question), do: %{title: question.title, answer: text}

    {read, {unrecorded, _taken_back}} = Enum.flat_map_reduce(decisions, {answered, taken_back}, &recorded_answer/2)
    read ++ unrecorded
  end

  defp recorded_answer(decision, {answered, taken_back}) do
    matching = &Enum.find_index(&1, fn entry -> same_answer?(entry, decision) end)

    case {matching.(answered), matching.(taken_back)} do
      {nil, nil} -> {[decision], {answered, taken_back}}
      {nil, index} -> {[], {answered, List.delete_at(taken_back, index)}}
      {index, _taken_back} -> {[Enum.at(answered, index)], {List.delete_at(answered, index), taken_back}}
    end
  end

  # The answers taken back from a question, oldest first; none on a question stored before Undo.
  defp taken_back(question), do: Map.get(question, :taken_back, [])

  # The decision section keeps an answer on one line, cut to its length.
  defp same_answer?(entry, decision) do
    recorded = title_key(Map.get(decision, :answer))
    title_key(entry.title) == title_key(Map.get(decision, :title)) and recorded != "" and String.starts_with?(title_key(entry.answer), recorded)
  end

  @doc "The questions on `ticket` still waiting for an answer, in the order they were asked."
  @spec open(ticket()) :: [question()]
  def open(ticket), do: ticket |> questions() |> Enum.filter(&(&1.state == :open))

  @doc "The questions on `ticket` a person answered, in the order they were asked."
  @spec answered(ticket()) :: [question()]
  def answered(ticket), do: ticket |> questions() |> Enum.filter(&(&1.state == :answered))

  @doc """
  The open question on `ticket` that the Director's Unblock answers: one Symphony asked when it
  paused the ticket on a dispatch loop or a quiet handoff (`SymphonyElixir.DispatchLoop`), an idle
  run's park (`SymphonyElixir.IdlePark`), or a
  run's block report asked (`SymphonyElixir.TransitionGuard.block_report_question/1`), known by its
  Unblock option. The newest when there are several; nil when there is none.
  """
  @spec held(ticket()) :: question() | nil
  def held(ticket) do
    labels = [DispatchLoop.option_label(:unblock), TransitionGuard.unblock_option()]
    ticket |> open() |> Enum.filter(fn question -> Enum.any?(question.options, &(&1.label in labels)) end) |> List.last()
  end

  @doc "The question `id` on `ticket`, whatever its state, or nil."
  @spec find(ticket(), String.t()) :: question() | nil
  def find(ticket, id), do: ticket |> questions() |> Enum.find(&(&1.id == id))

  @doc "The open question on `ticket` with `request`'s title and question, as `ask/3` would return it, or nil."
  @spec open_asking(ticket(), map()) :: question() | nil
  def open_asking(ticket, request) when is_map(request) do
    key = {line(Map.get(request, :title)), line(Map.get(request, :question))}
    ticket |> open() |> Enum.find(&({&1.title, &1.question} == key))
  end

  @doc "Whether `ticket` has an open question with `request`'s title and question, as `ask/3` would return."
  @spec same_open?(ticket(), map()) :: boolean()
  def same_open?(ticket, request) when is_map(request), do: open_asking(ticket, request) != nil

  @doc """
  The questions as stored or given: each a map with a string `id` and a known `state`, once by id;
  anything else is dropped. Every field a question stored before it existed lacks reads as its
  default (`unblocks`, `request`, `asked_in` and `reopened_at` nil, `taken_back` empty; on each
  option, no trade-offs, not recommended and nothing unlocked), so a reader of the record never
  meets a missing key: a question the backfill wrote from an old decision comment carries only
  what that comment had.
  """
  @spec normalize(term()) :: [question()]
  def normalize(questions) when is_list(questions) do
    for(%{id: id, state: state} = question <- questions, is_binary(id) and state in @states, do: question)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&with_defaults/1)
  end

  def normalize(_questions), do: []

  defp with_defaults(question) do
    question = Map.merge(@question_defaults, question)
    %{question | options: question.options |> List.wrap() |> Enum.filter(&is_map/1) |> Enum.map(&Map.merge(@option_defaults, &1)), taken_back: List.wrap(question.taken_back)}
  end

  # The changes, from the questions and the pause the store read under its lock: pure, as the store
  # may run them more than once.
  defp asked(ticket, questions, pause, question, backfilled?) do
    case Enum.find(questions, &same?(&1, question)) do
      nil ->
        at = question.asked_at
        event = {"question.asked", asked_payload(question, backfilled?), [at: at, idempotency: asked_key(question, backfilled?)]}
        pause_opts = [set_by: Map.take(question.asked_by, [:kind, :name]), at: at, backfilled: backfilled?]
        write(ticket, question, event, paused(ticket, pause, question, pause_opts))

      asked ->
        {:ok, asked}
    end
  end

  # The question already asked: the one with its id, or an open one with its title and text.
  defp same?(asked, question) do
    asked.id == question.id or
      (asked.state == :open and question.state == :open and {asked.title, asked.question} == {question.title, question.question})
  end

  # An open question pauses the ticket on it; a backfilled answered one leaves the pause as it is.
  defp paused(ticket, pause, %{state: :open} = question, opts), do: Pauses.set_change(ticket, pause, reason(question), opts)
  defp paused(_ticket, pause, _answered, _opts), do: {:ok, pause, []}

  defp asked_key(question, true), do: "backfill:question.asked:#{question.id}"
  defp asked_key(_question, false), do: nil

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

      event = {"question.answered", payload, [at: given.at, idempotency: answered_key(question)]}
      write(ticket, question, event, unpaused(ticket, pause, id, given.by, given.at))
    end
  end

  defp withdrawn(ticket, questions, pause, id, {reason, cause}, by, at) do
    with {:ok, question} <- open_question(questions, id) do
      question = %{question | state: :withdrawn, withdrawn: %{reason: reason, at: at}}
      payload = %{question_id: id, title: question.title, reason: reason, by: by} |> put_present(:cause, cause)
      write(ticket, question, {"question.withdrawn", payload, [at: at]}, unpaused(ticket, pause, id, by, at))
    end
  end

  defp reopened(ticket, questions, pause, id, by, at) do
    case Enum.find(questions, &(&1.id == id)) do
      %{state: :answered} = question ->
        taken_back = taken_back(question) ++ [question.answer.text]
        question = question |> Map.merge(%{state: :open, answer: nil, reopened_at: at, taken_back: taken_back})
        payload = %{question_id: id, title: question.title, by: by}
        event = {"question.reopened", payload, [at: at, idempotency: "question.reopened:#{id}:#{stamp(at)}"]}
        write(ticket, question, event, Pauses.set_change(ticket, pause, reason(question), set_by: by, at: at))

      nil ->
        {:error, :question_not_found}

      %{state: state} ->
        {:error, {:question_not_answered, state}}
    end
  end

  # An answer after a reopen is a new answer: its event's key names the reopen, so the ledger keeps both.
  defp answered_key(%{reopened_at: %DateTime{} = at, id: id}), do: "question.answered:#{id}:#{stamp(at)}"
  defp answered_key(_question), do: nil

  defp stamp(at), do: DateTime.to_unix(at, :microsecond)

  # The question with its event, and the pause as its change leaves it with that change's events,
  # for the store to write in one transaction.
  defp write({:ticket, repo_key, issue_id}, question, {type, payload, event_opts}, pause_change) do
    with {:ok, event} <- TicketEvents.build(repo_key, issue_id, type, payload, event_opts),
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

  defp title_key(title), do: String.downcase(line(title) || "")

  defp update(repo_key, issue_id, at, fun) do
    with {:ok, question, events} <- RunStore.update_ticket_question(repo_key, issue_id, at, fun) do
      Enum.each(events, &TicketEvents.notify/1)
      if events != [], do: Projector.project_now({:ticket, repo_key, issue_id})
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
      unblocks: line(Map.get(request, :unblocks)),
      request: Keyword.get(opts, :request) == true,
      asked_in: line(Keyword.get(opts, :asked_in)),
      state: :open,
      answer: nil,
      asked_at: at,
      withdrawn: nil,
      legacy_event: nil,
      reopened_at: nil,
      taken_back: []
    }
    |> backfilled(opts, Keyword.get(opts, :backfilled) == true)
  end

  # A backfilled question keeps the id, the answer and the legacy event the backfill gives it.
  defp backfilled(question, opts, true) do
    # Whether a request comment shows it is read from the holds, as before questions carried it.
    question = %{question | id: Keyword.get(opts, :id) || question.id, legacy_event: Keyword.get(opts, :legacy_event), request: nil}

    case Keyword.get(opts, :answer) do
      %{} = answer -> %{question | state: :answered, answer: answer}
      _open -> question
    end
  end

  defp backfilled(question, _opts, false), do: question

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

  defp asked_payload(question, backfilled?) do
    payload =
      question
      |> Map.take([:title, :question, :why, :if_unanswered, :options, :recommendation_reason, :confirm, :step, :asked_by])
      |> Map.put(:question_id, question.id)
      # A backfilled question may lack the fields the standard asks for; the ledger takes no blank.
      |> Map.reject(fn {_field, value} -> value == "" end)

    if backfilled?, do: Map.put(payload, :source, :backfill), else: payload
  end

  # A backfilled question was asked before: the standard is not checked again.
  defp check(request, true) when is_map(request), do: :ok
  defp check(request, _backfilled?), do: check(request)

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

  defp cause(cause) when is_nil(cause) or cause in @causes, do: {:ok, cause}
  defp cause(cause), do: {:error, {:invalid_option, {:cause, cause}}}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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
