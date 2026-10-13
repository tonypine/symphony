defmodule SymphonyElixir.RetiredStates do
  @moduledoc """
  The startup report of tickets still sitting in a retired state.

  `Auto Review` is retired with the acceptance gate (`docs/design/state-machine.md` §Retired): the
  transition guard refuses every move into it (`SymphonyElixir.TransitionGuard.retired_states/0`),
  so no ticket can enter it again. A ticket that somehow still sits there — moved by hand, or left
  over from before the retirement — is dispatched by nothing, so `report/1` names each one loudly at
  startup, with the move that frees it. A person resolves the tail by hand, as the drain of the
  other retired states does (decision D11: drain only).
  """

  require Logger

  alias SymphonyElixir.{Tracker, TransitionGuard}

  @doc """
  Logs an error for each ticket in a retired state and returns them. `opts[:tracker]` overrides the
  tracker (tests, a fake). A tracker that can't be read is logged as a warning and reports nothing.
  """
  @spec report(keyword()) :: [map()]
  def report(opts \\ []) do
    tracker = Keyword.get(opts, :tracker, Tracker)

    case tracker.fetch_issues_by_states(TransitionGuard.retired_states()) do
      {:ok, issues} ->
        Enum.each(issues, &log_straggler/1)
        issues

      {:error, reason} ->
        Logger.warning("Could not check for tickets left in a retired state (#{Enum.join(TransitionGuard.retired_states(), ", ")}): #{inspect(reason)}")
        []
    end
  end

  defp log_straggler(issue) do
    Logger.error(
      "#{Map.get(issue, :identifier) || Map.get(issue, :id)} is still in the retired #{Map.get(issue, :state)} state, " <>
        "which nothing dispatches or moves on: move it by hand to Code Review (its PR is open) or In Progress"
    )
  end
end
