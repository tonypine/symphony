defmodule SymphonyElixir.PlanComments do
  @moduledoc """
  Acts on people's comments on a `breakdown` parent's plan.

  A plan under review (the parent in `In Review`, none of its open sub-issues promoted out of
  `Backlog`) is revised in place: a person's new comment sends the parent back to `In Progress`,
  where the breakdown run picks it up, edits the plan, answers the comment and returns the parent
  to `In Review` (see `SymphonyElixir.Linear.Issue.unapproved_plan?/2`). An approved plan (the parent
  in the waiting state, or in `In Review` with sub-issues already promoted) is not changed from
  comments: Symphony replies once under each new comment thread that a plan change goes through
  `Rework`.

  Only a person's comment counts. Integration bots are skipped, and so are Symphony's own comments,
  told apart by how they start because Symphony and the reviewer can share one Linear user. A
  comment counts only when it came after the parent's latest move into its current state and after
  Symphony's last run on it ended, so a revision run's own replies never start another one.
  """

  alias SymphonyElixir.{AgentLabels, AutoReview, BreakdownReview, SubIssueWait, Tracker}
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent.Report

  @reply_opener "Symphony doesn't change an approved plan from comments"
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

  @doc """
  What a new comment on `issue` asks of Symphony: `:revise` for a `breakdown` parent in `In Review`
  whose plan was not approved, `:answer` for one whose plan was (in the waiting state, or back in
  `In Review` with sub-issues under way), nil otherwise. A parent whose sub-issues are all terminal
  is left to its close-out.
  """
  @spec action(Issue.t() | term(), Enumerable.t(String.t()), term()) :: action() | nil
  def action(%Issue{state: state} = issue, terminal_states, settings) when is_binary(state) do
    cond do
      not Issue.breakdown?(issue) or Issue.close_out_ready?(issue, terminal_states) -> nil
      SubIssueWait.in_state?(issue, settings) -> :answer
      not state_matches?(state, AutoReview.review_state()) -> nil
      Issue.waiting_on_sub_issues?(issue, terminal_states) -> :answer
      true -> :revise
    end
  end

  def action(_issue, _terminal_states, _settings), do: nil

  @doc """
  The people's comments `action` acts on, oldest first: those after the parent's latest move into
  `state` and after `ran_at` (when Symphony's last run on it ended, nil when unknown). With no move
  into `state` in the history there are none. For `:answer`, only comments in a thread Symphony has
  not replied to since.
  """
  @spec pending(action(), feedback(), String.t(), DateTime.t() | nil) :: [comment()]
  def pending(action, %{state_changes: changes, comments: comments}, state, ran_at) do
    case entered_at(changes, state) do
      nil ->
        []

      entered_at ->
        since = latest(entered_at, ran_at)

        comments
        |> Enum.filter(&(human?(&1) and after?(&1.created_at, since)))
        |> Enum.sort_by(& &1.created_at, DateTime)
        |> unanswered(action, comments)
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

  @doc "The reply Symphony posts under a comment on an approved plan."
  @spec reply(String.t() | nil) :: String.t()
  def reply(identifier) do
    parent = identifier || "the parent"

    "#{@reply_opener}, so this one changed nothing. To change the plan, move #{parent} to Rework: " <>
      "Symphony re-plans it, cancels only the sub-tickets still in Backlog and keeps the ones already promoted."
  end

  defp unanswered(pending, :revise, _comments), do: pending

  defp unanswered(pending, :answer, comments) do
    replied_at =
      for %{body: body, created_at: %DateTime{} = at} = comment <- comments,
          is_binary(body) and String.starts_with?(String.trim_leading(body), @reply_opener),
          reduce: %{} do
        acc -> Map.update(acc, thread_id(comment), at, &latest(&1, at))
      end

    Enum.filter(pending, &after?(&1.created_at, Map.get(replied_at, thread_id(&1))))
  end

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
