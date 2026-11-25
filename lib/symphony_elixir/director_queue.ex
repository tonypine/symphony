defmodule SymphonyElixir.DirectorQueue do
  @moduledoc """
  The Director's controls of the dispatch queue (`SymphonyElixir.Dispatch.Queue`): `move/3` puts a
  ticket at another place in the stored order, and `set_slots/2` sets how many tickets hold a slot
  at once.

  A move stays inside the ticket's scope (the top level, or its parent's sub-tickets), as
  `SymphonyElixir.RunStore.move_in_queue/2` keeps it: to the `:top`, to the `:end`, or
  `{:after, ticket}` / `{:before, ticket}` next to another ticket of the same scope, named by
  identifier or id. An epic's sub-tickets still to come move the same way while the epic holds a
  slot and one of them is in work: each keeps its place in the epic's scope. It is refused when:

    * Symphony doesn't track the ticket or the neighbour (`{:error, {:invalid, message}}`);
    * the ticket holds no place in the queue (done, removed), the neighbour is the ticket itself or
      sits in another scope, the queue changed under the move, or the new order would put a ticket
      above one it depends on ("TP-978 depends on TP-977 and must stay below it.", compared where
      their scopes meet, decided under the store's queue lock; nothing moves)
      (`{:error, {:conflict, message}}`);
    * the store refuses the write (`{:error, {:store, message}}`).

  The slot count is a whole number from 1 to 6 (`{:error, {:invalid, message}}` otherwise, and the
  file is left as it is). It is written to `execution.concurrency.max_total` in `symphony.yml`
  (`execution.max_concurrent_agents`) by editing that one line, as the Settings page does
  (`SymphonyElixir.Config.LineEditor`); a file the editor can't change is
  `{:error, {:config, message}}`.

  After either write, at once and in the same call: the orchestrator walks its candidates again and
  publishes the reads (`SymphonyElixir.Orchestrator.queue_changed/1`, `slots_changed/1`), so a read
  made after the answer shows the change and a free slot is filled without waiting for a poll, and
  the open streams get a queue notice
  (`SymphonyElixirWeb.ObservabilityPubSub.broadcast_queue_change/2`). A lowered slot count stops no
  run: the tickets in progress keep their slots until they are done.
  """

  require Logger

  alias SymphonyElixir.Config.{Cache, LineEditor}
  alias SymphonyElixir.Dispatch.Queue
  alias SymphonyElixir.{Orchestrator, RunStore, TicketState, Workflow}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @slot_path ["execution", "concurrency", "max_total"]
  @slot_range 1..6

  @type target :: :top | :end | {:after, String.t()} | {:before, String.t()}
  @type error :: {:invalid, String.t()} | {:conflict, String.t()} | {:store, String.t()} | {:config, String.t()}

  @doc "The slot counts `set_slots/2` accepts."
  @spec slot_range() :: Range.t()
  def slot_range, do: @slot_range

  @doc """
  Moves the ticket `identifier` (identifier or id) to `target` in its scope, as the moduledoc says.
  Answers the ticket, its scope (`scope`: its parent's identifier, nil at the top level) and the
  scope's tickets in their new order (`order`, identifiers).

  Options: `:orchestrator` (told of the move, default `SymphonyElixir.Orchestrator`), `:store` (the
  module whose `move_in_queue/2` writes it, default `SymphonyElixir.RunStore`).
  """
  @spec move(String.t(), target(), keyword()) :: {:ok, map()} | {:error, error()}
  def move(identifier, target, opts) when is_binary(identifier) do
    records = records()

    with {:ok, ticket} <- find(records, identifier, "it can't move it in the queue"),
         :ok <- queued(ticket),
         siblings = siblings(records, ticket),
         {:ok, index, to} <- spot(records, siblings, ticket, target),
         :ok <- write_move(Keyword.get(opts, :store, RunStore), records, ticket, to) do
      Orchestrator.queue_changed(Keyword.get(opts, :orchestrator, Orchestrator))
      notice = %{issue_id: ticket.issue_id, issue_identifier: ticket.issue_identifier}
      ObservabilityPubSub.broadcast_queue_change("order", notice)
      Logger.info("Director move_in_queue issue_identifier=#{ticket.issue_identifier} to=#{inspect(target)}")
      order = siblings |> Enum.map(& &1.issue_identifier) |> List.insert_at(index, ticket.issue_identifier)

      {:ok,
       %{
         action: "move_in_queue",
         issue_id: ticket.issue_id,
         issue_identifier: ticket.issue_identifier,
         scope: Queue.scope(ticket),
         order: order
       }}
    end
  end

  @doc """
  Sets the slot count to `count` (an integer, or its digits as a string), as the moduledoc says.
  Answers the new `count` and the slots as the reads now show them (`slots`, nil when no
  orchestrator runs).

  Options: `:orchestrator` (told of the new count, default `SymphonyElixir.Orchestrator`), `:file`
  (the `symphony.yml` to write, default `SymphonyElixir.Workflow.symphony_file_path/0`).
  """
  @spec set_slots(integer() | String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def set_slots(count, opts) do
    file = Keyword.get_lazy(opts, :file, &Workflow.symphony_file_path/0)

    with {:ok, count} <- slot_count(count),
         :ok <- write_slots(file, count) do
      slots =
        case Orchestrator.slots_changed(Keyword.get(opts, :orchestrator, Orchestrator)) do
          {:ok, slots} -> slots
          :unavailable -> nil
        end

      ObservabilityPubSub.broadcast_queue_change("slots", %{count: count})
      Logger.info("Director set_slots count=#{count}")
      {:ok, %{action: "set_slots", count: count, slots: slots}}
    end
  end

  defp slot_count(count) when is_integer(count) and count in @slot_range, do: {:ok, count}

  defp slot_count(count) when is_binary(count) do
    case Integer.parse(String.trim(count)) do
      {value, ""} -> slot_count(value)
      _other -> invalid_count(count)
    end
  end

  defp slot_count(count), do: invalid_count(count)

  defp invalid_count(count),
    do: {:error, {:invalid, "#{inspect(count)} is not a slot count: use a whole number from #{@slot_range.first} to #{@slot_range.last}."}}

  defp write_slots(file, count) do
    case LineEditor.write(file, [{@slot_path, Integer.to_string(count)}]) do
      # A same-second edit of the same length keeps the file's stamp, so the cache is told.
      :ok ->
        :ok = Cache.invalidate(file)

      {:error, reason} ->
        {:error, {:config, "Symphony couldn't change #{Enum.join(@slot_path, ".")} in symphony.yml (#{format_reason(reason)}); edit it by hand."}}
    end
  end

  defp format_reason({:not_a_block, key}), do: "#{key}: is not an indented block"
  defp format_reason(reason), do: inspect(reason)

  defp records do
    records = List.wrap(with({:error, _reason} <- RunStore.list_all_ticket_states(), do: []))

    records
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.filter(&(is_binary(&1.issue_id) and is_nil(&1.removed_at)))
  end

  defp find(records, name, so) do
    name = String.trim(name)

    case Enum.find(records, &(&1.issue_id == name or same_identifier?(&1.issue_identifier, name))) do
      nil -> {:error, {:invalid, "Symphony doesn't track #{name}, so #{so}."}}
      record -> {:ok, record}
    end
  end

  defp same_identifier?(identifier, name), do: is_binary(identifier) and String.upcase(identifier) == String.upcase(name)

  defp queued(%{sort_key: key}) when is_binary(key), do: :ok
  defp queued(ticket), do: {:error, {:conflict, "#{label(ticket)} holds no place in the queue."}}

  # The other queued tickets of the ticket's scope, in their stored order.
  defp siblings(records, ticket) do
    scope = Queue.scope(ticket)

    records
    |> Enum.filter(&(is_binary(&1.sort_key) and &1.issue_id != ticket.issue_id and Queue.scope(&1) == scope))
    |> Enum.sort_by(& &1.sort_key)
  end

  # Where the ticket goes among `siblings`: its index there and the move `RunStore.move_in_queue/2` takes.
  defp spot(_records, _siblings, _ticket, :top), do: {:ok, 0, :top}
  defp spot(_records, siblings, _ticket, :end), do: {:ok, length(siblings), :end}

  defp spot(records, siblings, ticket, {side, name}) when side in [:after, :before] do
    with {:ok, neighbour} <- find(records, name, "it can't move a ticket next to it"),
         {:ok, at} <- sibling_index(siblings, ticket, neighbour) do
      index = if side == :after, do: at + 1, else: at
      {:ok, index, {:between, id_at(siblings, index - 1), id_at(siblings, index)}}
    end
  end

  defp sibling_index(siblings, ticket, neighbour) do
    cond do
      neighbour.issue_id == ticket.issue_id ->
        {:error, {:conflict, "#{label(ticket)} can't be moved next to itself."}}

      index = Enum.find_index(siblings, &(&1.issue_id == neighbour.issue_id)) ->
        {:ok, index}

      true ->
        {:error, {:conflict, "#{label(neighbour)} is not queued in the same list as #{label(ticket)}; a ticket moves only among #{scope_name(ticket)}."}}
    end
  end

  defp scope_name(ticket) do
    case Queue.scope(ticket) do
      nil -> "the top-level tickets"
      parent -> "the sub-tickets of #{parent}"
    end
  end

  defp id_at(_siblings, index) when index < 0, do: nil
  defp id_at(siblings, index), do: siblings |> Enum.at(index) |> then(&(&1 && &1.issue_id))

  defp write_move(store, records, ticket, to) do
    case store.move_in_queue(ticket.issue_id, to) do
      :ok -> :ok
      {:error, {:dependency_order, dependent, on}} -> {:error, {:conflict, below_reason(records, dependent, on)}}
      {:error, :not_in_queue} -> queued(%{ticket | sort_key: nil})
      {:error, :not_neighbours} -> {:error, {:conflict, "The queue changed while #{label(ticket)} was being moved; try again."}}
      {:error, reason} -> {:error, {:store, "Symphony couldn't store the move: #{inspect(reason)}"}}
    end
  end

  # The refusal of a move that would put the ticket `dependent` above the ticket `on` it depends on.
  defp below_reason(records, dependent, on), do: "#{name_of(records, dependent)} depends on #{name_of(records, on)} and must stay below it."

  defp name_of(records, id) do
    case Enum.find(records, &(&1.issue_id == id)) do
      nil -> id
      record -> label(record)
    end
  end

  defp label(ticket), do: ticket.issue_identifier || ticket.issue_id
end
