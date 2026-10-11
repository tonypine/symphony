defmodule SymphonyElixir.TicketStateReconciler do
  @moduledoc """
  Reconciles the persisted per-ticket state records against Linear at Symphony startup.

  Linear is a window on the canonical store, but today it is still the source of an in-flight
  ticket's board state. When a record's stored phase disagrees with the ticket's Linear state, the
  record adopts the Linear state (deterministically: the board wins while the migration is in
  flight) and the drift is logged. When they agree, the ticket is logged as reconciled with no
  drift. A record whose ticket Linear no longer returns is left alone and counted as missing.
  """

  require Logger

  alias SymphonyElixir.{RunStore, TicketState, Tracker}

  @type outcome :: %{checked: non_neg_integer(), drifted: non_neg_integer(), missing: non_neg_integer()}

  @doc """
  Reconciles one record against the Linear `state` it now has. Returns `{:ok, record}` when they
  agree, `{:stamped, record}` when the record had no phase yet (it adopts the board's), and
  `{:drift, record, %{from:, to:}}` when the board state differs.
  """
  @spec reconcile(TicketState.t(), String.t() | nil, DateTime.t()) ::
          {:ok, TicketState.t()}
          | {:stamped, TicketState.t()}
          | {:drift, TicketState.t(), %{from: String.t() | nil, to: String.t() | nil}}
  def reconcile(record, state, at \\ DateTime.utc_now()) do
    record = TicketState.normalize(record)

    cond do
      state == record.phase ->
        {:ok, record}

      is_nil(record.phase) ->
        {:stamped, TicketState.put_phase(record, state, at)}

      true ->
        {:drift, TicketState.put_phase(record, state, at), %{from: record.phase, to: state}}
    end
  end

  @doc """
  Reconciles every persisted record against Linear. `opts`:

  - `:fetcher` — `fun([issue_id]) -> {:ok, [issue]} | {:error, reason}`, defaulting to
    `Tracker.fetch_issue_states_by_ids/1`
  - `:store` — the store to read and update records through, defaulting to `RunStore`
  - `:now` — the time stamped on a record whose phase was empty

  Returns `%{checked:, drifted:, missing:}`. A read or fetch error is logged and leaves the records
  as they are.
  """
  @spec reconcile_all(keyword()) :: outcome()
  def reconcile_all(opts \\ []) do
    store = Keyword.get(opts, :store, RunStore)
    records = stored_records(store)

    case records do
      [] ->
        %{checked: 0, drifted: 0, missing: 0}

      records ->
        case fetch_states(Enum.map(records, & &1.issue_id), opts) do
          {:ok, issues} ->
            reconcile_records(records, index_states(issues), Keyword.get(opts, :now, DateTime.utc_now()), store)

          {:error, reason} ->
            fetch_failed(reason)
        end
    end
  end

  defp stored_records(store) do
    case store.list_all_ticket_states() do
      records when is_list(records) -> records
      {:error, reason} -> log_read_error(reason)
    end
  end

  defp log_read_error(reason) do
    Logger.warning("Ticket state reconciliation skipped: failed to read the store: #{inspect(reason)}")
    []
  end

  defp fetch_states(issue_ids, opts) do
    fetcher = Keyword.get(opts, :fetcher, &Tracker.fetch_issue_states_by_ids/1)
    fetcher.(issue_ids)
  rescue
    error -> {:error, error}
  end

  defp index_states(issues) when is_list(issues) do
    Enum.reduce(issues, %{}, fn issue, acc ->
      case issue_state(issue) do
        {issue_id, state} when is_binary(issue_id) -> Map.put(acc, issue_id, state)
        _missing -> acc
      end
    end)
  end

  defp issue_state(issue) do
    case issue_id(issue) do
      issue_id when is_binary(issue_id) -> {issue_id, state_of(issue)}
      _issue_id -> nil
    end
  end

  defp issue_id(issue) when is_map(issue), do: Map.get(issue, :id) || Map.get(issue, "id")
  defp issue_id(_issue), do: nil

  defp state_of(issue), do: Map.get(issue, :state) || Map.get(issue, "state")

  defp reconcile_records(records, states, now, store) do
    Enum.reduce(records, %{checked: 0, drifted: 0, missing: 0}, fn record, acc ->
      case Map.fetch(states, record.issue_id) do
        {:ok, state} -> reconcile_record(record, state, now, acc, store)
        :error -> %{acc | missing: acc.missing + 1}
      end
    end)
    |> tap(&log_summary/1)
  end

  defp reconcile_record(record, state, now, acc, store) do
    case reconcile(record, state, now) do
      {:ok, _record} ->
        %{acc | checked: acc.checked + 1}

      {:stamped, updated} ->
        persist_phase(updated, "ticket state phase", store)
        %{acc | checked: acc.checked + 1}

      {:drift, updated, drift} ->
        persist_phase(updated, "ticket state drift", store)
        log_drift(updated.issue_id, drift)
        %{acc | checked: acc.checked + 1, drifted: acc.drifted + 1}
    end
  end

  defp persist_phase(%{repo_key: repo_key, issue_id: issue_id, phase: phase, updated_at: at}, action, store) do
    case store.update_ticket_state(repo_key, issue_id, %{phase: phase, updated_at: at}) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record #{action} for #{issue_id}: #{inspect(reason)}")
    end
  end

  defp log_drift(issue_id, %{from: from, to: to}) do
    Logger.info("Ticket state drift reconciled issue_id=#{issue_id} from=#{inspect(from)} to=#{inspect(to)}")
  end

  defp log_summary(%{checked: checked, drifted: drifted, missing: missing}) do
    Logger.info("Ticket state store reconciled checked=#{checked} drifted=#{drifted} missing=#{missing}")
  end

  defp fetch_failed(reason) do
    Logger.warning("Ticket state reconciliation skipped: failed to read Linear states: #{inspect(reason)}")
    %{checked: 0, drifted: 0, missing: 0}
  end
end
