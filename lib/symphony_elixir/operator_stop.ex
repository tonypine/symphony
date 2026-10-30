defmodule SymphonyElixir.OperatorStop do
  @moduledoc """
  What an operator's Stop leaves on a ticket, so the dispatcher does not start it again.

  A stop ends the run, but Symphony's copy of the ticket still reads the state it had (often
  `Todo`), so without a mark the next dispatch tick would start it again within seconds. The stop
  therefore pauses the ticket (`SymphonyElixir.Pauses`, the one writer) on a `:person` reason that
  waits on the Director's Unblock (`reason/1`), and the dispatcher skips a ticket whose pause has
  it, listing it under `dispatch_skipped` with the reason's text (`skip_reason/2`). The pause is in
  the run store, so a stopped ticket is still stopped after Symphony restarts.

  Beside the pause, and after it, the stop sets a Blocked hold whose `waits_on` type is
  `operator_stop` (`hold_attrs/1`): its Linear label, and the Director's Inbox row "Stopped by you",
  where Unblock runs the ticket again in place and Restart starts it over. The hold is cleared with
  the reason (`clear_hold/3`).

  The stop asks for a poll at once, and each poll reads the stopped tickets (`stopped/1`) by id
  (`confirm/3`): a ticket that is gone, terminal or no longer in an active state, or whose phase
  was written after the stop (a person's move on the board), loses its reason and its hold (nothing
  waits to start). A person who unblocks or restarts it clears both at once.
  """

  alias SymphonyElixir.{Hold, Pauses, RunStore, TicketState}
  alias SymphonyElixir.Linear.Issue

  @hold_type "operator_stop"
  # The reason's kind and `waits_on`, as the backfill of the stops' holds wrote them too
  # (`SymphonyElixir.Pauses.Backfill`).
  @kind :person
  @waits_on %{action: "unblock"}
  @director %{kind: :person, name: "Director"}

  @typedoc """
  A stopped ticket as the store holds it: its id, repo and identifier, when it was stopped, and
  when its record's phase was last written (nil when never).
  """
  @type stop :: %{
          issue_id: String.t(),
          repo_key: String.t(),
          identifier: String.t() | nil,
          stopped_at: DateTime.t() | nil,
          phase_at: DateTime.t() | nil
        }

  @doc "The `waits_on` type of the Blocked hold a stop sets."
  @spec hold_type() :: String.t()
  def hold_type, do: @hold_type

  @doc "Whether `hold` is the Blocked hold an operator's stop set."
  @spec hold?(TicketState.hold() | term()) :: boolean()
  def hold?(%{waits_on: %{type: @hold_type}}), do: true
  def hold?(_hold), do: false

  @doc "The pause reason a stop at `stopped_at` sets: the Director's, released by Unblock."
  @spec reason(DateTime.t()) :: Pauses.reason_input()
  def reason(%DateTime{} = stopped_at) do
    %{
      kind: @kind,
      waits_on: @waits_on,
      text: "Stopped by you at #{format_time(stopped_at)}. Unblock runs it again; Restart starts it over from main."
    }
  end

  @doc "Pauses the ticket on the stop's reason, set by the Director at `stopped_at`."
  @spec mark(String.t() | nil, String.t(), DateTime.t()) :: :ok | {:error, term()}
  def mark(repo_key, issue_id, %DateTime{} = stopped_at) do
    with {:ok, _pause} <- Pauses.set({:ticket, repo_key, issue_id}, reason(stopped_at), set_by: @director, at: stopped_at), do: :ok
  end

  @doc "The Blocked hold's attributes: the Inbox shows its reason as \"Stopped by you …\"."
  @spec hold_attrs(DateTime.t()) :: map()
  def hold_attrs(%DateTime{} = stopped_at) do
    %{
      reason: "Stopped by you at #{format_time(stopped_at)}. Unblock runs it again where it stopped; Restart starts it over from main.",
      clearing_condition: "when a person unblocks or restarts it, or moves it on the board",
      waits_on: %{type: @hold_type, keys: []}
    }
  end

  @doc "Whether the ticket's pause has the stop's reason."
  @spec held?(String.t() | nil, String.t()) :: boolean()
  def held?(repo_key, issue_id), do: skip_reason(repo_key, issue_id) != nil

  @doc "Why the dispatcher skips the ticket: its stop reason's text, or nil when it is not stopped."
  @spec skip_reason(String.t() | nil, String.t()) :: String.t() | nil
  def skip_reason(repo_key, issue_id) do
    with {:ok, %{reasons: reasons}} <- Pauses.get({:ticket, repo_key, issue_id}),
         %{text: text} <- Enum.find(reasons, &stop_reason?/1),
         do: text,
         else: (_none -> nil)
  end

  @doc "The stopped tickets in the store, of every repo: those whose pause has the stop's reason."
  @spec stopped(module()) :: [stop()]
  def stopped(store \\ RunStore) do
    case store.list_all_ticket_states() do
      records when is_list(records) -> records |> Enum.map(&TicketState.normalize/1) |> Enum.flat_map(&stop/1)
      _error -> []
    end
  end

  @doc """
  What a poll's read calls for: keep the stop, or clear it. `issue` is the ticket as the poll read
  it by id (nil when Linear no longer returns it) and `candidate?` whether its state is active and
  not terminal; a phase written after the stop is a move on the board.
  """
  @spec confirm(stop(), Issue.t() | nil, boolean()) :: :keep | :clear
  def confirm(_stop, nil, _candidate?), do: :clear
  def confirm(_stop, %Issue{}, false = _candidate?), do: :clear

  def confirm(%{phase_at: %DateTime{} = phase_at, stopped_at: %DateTime{} = stopped_at}, %Issue{}, true) do
    if DateTime.compare(phase_at, stopped_at) == :gt, do: :clear, else: :keep
  end

  def confirm(_stop, %Issue{}, true), do: :keep

  @doc """
  Writes the stop's Blocked hold, unless the ticket already carries a Blocked hold of another kind
  (that one already keeps it from running, and a stop must not erase what it waits on).
  """
  @spec set_hold(String.t() | nil, String.t(), DateTime.t(), keyword()) :: :ok | {:error, term()}
  def set_hold(repo_key, issue_id, %DateTime{} = stopped_at, opts \\ []) do
    case Hold.get(repo_key, issue_id, :blocked, opts) do
      nil -> Hold.set(repo_key, issue_id, :blocked, hold_attrs(stopped_at), opts)
      _other -> :ok
    end
  end

  @doc """
  Clears the stop: its reason from the ticket's pause (cleared by `opts[:by]`, Symphony by default),
  then its Blocked hold when it is the stop's; any other reason and hold stay.
  """
  @spec clear_hold(String.t() | nil, String.t(), keyword()) :: :ok | {:error, term()}
  def clear_hold(repo_key, issue_id, opts \\ []) do
    with {:ok, _pause} <- Pauses.clear_reason({:ticket, repo_key, issue_id}, %{kind: @kind, waits_on: @waits_on}, Keyword.take(opts, [:by])) do
      if repo_key |> Hold.get(issue_id, :blocked, opts) |> hold?(),
        do: Hold.clear(repo_key, issue_id, :blocked, opts),
        else: :ok
    end
  end

  @doc "Who clears a stop from the Director: `clear_hold/3`'s `by:`."
  @spec director() :: Pauses.set_by()
  def director, do: @director

  # A record's pause is written under its repo and id, so a record with the stop's reason has both.
  defp stop(record) do
    case record |> TicketState.pause_reasons() |> Enum.find(&stop_reason?/1) do
      nil ->
        []

      reason ->
        [
          %{
            issue_id: record.issue_id,
            repo_key: record.repo_key,
            identifier: record.issue_identifier,
            stopped_at: reason.set_at,
            phase_at: record.phase_at
          }
        ]
    end
  end

  defp stop_reason?(%{kind: @kind, waits_on: @waits_on}), do: true
  defp stop_reason?(_reason), do: false

  defp format_time(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
end
