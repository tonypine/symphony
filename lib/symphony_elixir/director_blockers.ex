defmodule SymphonyElixir.DirectorBlockers do
  @moduledoc """
  The Director's blockers, from a ticket's page in the Mac app (TP-1354): `change/4` adds or
  removes "`blocker` blocks the ticket", and `blockers/2` lists the ticket's blockers and the
  tickets it can be given as one.

  A blocker is a stored dependency of the ticket (`depends_on` on `SymphonyElixir.TicketState`)
  that needs the blocker done (`:done`): `change/4` writes it through the engine
  (`SymphonyElixir.RunStore.add_dependency/3` and `remove_dependency/2`) and writes nothing to
  Linear, and the `:depends_on` dispatch gate (`SymphonyElixir.Dispatch.DependsOn`) holds the
  ticket until the blocker is done, with no pause of its own. A blocker Linear's links name is not
  one of these: it is not listed, and the Director doesn't remove it.

  Both tickets are ones Symphony tracks: each has a record that is not removed, found by identifier
  or id in every configured repository's records. A change is refused, with a reason the app shows
  (`{:error, {:conflict, message}}`), when:

    * either ticket has no record ("Symphony doesn't track TP-9");
    * the blocker is the ticket itself;
    * adding it closes a cycle: the blocker already depends on the ticket, directly or through
      others (the engine's `:dependency_cycle`);
    * the blocker is finished (a terminal phase), so it would block nothing;
    * the dependency is already there (add) or isn't (remove).

  A write the store refuses for another reason is `{:error, {:store, message}}` and changes
  nothing. A change that went through is announced
  (`SymphonyElixirWeb.ObservabilityPubSub.broadcast_ticket_record_changed/3`), the ticket's events
  get a `person.action` (`add_blocker` or `remove_blocker`, with the `blocker`; `add_dependency`
  with its `kind` or `remove_dependency` from `dependency/5`) by the Director, the
  audit log a `director_move`, and the orchestrator is asked to poll the ticket's repository, so a
  ticket the change releases is dispatched in its turn.

  `dependency/5` is the same change with the kind the Director chose (`POST /api/v1/control/dependency`):
  `:done` or `:released`, refused and answered in a dependency's words, and adding a pair already
  stored with the other kind changes its kind. Both add a dependency pointing upward in the queue:
  when the ticket sits above the one it depends on, the store moves it just below in the same
  write, and the move reaches the orchestrator and the queue's stream
  (`SymphonyElixirWeb.ObservabilityPubSub.broadcast_queue_change/2`, `order`) as a move in the queue
  does.
  """

  require Logger

  alias SymphonyElixir.{AuditLog, Config, Orchestrator, RunStore, TicketMoves, TicketSignals, TicketState}
  alias SymphonyElixir.Dispatch.Queue
  alias SymphonyElixirWeb.ObservabilityPubSub

  @director {:person, "the Director"}

  @type action :: :add | :remove
  @type error :: {:invalid, String.t()} | {:conflict, String.t()} | {:store, String.t()}

  @doc """
  Adds (`:add`) or removes (`:remove`) "`blocker` blocks `identifier`", both named by identifier or
  id, as the moduledoc says. Answers the ticket's blockers after the change.

  Options: `:kind` (`:done` or `:released`: the change is the dependency route's, see
  `dependency/5`), `:orchestrator` (asked to poll again and told of a queue move, default
  `SymphonyElixir.Orchestrator`), `:audit_log` (the audit log's options), `:records` (the tracked
  records, default every record in the run store) and `:terminal_states` (default the settings').
  """
  @spec change(action(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def change(action, identifier, blocker, opts \\ []) when action in [:add, :remove] and is_binary(identifier) and is_binary(blocker) do
    records = records(opts)
    terminal = terminal_states(opts)
    kind = Keyword.get(opts, :kind)

    with {:ok, ticket} <- find(records, identifier),
         {:ok, blocking} <- find(records, blocker),
         :ok <- allowed(action, ticket, blocking, terminal, kind),
         move = queue_move(action, records, ticket, blocking),
         :ok <- write(action, ticket, blocking, kind) do
      record = stored(ticket, blocking, action, kind || :done)
      :ok = ObservabilityPubSub.broadcast_ticket_record_changed(record.repo_key, record.issue_id, [:depends_on])
      announce_move(move, records, opts)
      record_action(action, record, blocking, kind, opts)
      Orchestrator.request_refresh(Keyword.get(opts, :orchestrator, Orchestrator), record.repo_key, due: :now)
      Logger.info("Director #{move_name(action, kind)} issue_identifier=#{record.issue_identifier} on=#{blocking.issue_identifier}")

      {:ok, answer(action, record, blocking, kind, records)}
    end
  end

  @doc """
  Adds (`:add`, with `kind` `:done` or `:released`) or removes (`:remove`, `kind` nil) the stored
  dependency of the ticket `identifier` on the ticket `on`: it needs `on` done (merged) or released
  (installed and live). Adding a pair already stored with another kind changes its kind. As
  `change/4` otherwise: the same refusals in a dependency's words, the same announcements, and the
  queue move the add makes (the depending ticket goes just below `on`) announced on the queue's
  stream. Answers the ticket's dependencies after the change, each with its kind.
  """
  @spec dependency(action(), String.t(), String.t(), TicketState.dependency_kind() | nil, keyword()) ::
          {:ok, map()} | {:error, error()}
  def dependency(:add, identifier, on, kind, opts) when kind in [:done, :released], do: change(:add, identifier, on, Keyword.put(opts, :kind, kind))
  def dependency(:remove, identifier, on, _kind, opts), do: change(:remove, identifier, on, Keyword.put(opts, :kind, :any))

  @doc """
  The blockers of the ticket `identifier` (identifier or id): its stored dependencies, each with
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

      blockers = links(ticket.depends_on, records)
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
      nil -> {:error, {:conflict, TicketMoves.untracked_reason(:blocker, name)}}
      record -> {:ok, record}
    end
  end

  defp same_identifier?(identifier, name) when is_binary(identifier), do: String.upcase(identifier) == String.upcase(name)
  defp same_identifier?(_identifier, _name), do: false

  # `kind` nil is the blocker route's change; any other is the dependency route's (`:any` for a remove).
  defp allowed(_action, %{issue_id: id} = ticket, %{issue_id: id}, _terminal, nil),
    do: {:error, {:conflict, "#{ticket.issue_identifier} can't block itself."}}

  defp allowed(_action, %{issue_id: id} = ticket, %{issue_id: id}, _terminal, _kind),
    do: {:error, {:conflict, "#{ticket.issue_identifier} can't depend on itself."}}

  defp allowed(:add, ticket, blocking, terminal, nil) do
    cond do
      blocks?(ticket, blocking) ->
        {:error, {:conflict, "#{blocking.issue_identifier} already blocks #{ticket.issue_identifier}."}}

      terminal?(blocking.phase, terminal) ->
        {:error, {:conflict, "#{blocking.issue_identifier} is #{blocking.phase}: a finished ticket blocks nothing."}}

      true ->
        :ok
    end
  end

  # A ticket done can still wait for its release; any other finished one holds nothing back.
  defp allowed(:add, ticket, blocking, terminal, kind) do
    cond do
      stored_kind(ticket, blocking) == kind ->
        {:error, {:conflict, "#{ticket.issue_identifier} already depends on #{blocking.issue_identifier} being #{kind}."}}

      terminal?(blocking.phase, terminal) and not (kind == :released and normalize(blocking.phase) == "done") ->
        {:error, {:conflict, "#{blocking.issue_identifier} is #{blocking.phase}: a finished ticket holds nothing back."}}

      true ->
        :ok
    end
  end

  defp allowed(:remove, ticket, blocking, _terminal, kind) do
    cond do
      blocks?(ticket, blocking) -> :ok
      is_nil(kind) -> {:error, {:conflict, "#{blocking.issue_identifier} doesn't block #{ticket.issue_identifier}."}}
      true -> {:error, {:conflict, "#{ticket.issue_identifier} doesn't depend on #{blocking.issue_identifier}."}}
    end
  end

  defp stored_kind(ticket, blocking), do: Enum.find_value(ticket.depends_on, &(&1.issue_id == blocking.issue_id and &1.kind))

  defp blocks?(ticket, blocking), do: Enum.any?(ticket.depends_on, &(&1.issue_id == blocking.issue_id))

  defp write(action, ticket, blocking, kind) do
    result =
      case action do
        :add -> RunStore.add_dependency(ticket.issue_id, blocking.issue_id, kind || :done)
        :remove -> RunStore.remove_dependency(ticket.issue_id, blocking.issue_id)
      end

    case result do
      :ok ->
        :ok

      {:error, :dependency_cycle} ->
        {:error, {:conflict, cycle_reason(ticket, blocking, kind)}}

      {:error, reason} ->
        Logger.warning("Failed to store a dependency issue_id=#{ticket.issue_id} on=#{blocking.issue_id} action=#{action}: #{inspect(reason)}")
        {:error, {:store, store_reason(action, ticket, blocking, kind)}}
    end
  end

  defp cycle_reason(ticket, blocking, nil),
    do: "#{blocking.issue_identifier} already waits on #{ticket.issue_identifier}, so blocking #{ticket.issue_identifier} on it would make a cycle."

  defp cycle_reason(ticket, blocking, _kind),
    do: "#{blocking.issue_identifier} already depends on #{ticket.issue_identifier}, so #{ticket.issue_identifier} can't depend on it: that would make a cycle."

  defp store_reason(action, ticket, blocking, nil),
    do: "Symphony couldn't #{verb(action)} #{blocking.issue_identifier} as a blocker of #{ticket.issue_identifier}, so nothing changed. Try again in a moment."

  defp store_reason(action, ticket, blocking, _kind),
    do: "Symphony couldn't #{verb(action)} the dependency of #{ticket.issue_identifier} on #{blocking.issue_identifier}, so nothing changed. Try again in a moment."

  defp verb(:add), do: "add"
  defp verb(:remove), do: "remove"

  # Where the add moves a ticket in the queue (a dependency points upward), read before the write
  # makes it: `{:below, moved, ...}` or `:stay` (`SymphonyElixir.Dispatch.Queue.dependency_move/3`).
  defp queue_move(:add, records, ticket, blocking), do: Queue.dependency_move(records, ticket.issue_id, blocking.issue_id)
  defp queue_move(:remove, _records, _ticket, _blocking), do: :stay

  # The queue move an add made reaches the orchestrator and the queue's stream as a Director's move
  # in the queue does (`SymphonyElixir.DirectorQueue.move/3`).
  defp announce_move({:below, moved, _index, _siblings}, records, opts) do
    Orchestrator.queue_changed(Keyword.get(opts, :orchestrator, Orchestrator))
    identifier = Enum.find_value(records, &(&1.issue_id == moved and &1.issue_identifier))
    ObservabilityPubSub.broadcast_queue_change("order", %{issue_id: moved, issue_identifier: identifier})
  end

  defp announce_move(:stay, _records, _opts), do: :ok

  # The ticket's record with the change the store made: a pair stored again keeps its place.
  defp stored(ticket, blocking, :remove, _kind), do: %{ticket | depends_on: Enum.reject(ticket.depends_on, &(&1.issue_id == blocking.issue_id))}

  defp stored(ticket, blocking, :add, kind) do
    entry = %{issue_id: blocking.issue_id, identifier: blocking.issue_identifier, kind: kind}

    depends_on =
      if blocks?(ticket, blocking),
        do: Enum.map(ticket.depends_on, &if(&1.issue_id == blocking.issue_id, do: entry, else: &1)),
        else: ticket.depends_on ++ [entry]

    %{ticket | depends_on: depends_on}
  end

  defp move_name(action, nil), do: "#{action}_blocker"
  defp move_name(action, _kind), do: "#{action}_dependency"

  defp answer(action, record, blocking, nil, records) do
    %{
      action: Atom.to_string(action),
      issue_identifier: record.issue_identifier,
      blocker: blocking.issue_identifier,
      blockers: links(record.depends_on, records)
    }
  end

  defp answer(action, record, blocking, kind, records) do
    %{
      action: move_name(action, kind),
      issue_identifier: record.issue_identifier,
      on: blocking.issue_identifier,
      kind: if(action == :add, do: Atom.to_string(kind)),
      dependencies: Enum.map(record.depends_on, &Map.put(link(&1, records), :kind, Atom.to_string(&1.kind)))
    }
  end

  defp record_action(action, record, blocking, kind, opts) do
    move = move_name(action, kind)

    fields =
      case kind do
        kind when kind in [nil, :any] -> %{blocker: blocking.issue_identifier}
        kind -> %{blocker: blocking.issue_identifier, kind: Atom.to_string(kind)}
      end

    %{
      event_type: "director_move",
      move: move,
      repo_key: record.repo_key,
      issue_id: record.issue_id,
      issue_identifier: record.issue_identifier
    }
    |> Map.merge(fields)
    |> AuditLog.record(Keyword.get(opts, :audit_log, []))
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record director_move audit event: issue_id=#{record.issue_id} reason=#{inspect(reason)}")
    end

    TicketSignals.record_event(record.repo_key, record.issue_id, "person.action", Map.put(fields, :action, move), actor: @director)
  end

  # Each blocker as the app lists it: the stored dependency, with its title and phase when Symphony
  # tracks the ticket it names.
  defp links(dependencies, records), do: Enum.map(dependencies, &link(&1, records))

  defp link(dependency, records) do
    case Enum.find(records, &(&1.issue_id == dependency.issue_id)) do
      nil -> %{issue_identifier: dependency.identifier, title: nil, state: nil}
      record -> ticket_json(record)
    end
  end

  defp ticket_json(record), do: %{issue_identifier: record.issue_identifier, title: record.title, state: record.phase}

  defp terminal?(phase, terminal) when is_binary(phase), do: MapSet.member?(terminal, normalize(phase))
  defp terminal?(_phase, _terminal), do: false

  defp terminal_states(opts),
    do: opts |> Keyword.get_lazy(:terminal_states, fn -> Config.settings!().tracker.terminal_states end) |> MapSet.new(&normalize/1)

  # "TP-9" before "TP-10": the team key, then the number.
  defp identifier_sort_key(identifier) do
    case Regex.run(~r/^(.*?)-(\d+)$/, identifier) do
      [_, team, number] -> {team, String.to_integer(number)}
      _other -> {identifier, 0}
    end
  end

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
