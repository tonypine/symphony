defmodule SymphonyElixir.BreakdownReview do
  @moduledoc """
  Acts on a human's review of a `breakdown` parent's plan.

  A breakdown run leaves its sub-issues in `Backlog` and the parent in `In Review`. The human
  approves the plan with one move of the parent, `In Review` to the waiting state
  (`Waiting on sub-tickets`), and Symphony then moves every sub-issue still in `Backlog` to
  `Todo` in one batch; blocked-by links keep the order. Moving the parent to `Rework` rejects
  the plan: Symphony cancels the sub-issues still in `Backlog` and runs the breakdown again.

  Symphony only polls, so it reads the parent's state history to see the move. A sub-issue is
  acted on only when it has sat in `Backlog` since before that move, which keeps both actions
  idempotent across polls and restarts: a sub-issue a human (or a final verification run) moves
  back to `Backlog` later is left alone, and so is one created after the move, such as the
  sub-issues of the re-planned breakdown.
  """

  alias SymphonyElixir.AutoReview
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SubIssueWait
  alias SymphonyElixir.Tracker

  @backlog_state "Backlog"
  @todo_state "Todo"
  @rework_state "Rework"
  # Linear names the canceled state either way; the first one the team has is used.
  @canceled_states ["Canceled", "Cancelled"]

  @typedoc "What the review asks of a parent: promote its plan, or cancel it before a re-plan."
  @type action :: :promote | :replace

  @doc """
  The action a `breakdown` parent with sub-issues in `Backlog` may need: `:promote` in the
  waiting state, `:replace` in `Rework`, nil otherwise.
  """
  @spec action(Issue.t() | term(), term()) :: action() | nil
  def action(%Issue{} = issue, settings) do
    cond do
      backlog_sub_issue_ids(issue) == [] -> nil
      Issue.replanning?(issue) -> :replace
      Issue.breakdown?(issue) and SubIssueWait.in_state?(issue, settings) -> :promote
      true -> nil
    end
  end

  def action(_issue, _settings), do: nil

  @doc "The ids of the issue's sub-issues in `Backlog`, sorted."
  @spec backlog_sub_issue_ids(Issue.t()) :: [String.t()]
  def backlog_sub_issue_ids(%Issue{sub_issues: sub_issues}) when is_list(sub_issues) do
    for(%{id: id, state: state} when is_binary(id) <- sub_issues, state_matches?(state, @backlog_state), do: id)
    |> Enum.sort()
    |> Enum.dedup()
  end

  def backlog_sub_issue_ids(_issue), do: []

  @doc """
  The sub-issues `action` applies to: those in `Backlog` since before the move that asked for it.
  With no such move as the parent's latest state change (for example a parent Symphony parked
  from `In Progress`, which nobody approved), there are none.
  """
  @spec sub_issues_to_move(action(), Tracker.breakdown_history(), term()) :: [map()]
  def sub_issues_to_move(action, %{state_changes: changes, sub_issues: sub_issues}, settings) do
    case decided_at(action, latest(changes), settings) do
      %DateTime{} = at -> Enum.filter(sub_issues, &backlog_since?(&1, at))
      nil -> []
    end
  end

  @doc "Moves one sub-issue as `action` asks: to `Todo`, or to the team's canceled state."
  @spec move(action(), String.t(), module()) :: :ok | {:error, term()}
  def move(:promote, sub_issue_id, tracker), do: tracker.update_issue_state(sub_issue_id, @todo_state)

  def move(:replace, sub_issue_id, tracker) do
    Enum.reduce_while(@canceled_states, {:error, :state_not_found}, fn state, _result ->
      case tracker.update_issue_state(sub_issue_id, state) do
        {:error, :state_not_found} = error -> {:cont, error}
        result -> {:halt, result}
      end
    end)
  end

  @doc "The state `action` moves sub-issues to, for logs."
  @spec target(action()) :: String.t()
  def target(:promote), do: @todo_state
  def target(:replace), do: hd(@canceled_states)

  defp decided_at(:promote, %{from: from, to: to, at: at}, settings) do
    if state_matches?(from, AutoReview.review_state()) and state_matches?(to, SubIssueWait.state(settings)), do: at
  end

  defp decided_at(:replace, %{to: to, at: at}, _settings) do
    if state_matches?(to, @rework_state), do: at
  end

  defp decided_at(_action, nil, _settings), do: nil

  defp latest([]), do: nil
  defp latest(changes), do: Enum.max_by(changes, & &1.at, DateTime)

  defp backlog_since?(%{id: id, state: state, created_at: %DateTime{} = created_at} = sub_issue, at)
       when is_binary(id) do
    state_matches?(state, @backlog_state) and not after?(created_at, at) and
      not after?(sub_issue[:state_changed_at], at)
  end

  defp backlog_since?(_sub_issue, _at), do: false

  defp after?(%DateTime{} = time, at), do: DateTime.compare(time, at) == :gt
  defp after?(nil, _at), do: false

  defp state_matches?(state, expected) when is_binary(state) and is_binary(expected),
    do: normalize(state) == normalize(expected)

  defp state_matches?(_state, _expected), do: false

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
