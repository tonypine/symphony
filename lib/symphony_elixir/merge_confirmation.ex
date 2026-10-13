defmodule SymphonyElixir.MergeConfirmation do
  @moduledoc """
  The merge-confirmation pause: with a repo's manual review `on`, the last step into `Merging` waits
  for a person.

  The design (`docs/design/state-machine.md` §Attributes, **Manual review**) makes the setting a
  choice about decision authority, not about verification: the machine verifies the same way either
  way. With it `on`, the verdicts that carry a ticket into `Merging` — a Code Review approval that
  skips QA, a QA pass, a QA skip — do not perform their move. Instead the ticket pauses where it is
  with a **Needs Decision hold** whose decision payload carries the summary a person needs to decide:
  the recommendation, the Code Review reasons, the QA result and the PR link.

  The pause is the ordinary decision request the rest of the machine already uses: the same
  `## Decision needed:` comment (`SymphonyElixir.HumanActions.Request`, rendered with
  `render_hold/2` so it says the ticket stays in its phase), and the same hold
  (`SymphonyElixir.NeedsDecisionHold`) the Inbox loop reconciles against it. The hold's decision
  payload also carries a `:confirm` target — `"Merging"` — which is what makes confirming continue
  into `Merging` exactly as when the setting is `off`: both the Inbox's Decide and a reply under the
  request clear the hold and then perform that move through the guard
  (`SymphonyElixir.DirectorMoves`, `SymphonyElixir.NeedsDecisionHold`). A redirect is a directed
  move — the Inbox's Send to Rework, or a reply naming that option (`reply_target/2`) — and goes
  through the guard the same way.

  Nothing else changes: rework verdicts never wait on a person, and CI Fix and holds behave the
  same in both modes. The gating itself lives in the guard's edge table, not here:
  `SymphonyElixir.TransitionGuard.confirmation_required?/2` is true only for the verdict rows into
  `Merging`, and only when the setting is `on`.
  """

  require Logger

  alias SymphonyElixir.{Handoff, Hold, NeedsDecisionHold, TransitionGuard}
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.Issue

  @merging_state "Merging"
  @rework_state "Rework"
  @confirm_target @merging_state
  @rework_label "Send to Rework"
  @change_state "In Progress"
  @review_signal "code_review"
  @part_max 240

  @typedoc """
  What a person deciding the merge is told: the recommendation, the Code Review reasons, the QA
  result and the PR link (`nil` when the ticket carries none yet).
  """
  @type summary :: %{
          recommendation: String.t() | nil,
          review: String.t() | nil,
          qa: String.t() | nil,
          pr: String.t() | nil
        }

  @doc """
  Pauses `issue` on the merge: posts the decision request carrying `summary` and sets the Needs
  Decision hold whose confirmation continues into `Merging`. `opts[:tracker]` and `opts[:store]`
  override the tracker and the run store (tests, a fake).
  """
  @spec pause(Issue.t(), keyword(), summary()) :: :ok | {:error, term()}
  def pause(%Issue{} = issue, opts, summary) do
    request = request(issue, summary)

    with :ok <- post_request(issue, opts, request) do
      set_hold(issue, opts, request)
    end
  end

  @doc """
  The summary a pause carries, from what the caller knows (`:recommendation` and `:qa`, and `:review`
  or `:pr` when it has them) filled in from the ticket itself: the reviewer's own reason, read from
  the ticket's newest `code_review` signal, and the ticket's PR.
  """
  @spec summary(Issue.t(), keyword(), map()) :: summary()
  def summary(%Issue{} = issue, opts, parts) do
    %{
      recommendation: Map.get(parts, :recommendation),
      review: Map.get(parts, :review) || review_reason(issue, opts),
      qa: Map.get(parts, :qa),
      pr: Map.get(parts, :pr) || pr_link(issue, opts)
    }
  end

  @doc """
  The decision request the pause posts: what confirming does, what it waits on and what redirecting
  does. Exposed so a caller can render or assert it without posting.
  """
  @spec request(Issue.t(), summary()) :: map()
  def request(%Issue{} = issue, summary) do
    %{
      title: "Merge #{label(issue)}",
      question: "Merge #{label(issue)} into its base branch?",
      why: why(summary),
      options: options(summary),
      est_minutes: 1
    }
  end

  @doc """
  The Needs Decision hold attrs the pause records: the request's own payload plus the `:confirm`
  target this hold's confirmation performs. Kept here rather than in `NeedsDecisionHold` because the
  carried move is what makes this hold a merge confirmation and not an ordinary decision.
  """
  @spec attrs(map()) :: map()
  def attrs(request) do
    attrs = NeedsDecisionHold.attrs(request)
    %{attrs | decision: Map.put(attrs.decision, :confirm, @confirm_target)}
  end

  @doc """
  The move a hold's confirmation performs, or nil when it carries none (every ordinary decision).
  `SymphonyElixir.DirectorMoves` and `SymphonyElixir.NeedsDecisionHold` read it to continue into
  `Merging` when the merge is confirmed.
  """
  @spec confirm_target(map() | nil) :: String.t() | nil
  def confirm_target(%{decision: %{} = decision}) do
    case Map.get(decision, :confirm) do
      target when is_binary(target) -> TransitionGuard.target(:director_move, %{target: target})
      _none -> nil
    end
  end

  def confirm_target(_hold), do: nil

  @doc """
  The move a reply under the request performs. A reply continues to the carried confirmation
  (`confirm_target/1`) only when it picks that option, and goes to `Rework` only when it picks the
  option that moves there (`picked/2`). Any other reply — free text, "neither", a question — is a
  change request: the ticket goes to `In Progress`, where the run addresses it on the same PR. A
  reply that picks an option moving nothing (CI's `Leave it`) moves nothing, and an ordinary
  decision's hold carries no confirmation, so its reply moves nothing either.
  """
  @spec reply_target(map() | nil, [String.t()]) :: String.t() | nil
  def reply_target(hold, replies) do
    case confirm_target(hold) do
      nil ->
        nil

      _carried ->
        case picked(hold, replies) do
          {:ok, target} -> target
          :none -> @change_state
        end
    end
  end

  @doc """
  The move the answers to a confirmation hold pick: `{:ok, target}` when they pick exactly one of
  its options — by number (`1`, `option 1`) or by label, alone, set off by punctuation, or followed only by confirming
  words such as `please` — where `target`
  is the carried confirmation, `Rework`, or nil for an option that moves nothing; `:none` when no
  answer picks an option, or the answers pick options that disagree.
  """
  @spec picked(map() | nil, [String.t()]) :: {:ok, String.t() | nil} | :none
  def picked(hold, answers) do
    carried = confirm_target(hold)
    options = hold |> get_in([:decision, :options]) |> List.wrap() |> Enum.map(&option/1)

    answers
    |> Enum.flat_map(&picks(&1, options))
    |> Enum.map(&option_target(&1, carried))
    |> Enum.uniq()
    |> case do
      [target] -> {:ok, target}
      _none_or_ambiguous -> :none
    end
  end

  # The options an answer picks: the one its number or label opens with.
  defp picks(answer, options) when is_binary(answer) do
    head = answer |> String.replace(~r/[*_`>#]/, "") |> String.trim() |> String.downcase()

    options
    |> Enum.with_index(1)
    |> Enum.filter(fn {{label, _effect}, index} -> opens_with?(head, "#{index}") or opens_with?(head, "option #{index}") or opens_with?(head, label) end)
    |> Enum.map(fn {option, _index} -> option end)
    |> Enum.take(1)
  end

  defp picks(_answer, _options), do: []

  defp opens_with?(_head, ""), do: false

  defp opens_with?(head, word) do
    case String.split_at(head, String.length(word)) do
      {^word, rest} -> confirming_tail?(rest)
      _other -> false
    end
  end

  # What may follow a pick: nothing, punctuation that sets it off (`Merge.`, `2. the tests are
  # thin`), or a few confirming words. A sentence that merely opens with an option's number or label
  # (`Merge conflicts remain`, `1 change needed`) is free text.
  @confirming_words ~w(please thanks thank you ok okay yes go ahead do it confirmed sounds good lgtm)

  defp confirming_tail?(rest) do
    Regex.match?(~r/^\s*([[:punct:]]|$)/u, rest) or
      rest |> String.split(~r/\s+/u, trim: true) |> Enum.all?(&(&1 in @confirming_words))
  end

  # An option as the hold records it: the tool's map, or the line Linear's comment reads back.
  defp option(%{} = option), do: {normalize(Map.get(option, :label) || Map.get(option, "label")), Map.get(option, :effect) || Map.get(option, "effect") || ""}

  defp option(line) when is_binary(line) do
    case Regex.run(~r/^\*\*(.+?)\*\*(?:\s*\(recommended\))?:\s*(.*)$/, String.trim(line)) do
      [_, label, effect] -> {normalize(label), effect}
      nil -> {"", line}
    end
  end

  defp option(_other), do: {"", ""}

  defp normalize(label) when is_binary(label), do: label |> String.replace(~r/[*_`]/, "") |> String.trim() |> String.downcase()
  defp normalize(_label), do: ""

  # What an option does, read from its effect: the carried move, Rework, or nothing.
  defp option_target({_label, effect}, carried) do
    effect = String.downcase(effect)

    cond do
      is_binary(carried) and String.contains?(effect, "moves to " <> String.downcase(carried)) -> carried
      String.contains?(effect, "moves to " <> String.downcase(@rework_state)) -> TransitionGuard.target(:director_move, %{target: @rework_state})
      true -> nil
    end
  end

  defp post_request(issue, opts, request) do
    case tracker(opts).create_comment(issue.id, Request.render_hold(request, issue.state)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:merge_confirmation_request_failed, reason}}
    end
  end

  defp set_hold(issue, opts, request) do
    attrs = attrs(request)
    attrs = %{attrs | decision: Map.put(attrs.decision, :state, issue.state)}

    case Hold.set(repo_key(issue, opts), issue.id, :needs_decision, attrs, store_opts(opts)) do
      :ok ->
        Logger.info("Merge confirmation for #{label(issue)}: manual review is on, so the step into Merging waits")
        :ok

      {:error, reason} ->
        {:error, {:merge_confirmation_hold_failed, reason}}
    end
  end

  # The summary, as the one line the request renders: each part says what it knows and nothing when
  # it doesn't, so the request carries what the mode needs a person to weigh — recommendation, the
  # reviewer's reasons, the QA result and the PR.
  defp why(summary) do
    [
      {"Recommendation", Map.get(summary, :recommendation)},
      {"Code Review", Map.get(summary, :review)},
      {"QA", Map.get(summary, :qa)},
      {"PR", Map.get(summary, :pr)}
    ]
    |> Enum.flat_map(fn
      {_name, nil} -> []
      {name, value} -> ["#{name}: #{part(value)}"]
    end)
    |> Enum.join(" · ")
  end

  defp part(value) when is_binary(value) do
    value = value |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(value) > @part_max, do: String.slice(value, 0, @part_max - 3) <> "...", else: value
  end

  defp part(value), do: value |> inspect() |> part()

  defp options(summary) do
    [
      %{label: "Merge", effect: "the ticket moves to #{@merging_state} and the machinery merges it", recommended: true},
      %{
        label: @rework_label,
        effect: "the ticket moves to #{@rework_state} with this summary#{pr_clause(summary)}",
        recommended: false
      }
    ]
  end

  defp pr_clause(%{pr: pr}) when is_binary(pr), do: " and the PR #{pr}"
  defp pr_clause(_summary), do: ""

  # The reviewer's own reason, from the ticket's newest `code_review` signal: the approve rows
  # record it as `review_reason` (`SymphonyElixir.CodeReview`). A ticket whose reviewer left none
  # (an overridden reviewer, a hand-moved ticket) carries the approve's own reason instead.
  defp review_reason(issue, opts) do
    repo_key(issue, opts)
    |> Handoff.signals(issue.id)
    |> Enum.find(&(&1.name == @review_signal))
    |> case do
      nil -> nil
      %{details: details} -> Map.get(details, :review_reason) || Map.get(details, :reason)
    end
  end

  defp pr_link(%Issue{pr_urls: pr_urls}, opts) when is_list(pr_urls) do
    Keyword.get(opts, :pr_url) || List.first(pr_urls)
  end

  defp pr_link(_issue, opts), do: Keyword.get(opts, :pr_url)

  defp label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp label(%Issue{id: id}), do: inspect(id)

  defp repo_key(issue, opts), do: Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)

  defp tracker(opts), do: Keyword.get(opts, :tracker, SymphonyElixir.Tracker)

  defp store_opts(opts), do: Keyword.take(opts, [:store])
end
