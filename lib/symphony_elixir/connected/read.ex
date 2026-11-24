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
      Symphony has no record of it. The parent is the one `parent` reads.
    * `blocked_by`: every ticket it depends on (its stored dependencies, `depends_on`), each `open`
      while `SymphonyElixir.Dispatch.DependsOn.open/2` finds it unmet, else `resolved` with the time
      the ticket it names reached its phase. A dependency removed leaves the list. Linear's blocker
      links are not read.
    * `blocks`: the tickets whose records depend on this one and are still open on it, each with its
      situation kind. A ticket that ended holds nothing up.

  It reads the ledgers and the records and never Linear, and a read writes nothing.
  """

  alias SymphonyElixir.{Connected, Initiatives, Situation, TicketState}
  alias SymphonyElixir.Dispatch.DependsOn
  alias SymphonyElixir.Initiatives.Initiative

  @done "done"

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
    context =
      Map.merge(facts, %{
        by_identifier: Map.new(facts.records, &{&1.issue_identifier, &1}),
        by_id: Map.new(facts.records, &{&1.issue_id, &1}),
        terminal: terminal(facts.live)
      })

    connected = Enum.map(tickets, fn {record, tracked} -> shape(TicketState.normalize(record), tracked, context) end)
    kinds = connected |> Enum.flat_map(&situated/1) |> Enum.uniq() |> Map.new(&{&1, kind(&1, context)})

    Enum.map(connected, &with_situations(&1, kinds))
  end

  defp shape(record, tracked, context) do
    own = Connected.build(record, nil)
    base = tracked || own
    parent = base.parent || record.parent

    %{
      parent: parent,
      epic: epic(%{record | parent: parent}, context),
      sub_tickets: known(base.sub_tickets, context),
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

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_at), do: nil
end
