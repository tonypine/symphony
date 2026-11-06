defmodule SymphonyElixir.DirectorPriority do
  @moduledoc """
  The Director's priority move, from a ticket's page in the Mac app (TP-1355): `set/3` sets a
  tracked ticket's Linear priority, and `priority/2` reads it as the ticket's record holds it.

  A priority is one of Linear's five, by name: `none` (0), `urgent` (1), `high` (2), `medium` (3)
  and `low` (4), or the number. The ticket is one Symphony tracks: it has a record
  (`SymphonyElixir.TicketState`) that is not removed, found by identifier or id in every configured
  repository's records. A move is refused when:

    * the priority is not one of the five (`{:error, {:invalid, message}}`);
    * Symphony doesn't track the ticket, or it already has that priority
      (`{:error, {:conflict, message}}`, the reason the app shows).

  A move writes the tracker first (`SymphonyElixir.Tracker.update_issue_priority/2`, the
  `:tracker`: Linear, or the memory tracker of a QA or local server); a write it refuses is
  `{:error, {:linear, message}}`, the message saying why in the app's words, and changes nothing.
  Then, at once and without waiting for the next read of Linear:

    * the record's `priority` changes and the change is announced
      (`SymphonyElixirWeb.ObservabilityPubSub.broadcast_ticket_record_changed/3`), so the dispatch
      filter (`tickets.priorities`) and the dispatch order (`SymphonyElixir.Dispatch.Candidates`)
      read the new priority;
    * the ticket's events get a `person.action` (`set_priority`, `from` and `to` the priorities'
      names) by the Director, the audit log a `director_move`, and the orchestrator is asked to poll
      the ticket's repository, so a ticket the move lets in is dispatched in its turn.
  """

  require Logger

  alias SymphonyElixir.{AuditLog, Orchestrator, RunStore, TicketMoves, TicketSignals, TicketState}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @director {:person, "the Director"}

  @priorities [{"none", 0, "No priority"}, {"urgent", 1, "Urgent"}, {"high", 2, "High"}, {"medium", 3, "Medium"}, {"low", 4, "Low"}]

  @type error :: {:invalid, String.t()} | {:conflict, String.t()} | {:linear, String.t()}

  @doc "Linear's priority names, in Linear's order of the numbers 0 to 4."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@priorities, &elem(&1, 0))

  @doc """
  Sets the priority of the ticket `identifier` (identifier or id) to `priority` (a name or the
  number, as a string or an integer), as the moduledoc says. Answers the ticket's priority after
  the move.

  Options: `:tracker` (default `SymphonyElixir.Tracker`), `:orchestrator` (asked to poll again,
  default `SymphonyElixir.Orchestrator`), `:audit_log` (the audit log's options), `:records` (the
  tracked records, default every record in the run store).
  """
  @spec set(String.t(), String.t() | integer(), keyword()) :: {:ok, map()} | {:error, error()}
  def set(identifier, priority, opts \\ []) when is_binary(identifier) do
    with {:ok, value} <- parse(priority),
         {:ok, ticket} <- find(records(opts), identifier),
         :ok <- changes(ticket, value),
         :ok <- write_tracker(ticket, value, opts) do
      record = write_record(ticket, value)
      record_action(ticket, value, opts)
      Orchestrator.request_refresh(Keyword.get(opts, :orchestrator, Orchestrator), record.repo_key, due: :now)
      Logger.info("Director set_priority issue_identifier=#{record.issue_identifier} priority=#{name(value)}")

      {:ok, Map.put(json(record), :action, "set_priority")}
    end
  end

  @doc """
  The priority of the ticket `identifier` (identifier or id) as its record holds it, by name and
  number, with Linear's five names to pick from. `{:error, {:conflict, message}}` for a ticket
  Symphony doesn't track. Options as for `set/3`.
  """
  @spec priority(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def priority(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, ticket} <- find(records(opts), identifier), do: {:ok, json(ticket)}
  end

  defp parse(priority) when is_integer(priority) and priority in 0..4, do: {:ok, priority}

  defp parse(priority) when is_binary(priority) do
    trimmed = priority |> String.trim() |> String.downcase()

    case Enum.find(@priorities, fn {name, value, _title} -> trimmed in [name, Integer.to_string(value)] end) do
      {_name, value, _title} -> {:ok, value}
      nil -> invalid(priority)
    end
  end

  defp parse(priority), do: invalid(priority)

  defp invalid(priority),
    do: {:error, {:invalid, "#{inspect(priority)} is not a Linear priority: use one of #{Enum.join(names(), ", ")}."}}

  defp records(opts) do
    opts
    |> Keyword.get_lazy(:records, fn -> List.wrap(with({:error, _reason} <- RunStore.list_all_ticket_states(), do: [])) end)
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.filter(&(is_binary(&1.issue_id) and is_binary(&1.repo_key) and is_nil(&1.removed_at)))
  end

  defp find(records, name) do
    name = String.trim(name)

    case Enum.find(records, &(&1.issue_id == name or same_identifier?(&1.issue_identifier, name))) do
      nil -> {:error, {:conflict, TicketMoves.untracked_reason(:priority, name)}}
      record -> {:ok, record}
    end
  end

  defp same_identifier?(identifier, name) when is_binary(identifier), do: String.upcase(identifier) == String.upcase(name)
  defp same_identifier?(_identifier, _name), do: false

  defp changes(%{priority: value} = ticket, value), do: {:error, {:conflict, "#{ticket.issue_identifier} is already #{title(value)}."}}
  defp changes(_ticket, _value), do: :ok

  defp write_tracker(ticket, value, opts) do
    case Keyword.get(opts, :tracker, SymphonyElixir.Tracker).update_issue_priority(ticket.issue_id, value) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write a priority issue_id=#{ticket.issue_id} priority=#{name(value)}: #{inspect(reason)}")
        {:error, {:linear, write_failure(ticket, value, reason)}}
    end
  end

  # The reason a write failed, in the words the app shows; the raw reason goes to the log.
  defp write_failure(ticket, value, reason) do
    move = "set #{ticket.issue_identifier} to #{title(value)}"

    if missing_key?(reason),
      do: "Symphony has no Linear API key, so it couldn't #{move} in Linear.",
      else: "Linear didn't #{move}, so nothing changed. Try again in a moment."
  end

  defp missing_key?(:missing_linear_api_token), do: true
  defp missing_key?({_kind, :missing_linear_api_token}), do: true
  defp missing_key?(_reason), do: false

  defp write_record(ticket, value) do
    case RunStore.update_ticket_state(ticket.issue_id, %{priority: value, updated_at: DateTime.utc_now()}) do
      :ok -> :ok = ObservabilityPubSub.broadcast_ticket_record_changed(ticket.repo_key, ticket.issue_id, [:priority])
      error -> Logger.warning("Failed to write the priority of issue_id=#{ticket.issue_id}: #{inspect(error)}")
    end

    %{ticket | priority: value}
  end

  defp record_action(ticket, value, opts) do
    %{
      event_type: "director_move",
      move: "set_priority",
      repo_key: ticket.repo_key,
      issue_id: ticket.issue_id,
      issue_identifier: ticket.issue_identifier,
      priority: title(value),
      from_priority: title(ticket.priority)
    }
    |> AuditLog.record(Keyword.get(opts, :audit_log, []))
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to record director_move audit event: issue_id=#{ticket.issue_id} reason=#{inspect(reason)}")
    end

    payload = %{action: "set_priority", from: title(ticket.priority), to: title(value)}
    TicketSignals.record_event(ticket.repo_key, ticket.issue_id, "person.action", payload, actor: @director)
  end

  defp json(record) do
    %{
      issue_identifier: record.issue_identifier,
      priority: name(record.priority),
      priority_value: record.priority,
      priorities: names()
    }
  end

  # A priority Linear never sent (an old record) reads as none, as Linear's 0.
  defp name(value), do: @priorities |> Enum.find(&(elem(&1, 1) == value)) |> Kernel.||(hd(@priorities)) |> elem(0)
  defp title(value), do: @priorities |> Enum.find(&(elem(&1, 1) == value)) |> Kernel.||(hd(@priorities)) |> elem(2)
end
