defmodule SymphonyElixir.Reports.Material do
  @moduledoc """
  What a report run reads: the notable events of its period, the Journal's
  (`SymphonyElixir.TicketEvents.Journal`), oldest first, and the situation now of every ticket they
  concern (`SymphonyElixir.Situation`). `prompt/1` renders them as the run's prompt, each event with
  the id a sentence cites it by. It reads Symphony's store only and writes nothing.
  """

  alias SymphonyElixir.{RunStore, Situation, TicketState}
  alias SymphonyElixir.Reports.Period
  alias SymphonyElixir.TicketEvents.Journal

  # The most events one report reads: a period with more is told from its newest ones.
  @max_events 400
  @page 200

  @type event :: %{
          id: String.t(),
          at: DateTime.t(),
          ticket: String.t() | nil,
          title: String.t() | nil,
          type: String.t(),
          summary: String.t(),
          by: String.t()
        }

  @type ticket :: %{identifier: String.t(), title: String.t() | nil, phase: String.t() | nil, situation: String.t()}

  @type t :: %{period: Period.t(), events: [event()], tickets: [ticket()]}

  @doc """
  The material of `period`. `opts`: `live:` (`SymphonyElixir.Situation.live_facts/2`, default none
  running) and `records:` (the ticket records, default the store's).
  """
  @spec read(Period.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def read(%{from: from, to: to} = period, opts \\ []) do
    with {:ok, entries} <- entries(from, to, nil, []) do
      records = Keyword.get_lazy(opts, :records, fn -> RunStore.list_all_ticket_states() |> List.wrap() end) |> Enum.map(&TicketState.normalize/1)
      live = Keyword.get_lazy(opts, :live, fn -> Situation.live_facts(%{}) end)
      events = entries |> Enum.reverse() |> Enum.map(&event/1)
      {:ok, %{period: period, events: events, tickets: tickets(entries, records, live)}}
    end
  end

  # The period's notable entries, newest first, page by page up to `@max_events`.
  defp entries(from, to, until, acc) do
    with {:ok, %{entries: entries, next_until: next}} <- Journal.read(since: from, until: until || to, notable: true, limit: @page) do
      acc = acc ++ entries
      if is_nil(next) or length(acc) >= @max_events, do: {:ok, Enum.take(acc, @max_events)}, else: entries(from, to, next, acc)
    end
  end

  defp event(%{event: event, ticket: ticket, by: by}) do
    %{
      id: event.id,
      at: event.at,
      ticket: ticket.identifier,
      title: ticket.title,
      type: event.type,
      summary: summary(event.summary),
      by: by_name(by)
    }
  end

  defp summary(%{title: title, detail: detail}) when is_binary(detail), do: "#{title}: #{detail}"
  defp summary(%{title: title}), do: title

  defp by_name(%{kind: kind, name: name}) when is_binary(name), do: "#{kind} #{name}"
  defp by_name(%{kind: kind}), do: kind

  # Each ticket the events concern, once, in the order its first event falls, with its situation now.
  defp tickets(entries, records, live) do
    ids = entries |> Enum.reverse() |> Enum.map(& &1.event.issue_id) |> Enum.uniq()
    by_id = Map.new(records, &{&1.issue_id, &1})

    for id <- ids, %{issue_identifier: identifier} = record when is_binary(identifier) <- [Map.get(by_id, id)] do
      situation = Situation.read(record, live, records)
      %{identifier: identifier, title: record.title, phase: record.phase, situation: "#{situation.word} #{situation.cause}"}
    end
  end

  @doc "The identifiers of the tickets the material concerns."
  @spec ticket_identifiers(t()) :: [String.t()]
  def ticket_identifiers(%{tickets: tickets}), do: Enum.map(tickets, & &1.identifier)

  @doc "The ids of the material's events."
  @spec event_ids(t()) :: [String.t()]
  def event_ids(%{events: events}), do: Enum.map(events, & &1.id)

  @doc "The identifiers of the tickets the events `ids` are on, once each, in the material's order."
  @spec tickets_of(t(), [String.t()]) :: [String.t()]
  def tickets_of(%{events: events}, ids) do
    ids = MapSet.new(ids)
    events |> Enum.filter(&(MapSet.member?(ids, &1.id) and is_binary(&1.ticket))) |> Enum.map(& &1.ticket) |> Enum.uniq()
  end

  @doc "The material as the report run's prompt: the period, the events with their ids, and the tickets' situations."
  @spec prompt(t()) :: String.t()
  def prompt(%{period: period, events: events, tickets: tickets}) do
    """
    Period: #{DateTime.to_iso8601(period.from)} to #{DateTime.to_iso8601(period.to)}

    Notable events, oldest first (cite each by its id):
    #{Enum.map_join(events, "\n", &event_line/1)}

    Where each ticket stands now:
    #{if tickets == [], do: "- none", else: Enum.map_join(tickets, "\n", &ticket_line/1)}
    """
  end

  defp event_line(event) do
    ticket = if event.ticket, do: "#{event.ticket} (#{event.title || "untitled"})", else: "Symphony"
    "- [#{event.id}] #{DateTime.to_iso8601(event.at)} #{ticket}, by #{event.by}: #{event.summary}"
  end

  defp ticket_line(ticket), do: "- #{ticket.identifier} (#{ticket.title || "untitled"}), in #{ticket.phase || "an unknown phase"}: #{ticket.situation}"
end
