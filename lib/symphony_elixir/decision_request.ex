defmodule SymphonyElixir.DecisionRequest do
  @moduledoc """
  The one writer of a question for a person, whoever asks it: an agent's
  `linear_request_human_action`, a plan run's open choices, a rework that failed the same way twice,
  and Symphony's own requests (a merge confirmation, a closed or missing pull request, a protected
  file, a dependency change, a check that never reported, a Code Review or QA escalation, a stuck
  self-heal).

  `ask/4` checks the request against the standard (`check/1`,
  `docs/standards/decision-writing.md`) and asks it as a Question first
  (`SymphonyElixir.Questions.ask/3`, which records `question.asked` and pauses the ticket on it).
  The Needs Decision hold and the `## Decision needed:` comment the Inbox lists
  (`SymphonyElixir.HumanActions.Request`) are its projections until the Inbox reads Questions: the
  hold carries the question's id in its decision (`question_id`) and the comment in a hidden line,
  `<!-- symphony:question <id> -->`. A request that misses the standard is refused, and the asker
  rewrites it: an agent reads the message and calls again, and Symphony's own requests are written
  to pass, quoting text from elsewhere through `SymphonyElixir.HumanActions.PlainWords.scrub/1`.

  `project/4` sets the hold again for a request already on Linear, as the Inbox's reconciliation
  and an agent's repeated request do, and `repost/5` posts a request comment whose post failed. No
  other code sets a Needs Decision hold or posts a request.
  """

  require Logger

  alias SymphonyElixir.{Hold, NeedsDecisionHold, Questions, RunStore, TicketSignals, TicketState}
  alias SymphonyElixir.HumanActions.{PlainWords, Request}

  @title_max_length 120
  @question_line ~r/^<!--\s*symphony:question\s+(\S+)\s*-->\s*$/m
  @option_count 2..4
  @max_tradeoffs 3

  @doc "How many options a request offers: two to four."
  @spec option_count() :: Range.t()
  def option_count, do: @option_count

  @doc "The most trade-offs one option may carry."
  @spec max_tradeoffs() :: pos_integer()
  def max_tradeoffs, do: @max_tradeoffs

  @doc """
  `:ok` when `request` meets the standard, else `{:error, message}` naming the first field that
  misses it, as the tool's input names it. The standard: a title of at most
  #{@title_max_length} characters, a question, why it is asked, what happens if nobody answers,
  #{@option_count.first} to #{@option_count.last} options each with a label and what it does, exactly
  one of them recommended with the reason why, at most #{@max_tradeoffs} trade-offs an option, and
  no code or internal word in any of it (`SymphonyElixir.HumanActions.PlainWords`).
  """
  @spec check(map()) :: :ok | {:error, String.t()}
  def check(request) when is_map(request) do
    case Enum.find(checks(request), fn {valid?, _message} -> not valid?.() end) do
      {_check, message} -> {:error, message}
      nil -> PlainWords.check(request)
    end
  end

  # In order, and lazy: a later check relies on the earlier ones having passed.
  defp checks(request) do
    options = Map.get(request, :options)

    [
      {fn -> text?(Map.get(request, :title)) end, "`title` must say the decision in a few words."},
      {fn -> String.length(Request.one_line(request.title)) <= @title_max_length end, "`title` must be at most #{@title_max_length} characters."},
      {fn -> text?(Map.get(request, :question)) end, "`decision.question` must ask the one question the person answers."},
      {fn -> text?(Map.get(request, :why)) end, "`why` must say what happened and why it needs a person."},
      {fn -> is_list(options) and length(options) in @option_count end,
       "`decision.options` must list #{@option_count.first} to #{@option_count.last} options, each with a `label` and an `effect`; " <>
         "with no real choice to make, there is nothing to ask a person."},
      {fn -> Enum.all?(options, &option?/1) end, "Each of `decision.options` needs a non-blank `label` and `effect`."},
      {fn -> Enum.count(options, &(Map.get(&1, :recommended) == true)) == 1 end, "Exactly one of `decision.options` must be `recommended`."},
      {fn -> Enum.all?(options, &tradeoffs?(Map.get(&1, :tradeoffs))) end,
       "Each option's `tradeoffs` lists at most #{@max_tradeoffs}, each with a `kind` (#{Enum.join(Request.tradeoff_kinds(), ", ")}) and a non-blank `text`."},
      {fn -> text?(Map.get(request, :if_unanswered)) end, "`if_unanswered` must say what waits or repeats until someone answers."},
      {fn -> text?(Map.get(request, :recommendation_reason)) end, "`decision.recommendation_reason` must say in one line why the recommended option is the one to pick."}
    ]
  end

  defp option?(%{} = option), do: text?(Map.get(option, :label)) and text?(Map.get(option, :effect))
  defp option?(_option), do: false

  defp tradeoffs?(nil), do: true
  defp tradeoffs?(tradeoffs) when is_list(tradeoffs) and length(tradeoffs) <= @max_tradeoffs, do: Enum.all?(tradeoffs, &tradeoff?/1)
  defp tradeoffs?(_tradeoffs), do: false

  defp tradeoff?(%{kind: kind, text: text}), do: kind in Request.tradeoff_kinds() and text?(text)
  defp tradeoff?(_tradeoff), do: false

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  @doc """
  Asks a person `request` on `issue`, which pauses in its phase until they answer: checks it
  (`check/1`), asks it as a Question (`SymphonyElixir.Questions.ask/3`), sets the Needs Decision hold
  carrying it, then posts it as the `## Decision needed:` comment rendered to say the ticket stays
  where it is. `confirm`, when given, is the state a confirmation continues into, as a merge
  confirmation's does (`SymphonyElixir.MergeConfirmation.confirm_target/1`); without it the ticket
  continues in place once the decision is recorded.

  The same question asked again while it is open is the one Question: when the hold already carries
  it, nothing is posted again and the answer is `:ok`. A different question asked while another is
  open takes the hold and leaves the other open, as its request is on Linear: once the newer one is
  answered the Inbox sets the hold back to it (`project/4`), and an answer to it given meanwhile
  ends it (`SymphonyElixir.NeedsDecisionHold`). A hold that can't be set posts nothing, so a
  retry posts the comment once. A comment that can't be posted takes nothing back: the Question and
  the hold stay, the comment is marked pending on the ticket's record (`{:question_comment, id}`) and
  the Inbox's next sweep posts it (`repost/5`); the caller still gets the post's error.

  `issue` needs `:id` and `:state`, and `:repo_key` unless `opts[:repo_key]` names it.
  `opts[:post]` posts the rendered comment (`(body -> :ok | {:ok, term} | {:error, term})`), as the
  agent tool does through its own Linear client; without it `opts[:tracker]` (default
  `SymphonyElixir.Tracker`) creates the comment. `opts[:label_tracker]` writes the hold's label
  (default `SymphonyElixir.Tracker`), `opts[:store]` overrides the run store the hold is written
  through, and `opts[:asked_by]` names who asks (`SymphonyElixir.Questions.ask/3`, default Symphony).
  Answers what the post answered: `:ok`, or `{:ok, term}` from a custom `:post`.
  """
  @spec ask(map(), map(), keyword(), String.t() | nil) :: :ok | {:ok, term()} | {:error, term()}
  def ask(%{id: issue_id} = issue, request, opts, confirm \\ nil) do
    repo_key = Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)
    hold_opts = opts |> Keyword.take([:store]) |> label_tracker(opts[:label_tracker])

    with {:check, :ok} <- {:check, check(request)},
         {:question, {:ok, question}} <- {:question, ask_question(repo_key, issue_id, request, opts, confirm)},
         asked? = asked?(repo_key, issue_id, question, hold_opts),
         attrs = request |> NeedsDecisionHold.attrs() |> confirming(confirm, Map.get(issue, :state)) |> with_question(question),
         {:hold, :ok} <- {:hold, Hold.set(repo_key, issue_id, :needs_decision, attrs, hold_opts)},
         body = comment(request, question, Map.get(issue, :state)),
         posted = post_once(asked?, {repo_key, issue_id}, question, body, opts),
         {:post, posted} when posted == :ok or elem(posted, 0) == :ok <- {:post, posted} do
      posted
    else
      {:check, {:error, message}} ->
        Logger.error("Refused a decision request on issue_id=#{issue_id} that misses the standard: #{message}")
        {:error, {:invalid_decision_request, message}}

      {:question, {:error, reason}} ->
        {:error, {:decision_hold_failed, reason}}

      {:hold, {:error, reason}} ->
        {:error, {:decision_hold_failed, reason}}

      {:post, {:error, reason}} ->
        Logger.warning("Failed to post the decision request on issue_id=#{issue_id}; the question stays open and the Inbox posts it: #{inspect(reason)}")
        {:error, {:decision_request_failed, reason}}
    end
  end

  # The Question goes first: it is the truth the hold and the comment project. A ticket with no
  # repo key is refused, and logged, by the hold's own check, as before.
  defp ask_question(repo_key, issue_id, request, opts, confirm) when is_binary(repo_key) and repo_key != "" do
    question_opts = [confirm: confirm] ++ Keyword.take(opts, [:asked_by])
    Questions.ask({:ticket, repo_key, issue_id}, request, question_opts)
  end

  defp ask_question(repo_key, issue_id, _request, _opts, _confirm), do: Hold.set(repo_key, issue_id, :needs_decision)

  # Whether the hold already carries this question: it was asked before, and its comment posted or
  # marked pending.
  defp asked?(repo_key, issue_id, question, hold_opts) do
    case Hold.get(repo_key, issue_id, :needs_decision, hold_opts) do
      %{decision: %{question_id: id}} -> id == question.id
      _none -> false
    end
  end

  defp with_question(attrs, question), do: %{attrs | decision: Map.put(attrs.decision, :question_id, question.id)}

  # A comment that can't be posted is marked pending on the record, so the Inbox posts it.
  defp post_once(true = _asked?, _ticket, _question, _body, _opts), do: :ok

  defp post_once(false = _asked?, {repo_key, issue_id}, question, body, opts) do
    with {:error, reason} <- post(issue_id, body, opts) do
      TicketSignals.mark_projection(repo_key, issue_id, {:question_comment, question.id}, reason)
      {:error, reason}
    end
  end

  # The comment a request posts: rendered for the Director, with the question's id in a hidden line.
  defp comment(request, question, state), do: Request.render_hold(request, state) <> "\n\n<!-- symphony:question #{question.id} -->"

  @doc "The id of the question a request comment's hidden line names (`ask/4` writes it), or nil."
  @spec question_id(String.t() | nil) :: String.t() | nil
  def question_id(body) when is_binary(body) do
    case Regex.run(@question_line, body, capture: :all_but_first) do
      [id] -> id
      nil -> nil
    end
  end

  def question_id(_body), do: nil

  # A confirmation also records the state the ticket waits in, so a person's move made after the
  # request wins over the move the answer would perform (`SymphonyElixir.NeedsDecisionHold`).
  defp confirming(attrs, nil, _state), do: attrs
  defp confirming(attrs, confirm, state), do: %{attrs | decision: attrs.decision |> Map.put(:confirm, confirm) |> Map.put(:state, state)}

  defp label_tracker(hold_opts, nil), do: hold_opts
  defp label_tracker(hold_opts, tracker), do: Keyword.put(hold_opts, :tracker, tracker)

  defp post(issue_id, body, opts) do
    case Keyword.fetch(opts, :post) do
      {:ok, post} -> post.(body)
      :error -> Keyword.get(opts, :tracker, SymphonyElixir.Tracker).create_comment(issue_id, body)
    end
  end

  @doc """
  Posts the request comment of the question `hold` carries when its post failed (`ask/4` marked it
  pending on the ticket's record), rendered from the Question as `ask/4` renders it, for a ticket in
  `state`: the Inbox's sweep calls it for a held ticket whose comments show no request for it.
  Returns `:none` when there is nothing to post (no pending comment, or a question no longer open,
  whose mark is dropped), `:posted` once it is posted and its mark dropped, and `:pending` when the
  post failed again. `opts[:tracker]` (default `SymphonyElixir.Tracker`) creates the comment.
  """
  @spec repost(String.t(), String.t(), map() | nil, String.t() | nil, keyword()) :: :none | :posted | :pending
  def repost(repo_key, issue_id, hold, state, opts) do
    with id when is_binary(id) <- get_in(hold || %{}, [:decision, :question_id]),
         %{} = mark <- pending_comment(repo_key, issue_id, id) do
      repost_question(repo_key, issue_id, Questions.find({:ticket, repo_key, issue_id}, id), mark, state, opts)
    else
      _nothing_pending -> :none
    end
  end

  defp repost_question(repo_key, issue_id, %{state: :open} = question, mark, state, opts) do
    case Keyword.get(opts, :tracker, SymphonyElixir.Tracker).create_comment(issue_id, comment(request(question), question, state)) do
      :ok ->
        TicketSignals.clear_projection(repo_key, issue_id, mark)
        :posted

      {:error, reason} ->
        Logger.warning("Failed again to post the decision request on issue_id=#{issue_id}: #{inspect(reason)}")
        :pending
    end
  end

  defp repost_question(repo_key, issue_id, _ended, mark, _state, _opts) do
    TicketSignals.clear_projection(repo_key, issue_id, mark)
    :none
  end

  defp pending_comment(repo_key, issue_id, id) do
    case RunStore.get_ticket_state(repo_key, issue_id) do
      %{} = record -> record |> TicketState.normalize() |> Map.fetch!(:pending_projection) |> Enum.find(&(TicketState.projection_of(&1) == {:question_comment, id}))
      _none -> nil
    end
  end

  # The request a Question was asked with, as `Request.render_hold/2` reads it.
  defp request(question) do
    options =
      for option <- question.options do
        tradeoffs = for {kind, key} <- [{"good", :good}, {"cost", :cost}, {"risk", :risk}], text <- Map.get(option, key, []), do: %{kind: kind, text: text}
        %{label: option.label, effect: option.effect, recommended: option.recommended?, tradeoffs: tradeoffs, unlocks: option.unlocks}
      end

    question |> Map.take([:title, :question, :why, :if_unanswered, :recommendation_reason]) |> Map.put(:options, options)
  end

  @doc """
  Sets the Needs Decision hold again for a request already posted on the ticket, with the hold
  payload `attrs` (`SymphonyElixir.NeedsDecisionHold.attrs/1`): the Inbox's reconciliation does it
  for the newest open request, and the agent tool for a request the ticket already has. The
  request passed the standard when it was asked, so it is not checked again. A request asked as a
  Question still open (the same title and question, `SymphonyElixir.Questions.open_asking/2`) is set
  carrying it, as `ask/4` sets it: a hold that moved on to a newer request and comes back to this one
  records no second request, and the answer that clears it ends that Question. `opts[:store]` and
  `opts[:tracker]` override the run store and the tracker the label is written through.
  """
  @spec project(String.t() | nil, String.t(), map(), keyword()) :: :ok | {:error, term()}
  def project(repo_key, issue_id, attrs, opts),
    do: Hold.set(repo_key, issue_id, :needs_decision, with_open_question(repo_key, issue_id, attrs), Keyword.take(opts, [:store, :tracker]))

  defp with_open_question(repo_key, issue_id, %{decision: %{} = decision} = attrs) when is_binary(repo_key) and repo_key != "" do
    case Questions.open_asking({:ticket, repo_key, issue_id}, decision) do
      %{} = question -> with_question(attrs, question)
      nil -> attrs
    end
  end

  defp with_open_question(_repo_key, _issue_id, attrs), do: attrs
end
