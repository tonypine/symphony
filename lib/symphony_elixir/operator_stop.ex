defmodule SymphonyElixir.OperatorStop do
  @moduledoc """
  What an operator's Stop leaves on a ticket, so the dispatcher does not start it again.

  A stop ends the run, but Symphony's copy of the ticket still reads the state it had (often
  `Todo`) until a poll reads Linear again, so without a mark the next dispatch tick would start it
  again within seconds. The stop therefore leaves a mark on the ticket:

    * in the orchestrator, a `t:mark/0`: the stop's time, and the state the first poll after the
      stop confirmed (nil until then). The dispatcher skips a marked ticket, and `/api/v1/state`
      lists it under `dispatch_skipped` with `skip_reason/1`;
    * in the run store, a Blocked hold whose `waits_on` type is `operator_stop` (`hold_attrs/1`),
      which keeps the mark across a restart (`hydrate/2`) and puts the ticket in the Director's
      Inbox as "Stopped by you", where Unblock runs it again in place and Restart starts it over.

  The stop asks for a poll at once, and each poll reads the marked tickets by id (`confirm/4`): a
  ticket that is gone, terminal or no longer in an active state loses its mark and its hold (the
  ticket left the workflow, so nothing waits to start); on first sight the poll confirms the state
  and the ticket stays skipped; a later change of state is a person's move on the board, which
  also clears the mark. A person who lifts the hold (Unblock or Restart) lifts the mark with it.
  """

  alias SymphonyElixir.{Hold, RunStore, TicketState}
  alias SymphonyElixir.Linear.Issue

  @hold_type "operator_stop"

  @typedoc """
  The orchestrator's mark: the ticket's identifier and repo, when it was stopped, the state the
  first poll after the stop confirmed (nil until then), and whether its Blocked hold landed in the
  store.
  """
  @type mark :: %{
          identifier: String.t() | nil,
          repo_key: String.t() | nil,
          stopped_at: DateTime.t(),
          state: String.t() | nil,
          held: boolean()
        }

  @typedoc """
  What a poll's read of the ticket calls for: keep the mark (with the state it confirmed), clear it
  and its hold, or drop the mark because a person already lifted its hold.
  """
  @type verdict :: {:keep, mark()} | :clear | :lifted

  @doc "The `waits_on` type of the Blocked hold a stop sets."
  @spec hold_type() :: String.t()
  def hold_type, do: @hold_type

  @doc "Whether `hold` is the Blocked hold an operator's stop set."
  @spec hold?(TicketState.hold() | term()) :: boolean()
  def hold?(%{waits_on: %{type: @hold_type}}), do: true
  def hold?(_hold), do: false

  @doc "A new mark for a ticket stopped at `stopped_at`: its state unconfirmed and its hold not yet written."
  @spec mark(String.t() | nil, String.t() | nil, DateTime.t()) :: mark()
  def mark(identifier, repo_key, %DateTime{} = stopped_at) do
    %{identifier: identifier, repo_key: repo_key, stopped_at: stopped_at, state: nil, held: false}
  end

  @doc "The Blocked hold's attributes: the Inbox shows its reason as \"Stopped by you …\"."
  @spec hold_attrs(mark()) :: map()
  def hold_attrs(%{stopped_at: stopped_at}) do
    %{
      reason: "Stopped by you at #{format_time(stopped_at)}. Unblock runs it again where it stopped; Restart starts it over from main.",
      clearing_condition: "when a person unblocks or restarts it, or moves it on the board",
      waits_on: %{type: @hold_type, keys: []}
    }
  end

  @doc "Why the dispatcher skips the ticket, as `dispatch_skipped` lists it."
  @spec skip_reason(mark()) :: String.t()
  def skip_reason(%{stopped_at: stopped_at, state: nil}),
    do: "stopped by the operator at #{format_time(stopped_at)}; waiting for the next poll"

  def skip_reason(%{stopped_at: stopped_at}),
    do: "stopped by the operator at #{format_time(stopped_at)}; Unblock or Restart in the Director runs it again"

  @doc """
  What a poll's read calls for. `issue` is the ticket as the poll read it by id (nil when Linear
  no longer returns it), `candidate?` whether its state is active and not terminal, and `held?`
  whether its operator-stop hold is still in the store.
  """
  @spec confirm(mark(), Issue.t() | nil, boolean(), boolean()) :: verdict()
  def confirm(_mark, nil, _candidate?, _held?), do: :clear
  def confirm(_mark, %Issue{}, false = _candidate?, _held?), do: :clear
  def confirm(%{held: true}, %Issue{}, true, false = _held?), do: :lifted
  def confirm(%{state: nil} = mark, %Issue{state: state}, true, _held?), do: {:keep, %{mark | state: state}}

  def confirm(%{state: confirmed} = mark, %Issue{state: state}, true, _held?) do
    if same_state?(confirmed, state), do: {:keep, mark}, else: :clear
  end

  @doc """
  The marks the run store's operator-stop holds call for in `repo_keys`, each with its state
  unconfirmed, so the first poll after a restart confirms it again.
  """
  @spec hydrate([String.t()], module()) :: %{String.t() => mark()}
  def hydrate(repo_keys, store \\ RunStore) when is_list(repo_keys) do
    for repo_key <- repo_keys,
        records <- [store.list_ticket_states(repo_key)],
        is_list(records),
        record <- records,
        %{issue_id: issue_id} = normalized <- [TicketState.normalize(record)],
        is_binary(issue_id),
        hold <- [TicketState.get_hold(normalized, :blocked)],
        hold?(hold),
        into: %{} do
      stopped_at = Map.get(hold, :set_at) || DateTime.utc_now()
      {issue_id, %{mark(normalized.issue_identifier, repo_key, stopped_at) | held: true}}
    end
  end

  @doc """
  Writes the stop's Blocked hold, unless the ticket already carries a Blocked hold of another kind
  (that one already keeps it from running, and a stop must not erase what it waits on).
  """
  @spec set_hold(String.t() | nil, String.t(), mark(), keyword()) :: :ok | {:error, term()}
  def set_hold(repo_key, issue_id, mark, opts \\ []) do
    case Hold.get(repo_key, issue_id, :blocked, opts) do
      nil -> Hold.set(repo_key, issue_id, :blocked, hold_attrs(mark), opts)
      _other -> :ok
    end
  end

  @doc "Whether the ticket's operator-stop hold is still in the store."
  @spec held?(String.t() | nil, String.t(), keyword()) :: boolean()
  def held?(repo_key, issue_id, opts \\ []), do: repo_key |> Hold.get(issue_id, :blocked, opts) |> hold?()

  @doc "Clears the ticket's Blocked hold when it is the stop's; any other hold stays."
  @spec clear_hold(String.t() | nil, String.t(), keyword()) :: :ok | {:error, term()}
  def clear_hold(repo_key, issue_id, opts \\ []) do
    if held?(repo_key, issue_id, opts), do: Hold.clear(repo_key, issue_id, :blocked, opts), else: :ok
  end

  defp format_time(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

  defp same_state?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(String.trim(left)) == String.downcase(String.trim(right))

  defp same_state?(left, right), do: left == right
end
