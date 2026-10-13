defmodule SymphonyElixir.Handoff do
  @moduledoc """
  The explicit handoff signal: how a session says its implementation is done and its PR is ready
  for review.

  A `designed` repo advances `In Progress` (or `Rework`) to `Code Review` only on this signal —
  never when a run merely goes quiet. The signal is emitted mechanically by the push and
  pull-request tool hooks (`SymphonyElixir.AgentTools.GitHub`), recorded in the ticket's signals
  ledger bound to the head it handed off, and read back by the runner before it performs any move
  into `Code Review`. A run that stops quiet with its PR already on its workspace HEAD has nothing
  to push, so the runner records the signal for that head itself and hands off. A run that ends
  without it records a `handoff_missing` event and is left where it is, for the retry machinery
  to pick up; its quiet successors back off and, after two on the same head, the ticket is held
  `Blocked` with `handoff_missing`.

  A `legacy` repo neither emits nor consults the signal, so its behavior is unchanged. This module
  is the one place that decides the handoff's target state, so the guard table, the runner and the
  GitHub tool hooks all read the same answer.
  """

  alias SymphonyElixir.{RunStore, StateMachine, TicketSignals, TicketState}

  @signal "handoff"
  @missing_signal "handoff_missing"
  @origins ["In Progress", "Rework"]
  # A legacy repo hands a PR off to In Review: Auto Review is retired, and In Review retires with
  # the legacy machine once its tickets drain.
  @legacy_target "In Review"

  @doc "The ledger signal name a session's handoff is recorded under."
  @spec signal() :: String.t()
  def signal, do: @signal

  @doc "The ledger signal name recorded when a run ends without its handoff."
  @spec missing_signal() :: String.t()
  def missing_signal, do: @missing_signal

  @doc "Whether the repo runs the designed machine, and so emits and consults the handoff signal."
  @spec designed?(map()) :: boolean()
  def designed?(settings), do: StateMachine.designed?(settings)

  @doc "The state a repo hands a finished implementation off to."
  @spec target_state(map()) :: String.t()
  def target_state(settings) do
    if designed?(settings), do: settings.tracker.code_review_state, else: @legacy_target
  end

  @doc """
  Whether a move out of `state` needs the handoff signal first: a designed repo's move from an
  origin state (`In Progress`, `Rework`) into `Code Review`.
  """
  @spec required?(String.t() | nil, map()) :: boolean()
  def required?(state, settings) do
    designed?(settings) and origin?(state)
  end

  @doc "Whether `state` is an origin the handoff signal may fire from."
  @spec origin?(String.t() | nil) :: boolean()
  def origin?(state) when is_binary(state), do: Enum.any?(@origins, &matches?(state, &1))
  def origin?(_state), do: false

  @doc """
  Records the handoff signal for the ticket, bound to the head (and branch or PR) it hands off.
  Best-effort: a store failure is logged and swallowed, exactly like every other ledger write.
  """
  @spec emit(String.t() | nil, String.t() | nil, map()) :: :ok
  def emit(repo_key, issue_id, details \\ %{}) do
    TicketSignals.record(repo_key, issue_id, @signal, Map.new(details))
  end

  @doc """
  Whether the ticket's ledger holds a handoff signal for `head`. A signal with no recorded head
  counts for any head, so a tool hook that could not read the workspace HEAD still hands off. The
  runner's own record of a completed move is a `handoff` signal too, marked `move: true`, and never
  counts: only a real emission opens the gate.
  """
  @spec emitted?(String.t() | nil, String.t() | nil, String.t() | nil) :: boolean()
  def emitted?(repo_key, issue_id, head) do
    repo_key
    |> signals(issue_id)
    |> Enum.any?(&handoff_for_head?(&1, head))
  end

  @doc """
  The ticket's recorded verdicts of `kind`, newest first. The reviewer run reads its own past
  verdicts from here to bound its inconclusive retries.
  """
  @spec verdicts(String.t() | nil, String.t() | nil, String.t()) :: [map()]
  def verdicts(repo_key, issue_id, kind) do
    case ticket_state(repo_key, issue_id) do
      nil -> []
      record -> record |> TicketState.normalize() |> Map.fetch!(:verdicts) |> Enum.filter(&(&1.kind == kind))
    end
  end

  @doc "The ticket's signals ledger, newest first; empty when there is none."
  @spec signals(String.t() | nil, String.t() | nil) :: [map()]
  def signals(repo_key, issue_id) do
    case ticket_state(repo_key, issue_id) do
      nil -> []
      record -> record |> TicketState.normalize() |> Map.fetch!(:signals)
    end
  end

  defp ticket_state(repo_key, issue_id) when is_binary(repo_key) and is_binary(issue_id) do
    case RunStore.get_ticket_state(repo_key, issue_id) do
      %{} = record -> record
      _none_or_error -> nil
    end
  end

  defp ticket_state(_repo_key, _issue_id), do: nil

  defp handoff_for_head?(%{name: @signal} = signal, head), do: not move_record?(signal) and head_matches?(signal, head)

  defp handoff_for_head?(_signal, _head), do: false

  # A signal the runner records for its own completed move, not a tool hook's emission. Every
  # normalized signal carries a `details` map.
  defp move_record?(%{details: details}), do: map_value(details, :move) == true

  defp head_matches?(%{details: details}, head) when is_binary(head) do
    case map_value(details, :head) do
      nil -> true
      recorded -> matches?(recorded, head)
    end
  end

  defp head_matches?(_signal, _head), do: true

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp matches?(name, expected) when is_binary(name) and is_binary(expected),
    do: String.downcase(String.trim(name)) == String.downcase(String.trim(expected))

  defp matches?(_name, _expected), do: false
end
