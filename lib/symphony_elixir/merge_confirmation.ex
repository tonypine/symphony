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
  move — the Inbox's Send to Rework — and goes through the guard the same way.

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

  defp post_request(issue, opts, request) do
    case tracker(opts).create_comment(issue.id, Request.render_hold(request, issue.state)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:merge_confirmation_request_failed, reason}}
    end
  end

  defp set_hold(issue, opts, request) do
    case Hold.set(repo_key(issue, opts), issue.id, :needs_decision, attrs(request), store_opts(opts)) do
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
        label: "Send to Rework",
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
