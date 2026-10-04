defmodule SymphonyElixir.HumanReview do
  @moduledoc """
  The state an issue waits in when only a person can move it on (`issues.states.human_review`,
  default `Human Review`), apart from the supervisor's `In Review` queue.

  Symphony never dispatches an issue in it, and the CI and PR review pollers watch its PR as they
  do in `In Review`. A person's move out of it counts like one out of `In Review`: to `Merging`,
  `Rework`, the waiting state (a plan approval) or `Done`. Symphony puts an issue there instead of
  `In Review` when the next step needs a person:

  - an Auto Review QA verdict `blocked` that the QA agent says needs a person (a missing secret or
    key, a check on a real device), as opposed to a tooling gap the factory can fix;
  - a parent walkthrough (`Final verification:`) whose remaining steps are manual;
  - a `breakdown` plan whose ticket says a human reviews it (`requested_by_ticket?/2`);
  - an issue whose run posted a `linear_request_human_action` request.

  At startup Symphony checks that the Linear team has the state. When it is missing, the state is
  turned off for the life of the process and a warning is logged, so those issues go to
  `In Review` as before. `null` in config turns it off too.
  """

  require Logger

  alias SymphonyElixir.AcceptanceGate.Escalation
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @review_state "In Review"

  @doc "The configured state name, or nil when it is turned off in config."
  @spec state(Schema.t() | term()) :: String.t() | nil
  def state(%Schema{tracker: %{human_review_state: state}}) when is_binary(state), do: state
  def state(_settings), do: nil

  @doc "Whether the state is configured and the startup check did not turn it off."
  @spec enabled?(Schema.t() | term()) :: boolean()
  def enabled?(settings) do
    case state(settings) do
      nil -> false
      state -> not :persistent_term.get(disabled_key(state), false)
    end
  end

  @doc "The state an issue that needs a person goes to: the configured state, else `In Review`."
  @spec target_state(Schema.t() | term()) :: String.t()
  def target_state(settings) do
    if enabled?(settings), do: state(settings), else: @review_state
  end

  @doc "The states a person reviews in: `In Review`, and the configured state when set."
  @spec review_states(Schema.t() | term()) :: [String.t()]
  def review_states(settings) do
    case state(settings) do
      nil -> [@review_state]
      state -> [@review_state, state]
    end
  end

  @doc "True when `state_name` is one of `review_states/1`."
  @spec review_state?(String.t() | nil, Schema.t() | term()) :: boolean()
  def review_state?(state_name, settings) when is_binary(state_name),
    do: Enum.any?(review_states(settings), &(normalize(&1) == normalize(state_name)))

  def review_state?(_state_name, _settings), do: false

  @doc "True when `issue` (or a state name) sits in the configured state."
  @spec in_state?(Issue.t() | String.t() | term(), Schema.t() | term()) :: boolean()
  def in_state?(%Issue{state: issue_state}, settings), do: in_state?(issue_state, settings)

  def in_state?(state_name, settings) when is_binary(state_name) do
    case state(settings) do
      nil -> false
      state -> normalize(state_name) == normalize(state)
    end
  end

  def in_state?(_issue, _settings), do: false

  @doc "`in_state?/2` against the current settings, false when they can't be read."
  @spec in_state?(String.t() | nil) :: boolean()
  def in_state?(state_name) do
    case Config.settings() do
      {:ok, settings} -> in_state?(state_name, settings)
      {:error, _reason} -> false
    end
  end

  @doc """
  True when the ticket says a person reviews it: an `auto_review.acceptance_gate.escalate` label
  other than `breakdown` (every plan has that one), or a title or description matching one of its
  `ticket_patterns` ("must not auto-approve", "needs human", "human review").
  """
  @spec requested_by_ticket?(Issue.t(), Schema.t()) :: boolean()
  def requested_by_ticket?(%Issue{} = issue, %Schema{} = settings) do
    rules = settings.auto_review.acceptance_gate.escalate
    rules = %{rules | labels: Enum.reject(rules.labels, &Issue.breakdown_label?/1)}
    Escalation.ticket_reasons(%{issue | labels: issue.labels || []}, rules) != []
  end

  @doc """
  Checks that the given Linear teams have the state. With no teams, any team in the workspace
  having it is enough.

  Returns `:ok` when the state exists, `:disabled` when it is missing (issues that need a person
  then go to `In Review` until restart), `:skipped` when no state is configured, and
  `{:error, reason}` when the tracker could not be asked (the state stays on).
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
          "Human review state disabled: Linear state #{inspect(state)} is missing#{teams_suffix(teams)}; " <>
            "issues that need a person go to #{@review_state}. Add it as a started state after #{@review_state}, then restart Symphony"
        )

        :persistent_term.put(disabled_key(state), true)
        :disabled

      {:error, reason} ->
        Logger.warning("Could not check the Linear state #{inspect(state)} for human review; leaving it on: #{inspect(reason)}")
        {:error, reason}
    end
  end

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
