defmodule SymphonyElixir.DirectorBlockers do
  @moduledoc """
  The Director's blocked-by links, from a ticket's page in the Mac app (TP-1354): `change/4` adds
  or removes the link "`blocker` blocks the ticket", and `blockers/2` lists the ticket's blockers
  and the tickets it can be given as one.

  Both tickets are ones Symphony tracks: each has a record (`SymphonyElixir.TicketState`) that is
  not removed, found by identifier or id in every configured repository's records. A change is
  refused, with a reason the app shows (`{:error, {:conflict, message}}`), when:

    * either ticket has no record ("Symphony doesn't track TP-9");
    * the blocker is the ticket itself;
    * adding the link closes a cycle: the blocker already waits on the ticket, directly or through
      others, as the records' blockers say (`SymphonyElixir.PrWatch.Competitors.closes_cycle?/3`);
    * the blocker is finished (a terminal phase), so it would block nothing;
    * the link is already there (add) or isn't (remove).

  A change writes Linear first (`SymphonyElixir.Linear.Adapter.add_blocked_by/2` and
  `remove_blocked_by/2`, the `:linker`); a write Linear refuses is `{:error, {:linear, reason}}`
  and changes nothing. Then, at once and without waiting for the next read of Linear:

    * the record's `blockers` gain the blocker (its id, identifier and phase) or lose it, and the
      change is announced (`SymphonyElixirWeb.ObservabilityPubSub.broadcast_ticket_record_changed/3`);
    * the ticket's pause follows: an added blocker holds a ticket in an active phase
      (`SymphonyElixir.Pauses.Dependencies.sync_records/3`), and a removed one's reason clears in
      any phase, so the ticket no longer waits for it;
    * the ticket's events get a `person.action` (`add_blocker` or `remove_blocker`, with the
      `blocker`) by the Director, the audit log a `director_move`, and the orchestrator is asked to
      poll the ticket's repository, so a ticket the change releases is dispatched in its turn.
  """

  require Logger

  alias SymphonyElixir.{AuditLog, Config, Orchestrator, Pauses, RunStore, StateMachine, TicketSignals, TicketState}
  alias SymphonyElixir.Pauses.Dependencies
  alias SymphonyElixir.PrWatch.Competitors
  alias SymphonyElixirWeb.ObservabilityPubSub

  @director {:person, "the Director"}

  @type action :: :add | :remove
  @type error :: {:invalid, String.t()} | {:conflict, String.t()} | {:linear, term()}

  @doc """
  Adds (`:add`) or removes (`:remove`) the link "`blocker` blocks `identifier`", both named by
  identifier or id, as the moduledoc says. Answers the ticket's blockers after the change.

  Options: `:linker` (default `SymphonyElixir.Linear.Adapter`), `:orchestrator` (asked to poll
  again, default `SymphonyElixir.Orchestrator`), `:audit_log` (the audit log's options),
  `:records` (the tracked records, default every record in the run store), `:terminal_states` and
  `:active_states` (default the settings').
  """
  @spec change(action(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def change(action, identifier, blocker, opts \\ []) when action in [:add, :remove] and is_binary(identifier) and is_binary(blocker) do
    records = records(opts)
    terminal = terminal_states(opts)

    with {:ok, ticket} <- find(records, identifier),
         {:ok, blocking} <- find(records, blocker),
         :ok <- allowed(action, ticket, blocking, records, terminal),
         :ok <- write_linear(action, ticket, blocking, opts) do
      record = write_record(action, ticket, blocking)
      follow_pause(action, record, blocking, terminal, opts)
      record_action(action, record, blocking, opts)
      Orchestrator.request_refresh(Keyword.get(opts, :orchestrator, Orchestrator), record.repo_key, due: :now)
      Logger.info("Director #{action}_blocker issue_identifier=#{record.issue_identifier} blocker=#{blocking.issue_identifier}")

      {:ok,
       %{
         action: Atom.to_string(action),
         issue_identifier: record.issue_identifier,
         blocker: blocking.issue_identifier,
         blockers: links(record.blockers, records)
       }}
    end
  end

  @doc """
  The blockers of the ticket `identifier` (identifier or id) as its record holds them, each with
  its title and phase when Symphony tracks it, and the `candidates`: every other open ticket
  Symphony tracks that doesn't block it yet, by identifier. `{:error, {:conflict, message}}` for
  a ticket Symphony doesn't track. Options as for `change/4`.
  """
  @spec blockers(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def blockers(identifier, opts \\ []) when is_binary(identifier) do
    records = records(opts)
    terminal = terminal_states(opts)

    with {:ok, ticket} <- find(records, identifier) do
      candidates =
        records
        |> Enum.reject(&(&1.issue_id == ticket.issue_id or blocks?(ticket, &1) or terminal?(&1.phase, terminal) or is_nil(&1.issue_identifier)))
        |> Enum.sort_by(&identifier_sort_key(&1.issue_identifier))
        |> Enum.map(&ticket_json/1)

      blockers = links(ticket.blockers, records)
      {:ok, %{issue_identifier: ticket.issue_identifier, blockers: blockers, candidates: candidates}}
    end
  end

  defp records(opts) do
    opts
    |> Keyword.get_lazy(:records, fn -> List.wrap(with({:error, _reason} <- RunStore.list_all_ticket_states(), do: [])) end)
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.filter(&(is_binary(&1.issue_id) and is_binary(&1.repo_key) and is_nil(&1.removed_at)))
  end

  defp find(records, name) do
    name = String.trim(name)

    case Enum.find(records, &(&1.issue_id == name or same_identifier?(&1.issue_identifier, name))) do
      nil -> {:error, {:conflict, "Symphony doesn't track #{name}, so it can't be linked as a blocker or be given one."}}
      record -> {:ok, record}
    end
  end

  defp same_identifier?(identifier, name) when is_binary(identifier), do: String.upcase(identifier) == String.upcase(name)
  defp same_identifier?(_identifier, _name), do: false

  defp allowed(_action, %{issue_id: id} = ticket, %{issue_id: id}, _records, _terminal),
    do: {:error, {:conflict, "#{ticket.issue_identifier} can't block itself."}}

  defp allowed(:add, ticket, blocking, records, terminal) do
    cond do
      blocks?(ticket, blocking) ->
        {:error, {:conflict, "#{blocking.issue_identifier} already blocks #{ticket.issue_identifier}."}}

      terminal?(blocking.phase, terminal) ->
        {:error, {:conflict, "#{blocking.issue_identifier} is #{blocking.phase}: a finished ticket blocks nothing."}}

      Competitors.closes_cycle?(graph(records), blocking.issue_id, ticket.issue_id) ->
        {:error, {:conflict, "#{blocking.issue_identifier} already waits on #{ticket.issue_identifier}, so blocking #{ticket.issue_identifier} on it would make a cycle."}}

      true ->
        :ok
    end
  end

  defp allowed(:remove, ticket, blocking, _records, _terminal) do
    if blocks?(ticket, blocking), do: :ok, else: {:error, {:conflict, "#{blocking.issue_identifier} doesn't block #{ticket.issue_identifier}."}}
  end

  defp blocks?(ticket, blocking), do: Enum.any?(ticket.blockers, &link_to?(&1, blocking))

  defp link_to?(link, record), do: (is_binary(link.id) and link.id == record.issue_id) or (is_nil(link.id) and same_identifier?(link.identifier, record.issue_identifier || ""))

  # Each tracked ticket's issue id mapped to its blockers' ids, a blocker known by identifier only
  # resolved through the records.
  defp graph(records) do
    ids = for record <- records, is_binary(record.issue_identifier), into: %{}, do: {String.upcase(record.issue_identifier), record.issue_id}

    Map.new(records, fn record ->
      {record.issue_id, Enum.flat_map(record.blockers, &List.wrap(&1.id || Map.get(ids, String.upcase(&1.identifier || ""))))}
    end)
  end

  defp write_linear(action, ticket, blocking, opts) do
    linker = Keyword.get(opts, :linker, SymphonyElixir.Linear.Adapter)

    result =
      case action do
        :add -> linker.add_blocked_by(blocking.issue_id, ticket.issue_id)
        :remove -> linker.remove_blocked_by(blocking.issue_id, ticket.issue_id)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:linear, reason}}
    end
  end

  defp write_record(action, ticket, blocking) do
    blockers =
      case action do
        :add -> ticket.blockers ++ [%{id: blocking.issue_id, identifier: blocking.issue_identifier, state: blocking.phase}]
        :remove -> Enum.reject(ticket.blockers, &link_to?(&1, blocking))
      end

    record = %{ticket | blockers: blockers}

    case RunStore.update_ticket_state(ticket.issue_id, %{blockers: blockers, updated_at: DateTime.utc_now()}) do
      :ok -> :ok = ObservabilityPubSub.broadcast_ticket_record_changed(ticket.repo_key, ticket.issue_id, [:blockers])
      error -> Logger.warning("Failed to write the blockers of issue_id=#{ticket.issue_id}: #{inspect(error)}")
    end

    record
  end

  defp follow_pause(:add, record, _blocking, terminal, opts),
    do: Dependencies.sync_records([record], terminal, active_states: active_states(opts))

  defp follow_pause(:remove, record, blocking, _terminal, _opts) do
    identifier = blocking.issue_identifier

    Pauses.clear_reasons(
      {:ticket, record.repo_key, record.issue_id},
      &(Pauses.ticket_source(&1) == :dependency and same_identifier?(&1.waits_on.identifier, identifier || ""))
    )
  end

  defp record_action(action, record, blocking, opts) do
    move = "#{action}_blocker"

    %{
      event_type: "director_move",
      move: move,
      repo_key: record.repo_key,
      issue_id: record.issue_id,
      issue_identifier: record.issue_identifier,
      blocker: blocking.issue_identifier
    }
    |> AuditLog.record(Keyword.get(opts, :audit_log, []))
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record director_move audit event: issue_id=#{record.issue_id} reason=#{inspect(reason)}")
    end

    payload = %{action: move, blocker: blocking.issue_identifier}
    TicketSignals.record_event(record.repo_key, record.issue_id, "person.action", payload, actor: @director)
  end

  # Each blocker as the app lists it: the record's link, with its title and phase when Symphony
  # tracks it.
  defp links(blockers, records) do
    Enum.map(blockers, fn link ->
      case Enum.find(records, &link_to?(link, &1)) do
        nil -> %{issue_identifier: link.identifier, title: nil, state: link.state}
        record -> ticket_json(record)
      end
    end)
  end

  defp ticket_json(record), do: %{issue_identifier: record.issue_identifier, title: record.title, state: record.phase}

  defp terminal?(phase, terminal) when is_binary(phase), do: MapSet.member?(terminal, normalize(phase))
  defp terminal?(_phase, _terminal), do: false

  defp terminal_states(opts),
    do: opts |> Keyword.get_lazy(:terminal_states, fn -> Config.settings!().tracker.terminal_states end) |> MapSet.new(&normalize/1)

  defp active_states(opts), do: Keyword.get_lazy(opts, :active_states, fn -> StateMachine.active_states(Config.settings!()) end)

  # "TP-9" before "TP-10": the team key, then the number.
  defp identifier_sort_key(identifier) do
    case Regex.run(~r/^(.*?)-(\d+)$/, identifier) do
      [_, team, number] -> {team, String.to_integer(number)}
      _other -> {identifier, 0}
    end
  end

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
