defmodule SymphonyElixir.Connected.Read do
  @moduledoc """
  `connected` on the ticket read (`docs/control-api.md`): where a ticket sits among the others, facts
  15, 16 and 21 of `docs/design/director-ticket-page.md`. It starts from what the orchestrator holds
  of a tracked ticket (`SymphonyElixir.Connected`) or from the ticket's record, and adds:

    * `parent`: the ticket it is part of, from Symphony's own tree of the records
      (`SymphonyElixir.Dispatch.Queue.parents/1`, the tree the queue orders by): as its record names
      it, else as the parent's record lists it among its sub-issues. A ticket filed by a split, one a
      person filed as a sub-issue and one a split adopted are all found there, whether or not a run
      worked on them; what a run's enrichment read from Linear at dispatch decides nothing. Its count
      is the epic's.
    * `epic`: the plan the ticket is part of, its progress and its sub-tickets in chain order, each
      with its situation kind and whether it is this ticket (`current`). The Initiatives' read
      (`SymphonyElixir.Initiatives`) answers when it lists the plan, so the two count the same. A plan
      it does not list (long done, or not split by Symphony) comes from the tree: the parent's
      sub-tickets in creation order, or only the parent's own count when Symphony has no record of
      it.
    * `sub_tickets`: the tickets it is the parent of in the same tree, with the sub-issues its poll
      lists that Symphony holds no record of, in their order inside it: the done ones first, oldest
      first, then the open ones in the stored queue order (`SymphonyElixir.Dispatch.Queue.places/2`),
      each with its situation kind. A sub-ticket that ended without landing (cancelled) is left out,
      as the epic leaves it out.
    * `blocked_by`: every ticket it depends on (its stored dependencies, `depends_on`), each `open`
      while `SymphonyElixir.Dispatch.DependsOn.open/2` finds it unmet, else `resolved` with the time
      the ticket it names reached its phase. A dependency removed leaves the list. Linear's blocker
      links are not read.
    * `blocks`: the tickets whose records depend on this one and are still open on it, each with its
      situation kind. A ticket that ended holds nothing up.

  It reads the ledgers and the records and never Linear, and a read writes nothing.
  """

  alias SymphonyElixir.{Connected, Initiatives, Situation, TicketState}
  alias SymphonyElixir.Dispatch.{DependsOn, Queue}
  alias SymphonyElixir.Home.SubTickets
  alias SymphonyElixir.Initiatives.Initiative

  @done "done"

  @typedoc "What a read needs beside the ticket: every record, the orchestrator's facts and the Initiatives' plans."
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
          sub_tickets: [situated()],
          blocked_by: [blocker()],
          blocks: [situated()],
          related: [Connected.ticket()]
        }

  @doc "The facts of a read, with the plans the Initiatives read over the same `records`."
  @spec facts([map()], Situation.live_facts()) :: facts()
  def facts(records, live), do: facts(records, live, Initiatives.read(records: records))

  @doc "The facts of a read over `initiatives`."
  @spec facts([map()], Situation.live_facts(), [Initiative.t()]) :: facts()
  def facts(records, live, initiatives) do
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
    parents = Queue.parents(facts.records)
    terminal = terminal(facts.live)

    context =
      Map.merge(facts, %{
        by_identifier: Map.new(facts.records, &{&1.issue_identifier, &1}),
        by_id: Map.new(facts.records, &{&1.issue_id, &1}),
        terminal: terminal,
        parents: parents,
        children: SubTickets.index(facts.records, parents),
        places: SubTickets.places(facts.records, parents, terminal)
      })

    connected = Enum.map(tickets, fn {record, tracked} -> shape(TicketState.normalize(record), tracked, context) end)
    kinds = connected |> Enum.flat_map(&situated/1) |> Enum.uniq() |> Map.new(&{&1, kind(&1, context)})

    Enum.map(connected, &with_situations(&1, kinds))
  end

  defp shape(record, tracked, context) do
    base = tracked || Connected.build(record, nil)
    parent = parent(record, context)

    %{
      parent: parent,
      epic: epic(%{record | parent: parent}, context),
      sub_tickets: record |> family(base.sub_tickets, context) |> in_queue_order(context),
      blocked_by: blocked_by(record, context),
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

  ## The tree

  # The parent the tree names for the ticket, with its title and its sub-tickets' count from its
  # record; the ticket's own record of it when Symphony holds no record of the parent.
  defp parent(record, context) do
    case Map.get(context.parents, record.issue_id) do
      nil -> nil
      identifier -> tree_parent(identifier, record.parent, context)
    end
  end

  defp tree_parent(identifier, own, context) do
    case Map.get(context.by_identifier, identifier) do
      nil ->
        own

      parent_record ->
        tickets = family(parent_record, context)

        %{
          identifier: identifier,
          title: parent_record.title || (own && own.title),
          done: Enum.count(tickets, &done?/1),
          total: length(tickets),
          children: Enum.map(tickets, &if(done?(&1), do: "completed"))
        }
    end
  end

  defp family(parent_record, context), do: family(parent_record, Connected.build(parent_record, nil).sub_tickets, context)

  # The sub-tickets of `parent_record`: the records the tree puts under it, and the `links` (the
  # sub-issues its poll lists) Symphony holds no record of. What ended without landing is left out.
  defp family(parent_record, links, context) do
    records =
      for child <- Map.get(context.children, parent_record.issue_identifier, []), is_binary(child.issue_identifier) do
        %{identifier: child.issue_identifier, title: child.title, state: child.phase}
      end

    unrecorded = Enum.reject(links, &Map.has_key?(context.by_identifier, &1.identifier))

    Enum.reject(records ++ unrecorded, &(terminal?(&1.state, context) and not done?(&1)))
  end

  # Their order inside the parent: the done ones, oldest first, then the open ones in the stored
  # queue order, then the open ones Symphony holds no record of, as the poll lists them.
  defp in_queue_order(tickets, context) do
    Enum.sort_by(tickets, fn ticket -> order_key(ticket, Map.get(context.by_identifier, ticket.identifier), context) end)
  end

  defp order_key(ticket, nil, _context), do: if(done?(ticket), do: {0, 0, ""}, else: {3, [], ""})

  defp order_key(ticket, record, context) do
    cond do
      terminal?(record.phase, context) -> {0, unix(record.phase_at), ticket.identifier}
      place = Map.get(context.places, record.issue_id) -> {1, place, ticket.identifier}
      true -> {2, [], ticket.identifier}
    end
  end

  defp done?(ticket), do: normalized(ticket.state) == @done

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp unix(_at), do: 0

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
    case Map.get(context.by_identifier, parent.identifier) do
      nil ->
        parent |> Map.take([:identifier, :title, :done, :total]) |> Map.merge(%{incomplete: false, tickets: []})

      parent_record ->
        tickets = parent_record |> family(context) |> Enum.sort_by(&{created_at(&1.identifier, context), &1.identifier})

        %{
          identifier: parent.identifier,
          title: parent.title,
          done: Enum.count(tickets, &done?/1),
          total: length(tickets),
          incomplete: false,
          tickets: current(tickets, record)
        }
    end
  end

  defp created_at(identifier, context) do
    case Map.get(context.by_identifier, identifier) do
      %{created_at: %DateTime{} = at} -> DateTime.to_iso8601(at)
      _none -> ""
    end
  end

  defp current(tickets, record), do: Enum.map(tickets, &Map.put(&1, :current, &1.identifier == record.issue_identifier))

  ## The blockers

  defp blocked_by(record, context) do
    open = DependsOn.open(record.depends_on, context.by_id)

    record.depends_on
    |> Enum.map(fn dependency -> {dependency, Map.get(context.by_id, dependency.issue_id)} end)
    |> Enum.filter(fn {dependency, on} -> is_binary(dependency.identifier || (on && on.issue_identifier)) end)
    |> Enum.map(fn {dependency, on} -> blocker(dependency, on, dependency in open) end)
    |> Enum.uniq_by(& &1.identifier)
  end

  defp blocker(dependency, on, open?) do
    %{
      identifier: dependency.identifier || on.issue_identifier,
      title: on && on.title,
      state: on && on.phase,
      status: if(open?, do: "open", else: "resolved"),
      resolved_at: if(open? or is_nil(on), do: nil, else: iso8601(on.phase_at))
    }
  end

  ## The tickets it holds up

  defp blocks(record, links, context) do
    open_links = links |> known(context) |> Enum.reject(&terminal?(&1.state, context))

    Enum.uniq_by(open_links ++ holding(record.issue_id, context), & &1.identifier)
  end

  # The open tickets that depend on `issue_id` and whose dependency on it is still open.
  defp holding(nil, _context), do: []

  defp holding(issue_id, context) do
    for other <- context.records,
        is_binary(other.issue_identifier),
        not terminal?(other.phase, context),
        other.depends_on |> DependsOn.open(context.by_id) |> Enum.any?(&(&1.issue_id == issue_id)) do
      %{identifier: other.issue_identifier, title: other.title, state: other.phase}
    end
  end

  ## Situations

  defp situated(%{epic: epic, blocks: blocks, sub_tickets: sub_tickets}), do: Enum.map(blocks ++ sub_tickets ++ epic_tickets(epic), & &1.identifier)

  defp epic_tickets(nil), do: []
  defp epic_tickets(epic), do: epic.tickets

  defp kind(identifier, context) do
    case Map.get(context.by_identifier, identifier) do
      nil -> nil
      record -> Situation.read(record, context.live, context.records).kind
    end
  end

  defp with_situations(connected, kinds) do
    %{
      connected
      | epic: epic_with_situations(connected.epic, kinds),
        blocks: put_situations(connected.blocks, kinds),
        sub_tickets: put_situations(connected.sub_tickets, kinds)
    }
  end

  defp epic_with_situations(nil, _kinds), do: nil
  defp epic_with_situations(epic, kinds), do: %{epic | tickets: put_situations(epic.tickets, kinds)}

  defp put_situations(tickets, kinds), do: Enum.map(tickets, &Map.put(&1, :situation, Map.get(kinds, &1.identifier)))

  ## Small things

  defp terminal(%{terminal_states: states}), do: MapSet.new(states, &normalized/1)

  defp terminal?(state, context), do: MapSet.member?(context.terminal, normalized(state))

  defp normalized(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalized(_value), do: nil

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_at), do: nil
end
