defmodule SymphonyElixir.SubIssueWait do
  @moduledoc """
  The state a `breakdown` parent waits in while its sub-issues are worked
  (`issues.states.waiting_on_sub_issues`, default `Waiting on sub-tickets`).

  A human approving the breakdown plan moves the parent there, and on every poll Symphony
  moves a `breakdown` parent it finds `In Progress` with approved sub-issues open there too,
  so `In Progress` only holds issues an agent is working. A parent whose open sub-issues are
  all still in `Backlog` was never approved, so it is not moved: it gets a breakdown run that
  picks the plan up where it stopped (see `Issue.unapproved_plan?/2`). The poll's candidates
  can be stale, so the parent's state is read again just before the move. The state is active but
  held: an issue in it is dispatched only for the close-out run, once it is a
  `breakdown` parent whose sub-issues are all terminal.

  Any other issue whose pull request merges with a sub-issue still open waits there too, instead of
  closing (`wait_on_merge?/3`): its `Backlog` sub-issues move to `Todo`, and Symphony moves it to
  `Done` itself, with no run, once every sub-issue is terminal (`close?/3`). A sub-issue filed or
  canceled meanwhile just counts in that check. The RunStore records each issue the merge put there,
  so one a person moved there, with its pull request still open, waits for a human as before.

  At startup Symphony checks that the Linear team has the state. When it is
  missing, the state is turned off for the life of the process and a warning is
  logged, so parents keep waiting `In Progress` as before.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{RunStore, Tracker}

  @parked_from_state "In Progress"
  @backlog_state "Backlog"
  @todo_state "Todo"
  @done_state "Done"

  @doc "The configured waiting state name, or nil when it is turned off in config."
  @spec state(Schema.t() | term()) :: String.t() | nil
  def state(%Schema{tracker: %{waiting_on_sub_issues_state: state}}) when is_binary(state), do: state
  def state(_settings), do: nil

  @doc "Whether the waiting state is configured and the startup check did not turn it off."
  @spec enabled?(Schema.t() | term()) :: boolean()
  def enabled?(settings) do
    case state(settings) do
      nil -> false
      state -> not :persistent_term.get(disabled_key(state), false)
    end
  end

  @doc """
  Checks that the given Linear teams have the waiting state. With no teams, any
  team in the workspace having it is enough.

  Returns `:ok` when the state exists, `:disabled` when it is missing (parents
  then stay `In Progress` until restart), `:skipped` when no state is configured,
  and `{:error, reason}` when the tracker could not be asked (the state stays on).
  """
  @spec check_tracker_state(Schema.t(), [String.t()], keyword()) :: :ok | :disabled | :skipped | {:error, term()}
  def check_tracker_state(settings, teams, opts \\ []) do
    case state(settings) do
      nil -> :skipped
      state -> check_tracker_state_exists(state, teams, Keyword.get(opts, :tracker, Tracker))
    end
  end

  defp check_tracker_state_exists(state, teams, tracker) do
    case tracker.workflow_state_exists?(state, teams) do
      {:ok, true} ->
        :persistent_term.erase(disabled_key(state))
        :ok

      {:ok, false} ->
        Logger.warning(
          "Waiting on sub-issues state disabled: Linear state #{inspect(state)} is missing#{teams_suffix(teams)}; " <>
            "breakdown parents stay #{@parked_from_state}. Add it as a started state after In Progress, then restart Symphony"
        )

        :persistent_term.put(disabled_key(state), true)
        :disabled

      {:error, reason} ->
        Logger.warning("Could not check the Linear state #{inspect(state)} for breakdown parents; leaving it on: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "True when `issue` sits in the waiting state."
  @spec in_state?(Issue.t() | term(), Schema.t() | term()) :: boolean()
  def in_state?(%Issue{state: issue_state}, settings) when is_binary(issue_state) do
    case state(settings) do
      nil -> false
      state -> normalize(issue_state) == normalize(state)
    end
  end

  def in_state?(_issue, _settings), do: false

  @doc """
  True when an issue in the waiting state must not run: anything but a `breakdown`
  parent whose sub-issues are all terminal.
  """
  @spec held?(Issue.t() | term(), Enumerable.t(String.t()), Schema.t() | term()) :: boolean()
  def held?(issue, terminal_states, settings) do
    in_state?(issue, settings) and not Issue.close_out_ready?(issue, terminal_states)
  end

  @doc """
  True when Symphony should move `issue` from `In Progress` to the waiting state: a `breakdown`
  parent whose approved sub-issues are open (see `Issue.waiting_on_sub_issues?/2`).
  """
  @spec park?(Issue.t() | term(), Enumerable.t(String.t()), Schema.t() | term()) :: boolean()
  def park?(%Issue{} = issue, terminal_states, settings) do
    enabled?(settings) and parked_from?(issue) and Issue.waiting_on_sub_issues?(issue, terminal_states)
  end

  def park?(_issue, _terminal_states, _settings), do: false

  @doc """
  True when `issue` sits in the state Symphony parks parents from (`In Progress`). Symphony checks
  it again on a fresh read just before parking: a parent in `In Review` waits there for a human's
  review of its plan, and moving it on would read as that approval.
  """
  @spec parked_from?(Issue.t() | term()) :: boolean()
  def parked_from?(%Issue{state: issue_state}) when is_binary(issue_state), do: normalize(issue_state) == normalize(@parked_from_state)
  def parked_from?(_issue), do: false

  @doc """
  True when `issue`, whose pull request merged, waits in the waiting state instead of closing: the
  state is on, the issue is not a `breakdown` parent (those wait from their plan's approval) and it
  has a sub-issue outside `terminal_states`.
  """
  @spec wait_on_merge?(Issue.t() | term(), Enumerable.t(String.t()), Schema.t() | term()) :: boolean()
  def wait_on_merge?(%Issue{} = issue, terminal_states, settings) do
    enabled?(settings) and not Issue.breakdown?(issue) and Issue.open_sub_issues(issue, terminal_states) != []
  end

  def wait_on_merge?(_issue, _terminal_states, _settings), do: false

  @doc """
  Moves `issue`, whose pull request merged with sub-issues open, to the waiting state and its
  sub-issues in `Backlog` to `Todo`, and comments on it. Only states change, so blocked-by links and
  labels stay. It first records the merge in the RunStore, which `close?/3` requires. It can run
  again: an issue already waiting is not moved or commented on again unless a sub-issue is left in
  `Backlog`, such as one whose promotion failed (returned as an error).
  """
  @spec wait_on_merge(Issue.t(), Schema.t(), module()) :: :ok | {:error, term()}
  def wait_on_merge(%Issue{} = issue, %Schema{} = settings, tracker) do
    waiting_state = state(settings)
    already_waiting? = in_state?(issue, settings)

    with :ok <- RunStore.put_merged_wait(issue.id),
         :ok <- move_to_waiting(issue, waiting_state, already_waiting?, tracker) do
      {promoted, failed} = promote_backlog_sub_issues(issue, tracker)
      log_wait(issue, waiting_state, already_waiting?, promoted)

      if not already_waiting? or promoted != [] do
        body = wait_comment(issue, waiting_state, already_waiting?, promoted, settings.tracker.terminal_states)
        comment(issue, body, tracker)
      end

      if failed == [], do: :ok, else: {:error, {:sub_issue_promotion_failed, failed}}
    end
  end

  @doc """
  True when Symphony closes `issue` itself: it sits in the waiting state, is not a `breakdown` parent
  (its close-out run closes it), has sub-issues, every one of them in `terminal_states`, and its
  pull request's merge put it there (`wait_on_merge/3`). One a person moved there waits for them.
  """
  @spec close?(Issue.t() | term(), Enumerable.t(String.t()), Schema.t() | term()) :: boolean()
  def close?(%Issue{sub_issues: [_ | _]} = issue, terminal_states, settings) do
    in_state?(issue, settings) and not Issue.breakdown?(issue) and
      Issue.open_sub_issues(issue, terminal_states) == [] and RunStore.merged_wait?(issue.id) == true
  end

  def close?(_issue, _terminal_states, _settings), do: false

  @doc "Moves `issue` to `Done` and comments how each of its sub-issues ended."
  @spec close(Issue.t(), module()) :: :ok | {:error, term()}
  def close(%Issue{id: issue_id} = issue, tracker) do
    with :ok <- tracker.update_issue_state(issue_id, @done_state) do
      Logger.info("Moved issue to #{@done_state}: every sub-issue is finished #{issue_fields(issue)}")
      _ = RunStore.delete_merged_wait(issue_id)
      comment(issue, close_comment(issue), tracker)
    end
  end

  @doc false
  @spec reset_for_test(String.t()) :: :ok
  def reset_for_test(state) when is_binary(state) do
    :persistent_term.erase(disabled_key(state))
    :ok
  end

  defp move_to_waiting(_issue, _waiting_state, true, _tracker), do: :ok
  defp move_to_waiting(%Issue{id: issue_id}, waiting_state, false, tracker), do: tracker.update_issue_state(issue_id, waiting_state)

  # Every `Backlog` sub-issue moves to `Todo`; returns the identifiers moved and those that failed.
  defp promote_backlog_sub_issues(%Issue{sub_issues: sub_issues} = issue, tracker) do
    sub_issues
    |> Enum.filter(&backlog_sub_issue?/1)
    |> Enum.reduce({[], []}, fn %{id: id} = sub_issue, {promoted, failed} ->
      label = sub_issue_label(sub_issue)

      case tracker.update_issue_state(id, @todo_state) do
        :ok ->
          {promoted ++ [label], failed}

        {:error, reason} ->
          Logger.warning("Failed to move sub-issue #{label} to #{@todo_state} after its parent's PR merged: #{issue_fields(issue)} reason=#{inspect(reason)}")
          {promoted, failed ++ [label]}
      end
    end)
  end

  defp backlog_sub_issue?(%{id: id, state: state}) when is_binary(id) and is_binary(state), do: normalize(state) == normalize(@backlog_state)
  defp backlog_sub_issue?(_sub_issue), do: false

  defp log_wait(issue, waiting_state, false, promoted),
    do: Logger.info("Moved issue to #{waiting_state} after its PR merged with sub-issues open#{promoted_suffix(promoted)}: #{issue_fields(issue)}")

  defp log_wait(_issue, _waiting_state, true, []), do: :ok
  defp log_wait(issue, _waiting_state, true, promoted), do: Logger.info("Promoted sub-issues of a waiting issue#{promoted_suffix(promoted)}: #{issue_fields(issue)}")

  defp promoted_suffix([]), do: ""
  defp promoted_suffix(promoted), do: "; promoted to #{@todo_state}: #{Enum.join(promoted, ", ")}"

  defp wait_comment(_issue, _waiting_state, true, promoted, _terminal_states), do: promoted_line(promoted)

  defp wait_comment(issue, waiting_state, false, promoted, terminal_states) do
    open = issue |> Issue.open_sub_issues(terminal_states) |> Enum.map_join(", ", &sub_issue_label/1)

    wait =
      "#{waiting_state}: the PR merged with sub-tickets still open (#{open}), so this ticket moves to " <>
        "#{@done_state} once every sub-ticket is finished. Canceling one counts as finishing it."

    Enum.join([wait | if(promoted == [], do: [], else: [promoted_line(promoted)])], "\n\n")
  end

  defp promoted_line(promoted), do: "Promoted to #{@todo_state}: #{Enum.join(promoted, ", ")}"

  defp close_comment(%Issue{sub_issues: sub_issues}) do
    outcomes = Enum.map_join(sub_issues, "\n", &"- #{sub_issue_label(&1)}: #{Map.get(&1, :state) || "unknown"}")
    "Every sub-ticket is finished, so this ticket is #{@done_state}:\n\n" <> outcomes
  end

  defp comment(%Issue{id: issue_id} = issue, body, tracker) do
    case tracker.create_comment(issue_id, body) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to comment on an issue waiting on its sub-issues: #{issue_fields(issue)} reason=#{inspect(reason)}")
    end

    :ok
  end

  defp sub_issue_label(sub_issue), do: Map.get(sub_issue, :identifier) || Map.get(sub_issue, :id)

  defp issue_fields(%Issue{id: issue_id, identifier: identifier}), do: "issue_id=#{issue_id} issue_identifier=#{identifier}"

  defp normalize(state), do: state |> String.trim() |> String.downcase()

  defp disabled_key(state), do: {__MODULE__, :disabled, state}

  defp teams_suffix([]), do: ""
  defp teams_suffix(teams), do: " for team(s) #{Enum.join(teams, ", ")}"
end
