defmodule SymphonyElixir.DecisionMove do
  @moduledoc """
  The move a decision's option makes once a person picks it.

  A question Symphony asks may offer an option whose answer is a move: QA's "Send it back to
  Rework" and "Merge without a QA result", a closed pull request's "Cancel". The option carries
  that move as data (`option/2`), so a pick never asks the person to also drag the ticket by hand,
  which under `dispatch.source: record` is drift moved back anyway. Whichever way the person
  answers — the Inbox's Decide (`SymphonyElixir.DirectorMoves`) or a reply under the request
  (`SymphonyElixir.NeedsDecisionHold`) — the picked option's move (`picked/2`) is performed through
  the guard (`perform/4`) before the hold clears, so no dispatch sees a cleared hold on a ticket
  still in its old phase, and a restart between the two leaves the record moved, with the answered
  request clearing the hold on the next read.

  A move may carry a verdict recorded before it, bound to the head the question was asked on: a
  merge without a QA result records the `qa` verdict `skip` with the reason `skipped by decision`.
  """

  alias SymphonyElixir.{MergeConfirmation, TicketSignals, TransitionGuard}

  @canceled_spellings ["Canceled", "Cancelled"]

  @typedoc "A verdict a move records first: its kind, outcome, the head it judges and why."
  @type verdict :: %{kind: String.t(), outcome: String.t(), head_sha: String.t() | nil, reason: String.t()}

  @typedoc "The state a picked option moves the ticket to, and the verdict it records first, if any."
  @type t :: %{required(:to) => String.t(), optional(:verdict) => verdict()}

  @doc "`option` carrying `move`: picking it makes the move."
  @spec option(map(), t()) :: map()
  def option(%{} = option, %{to: to} = move) when is_binary(to), do: Map.put(option, :move, move)

  @doc """
  The move of the one option `answers` pick among the hold's options (by number or label, as
  `SymphonyElixir.MergeConfirmation.picked_option/2` reads a pick), or nil when the answers pick
  none, several, or an option that moves nothing.
  """
  @spec picked(map() | nil, [String.t()]) :: t() | nil
  def picked(hold, answers) when is_list(answers) do
    options = hold |> decision_options() |> List.wrap()

    case MergeConfirmation.picked_option(Enum.map(options, &label/1), answers) do
      nil -> nil
      number -> options |> Enum.at(number - 1) |> move()
    end
  end

  @doc "Whether any of `options` carries a move."
  @spec moves?([map() | String.t()] | nil) :: boolean()
  def moves?(options), do: options |> List.wrap() |> Enum.any?(&(move(&1) != nil))

  @doc """
  Records the move's verdict, then moves the ticket `issue_id` of `repo_key` to the move's state
  through the guard (`SymphonyElixir.TransitionGuard.perform/4`, which writes the record first). A
  move to Canceled tries the team's other spelling when the first is not one of its states.
  Answers `{:ok, state}` with the state it moved to, or the guard's error. `opts[:issue_identifier]`
  names the ticket in a refusal's log, and `opts[:tracker]` overrides the tracker.
  """
  @spec perform(String.t() | nil, String.t(), t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def perform(repo_key, issue_id, %{to: to} = move, opts \\ []) do
    record_verdict(repo_key, issue_id, Map.get(move, :verdict))
    ctx = %{repo_key: repo_key, issue_identifier: Keyword.get(opts, :issue_identifier)}

    Enum.reduce_while(spellings(to), {:error, :state_not_found}, fn state, _result ->
      case TransitionGuard.perform(issue_id, :director_move, Map.put(ctx, :target, state), Keyword.take(opts, [:tracker])) do
        :ok -> {:halt, {:ok, state}}
        {:error, :state_not_found} = error -> {:cont, error}
        error -> {:halt, error}
      end
    end)
  end

  defp record_verdict(repo_key, issue_id, %{kind: kind, outcome: outcome} = verdict),
    do: TicketSignals.record_verdict(repo_key, issue_id, kind, Map.get(verdict, :head_sha), outcome, %{reason: Map.get(verdict, :reason)})

  defp record_verdict(_repo_key, _issue_id, _none), do: :ok

  defp spellings(to), do: if(to in @canceled_spellings, do: [to | @canceled_spellings -- [to]], else: [to])

  defp decision_options(%{decision: %{options: options}}), do: options
  defp decision_options(_hold), do: nil

  defp label(%{label: label}) when is_binary(label), do: label
  defp label(_option), do: ""

  defp move(%{move: %{to: to} = move}) when is_binary(to), do: move
  defp move(_option), do: nil
end
