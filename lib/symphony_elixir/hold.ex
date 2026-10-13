defmodule SymphonyElixir.Hold do
  @moduledoc """
  The machine-owned holds that pause a ticket in its phase without moving it.

  A hold is persisted in the ticket-state record (`SymphonyElixir.TicketState`, written through
  `SymphonyElixir.RunStore`) and surfaced as a machine-owned Linear label — the label is only the
  projection; the store is the truth. `SymphonyElixir.MachineLabels` refuses these names on the
  generic `Tracker.add_issue_label/2` and `Tracker.remove_issue_label/2` paths, so agents and
  people can never write one: only `set/5` and `clear/4` here do, through
  `Tracker.set_machine_label/2` and `Tracker.clear_machine_label/2`. Dispatch consults `held?/4`
  (the store), never the board.

  The store is written first and the label second: a label write that fails leaves the hold in
  force and is reported, rather than losing the pause. `drift/2` compares the store against the
  board — a hold label with no store record (a hand-added label) or a store hold missing its
  label — so the projection can be reported and repaired.
  """

  require Logger

  alias SymphonyElixir.{RunStore, TicketState, Tracker}

  @kind_labels %{blocked: "Blocked", needs_decision: "Needs Decision"}
  @kinds [:blocked, :needs_decision]
  @access_type "access"

  @typedoc "The holds the design defines."
  @type kind :: :blocked | :needs_decision

  @doc "The known hold kinds, in display order."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The machine label a hold of `kind` is projected as, or nil for an unknown kind."
  @spec label(kind() | term()) :: String.t() | nil
  def label(kind), do: Map.get(@kind_labels, kind)

  @doc "The hold kind a machine label names, or nil."
  @spec kind_for_label(String.t() | nil) :: kind() | nil
  def kind_for_label(name) when is_binary(name) do
    normalized = normalize(name)
    Enum.find(@kinds, &(normalize(@kind_labels[&1]) == normalized))
  end

  def kind_for_label(_name), do: nil

  @doc "The hold of `kind` on the ticket's record (the store truth), or nil."
  @spec get(String.t() | nil, String.t() | nil, kind(), keyword()) :: TicketState.hold() | nil
  def get(repo_key, issue_id, kind, opts \\ []) do
    repo_key
    |> record(issue_id, opts)
    |> TicketState.get_hold(kind)
  end

  @doc "Whether a hold of `kind` is set on the ticket's record (the store truth)."
  @spec held?(String.t() | nil, String.t() | nil, kind(), keyword()) :: boolean()
  def held?(repo_key, issue_id, kind, opts \\ []), do: get(repo_key, issue_id, kind, opts) != nil

  @doc """
  Whether the ticket carries a hold of any kind, read from the store in one go. Every hold pauses
  the flow the same way, whatever set it, so a dispatch gate asks this rather than naming a kind.
  """
  @spec held_any?(String.t() | nil, String.t() | nil, keyword()) :: boolean()
  def held_any?(repo_key, issue_id, opts \\ []), do: held_kinds(repo_key, issue_id, opts) != []

  @doc "The kinds of hold the ticket carries, in display order, read from the store in one go."
  @spec held_kinds(String.t() | nil, String.t() | nil, keyword()) :: [kind()]
  def held_kinds(repo_key, issue_id, opts \\ []) do
    record = record(repo_key, issue_id, opts)
    Enum.filter(@kinds, &TicketState.hold?(record, &1))
  end

  @doc """
  Whether a hold is waiting on an access grant a person hands over — what an agent's block report
  records. A dependency or fix-ticket hold clears on its own when what it waits on goes terminal;
  an access hold is lifted by a person's `Unblock` (see `SymphonyElixir.DirectorMoves`), so it is
  the one hold that never clears without a person.
  """
  @spec access_wait?(TicketState.hold() | term()) :: boolean()
  def access_wait?(%{waits_on: %{type: @access_type}}), do: true
  def access_wait?(_hold), do: false

  @doc """
  Sets the hold of `kind` on `issue_id`: the store record first, then the machine label. Returns
  `{:error, reason}` only when the store write failed (the hold did not land); a failed label
  write is reported and does not undo the hold.
  """
  @spec set(String.t() | nil, String.t() | nil, kind(), map(), keyword()) :: :ok | {:error, term()}
  def set(repo_key, issue_id, kind, attrs \\ %{}, opts \\ []) do
    if label(kind) do
      store = Keyword.get(opts, :store, RunStore)

      with :ok <- require_repo_key(repo_key, issue_id),
           :ok <- store.set_ticket_hold(repo_key, issue_id, kind, attrs) do
        project(Keyword.get(opts, :tracker, Tracker), issue_id, kind, :set)
      end
    else
      {:error, {:unknown_hold_kind, kind}}
    end
  end

  @doc """
  Clears the hold of `kind` from `issue_id`: the store record first, then the machine label. The
  ticket continues in place. Returns `{:error, reason}` only when the store write failed.
  """
  @spec clear(String.t() | nil, String.t() | nil, kind(), keyword()) :: :ok | {:error, term()}
  def clear(repo_key, issue_id, kind, opts \\ []) do
    if label(kind) do
      store = Keyword.get(opts, :store, RunStore)

      with :ok <- require_repo_key(repo_key, issue_id),
           :ok <- store.clear_ticket_hold(repo_key, issue_id, kind) do
        project(Keyword.get(opts, :tracker, Tracker), issue_id, kind, :clear)
      end
    else
      {:error, {:unknown_hold_kind, kind}}
    end
  end

  @doc """
  Re-projects the machine label of a hold already in the store, without writing the store. A store
  hold whose label write failed (the failure is swallowed by `set/5`) or whose label a person removed
  by hand is invisible on the board; this re-asserts the projection from the store truth so the hold
  becomes visible again. Returns `{:error, {:no_hold, kind}}` when the store has no such hold.
  """
  @spec reproject(String.t() | nil, String.t() | nil, kind(), keyword()) :: :ok | {:error, term()}
  def reproject(repo_key, issue_id, kind, opts \\ []) do
    if label(kind) do
      case get(repo_key, issue_id, kind, opts) do
        nil -> {:error, {:no_hold, kind}}
        _hold -> project(Keyword.get(opts, :tracker, Tracker), issue_id, kind, :set)
      end
    else
      {:error, {:unknown_hold_kind, kind}}
    end
  end

  @doc """
  Compares the ticket's store holds (`record`) with the machine labels it carries on the board
  (`labels`). Returns `:ok`, `{:stray_label, kind}` for a label with no store hold (a hand-added
  label), or `{:missing_label, kind}` for a store hold whose label the board is missing.
  """
  @spec drift(TicketState.t() | term(), [String.t()] | nil) ::
          :ok | {:stray_label, kind()} | {:missing_label, kind()}
  def drift(record, labels) do
    labels = Enum.map(labels || [], &normalize/1)

    Enum.find_value(@kinds, :ok, fn kind ->
      on_board? = normalize(label(kind)) in labels

      cond do
        on_board? and not TicketState.hold?(record, kind) -> {:stray_label, kind}
        not on_board? and TicketState.hold?(record, kind) -> {:missing_label, kind}
        true -> nil
      end
    end)
  end

  @doc """
  Reads the ticket's store record and its board labels and reports any drift, so a hand-added hold
  label (or a store hold the board is missing) is visible. Returns the drift it reported.
  """
  @spec report_drift(String.t() | nil, String.t() | nil, [String.t()] | nil, keyword()) ::
          :ok | {:stray_label, kind()} | {:missing_label, kind()}
  def report_drift(repo_key, issue_id, labels, opts \\ []) do
    case drift(record(repo_key, issue_id, opts), labels) do
      :ok ->
        :ok

      {:stray_label, kind} = drift ->
        Logger.warning(
          "Machine label #{inspect(label(kind))} is on issue_id=#{issue_id} with no store hold; " <>
            "a hand-added label — the store is the truth"
        )

        drift

      {:missing_label, kind} = drift ->
        Logger.warning("Store hold #{inspect(kind)} on issue_id=#{issue_id} is missing its machine label")
        drift
    end
  end

  defp project(tracker, issue_id, kind, action) do
    name = label(kind)

    result =
      case action do
        :set -> tracker.set_machine_label(issue_id, name)
        :clear -> tracker.clear_machine_label(issue_id, name)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to #{action} the machine label #{inspect(name)} on issue_id=#{issue_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp record(_repo_key, nil, _opts), do: TicketState.normalize(nil)

  defp record(repo_key, issue_id, opts) when is_binary(repo_key) and is_binary(issue_id) do
    store = Keyword.get(opts, :store, RunStore)

    case store.get_ticket_state(repo_key, issue_id) do
      {:error, reason} ->
        Logger.warning("Failed to read the ticket state for issue_id=#{issue_id}: #{inspect(reason)}")
        TicketState.normalize(nil)

      record ->
        TicketState.normalize(record)
    end
  end

  # A ticket read with no repo key would look like one with no hold, so say so instead of hiding it.
  defp record(repo_key, issue_id, _opts) when is_binary(issue_id) and repo_key in [nil, ""] do
    Logger.error("Read the holds of issue_id=#{issue_id} with no repo key; resolve the issue's repo before reading its holds")
    TicketState.normalize(nil)
  end

  defp record(_repo_key, _issue_id, _opts), do: TicketState.normalize(nil)

  # A hold written with no repo key would land nowhere the readers look, so it is refused loudly.
  defp require_repo_key(repo_key, _issue_id) when is_binary(repo_key) and repo_key != "", do: :ok

  defp require_repo_key(_repo_key, issue_id) do
    Logger.error("Refused a hold write on issue_id=#{issue_id} with no repo key; resolve the issue's repo first")
    {:error, :missing_repo_key}
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
