defmodule SymphonyElixir.PlanComments do
  @moduledoc """
  Acts on people's comments on a `breakdown` parent's plan.

  A plan under review (the parent in `In Review`, none of its open sub-issues promoted out of
  `Backlog`) is revised in place: a person's new comment sends the parent back to `In Progress`,
  where the breakdown run picks it up, edits the plan, answers the comment and returns the parent
  to `In Review` (see `SymphonyElixir.Linear.Issue.unapproved_plan?/2`). An approved plan (the parent
  in the waiting state, or in `In Review` with sub-issues already promoted) is not changed from
  comments: under each new top-level comment Symphony replies once that, if it asks for a plan
  change, the change goes through `Rework`. Replies inside a thread get nothing.

  Only a person's comment counts. Integration bots are skipped, and so are Symphony's own comments:
  the ones its last run posted, by id, and the others by how they start, because Symphony and the
  reviewer can share one Linear user.
  """

  alias SymphonyElixir.{AgentLabels, BreakdownReview, HumanReview, SubIssueWait, Tracker}
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent.Report

  @reply_opener "If this asks for a change to the plan: Symphony doesn't change an approved plan from comments"
  # How the comments Symphony posts itself start: run failures, landing notes, quality gate
  # results and its own replies.
  @symphony_openers [
    "Symphony stopped ",
    "Symphony parked ",
    "Symphony couldn't ",
    "Symphony turned off ",
    "Symphony quality gate",
    @reply_opener
  ]

  @typedoc "A comment on the parent: `parent_id` names the thread's first comment for a reply, `bot?` an integration's."
  @type comment :: %{
          id: String.t() | nil,
          body: String.t() | nil,
          created_at: DateTime.t() | nil,
          parent_id: String.t() | nil,
          bot?: boolean()
        }

  @typedoc "What Symphony reads to act on the comments: the parent's state changes and its comments."
  @type feedback :: %{state_changes: [Tracker.state_change()], comments: [comment()]}

  @typedoc "`:revise` the plan under review, or `:answer` comments on an approved plan."
  @type action :: :revise | :answer

  @typedoc """
  Symphony's last run on the parent: when it started and ended, and the ids of the comments it
  posted (nil when unknown, as for a run from before a restart).
  """
  @type last_run :: %{started_at: DateTime.t() | nil, ended_at: DateTime.t() | nil, comment_ids: [String.t()] | nil}

  @doc """
  What a new comment on `issue` asks of Symphony: `:revise` for a `breakdown` parent in `In Review` (or Human Review)
  whose plan was not approved, `:answer` for one whose plan was (in the waiting state, or back in
  `In Review` with sub-issues under way), nil otherwise. A parent whose sub-issues are all terminal
  is left to its close-out.
  """
  @spec action(Issue.t() | term(), Enumerable.t(String.t()), term()) :: action() | nil
  def action(%Issue{state: state} = issue, terminal_states, settings) when is_binary(state) do
    cond do
      not Issue.breakdown?(issue) or Issue.close_out_ready?(issue, terminal_states) -> nil
      SubIssueWait.in_state?(issue, settings) -> :answer
      not HumanReview.review_state?(state, settings) -> nil
      Issue.waiting_on_sub_issues?(issue, terminal_states) -> :answer
      true -> :revise
    end
  end

  def action(_issue, _terminal_states, _settings), do: nil

  @doc """
  The people's comments `action` acts on, oldest first, given Symphony's `last_run` on the parent
  (nil when there was none) and when Symphony started (`started_at`, nil when unknown).

  For `:revise`, those since the last run started that no later comment of Symphony's answers in
  their thread, so a comment made while the run worked still counts, and the run's own comments
  never do. When the run's comments are unknown, those after the parent's latest move into `state`
  and after the run ended. For `:answer`, top-level comments after the parent's latest move into
  `state`, the last run's end and `started_at`, in a thread Symphony has not replied to. With no
  run to measure from and no move into `state` in the history, there are none.
  """
  @spec pending(action(), feedback(), String.t(), last_run() | nil, DateTime.t() | nil) :: [comment()]
  def pending(action, %{state_changes: changes, comments: comments}, state, last_run, started_at) do
    owned = MapSet.new(owned_ids(last_run))

    case since(action, entered_at(changes, state), last_run, started_at) do
      nil ->
        []

      since ->
        comments
        |> Enum.filter(&(human?(&1) and not MapSet.member?(owned, &1.id) and after?(&1.created_at, since)))
        |> unanswered(action, comments, owned)
        |> Enum.sort_by(& &1.created_at, DateTime)
    end
  end

  @doc "True when a person wrote `comment`: not an integration bot, and not one of Symphony's own comments."
  @spec human?(comment() | term()) :: boolean()
  def human?(%{bot?: false, body: body}) when is_binary(body), do: not symphony_comment?(body)
  def human?(_comment), do: false

  @doc "The id of the thread `comment` belongs to: its own, or the first comment's for a reply."
  @spec thread_id(comment()) :: String.t() | nil
  def thread_id(%{parent_id: parent_id}) when is_binary(parent_id), do: parent_id
  def thread_id(%{id: id}), do: id

  @doc "The reply Symphony posts under a top-level comment on an approved plan."
  @spec reply(String.t() | nil) :: String.t()
  def reply(identifier) do
    parent = identifier || "the parent"

    "#{@reply_opener}. Move #{parent} to Rework instead: " <>
      "Symphony re-plans it, cancels only the sub-tickets still in Backlog and keeps the ones already promoted."
  end

  defp since(:revise, _entered_at, %{started_at: %DateTime{} = run_started_at, comment_ids: ids}, _started_at) when is_list(ids),
    do: run_started_at

  defp since(_action, nil, _last_run, _started_at), do: nil
  defp since(:revise, entered_at, last_run, _started_at), do: latest(entered_at, ended_at(last_run))
  defp since(:answer, entered_at, last_run, started_at), do: entered_at |> latest(ended_at(last_run)) |> latest(started_at)

  defp ended_at(%{ended_at: %DateTime{} = at}), do: at
  defp ended_at(_last_run), do: nil

  defp owned_ids(%{comment_ids: ids}) when is_list(ids), do: ids
  defp owned_ids(_last_run), do: []

  # A comment Symphony answered: a later comment of the last run's in the thread under review, its
  # reply under a top-level comment on an approved plan.
  defp unanswered(pending, :revise, comments, owned) do
    answered_at = answered_at(comments, &MapSet.member?(owned, &1.id))
    Enum.filter(pending, &after?(&1.created_at, Map.get(answered_at, thread_id(&1))))
  end

  defp unanswered(pending, :answer, comments, _owned) do
    answered = answered_at(comments, &reply?/1)
    Enum.filter(pending, &(is_nil(&1.parent_id) and not Map.has_key?(answered, &1.id)))
  end

  defp answered_at(comments, symphony?) do
    for %{created_at: %DateTime{} = at} = comment <- comments, symphony?.(comment), reduce: %{} do
      acc -> Map.update(acc, thread_id(comment), at, &latest(&1, at))
    end
  end

  defp reply?(%{body: body}) when is_binary(body), do: String.starts_with?(String.trim_leading(body), @reply_opener)
  defp reply?(_comment), do: false

  defp symphony_comment?(body) do
    trimmed = String.trim_leading(body)

    Enum.any?(AgentLabels.known_workpad_markers(), &String.contains?(body, &1)) or
      Enum.any?(openers(), &String.starts_with?(trimmed, &1))
  end

  defp openers, do: [Report.heading(), Request.heading() | BreakdownReview.comment_openers()] ++ @symphony_openers

  defp entered_at(changes, state) do
    changes
    |> Enum.filter(&state_matches?(&1.to, state))
    |> Enum.map(& &1.at)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp latest(at, nil), do: at
  defp latest(at, other), do: Enum.max([at, other], DateTime)

  defp after?(%DateTime{} = time, %DateTime{} = since), do: DateTime.compare(time, since) == :gt
  defp after?(%DateTime{}, nil), do: true
  defp after?(_time, _since), do: false

  defp state_matches?(state, expected) when is_binary(state) and is_binary(expected),
    do: normalize(state) == normalize(expected)

  defp state_matches?(_state, _expected), do: false

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
