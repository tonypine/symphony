defmodule SymphonyElixir.Connected.Read do
  @moduledoc """
  `connected` on the ticket read (`docs/control-api.md`): where a ticket sits among the others, facts
  15, 16 and 21 of `docs/design/director-ticket-page.md`. It starts from what the orchestrator holds
  of a tracked ticket (`SymphonyElixir.Connected`) or from the ticket's record, and adds:

    * `epic`: the plan the ticket is part of, its progress and its sub-tickets in chain order, each
      with its situation kind and whether it is this ticket (`current`). The Initiatives' cached read
      (`SymphonyElixir.Initiatives`) answers when it holds the plan, so the two count the same. A plan
      it does not hold (long done, not labelled a plan, or before its first read after a start) comes
      from the parent's record: its sub-issues in creation order, or only the parent's own count when
      Symphony has no record of it.
    * `blocked_by`: every blocker ever linked, each `open` or `resolved` with the time it resolved. The
      record's `blockers` keep only the open ones, for dispatch; the history comes from the ledger,
      from the pause events of the dependency reasons. A cleared reason whose blocker is still open
      and no longer linked was unlinked, not resolved, and leaves the list. A reason still set reads
      `open` even once its blocker landed: the ticket is still held, waiting for an app update.
    * `blocks`: the links the run read, and the tickets whose records name this one as an open
      blocker, each with its situation kind.

  It reads the ledgers and the records and never Linear, and a read writes nothing.
  """

  alias SymphonyElixir.{Connected, Initiatives, Pauses, Situation, TicketEvents, TicketState}
  alias SymphonyElixir.Initiatives.Initiative
  alias SymphonyElixir.TicketEvents.Event

  @done "done"
  @set_events ["pause.set", "pause.reason_added"]

  @typedoc "What a read needs beside the ticket: every record, the orchestrator's facts and the cached plans."
  @type facts :: %{records: [TicketState.t()], live: Situation.live_facts(), initiatives: [Initiative.t()]}

  @type blocker :: %{
          identifier: String.t(),
          title: String.t() | nil,
          state: String.t() | nil,
          status: String.t(),
          resolved_at: String.t() | nil
        }

  @type situated :: %{identifier: String.t(), title: String.t() | nil, state: String.t() | nil, situation: Situation.kind() | nil}

  @type epic :: %{
          identifier: String.t() | nil,
          title: String.t() | nil,
          done: non_neg_integer(),
          total: non_neg_integer(),
          incomplete: boolean(),
          tickets: [map()]
        }

  @type t :: %{
          parent: Connected.parent() | nil,
          epic: epic() | nil,
          sub_tickets: [Connected.ticket()],
          blocked_by: [blocker()],
          blocks: [situated()],
          related: [Connected.ticket()]
        }

  @doc "The facts of a read, the cached plans by default."
  @spec facts([map()], Situation.live_facts(), [Initiative.t()]) :: facts()
  def facts(records, live, initiatives \\ Initiatives.cached()) do
    %{records: Enum.map(records, &TicketState.normalize/1), live: live, initiatives: initiatives}
  end

  @doc """
  The `connected` of one ticket: its `record` (a map with at least its `issue_id` and
  `issue_identifier` when it has none) and what the orchestrator holds of it (`tracked`, nil when it
  holds nothing).
  """
  @spec read(map(), Connected.t() | nil, facts()) :: t()
  def read(record, tracked, facts), do: [{record, tracked}] |> read_all(facts) |> hd()

  @doc """
  The `connected` of each `{record, tracked}`, in order, as `read/3` gives one. A ticket several of
  them name has its situation read once.
  """
  @spec read_all([{map(), Connected.t() | nil}], facts()) :: [t()]
  def read_all(tickets, facts) do
    context = Map.merge(facts, %{by_identifier: Map.new(facts.records, &{&1.issue_identifier, &1}), terminal: terminal(facts.live)})
    connected = Enum.map(tickets, fn {record, tracked} -> shape(TicketState.normalize(record), tracked, context) end)
    kinds = connected |> Enum.flat_map(&situated/1) |> Enum.uniq() |> Map.new(&{&1, kind(&1, context)})

    Enum.map(connected, &with_situations(&1, kinds))
  end

  defp shape(record, tracked, context) do
    own = Connected.build(record, nil)
    base = tracked || own

    %{
      parent: base.parent || record.parent,
      epic: epic(record, context),
      sub_tickets: known(base.sub_tickets, context),
      blocked_by: blocked_by(record, base.blocked_by ++ own.blocked_by, context),
      blocks: blocks(record, base.blocks, context),
      related: known(base.related, context)
    }
  end

  # The title and the phase of a ticket Symphony has a record of: its record is newer than the link.
  defp known(tickets, context) do
    Enum.map(tickets, fn ticket ->
      case Map.get(context.by_identifier, ticket.identifier) do
        nil -> ticket
        record -> %{ticket | title: record.title || ticket.title, state: record.phase || ticket.state}
      end
    end)
  end

  ## The epic

  defp epic(record, context) do
    case Enum.find(context.initiatives, fn initiative -> Enum.any?(initiative.sub_tickets, &(&1.id == record.issue_id)) end) do
      nil -> recorded_epic(record, context)
      initiative -> initiative_epic(initiative, record)
    end
  end

  defp initiative_epic(initiative, record) do
    tickets = Enum.map(initiative.sub_tickets, &Map.take(&1, [:identifier, :title, :state]))

    %{
      identifier: initiative.identifier,
      title: initiative.title,
      done: Enum.count(initiative.sub_tickets, &(&1.state_type == "completed")),
      total: length(tickets),
      incomplete: initiative.incomplete,
      tickets: current(tickets, record)
    }
  end

  defp recorded_epic(%{parent: nil}, _context), do: nil

  defp recorded_epic(%{parent: parent} = record, context) do
    case sub_issues(parent, context) do
      [] ->
        parent |> Map.take([:identifier, :title, :done, :total]) |> Map.merge(%{incomplete: false, tickets: []})

      links ->
        tickets = chain(links, context)

        %{
          identifier: parent.identifier,
          title: parent.title,
          done: Enum.count(tickets, &(normalized(&1.state) == @done)),
          total: length(tickets),
          incomplete: false,
          tickets: current(tickets, record)
        }
    end
  end

  defp sub_issues(parent, context) do
    case Map.get(context.by_identifier, parent.identifier) do
      nil -> []
      parent_record -> Connected.build(parent_record, nil).sub_tickets
    end
  end

  # In creation order, with what ended without landing left out, as the Initiatives leave canceled
  # sub-tickets out.
  defp chain(links, context) do
    links
    |> known(context)
    |> Enum.reject(&(terminal?(&1.state, context) and normalized(&1.state) != @done))
    |> Enum.sort_by(&{created_at(&1.identifier, context), &1.identifier})
  end

  defp created_at(identifier, context) do
    case Map.get(context.by_identifier, identifier) do
      %{created_at: %DateTime{} = at} -> DateTime.to_iso8601(at)
      _none -> ""
    end
  end

  defp current(tickets, record), do: Enum.map(tickets, &Map.put(&1, :current, &1.identifier == record.issue_identifier))

  ## The blockers

  defp blocked_by(record, links, context) do
    history = record.issue_id |> ledger() |> Enum.reduce([], &history/2)
    links = links |> known(context) |> Enum.uniq_by(& &1.identifier)

    (Enum.map(history, &elem(&1, 0)) ++ Enum.map(links, & &1.identifier))
    |> Enum.uniq()
    |> Enum.flat_map(fn identifier ->
      link = Enum.find(links, &(&1.identifier == identifier))
      ticket = link || hd(known([%{identifier: identifier, title: nil, state: nil}], context))
      blocker(ticket, link != nil, last_word(history, identifier), context)
    end)
  end

  defp last_word(history, identifier) do
    case List.keyfind(history, identifier, 0) do
      {^identifier, last} -> last
      nil -> nil
    end
  end

  defp blocker(ticket, linked?, last, context) do
    ended? = terminal?(ticket.state, context)

    cond do
      last == :held or (linked? and not ended?) -> [Map.merge(ticket, %{status: "open", resolved_at: nil})]
      not linked? and is_binary(ticket.state) and not ended? -> []
      true -> [Map.merge(ticket, %{status: "resolved", resolved_at: iso8601(last)})]
    end
  end

  defp ledger(issue_id) do
    events = TicketEvents.query(issue_id, limit: :all)
    if is_list(events), do: events, else: []
  end

  # Each dependency reason's last word, in the order the blockers were first linked: `:held` while it
  # is set, the time it cleared once it is not.
  defp history(%Event{type: type, payload: payload}, history) when type in @set_events, do: note([payload], :held, history)
  defp history(%Event{type: "pause.reason_cleared", payload: payload, at: at}, history), do: note([payload], at, history)
  defp history(%Event{type: "pause.cleared", payload: payload, at: at}, history), do: note(List.wrap(field(payload, :cleared)), at, history)
  defp history(_event, history), do: history

  defp note(reasons, last, history) do
    Enum.reduce(reasons, history, fn reason, history ->
      case dependency(reason) do
        nil -> history
        identifier -> List.keystore(history, identifier, 0, {identifier, last})
      end
    end)
  end

  defp dependency(reason) do
    identifier = field(field(reason, :waits_on) || %{}, :identifier)
    source = Pauses.ticket_source(%{kind: :ticket, waits_on: %{identifier: identifier}, text: field(reason, :text)})

    if source == :dependency, do: identifier
  end

  ## The tickets it holds up

  defp blocks(record, links, context) do
    (known(links, context) ++ holding(record.issue_identifier, context)) |> Enum.uniq_by(& &1.identifier)
  end

  defp holding(nil, _context), do: []

  defp holding(identifier, context) do
    for other <- context.records,
        is_binary(other.issue_identifier),
        not terminal?(other.phase, context),
        Enum.any?(other.blockers, &(&1.identifier == identifier and not terminal?(&1.state, context))) do
      %{identifier: other.issue_identifier, title: other.title, state: other.phase}
    end
  end

  ## Situations

  defp situated(%{epic: epic, blocks: blocks}), do: Enum.map(blocks ++ epic_tickets(epic), & &1.identifier)

  defp epic_tickets(nil), do: []
  defp epic_tickets(epic), do: epic.tickets

  defp kind(identifier, context) do
    case Map.get(context.by_identifier, identifier) do
      nil -> nil
      record -> Situation.read(record, context.live, context.records).kind
    end
  end

  defp with_situations(connected, kinds) do
    %{connected | epic: epic_with_situations(connected.epic, kinds), blocks: put_situations(connected.blocks, kinds)}
  end

  defp epic_with_situations(nil, _kinds), do: nil
  defp epic_with_situations(epic, kinds), do: %{epic | tickets: put_situations(epic.tickets, kinds)}

  defp put_situations(tickets, kinds), do: Enum.map(tickets, &Map.put(&1, :situation, Map.get(kinds, &1.identifier)))

  ## Small things

  defp terminal(%{terminal_states: states}), do: MapSet.new(states, &normalized/1)

  defp terminal?(state, context), do: MapSet.member?(context.terminal, normalized(state))

  defp normalized(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalized(_value), do: nil

  # A payload the store read back holds string keys under its first level.
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_at), do: nil
end
