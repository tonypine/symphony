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
  get a `person.action` (`add_blocker` or `remove_blocker`, with the `blocker`) by the Director, the
  audit log a `director_move`, and the orchestrator is asked to poll the ticket's repository, so a
  ticket the change releases is dispatched in its turn.
  """

  require Logger

  alias SymphonyElixir.{AuditLog, Config, Orchestrator, RunStore, TicketMoves, TicketSignals, TicketState}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @director {:person, "the Director"}

  @type action :: :add | :remove
  @type error :: {:invalid, String.t()} | {:conflict, String.t()} | {:store, String.t()}

  @doc """
  Adds (`:add`) or removes (`:remove`) "`blocker` blocks `identifier`", both named by identifier or
  id, as the moduledoc says. Answers the ticket's blockers after the change.

  Options: `:orchestrator` (asked to poll again, default `SymphonyElixir.Orchestrator`),
  `:audit_log` (the audit log's options), `:records` (the tracked records, default every record in
  the run store) and `:terminal_states` (default the settings').
  """
  @spec change(action(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def change(action, identifier, blocker, opts \\ []) when action in [:add, :remove] and is_binary(identifier) and is_binary(blocker) do
    records = records(opts)
    terminal = terminal_states(opts)

    with {:ok, ticket} <- find(records, identifier),
         {:ok, blocking} <- find(records, blocker),
         :ok <- allowed(action, ticket, blocking, terminal),
         :ok <- write(action, ticket, blocking) do
      record = stored(ticket, blocking, action)
      :ok = ObservabilityPubSub.broadcast_ticket_record_changed(record.repo_key, record.issue_id, [:depends_on])
      record_action(action, record, blocking, opts)
      Orchestrator.request_refresh(Keyword.get(opts, :orchestrator, Orchestrator), record.repo_key, due: :now)
      Logger.info("Director #{action}_blocker issue_identifier=#{record.issue_identifier} blocker=#{blocking.issue_identifier}")

      {:ok,
       %{
         action: Atom.to_string(action),
         issue_identifier: record.issue_identifier,
         blocker: blocking.issue_identifier,
         blockers: links(record.depends_on, records)
       }}
    end
  end

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

  defp allowed(_action, %{issue_id: id} = ticket, %{issue_id: id}, _terminal),
    do: {:error, {:conflict, "#{ticket.issue_identifier} can't block itself."}}

  defp allowed(:add, ticket, blocking, terminal) do
    cond do
      blocks?(ticket, blocking) ->
        {:error, {:conflict, "#{blocking.issue_identifier} already blocks #{ticket.issue_identifier}."}}

      terminal?(blocking.phase, terminal) ->
        {:error, {:conflict, "#{blocking.issue_identifier} is #{blocking.phase}: a finished ticket blocks nothing."}}

      true ->
        :ok
    end
  end

  defp allowed(:remove, ticket, blocking, _terminal) do
    if blocks?(ticket, blocking), do: :ok, else: {:error, {:conflict, "#{blocking.issue_identifier} doesn't block #{ticket.issue_identifier}."}}
  end

  defp blocks?(ticket, blocking), do: Enum.any?(ticket.depends_on, &(&1.issue_id == blocking.issue_id))

  defp write(action, ticket, blocking) do
    result =
      case action do
        :add -> RunStore.add_dependency(ticket.issue_id, blocking.issue_id, :done)
        :remove -> RunStore.remove_dependency(ticket.issue_id, blocking.issue_id)
      end

    case result do
      :ok ->
        :ok

      {:error, :dependency_cycle} ->
        {:error, {:conflict, "#{blocking.issue_identifier} already waits on #{ticket.issue_identifier}, so blocking #{ticket.issue_identifier} on it would make a cycle."}}

      {:error, reason} ->
        Logger.warning("Failed to store a blocker issue_id=#{ticket.issue_id} blocker=#{blocking.issue_id} action=#{action}: #{inspect(reason)}")
        verb = if action == :add, do: "add", else: "remove"
        {:error, {:store, "Symphony couldn't #{verb} #{blocking.issue_identifier} as a blocker of #{ticket.issue_identifier}, so nothing changed. Try again in a moment."}}
    end
  end

  # The ticket's record with the change the store made.
  defp stored(ticket, blocking, action) do
    kept = Enum.reject(ticket.depends_on, &(&1.issue_id == blocking.issue_id))
    entry = %{issue_id: blocking.issue_id, identifier: blocking.issue_identifier, kind: :done}
    %{ticket | depends_on: if(action == :add, do: kept ++ [entry], else: kept)}
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

  # Each blocker as the app lists it: the stored dependency, with its title and phase when Symphony
  # tracks the ticket it names.
  defp links(dependencies, records) do
    Enum.map(dependencies, fn dependency ->
      case Enum.find(records, &(&1.issue_id == dependency.issue_id)) do
        nil -> %{issue_identifier: dependency.identifier, title: nil, state: nil}
        record -> ticket_json(record)
      end
    end)
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
