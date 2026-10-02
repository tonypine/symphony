defmodule SymphonyElixir.AutoReview do
  @moduledoc """
  Auto Review sits between the executor opening a PR and the human review.

  When `auto_review.enabled` is true, Symphony moves an issue with an open PR to the
  Auto Review state (default `Auto Review`) instead of `In Review`. The CI poller
  watches that state: red CI goes back to `In Progress` through the usual fix loop,
  and green CI runs QA, which for now is a pass-through stub that moves the issue
  to `In Review`.

  At startup Symphony checks that the Linear team has the Auto Review state and
  that the CI poller is on. When either is missing, Auto Review is turned off for
  the life of the process and a warning is logged, so issues keep flowing to
  `In Review`.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker

  @review_state "In Review"

  @doc "Whether Auto Review is configured on and the startup check did not turn it off."
  @spec enabled?(Schema.t() | term()) :: boolean()
  def enabled?(%Schema{auto_review: %{enabled: true, state: state}}) when is_binary(state),
    do: not disabled?(state)

  def enabled?(_settings), do: false

  @doc "The Linear state name Auto Review uses."
  @spec state(Schema.t()) :: String.t()
  def state(%Schema{auto_review: %{state: state}}), do: state

  @doc "The state human review happens in, which Auto Review hands issues to."
  @spec review_state() :: String.t()
  def review_state, do: @review_state

  @doc "The state Symphony moves an issue to once its PR is open."
  @spec post_pr_state(Schema.t()) :: String.t()
  def post_pr_state(settings) do
    if enabled?(settings), do: state(settings), else: @review_state
  end

  @doc "The Linear team keys or ids Symphony is scoped to, from `issues` and `repositories`."
  @spec configured_teams(Schema.t(), [map()]) :: [String.t()]
  def configured_teams(%Schema{} = settings, repos) when is_list(repos) do
    [settings.tracker.team | Enum.map(repos, &Map.get(&1, :team))]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  @doc """
  Checks that the given Linear teams have the Auto Review state. With no teams,
  any team in the workspace having it is enough.

  Returns `:ok` when the state exists, `:disabled` when it is missing or the CI
  poller that moves issues on from it is off (Auto Review is then off until
  restart), `:skipped` when Auto Review is not enabled, and `{:error, reason}` when
  the tracker could not be asked (Auto Review stays on).
  """
  @spec check_tracker_state(Schema.t(), [String.t()], keyword()) :: :ok | :disabled | :skipped | {:error, term()}
  def check_tracker_state(settings, teams, opts \\ []) do
    case settings do
      %Schema{auto_review: %{enabled: true, state: state}} ->
        if ci_polling?(settings) do
          check_tracker_state_exists(state, teams, Keyword.get(opts, :tracker, Tracker))
        else
          disable(state, "it needs `pull_requests.enabled: true` and `pull_requests.checks.enabled: true` to move issues on from #{state}")
        end

      _settings ->
        :skipped
    end
  end

  defp check_tracker_state_exists(state, teams, tracker) do
    case tracker.workflow_state_exists?(state, teams) do
      {:ok, true} ->
        :persistent_term.erase(disabled_key(state))
        :ok

      {:ok, false} ->
        disable(
          state,
          "Linear state #{inspect(state)} is missing#{teams_suffix(teams)}; " <>
            "add it as a started state between In Progress and In Review, then restart Symphony"
        )

      {:error, reason} ->
        Logger.warning("Could not check the Linear state #{inspect(state)} for Auto Review; leaving it on: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp disable(state, reason) do
    Logger.warning("Auto Review disabled: #{reason}")
    :persistent_term.put(disabled_key(state), true)
    :disabled
  end

  # The CI poller is what moves issues out of Auto Review.
  defp ci_polling?(%Schema{ci: %{enabled: ci_enabled}, pr_review: %{mode: mode}}), do: ci_enabled == true and mode == "polling"

  @doc false
  @spec reset_for_test(String.t()) :: :ok
  def reset_for_test(state) when is_binary(state) do
    :persistent_term.erase(disabled_key(state))
    :ok
  end

  defp disabled?(state), do: :persistent_term.get(disabled_key(state), false)

  defp disabled_key(state), do: {__MODULE__, :disabled, state}

  defp teams_suffix([]), do: ""
  defp teams_suffix(teams), do: " for team(s) #{Enum.join(teams, ", ")}"
end
