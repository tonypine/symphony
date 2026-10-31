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
  The Question is the only truth: the `Needs Decision` label, the Decisions section and the
  `## Decision needed:` comment (`SymphonyElixir.HumanActions.Request`, carrying the question's id
  in a hidden line, `<!-- symphony:question <id> -->`) are its projections
  (`SymphonyElixir.Pauses.Projector`). A request that misses the standard is refused, and the asker
  rewrites it: an agent reads the message and calls again, and Symphony's own requests are written
  to pass, quoting text from elsewhere through `SymphonyElixir.HumanActions.PlainWords.scrub/1`. No
  other code asks a person or posts a request.
  """

  require Logger

  alias SymphonyElixir.HumanActions.{PlainWords, Request}
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.Questions
  alias SymphonyElixir.TicketSignals

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
  (`check/1`), asks it as a Question (`SymphonyElixir.Questions.ask/3`), then posts it as the
  `## Decision needed:` comment rendered to say the ticket stays where it is. `confirm`, when given,
  is the state a confirmation continues into, as a merge confirmation's does
  (`SymphonyElixir.MergeConfirmation.confirm_target/1`); without it the ticket continues in place
  once the decision is recorded.

  The same question asked again while it is open is the one Question: nothing is posted again and
  the answer is `:ok`. A different question asked while another is open is a second Question, and
  both stay open until each is answered. A comment that can't be posted takes nothing back: the
  Question stays, the comment is marked pending on the ticket's record (`{:question_comment, id}`)
  and the caller gets the post's error.

  While the pause projector owns the request comments (`SymphonyElixir.Pauses.Projector.owns?/0`),
  `ask/4` posts nothing: the Question is asked with `request: true` and the phase it is asked in,
  and the projector posts its comment once from it (`Request.render_question/2`), marking its
  projection pending when Linear refuses it. The answer is then `:ok`.

  `issue` needs `:id` and `:state`, and `:repo_key` unless `opts[:repo_key]` names it.
  `opts[:post]` posts the rendered comment (`(body -> :ok | {:ok, term} | {:error, term})`), as the
  agent tool does through its own Linear client; without it `opts[:tracker]` (default
  `SymphonyElixir.Tracker`) creates the comment. `opts[:asked_by]` names who asks
  (`SymphonyElixir.Questions.ask/3`, default Symphony). Answers what the post answered: `:ok`, or
  `{:ok, term}` from a custom `:post`.
  """
  @spec ask(map(), map(), keyword(), String.t() | nil) :: :ok | {:ok, term()} | {:error, term()}
  def ask(%{id: issue_id} = issue, request, opts, confirm \\ nil) do
    repo_key = Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)

    with {:check, :ok} <- {:check, check(request)},
         {:repo_key, :ok} <- {:repo_key, require_repo_key(repo_key, issue_id)},
         asked? = Questions.same_open?({:ticket, repo_key, issue_id}, request),
         {:question, {:ok, question}} <- {:question, ask_question(repo_key, issue_id, request, Map.get(issue, :state), opts, confirm)},
         body = comment(request, question, Map.get(issue, :state)),
         posted = post_once(asked? or Projector.owns?(), {repo_key, issue_id}, question, body, opts),
         {:post, posted} when posted == :ok or elem(posted, 0) == :ok <- {:post, posted} do
      posted
    else
      {:check, {:error, message}} ->
        Logger.error("Refused a decision request on issue_id=#{issue_id} that misses the standard: #{message}")
        {:error, {:invalid_decision_request, message}}

      {:repo_key, {:error, reason}} ->
        {:error, {:decision_hold_failed, reason}}

      {:question, {:error, reason}} ->
        {:error, {:decision_hold_failed, reason}}

      {:post, {:error, reason}} ->
        Logger.warning("Failed to post the decision request on issue_id=#{issue_id}; the question stays open: #{inspect(reason)}")
        {:error, {:decision_request_failed, reason}}
    end
  end

  # A question asked with no repo key would land nowhere the readers look, so it is refused loudly.
  defp require_repo_key(repo_key, _issue_id) when is_binary(repo_key) and repo_key != "", do: :ok

  defp require_repo_key(_repo_key, issue_id) do
    Logger.error("Refused a decision request on issue_id=#{issue_id} with no repo key; resolve the issue's repo first")
    {:error, :missing_repo_key}
  end

  # A request comment shows it in Linear (`request: true`), naming the phase it was asked in.
  defp ask_question(repo_key, issue_id, request, state, opts, confirm) do
    question_opts = [confirm: confirm, request: true, asked_in: state] ++ Keyword.take(opts, [:asked_by])
    Questions.ask({:ticket, repo_key, issue_id}, request, question_opts)
  end

  # A comment that can't be posted is marked pending on the record. A question asked before, or one
  # the pause projector posts from the Question, posts nothing here.
  defp post_once(true = _skip?, _ticket, _question, _body, _opts), do: :ok

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

  defp post(issue_id, body, opts) do
    case Keyword.fetch(opts, :post) do
      {:ok, post} -> post.(body)
      :error -> Keyword.get(opts, :tracker, SymphonyElixir.Tracker).create_comment(issue_id, body)
    end
  end
end
