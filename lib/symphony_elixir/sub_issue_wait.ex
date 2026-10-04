defmodule SymphonyElixir.SubIssueWait do
  @moduledoc """
  The state a `breakdown` parent waits in while its sub-issues are worked
  (`issues.states.waiting_on_sub_issues`, default `Waiting on sub-tickets`).

  A human approving the breakdown plan moves the parent there, and on every poll Symphony
  moves a `breakdown` parent it finds `In Progress` with open sub-issues there too,
  so `In Progress` only holds issues an agent is working. The poll's candidates can be
  stale, so the parent's state is read again just before the move. The state is active but
  held: an issue in it is dispatched only for the close-out run, once it is a
  `breakdown` parent whose sub-issues are all terminal.

  At startup Symphony checks that the Linear team has the state. When it is
  missing, the state is turned off for the life of the process and a warning is
  logged, so parents keep waiting `In Progress` as before.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @parked_from_state "In Progress"

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

  @doc "True when Symphony should move `issue` from `In Progress` to the waiting state."
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

  @doc false
  @spec reset_for_test(String.t()) :: :ok
  def reset_for_test(state) when is_binary(state) do
    :persistent_term.erase(disabled_key(state))
    :ok
  end

  defp normalize(state), do: state |> String.trim() |> String.downcase()

  defp disabled_key(state), do: {__MODULE__, :disabled, state}

  defp teams_suffix([]), do: ""
  defp teams_suffix(teams), do: " for team(s) #{Enum.join(teams, ", ")}"
end
