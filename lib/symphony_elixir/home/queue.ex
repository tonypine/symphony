defmodule SymphonyElixir.Home.Queue do
  @moduledoc """
  The queue rows of the Home read (`queue.rows` of `GET /api/v1/home`,
  `docs/design/prototypes/home-queue/README.md`, section Queue): every open ticket with a place in
  the stored queue (`SymphonyElixir.Dispatch.Queue`) that is not in work, as a flat list in the
  stored order, read in pages and narrowed by a saved filter of the Tickets page.

  - Not in work: it holds no slot, no run works on it, and no ancestor of it does: a ticket under a
    slot's holder runs through that slot (`SymphonyElixir.Dispatch.Slots`), so its slot card holds
    it. Backlog tickets are rows too; the row's `phase` tells them apart.
  - A ticket's parent is its record's, else the one whose record lists it among its sub-issues
    (`SymphonyElixir.Dispatch.Queue.parents/1`), so a sub-ticket that never ran sits under its
    parent and not at the top level.
  - Each row has its position: `path`, the top-level number and then its number inside each parent
    down to it (`[6, 1]`), `number` the same as text (`"6.1"`), and `parent`, the identifier of the
    row it sits under. The numbers are counted over the whole queue before a filter and a page, so a
    filtered row keeps its real number.
  - A row carries its state (`phase`), identifier, title, repo, what it waits on (its open stored
    dependencies, `SymphonyElixir.Dispatch.DependsOn.open/2`, each with its kind: `done` or
    `released`), and for an epic its sub-tickets done and in all. The rows of a page also carry
    their situation, and whether they wait on the person.
  - A filter keeps the rows it matches (`SymphonyElixir.TicketList.matching/2`) and the rows above
    them, so an epic's row stays while one of its sub-tickets matches, with only the matching
    sub-rows under it. The order stays the stored order: a view's sort and columns do not apply.
  """

  alias SymphonyElixir.{Dispatch, Situation}
  alias SymphonyElixir.Dispatch.DependsOn

  @default_limit 100
  @max_limit 500
  @cancelled ["canceled", "cancelled", "duplicate"]

  @typedoc "Which rows a read gives: from `offset`, at most `limit`, those `matching` lets through (nil keeps all)."
  @type page :: %{offset: non_neg_integer(), limit: pos_integer(), matching: MapSet.t(String.t()) | nil}

  @doc "The page size a read without `limit` gets."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @doc "The largest page a read gets."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  The page `params` ask for (string keys `offset`, from 0, and `limit`, from 1 to `max_limit/0`, both
  optional), or `{:error, {:invalid, reason}}`.
  """
  @spec page(map()) :: {:ok, %{offset: non_neg_integer(), limit: pos_integer()}} | {:error, {:invalid, String.t()}}
  def page(params) when is_map(params) do
    with {:ok, offset} <- integer(params, "offset", 0, 0),
         {:ok, limit} <- integer(params, "limit", @default_limit, 1) do
      {:ok, %{offset: offset, limit: min(limit, @max_limit)}}
    end
  end

  defp integer(params, name, default, least) do
    case Map.get(params, name) do
      blank when blank in [nil, ""] ->
        {:ok, default}

      value ->
        case Integer.parse(to_string(value)) do
          {number, ""} when number >= least -> {:ok, number}
          _invalid -> {:error, {:invalid, "#{name} must be a whole number from #{least}"}}
        end
    end
  end

  @doc """
  The queue over the ticket `records` (normalized, `SymphonyElixir.TicketState`): `in_work` the
  issue ids of the tickets that hold a slot or have a run, `parents` each ticket's parent by issue id
  as its identifier (`SymphonyElixir.Dispatch.Queue.parents/1`), `live` the orchestrator's facts and
  `page` which rows to give. Answers the rows of the page, `count` (the rows the filter keeps),
  `total` (the rows of the whole queue), `offset`, `limit` and `next_offset` (nil on the last page).
  """
  @spec read([map()], MapSet.t(String.t()), %{String.t() => String.t()}, Situation.live_facts(), page(), keyword()) :: map()
  def read(records, in_work, parents, live, page, opts \\ []) do
    rows = rows(records, in_work, parents, live)
    kept = keep(rows, page.matching)
    taken = kept |> Enum.drop(page.offset) |> Enum.take(page.limit)
    next = page.offset + length(taken)
    by_id = Map.new(records, &{&1.issue_id, &1})

    %{
      rows: Enum.map(taken, &with_situation(&1, Map.fetch!(by_id, &1.issue_id), records, live, Keyword.get(opts, :moves))),
      count: length(kept),
      total: length(rows),
      offset: page.offset,
      limit: page.limit,
      next_offset: if(next < length(kept), do: next)
    }
  end

  @doc "Every row of the queue, in the stored order, with its position; no situation and no page."
  @spec rows([map()], MapSet.t(String.t()), %{String.t() => String.t()}, Situation.live_facts()) :: [map()]
  def rows(records, in_work, parents, live) do
    terminal = MapSet.new(live.terminal_states, &normalize/1)
    by_id = Map.new(records, &{&1.issue_id, &1})
    ids = for record <- records, is_binary(record.issue_identifier), into: %{}, do: {record.issue_identifier, record.issue_id}
    parent_ids = for {id, parent} <- parents, parent_id = Map.get(ids, parent), into: %{}, do: {id, parent_id}

    open = Enum.reject(records, &MapSet.member?(terminal, normalize(&1.phase)))
    places = Dispatch.Queue.places(open, parents)

    queued =
      open
      |> Enum.filter(&Map.has_key?(places, &1.issue_id))
      |> Enum.reject(fn record -> Enum.any?([record.issue_id | Dispatch.Slots.ancestors(record.issue_id, parent_ids)], &MapSet.member?(in_work, &1)) end)
      |> Enum.sort_by(&{Map.fetch!(places, &1.issue_id), &1.issue_identifier || ""})

    queued_ids = MapSet.new(queued, & &1.issue_id)
    ctx = %{by_id: by_id, parents: parents, parent_ids: parent_ids, terminal: terminal, records: records}

    queued
    |> Enum.map_reduce(%{}, fn record, numbers -> number(record, queued_ids, numbers, ctx) end)
    |> elem(0)
  end

  # The row's position: its parent's path and the next number under it, or the next top-level one.
  defp number(record, queued_ids, numbers, ctx) do
    parent_id = Map.get(ctx.parent_ids, record.issue_id)
    parent_id = if parent_id && MapSet.member?(queued_ids, parent_id), do: parent_id
    {path, count} = Map.get(numbers, parent_id, {[], 0})
    own = path ++ [count + 1]
    numbers = numbers |> Map.put(parent_id, {path, count + 1}) |> Map.put(record.issue_id, {own, 0})
    {row(record, own, parent_id, ctx), numbers}
  end

  defp row(record, path, parent_id, ctx) do
    %{
      issue_id: record.issue_id,
      identifier: record.issue_identifier,
      title: record.title,
      phase: record.phase,
      repo_key: record.repo_key,
      number: Enum.join(path, "."),
      path: path,
      parent: parent_id && Map.fetch!(ctx.by_id, parent_id).issue_identifier,
      waits_on: waits_on(record, ctx.by_id),
      sub_tickets: sub_tickets(record, ctx)
    }
  end

  defp waits_on(record, by_id) do
    for dependency <- DependsOn.open(record.depends_on, by_id) do
      identifier = dependency.identifier || Map.get(by_id, dependency.issue_id, %{})[:issue_identifier]
      %{issue_id: dependency.issue_id, identifier: identifier, kind: Atom.to_string(dependency.kind)}
    end
  end

  # An epic's sub-tickets, done and in all (a cancelled one counts in neither): the records it is the
  # parent of, and the sub-issues its record lists that Symphony holds no record of. Nil for a
  # ticket with none.
  defp sub_tickets(record, ctx) do
    kids = for {id, parent} <- ctx.parents, parent == record.issue_identifier, kid = Map.get(ctx.by_id, id), do: kid
    known = MapSet.new(kids, & &1.issue_id)
    phases = Enum.map(kids, & &1.phase) ++ for(link <- record.sub_issues, not MapSet.member?(known, link.id), do: link.state)
    phases = phases |> Enum.map(&normalize/1) |> Enum.reject(&(&1 in @cancelled))

    if phases != [], do: %{done: Enum.count(phases, &MapSet.member?(ctx.terminal, &1)), total: length(phases)}
  end

  # The rows `matching` lets through and every row above one of them; all of them with no filter.
  defp keep(rows, nil), do: rows

  defp keep(rows, matching) do
    by_identifier = Map.new(rows, &{&1.identifier, &1})

    kept =
      rows
      |> Enum.filter(&MapSet.member?(matching, &1.issue_id))
      |> Enum.flat_map(&[&1.issue_id | above(&1, by_identifier)])
      |> MapSet.new()

    Enum.filter(rows, &MapSet.member?(kept, &1.issue_id))
  end

  defp above(%{parent: nil}, _by_identifier), do: []

  defp above(%{parent: parent}, by_identifier) do
    row = Map.fetch!(by_identifier, parent)
    [row.issue_id | above(row, by_identifier)]
  end

  defp with_situation(row, record, records, live, moves) do
    situation = record |> Situation.read(live, records) |> Situation.payload()
    Map.merge(row, %{situation: situation, waits_on_you: situation.kind == "waiting_on_you", move: SymphonyElixir.Home.move(record, situation, moves)})
  end

  defp normalize(nil), do: ""
  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
