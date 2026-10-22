defmodule SymphonyElixir.DecisionRequest do
  @moduledoc """
  The one writer of a question for a person, whoever asks it: an agent's
  `linear_request_human_action`, a plan run's open choices, a rework that failed the same way twice,
  and Symphony's own requests (a merge confirmation, a closed or missing pull request, a protected
  file, a dependency change, a check that never reported, a Code Review or QA escalation, a stuck
  self-heal).

  `ask/4` checks the request against the standard (`check/1`,
  `docs/standards/decision-writing.md`), sets the Needs Decision hold carrying it — which records
  the ledger's `decision.requested` (`SymphonyElixir.Hold`) — and posts it as the
  `## Decision needed:` comment the Inbox lists (`SymphonyElixir.HumanActions.Request`). A request
  that misses the standard is refused, and the asker rewrites it: an agent reads the message and
  calls again, and Symphony's own requests are written to pass, quoting text from elsewhere
  through `SymphonyElixir.HumanActions.PlainWords.scrub/1`.

  `project/4` sets the hold again for a request already on Linear, as the Inbox's reconciliation
  and an agent's repeated request do. No other code sets a Needs Decision hold or posts a request.
  """

  require Logger

  alias SymphonyElixir.{Hold, NeedsDecisionHold}
  alias SymphonyElixir.HumanActions.{PlainWords, Request}

  @title_max_length 120
  @option_count 2..4
  @max_tradeoffs 3

  @doc "The longest title a request may have, in characters."
  @spec title_max_length() :: pos_integer()
  def title_max_length, do: @title_max_length

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
  (`check/1`), sets the Needs Decision hold carrying it, then posts it as the `## Decision needed:`
  comment rendered to say the ticket stays where it is. The hold goes first, so a hold that can't be
  set posts nothing and a retry never posts the comment twice; a comment that can't be posted takes
  the hold back. `confirm`, when given, is the state a confirmation continues into, as a merge
  confirmation's does (`SymphonyElixir.MergeConfirmation.confirm_target/1`); without it the ticket
  continues in place once the decision is recorded.

  `issue` needs `:id` and `:state`, and `:repo_key` unless `opts[:repo_key]` names it.
  `opts[:post]` posts the rendered comment (`(body -> :ok | {:ok, term} | {:error, term})`), as the
  agent tool does through its own Linear client; without it `opts[:tracker]` (default
  `SymphonyElixir.Tracker`) creates the comment. `opts[:label_tracker]` writes the hold's label
  (default `SymphonyElixir.Tracker`), and `opts[:store]` overrides the run store. Answers
  what the post answered: `:ok`, or `{:ok, term}` from a custom `:post`.
  """
  @spec ask(map(), map(), keyword(), String.t() | nil) :: :ok | {:ok, term()} | {:error, term()}
  def ask(%{id: issue_id} = issue, request, opts, confirm \\ nil) do
    repo_key = Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)
    hold_opts = opts |> Keyword.take([:store]) |> label_tracker(opts[:label_tracker])
    attrs = confirming(NeedsDecisionHold.attrs(request), confirm, Map.get(issue, :state))

    with {:check, :ok} <- {:check, check(request)},
         {:hold, :ok} <- {:hold, Hold.set(repo_key, issue_id, :needs_decision, attrs, hold_opts)},
         {:post, posted} when posted == :ok or elem(posted, 0) == :ok <- {:post, post(issue_id, Request.render_hold(request, Map.get(issue, :state)), opts)} do
      posted
    else
      {:check, {:error, message}} ->
        Logger.error("Refused a decision request on issue_id=#{issue_id} that misses the standard: #{message}")
        {:error, {:invalid_decision_request, message}}

      {:hold, {:error, reason}} ->
        {:error, {:decision_hold_failed, reason}}

      {:post, {:error, reason}} ->
        Hold.clear(repo_key, issue_id, :needs_decision, hold_opts)
        {:error, {:decision_request_failed, reason}}
    end
  end

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
  Sets the Needs Decision hold again for a request already posted on the ticket, with the hold
  payload `attrs` (`SymphonyElixir.NeedsDecisionHold.attrs/1`): the Inbox's reconciliation does it
  for the newest open request, and the agent tool for a request the ticket already has. The
  request passed the standard when it was asked, so it is not checked again. `opts[:store]` and
  `opts[:tracker]` override the run store and the tracker the label is written through.
  """
  @spec project(String.t() | nil, String.t(), map(), keyword()) :: :ok | {:error, term()}
  def project(repo_key, issue_id, attrs, opts), do: Hold.set(repo_key, issue_id, :needs_decision, attrs, Keyword.take(opts, [:store, :tracker]))
end
