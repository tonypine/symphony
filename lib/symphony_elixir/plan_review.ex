defmodule SymphonyElixir.PlanReview do
  @moduledoc """
  The epic path's `Plan Review` state (`issues.states.plan_review`, default `Plan Review`): where a
  plan parent waits for a person to review its plan (`docs/design/state-machine.md` §Epic path).

  The plan run hands the plan over by naming the state, the transition guard lets only a plan
  parent enter it, and only a person's move takes the parent out of it:
  to the waiting state (an approval) or to `Rework` (a re-plan). No run starts in it
  (`SymphonyElixir.StateMachine.active_states/1`). `null` in config turns it off.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @doc "The configured state name, or nil when it is turned off in config."
  @spec state(Schema.t() | term()) :: String.t() | nil
  def state(%Schema{tracker: %{plan_review_state: state}}) when is_binary(state), do: state
  def state(_settings), do: nil

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

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
