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
  - A row carries its state (`phase`), identifier, title, repo, its stored dependencies
    (`dependencies`, each with its kind, `done` or `released`, and whether it is `met`), what it
    waits on (`waits_on`: the open ones, `SymphonyElixir.Dispatch.DependsOn.open/2`, without
    `met`), and for an epic its sub-tickets done and in all (`sub_tickets`) and its done
    sub-tickets in order of completion (`done_sub_tickets`, `SymphonyElixir.Home.SubTickets`, on
    the rows of a page). An epic's open sub-tickets are the rows under it, in their own order; a
    done one is no row and counts in no number. The rows of a page also carry their situation, and
    whether they wait on the person.
  - A filter keeps the rows it matches (`SymphonyElixir.TicketList.matching/2`) and the rows above
    them, so an epic's row stays while one of its sub-tickets matches, with only the matching
    sub-rows under it. The order stays the stored order: a view's sort and columns do not apply.
  """

  alias SymphonyElixir.{Dispatch, Situation}
  alias SymphonyElixir.Home.SubTickets

  @default_limit 100
  @max_limit 500

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
  @spec read([map()], MapSet.t(String.t()), %{String.t() => String.t()}, Situation.live_facts(), page(), keyword()) ::
          map()
  def read(records, in_work, parents, live, page, opts \\ []) do
    rows = rows(records, in_work, parents, live)
    kept = keep(rows, page.matching)
    taken = kept |> Enum.drop(page.offset) |> Enum.take(page.limit)
    next = page.offset + length(taken)
    by_id = Map.new(records, &{&1.issue_id, &1})
    page_ctx = %{records: records, live: live, moves: Keyword.get(opts, :moves), index: SubTickets.index(records, parents)}

    %{
      rows: Enum.map(taken, &page_row(&1, Map.fetch!(by_id, &1.issue_id), page_ctx)),
      count: length(kept),
      total: length(rows),
      offset: page.offset,
      limit: page.limit,
      next_offset: if(next < length(kept), do: next)
    }
  end

  @doc "Every row of the queue, in the stored order, with its position; no situation, no done sub-tickets and no page."
  @spec rows([map()], MapSet.t(String.t()), %{String.t() => String.t()}, Situation.live_facts()) :: [map()]
  def rows(records, in_work, parents, live) do
    terminal = MapSet.new(live.terminal_states, &normalize/1)
    by_id = Map.new(records, &{&1.issue_id, &1})

    ids = for %{issue_identifier: key} = record <- records, is_binary(key), into: %{}, do: {key, record.issue_id}

    parent_ids = for {id, parent} <- parents, parent_id = Map.get(ids, parent), into: %{}, do: {id, parent_id}

    open = Enum.reject(records, &MapSet.member?(terminal, normalize(&1.phase)))
    places = Dispatch.Queue.places(open, parents)

    queued =
      open
      |> Enum.filter(&Map.has_key?(places, &1.issue_id))
      |> Enum.reject(fn record -> Enum.any?([record.issue_id | Dispatch.Slots.ancestors(record.issue_id, parent_ids)], &MapSet.member?(in_work, &1)) end)
      |> Enum.sort_by(&{Map.fetch!(places, &1.issue_id), &1.issue_identifier || ""})

    queued_ids = MapSet.new(queued, & &1.issue_id)
    ctx = %{by_id: by_id, parent_ids: parent_ids, terminal: terminal, index: SubTickets.index(records, parents)}

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
    dependencies = SubTickets.dependencies(record, ctx.by_id)

    %{
      issue_id: record.issue_id,
      identifier: record.issue_identifier,
      title: record.title,
      phase: record.phase,
      repo_key: record.repo_key,
      number: Enum.join(path, "."),
      path: path,
      parent: parent_id && Map.fetch!(ctx.by_id, parent_id).issue_identifier,
      waits_on: waits_on(dependencies),
      dependencies: dependencies,
      sub_tickets: sub_tickets(record, ctx)
    }
  end

  # The open dependencies, as `SymphonyElixir.Dispatch.DependsOn.open/2` finds them, without `met`.
  defp waits_on(dependencies), do: for(%{met: false} = dependency <- dependencies, do: Map.delete(dependency, :met))

  # An epic's sub-tickets done and in all (a cancelled one counts in neither), nil for a ticket with
  # none.
  defp sub_tickets(record, ctx) do
    {done, total} = record |> SubTickets.of(ctx.index) |> SubTickets.counts(ctx.terminal)
    if total > 0, do: %{done: done, total: total}
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

  # A row of the page: with its situation, whether it waits on the person and the move it then
  # allows, and an epic's done sub-tickets (read from the stored pull requests, so only for a page).
  defp page_row(row, record, ctx) do
    situation = record |> Situation.read(ctx.live, ctx.records) |> Situation.payload()
    terminal = MapSet.new(ctx.live.terminal_states, &normalize/1)

    Map.merge(row, %{
      situation: situation,
      waits_on_you: situation.kind == "waiting_on_you",
      move: SymphonyElixir.Home.move(record, situation, ctx.moves),
      done_sub_tickets: record |> SubTickets.of(ctx.index) |> SubTickets.done(terminal)
    })
  end

  defp normalize(state), do: state |> to_string() |> String.trim() |> String.downcase()
end
