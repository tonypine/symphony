defmodule SymphonyElixir.Home do
  @moduledoc """
  The Director's Home read (`GET /api/v1/home`, `docs/design/director-window-and-home.md`, section
  Home): the two lists the page draws, already shaped, from the ticket records, their ledgers
  (`SymphonyElixir.Situation`) and what the orchestrator walked at its last poll cycle
  (`SymphonyElixir.Dispatch.Order`). It makes no Linear request and decides nothing the app redraws.

  - `in_progress`: every ticket that has started and has not landed or been cancelled (its phase past
    Todo and not terminal, or a run working on it), each with its situation. A ticket of an epic sits
    under its epic's node, which counts the epic's tickets by state; tickets with no epic are entries
    of their own. An epic is a node only while one of its tickets is in progress.
  - `queue`: every ticket Symphony would dispatch that has not started (in Todo, walked by the
    dispatch pass, at a dispatched priority), as the tree of what waits on what. A ticket
    blocked by queued tickets sits under the one that lands last (the deepest, then the latest in the
    dispatch order) and names its other open blockers in `also_waits_on`. A root waits on nothing in
    the queue: when it waits on a ticket in progress it names the one that lands last in `after`, else
    it carries its situation. Ready roots come in the dispatcher's order (the stored queue order,
    `SymphonyElixir.Dispatch.Queue`), then the roots that wait,
    in the order of the ticket they wait on.
  - `outside`: how many open tickets neither list holds, by reason: `backlog`, `below_priority`,
    `epic` (an epic with no ticket in progress) and `behind` (a queued ticket whose blocker is one of
    those, or behind one).
  """

  alias SymphonyElixir.{Situation, TicketState}

  @not_started ["backlog", "todo", "triage"]
  @needs_fix ["rework", "ci fix"]
  @cancelled ["canceled", "cancelled", "duplicate"]
  @count_keys [:done, :in_progress, :needs_person, :needs_fix, :not_started]
  @last 1_000_000_000

  @typedoc "What the orchestrator walked at its last poll cycle (`SymphonyElixir.Dispatch.Order.t/0`), nil before the first."
  @type order :: %{required(:entries) => [map()], optional(atom()) => term()} | nil

  @doc """
  The read over `order`, the ticket `records` and the orchestrator's `live` facts
  (`Situation.live_facts/2`). `opts`:

  - `:priority_filter`: the Linear priorities `tickets.priorities` dispatches (`Config.ticket_priority_filter/0`),
    nil when every priority is; default nil.
  - `:moves`: a function from a record to its `moves` (`SymphonyElixir.TicketMoves.read/1`), for the
    move of a ticket that waits on a person; without it no entry carries one.
  """
  @spec read(order(), [map()], Situation.live_facts(), keyword()) :: map()
  def read(order, records, live, opts \\ []) when is_list(records) do
    records = records |> Enum.map(&TicketState.normalize/1) |> Enum.filter(&ticket?/1)
    entries = if order, do: Map.get(order, :entries, []), else: []

    ctx = %{
      records: records,
      by_id: Map.new(records, &{&1.issue_id, &1}),
      by_identifier: Map.new(records, &{&1.issue_identifier, &1}),
      walk: entries |> Enum.with_index() |> Map.new(fn {entry, index} -> {entry.issue_id, {index, entry}} end),
      live: live,
      terminal: MapSet.new(live.terminal_states, &normalize/1),
      priority_filter: Keyword.get(opts, :priority_filter),
      moves: Keyword.get(opts, :moves),
      children: children(records)
    }

    started = Enum.filter(records, &started?(&1, ctx))
    ticket_entries = Enum.reject(started, &epic?(&1, ctx))
    situations = Map.new(ticket_entries, &{&1.issue_id, &1 |> Situation.read(live, records) |> Situation.payload()})
    in_progress = in_progress(ticket_entries, situations, ctx)
    node_ids = in_progress |> Enum.filter(&(&1.kind == "epic")) |> MapSet.new(& &1.issue_id)
    in_progress_ids = MapSet.union(MapSet.new(ticket_entries, & &1.issue_id), node_ids)

    {queued, outside} = classify(records, in_progress_ids, ctx)
    {queued, behind} = behind(queued, in_progress_ids, ctx)

    %{
      in_progress: in_progress,
      queue: %{roots: queue(queued, in_progress_ids, ctx)},
      outside: Map.put(outside, :behind, length(behind))
    }
  end

  defp ticket?(record), do: is_binary(record.issue_identifier) and is_nil(record.removed_at) and is_nil(record.not_found_at)

  # -- In progress -----------------------------------------------------------------------------

  defp started?(record, ctx) do
    phase = normalize(record.phase)

    is_binary(record.phase) and not MapSet.member?(ctx.terminal, phase) and
      (phase not in @not_started or Map.has_key?(ctx.live.running, record.issue_id))
  end

  defp in_progress(tickets, situations, ctx) do
    {in_epics, alone} = Enum.split_with(tickets, &epic_of(&1, ctx))

    nodes =
      in_epics
      |> Enum.group_by(&epic_of(&1, ctx))
      |> Enum.map(fn {epic, kids} -> epic_node(epic, sort_by_order(kids, ctx), situations, ctx) end)

    (nodes ++ Enum.map(alone, &{order_key(&1, ctx), entry(&1, situations, ctx)}))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp entry(record, situations, ctx) do
    situation = Map.fetch!(situations, record.issue_id)

    %{
      kind: "ticket",
      issue_id: record.issue_id,
      identifier: record.issue_identifier,
      title: record.title,
      repo_key: record.repo_key,
      phase: record.phase,
      situation: situation,
      since: situation.since,
      working: Map.has_key?(ctx.live.running, record.issue_id),
      move: move(record, situation, ctx)
    }
  end

  # The Director's move on a ticket that waits on them: Answer for an open question, else Unblock.
  defp move(record, %{kind: "waiting_on_you"}, %{moves: moves}) when is_function(moves, 1) do
    read = moves.(record)

    Enum.find_value([:answer, :unblock], fn name ->
      case Map.get(read, name) do
        %{allowed: true} = entry -> Map.put(entry, :name, Atom.to_string(name))
        _refused -> nil
      end
    end)
  end

  defp move(_record, _situation, _ctx), do: nil

  defp epic_node({identifier, title}, kids, situations, ctx) do
    epic = Map.get(ctx.by_identifier, identifier)
    counts = epic_counts(identifier, epic, situations, ctx)

    node = %{
      kind: "epic",
      issue_id: epic && epic.issue_id,
      identifier: identifier,
      title: (epic && epic.title) || title,
      repo_key: epic && epic.repo_key,
      counts: counts,
      total: counts |> Map.values() |> Enum.sum(),
      tickets: Enum.map(kids, &entry(&1, situations, ctx))
    }

    {kids |> List.first() |> order_key(ctx), node}
  end

  # The epic's tickets by state: its records naming it as parent, and the sub-issues its own record
  # lists that have none. A cancelled ticket counts in none.
  defp epic_counts(identifier, epic, situations, ctx) do
    records = Map.get(ctx.children, identifier, [])
    known = MapSet.new(records, & &1.issue_identifier)
    links = if epic, do: Enum.reject(epic.sub_issues, &MapSet.member?(known, &1.identifier)), else: []

    states =
      Enum.map(records, &record_state(&1, situations, ctx)) ++
        Enum.map(links, &link_state(&1.state, ctx))

    zero = Map.new(@count_keys, &{&1, 0})
    states |> Enum.reject(&(&1 == :cancelled)) |> Enum.reduce(zero, &Map.update!(&2, &1, fn n -> n + 1 end))
  end

  defp record_state(record, situations, ctx) do
    case Map.get(situations, record.issue_id) do
      %{kind: "waiting_on_you"} -> :needs_person
      %{} -> link_state(record.phase, ctx) |> started_state()
      nil -> link_state(record.phase, ctx)
    end
  end

  defp started_state(:not_started), do: :in_progress
  defp started_state(state), do: state

  defp link_state(phase, ctx) do
    phase = normalize(phase)

    cond do
      phase in @cancelled -> :cancelled
      MapSet.member?(ctx.terminal, phase) -> :done
      phase in @not_started or phase == "" -> :not_started
      phase in @needs_fix -> :needs_fix
      true -> :in_progress
    end
  end

  # -- Queue -----------------------------------------------------------------------------------

  # The open tickets that have not started, each queued or outside with its reason.
  defp classify(records, in_progress_ids, ctx) do
    outside = %{backlog: 0, below_priority: 0, epic: 0}

    Enum.reduce(records, {[], outside}, fn record, {queued, outside} ->
      case queue_reason(record, in_progress_ids, ctx) do
        :skip -> {queued, outside}
        :queued -> {[record | queued], outside}
        reason -> {queued, Map.update!(outside, reason, &(&1 + 1))}
      end
    end)
  end

  defp queue_reason(record, in_progress_ids, ctx) do
    phase = normalize(record.phase)

    cond do
      MapSet.member?(in_progress_ids, record.issue_id) or MapSet.member?(ctx.terminal, phase) -> :skip
      epic?(record, ctx) -> :epic
      phase == "backlog" -> :backlog
      phase != "todo" or not Map.has_key?(ctx.walk, record.issue_id) -> :skip
      priority_allowed?(record, ctx) -> :queued
      true -> :below_priority
    end
  end

  defp priority_allowed?(_record, %{priority_filter: nil}), do: true

  defp priority_allowed?(record, ctx), do: MapSet.member?(ctx.priority_filter, record.priority || 0)

  # The queued tickets a blocker outside both lists holds back, directly or behind another: they are
  # outside too. Each pass moves at least one, so it ends.
  defp behind(queued, in_progress_ids, ctx) do
    queued_ids = MapSet.new(queued, & &1.issue_id)

    held =
      Enum.filter(queued, fn record ->
        Enum.any?(open_blockers(record, ctx), fn blocker ->
          not MapSet.member?(in_progress_ids, blocker.id) and not MapSet.member?(queued_ids, blocker.id)
        end)
      end)

    case held do
      [] ->
        {queued, []}

      held ->
        held_ids = MapSet.new(held, & &1.issue_id)
        {left, behind} = queued |> Enum.reject(&MapSet.member?(held_ids, &1.issue_id)) |> behind(in_progress_ids, ctx)
        {left, behind ++ MapSet.to_list(held_ids)}
    end
  end

  # A record's blockers still open (by the blocker's record when Symphony holds one, else by the
  # link), each with the id of the ticket it names and its identifier.
  defp open_blockers(record, ctx) do
    record.blockers
    |> Enum.map(&{&1, known_blocker(&1, ctx)})
    |> Enum.reject(fn {link, known} -> MapSet.member?(ctx.terminal, normalize(blocker_phase(link, known))) end)
    |> Enum.map(fn {link, known} -> blocker_ref(link, known) end)
  end

  defp known_blocker(%{id: id} = link, ctx) when is_binary(id),
    do: Map.get(ctx.by_id, id) || Map.get(ctx.by_identifier, link.identifier)

  defp known_blocker(link, ctx), do: Map.get(ctx.by_identifier, link.identifier)

  defp blocker_phase(link, nil), do: link.state
  defp blocker_phase(link, known), do: known.phase || link.state

  defp blocker_ref(link, nil), do: %{id: link.id || link.identifier, identifier: link.identifier}

  defp blocker_ref(link, known),
    do: %{id: known.issue_id || link.id || link.identifier, identifier: known.issue_identifier || link.identifier}

  defp queue(queued, in_progress_ids, ctx) do
    queued_ids = MapSet.new(queued, & &1.issue_id)

    placed =
      Map.new(queued, fn record ->
        blockers = open_blockers(record, ctx)
        in_queue = Enum.filter(blockers, &MapSet.member?(queued_ids, &1.id))
        waits = Enum.filter(blockers, &MapSet.member?(in_progress_ids, &1.id))
        {record.issue_id, {record, in_queue, waits}}
      end)

    depths = depths(placed)

    parents =
      Map.new(placed, fn {issue_id, {_record, in_queue, waits}} ->
        {issue_id, placement(in_queue, waits, depths, ctx)}
      end)

    kids = parents |> Enum.filter(fn {_id, {parent, _after, _also}} -> parent end) |> Enum.group_by(fn {_id, {parent, _a, _o}} -> parent.id end, &elem(&1, 0))
    {roots, reached} = roots(placed, parents, kids, ctx)

    # A cycle of blockers no root reaches is drawn from its first ticket, so no queued ticket is lost.
    orphans = placed |> Map.keys() |> Enum.reject(&MapSet.member?(reached, &1)) |> Enum.sort_by(&walk_index(&1, ctx))
    {orphan_roots, _reached} = orphan_roots(orphans, placed, parents, kids, reached, ctx)

    roots ++ orphan_roots
  end

  # The queued blocker a ticket sits under (the one that lands last), else the ticket in progress it
  # waits on, and the identifiers of the others it also waits on.
  defp placement(in_queue, waits, depths, ctx) do
    parent = Enum.max_by(in_queue, &{Map.fetch!(depths, &1.id), walk_index(&1.id, ctx)}, fn -> nil end)
    after_ticket = if parent, do: nil, else: Enum.max_by(waits, &order_key(&1.id, ctx), fn -> nil end)
    {parent, after_ticket, Enum.map((in_queue ++ waits) -- [parent || after_ticket], & &1.identifier)}
  end

  # How many queued tickets stand above each one at most; a cycle of blockers counts once.
  defp depths(placed) do
    Enum.reduce(Map.keys(placed), %{}, fn issue_id, memo -> elem(depth(issue_id, placed, memo, []), 1) end)
  end

  defp depth(issue_id, placed, memo, visiting) do
    case Map.fetch(memo, issue_id) do
      {:ok, depth} ->
        {depth, memo}

      :error ->
        {_record, in_queue, _waits} = Map.fetch!(placed, issue_id)
        visiting = [issue_id | visiting]

        {depth, memo} =
          in_queue
          |> Enum.reject(&(&1.id in visiting))
          |> Enum.reduce({0, memo}, fn blocker, {deepest, memo} ->
            {depth, memo} = depth(blocker.id, placed, memo, visiting)
            {max(deepest, depth + 1), memo}
          end)

        {depth, Map.put(memo, issue_id, depth)}
    end
  end

  defp roots(placed, parents, kids, ctx) do
    {ready, waiting} =
      placed
      |> Map.keys()
      |> Enum.filter(fn issue_id -> parents |> Map.fetch!(issue_id) |> elem(0) |> is_nil() end)
      |> Enum.split_with(fn issue_id -> parents |> Map.fetch!(issue_id) |> elem(1) |> is_nil() end)

    ready = Enum.sort_by(ready, &walk_index(&1, ctx))
    waiting = Enum.sort_by(waiting, &{parents |> Map.fetch!(&1) |> elem(1) |> Map.fetch!(:id) |> order_key(ctx), walk_index(&1, ctx)})

    Enum.map_reduce(ready ++ waiting, MapSet.new(), fn issue_id, reached -> node(issue_id, placed, parents, kids, reached, true, ctx) end)
  end

  defp orphan_roots(orphans, placed, parents, kids, reached, ctx) do
    Enum.flat_map_reduce(orphans, reached, fn issue_id, reached ->
      if MapSet.member?(reached, issue_id) do
        {[], reached}
      else
        {node, reached} = node(issue_id, placed, parents, kids, reached, true, ctx)
        {[node], reached}
      end
    end)
  end

  defp node(issue_id, placed, parents, kids, reached, root?, ctx) do
    {record, _in_queue, _waits} = Map.fetch!(placed, issue_id)
    {_parent, after_ticket, also} = Map.fetch!(parents, issue_id)
    reached = MapSet.put(reached, issue_id)

    {children, reached} =
      kids
      |> Map.get(issue_id, [])
      |> Enum.reject(&MapSet.member?(reached, &1))
      |> Enum.sort_by(&walk_index(&1, ctx))
      |> Enum.map_reduce(reached, fn kid, reached -> node(kid, placed, parents, kids, reached, false, ctx) end)

    situation = if root? and is_nil(after_ticket), do: record |> Situation.read(ctx.live, ctx.records) |> Situation.payload()

    node = %{
      issue_id: record.issue_id,
      identifier: record.issue_identifier,
      title: record.title,
      repo_key: record.repo_key,
      epic: queue_epic(record, ctx),
      after: after_ticket && after_ticket.identifier,
      also_waits_on: also,
      situation: situation,
      children: children
    }

    {node, reached}
  end

  defp queue_epic(record, ctx) do
    case epic_of(record, ctx) do
      {identifier, title} -> %{identifier: identifier, title: title}
      nil -> nil
    end
  end

  # -- Epics -----------------------------------------------------------------------------------

  # The records that name each identifier as their parent.
  defp children(records) do
    records
    |> Enum.filter(&match?(%{parent: %{identifier: identifier}} when is_binary(identifier), &1))
    |> Enum.group_by(& &1.parent.identifier)
  end

  defp epic?(record, ctx), do: record.sub_issues != [] or Map.has_key?(ctx.children, record.issue_identifier)

  # The epic a ticket sits under, as `{identifier, title}`: its parent's record's title, else the one
  # the ticket's record keeps.
  defp epic_of(%{parent: %{identifier: identifier} = parent}, ctx) when is_binary(identifier) do
    epic = Map.get(ctx.by_identifier, identifier)
    {identifier, (epic && epic.title) || Map.get(parent, :title)}
  end

  defp epic_of(_record, _ctx), do: nil

  # -- Order -----------------------------------------------------------------------------------

  defp walk_index(issue_id, ctx) do
    case Map.get(ctx.walk, issue_id) do
      {index, _entry} -> index
      nil -> @last
    end
  end

  # Where a ticket stands in the dispatch order: its place in the walk, then its identifier.
  defp order_key(%{issue_id: issue_id, issue_identifier: identifier}, ctx), do: {walk_index(issue_id, ctx), identifier_key(identifier)}

  defp order_key(issue_id, ctx) when is_binary(issue_id) do
    identifier = with %{issue_identifier: identifier} <- Map.get(ctx.by_id, issue_id), do: identifier
    {walk_index(issue_id, ctx), identifier_key(identifier || issue_id)}
  end

  defp sort_by_order(records, ctx), do: Enum.sort_by(records, &order_key(&1, ctx))

  defp identifier_key(identifier) do
    case Regex.run(~r/^(.*)-(\d+)$/, identifier) do
      [_whole, team, number] -> {team, String.to_integer(number)}
      nil -> {identifier, 0}
    end
  end

  defp normalize(nil), do: ""
  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
