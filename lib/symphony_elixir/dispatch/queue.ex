defmodule SymphonyElixir.Dispatch.Queue do
  @moduledoc """
  The dispatch queue: one order of the open top-level tickets across all repositories, each
  ticket's sub-tickets ordered among themselves inside its place, stored on each ticket's record as
  a fractional sort key (`sort_key` on `SymphonyElixir.TicketState`, `SymphonyElixir.Dispatch.SortKey`),
  never computed at a pass. No position number is stored: the 1, 2, 3 a read shows are counted from
  the walk (`SymphonyElixir.Dispatch.Order.place/1`).

  - Nesting means "part of": a ticket with a parent (`parent` on its record) is ordered by its key
    among the tickets of the same parent, and the parent holds the place in the queue. The parent
    link is permanent: a done sub-ticket keeps it, so finished work traces back to its epic. A
    sub-ticket whose parent holds no place is ordered as a top-level ticket by its own key.
  - The queue is rebuilt at any moment from the open tickets, their parent and their key (`places/1`).
  - A ticket joins at the end of its scope (the top level, or its parent's sub-tickets) the first
    time its record is written open, or when its parent changes (`SymphonyElixir.RunStore`), and
    keeps its key until it leaves the queue (a terminal state, a removal); reopened, it joins at the
    end again.
  - A move (`SymphonyElixir.RunStore.move_in_queue/2`) writes one key, between the two neighbours'
    keys (`insertion/2`). When that key would pass `max_key_length/0`, only a window of tickets
    around the spot is rewritten with evenly spaced keys, in the same order; the rest keep theirs.
  - Priority decides no place: the `tickets.priorities` filter stays a gate on which tickets may
    start, as blockers, pauses and the other gates do.
  - The dispatch pass walks its candidates in the stored order (`order/3`), the sub-tickets of a
    ticket that has started first (`SymphonyElixir.Dispatch.Slots`): a free slot goes to the first one
    that can start, and a ticket a gate holds keeps its place and is skipped.
  - The first start of the release that stored the queue placed the tickets already there in the
    order the pass computed before (`placement/2`): the tickets already started in front, then the
    rest, each group closest to done first (Merging, Rework, the other active states, then Todo and
    Backlog), then by priority, then age, then identifier. The first start of the release that
    stored sort keys gave those places keys in the same order.
  """

  alias SymphonyElixir.Dispatch.SortKey
  alias SymphonyElixir.Linear.Issue

  # The phases a ticket that has not started is in.
  @unstarted_phases ["todo", "backlog", "triage"]
  @last 9_223_372_036_854_775_807
  # The longest key a move or a join writes without rebalancing, and the tickets on each side of
  # the spot a rebalance rewrites first (the window doubles while the keys it gives are still too
  # long, up to the whole scope).
  @max_key_length 12
  @rebalance_window 4

  @typedoc "A ticket's place: the sort keys from its top-level ancestor down to it."
  @type place :: [SortKey.t()]

  @doc "The longest key a move or a join writes before the spot around it is rebalanced."
  @spec max_key_length() :: pos_integer()
  def max_key_length, do: @max_key_length

  @doc """
  `issues` in the stored order: by each one's place in `places` (issue id to place, `places/1`, from
  `SymphonyElixir.RunStore.queue_places/0`), then the ones that hold no place yet (no record) by
  creation time and identifier, then anything that is not an issue. `places` that are not a map
  (the store could not be read) count as no places.
  """
  @spec order([Issue.t() | term()], %{String.t() => place()} | term()) :: [Issue.t() | term()]
  def order(issues, places) when is_list(issues), do: order(issues, places, MapSet.new())

  @doc """
  `issues` in the stored order (`order/2`), the ones whose id is in `first` (the sub-tickets of a
  ticket that has started, `SymphonyElixir.Dispatch.Slots.first_ids/3`) ahead of the rest, each
  group in the stored order: a free slot goes to them first.
  """
  @spec order([Issue.t() | term()], %{String.t() => place()} | term(), MapSet.t()) :: [Issue.t() | term()]
  def order(issues, places, %MapSet{} = first) when is_list(issues) and is_map(places),
    do: Enum.sort_by(issues, &{group(&1, first), order_key(&1, places)})

  def order(issues, _places, first) when is_list(issues), do: order(issues, %{}, first)

  defp group(%Issue{id: id}, first), do: if(MapSet.member?(first, id), do: 0, else: 1)
  defp group(_other, _first), do: 1

  defp order_key(%Issue{id: id} = issue, places) do
    case Map.get(places, id) do
      [_key | _keys] = place -> {0, place, 0, ""}
      _none -> {1, [], created_key(issue.created_at), issue.identifier || id || ""}
    end
  end

  defp order_key(_other, _places), do: {2, [], 0, ""}

  @doc """
  Each keyed ticket's place, by issue id, rebuilt from `records` (ticket records,
  `SymphonyElixir.TicketState`) alone: its parent's place followed by its own key, so a list sort
  puts a parent's sub-tickets right after it, in their own key order, before the next top-level
  ticket. A ticket whose parent holds no key (out of the queue, or no record) is placed at the top
  level; a parent cycle is cut where it closes.
  """
  @spec places([map()]) :: %{String.t() => place()}
  def places(records) when is_list(records) do
    {keys, parents} = links(records)
    Map.new(keys, fn {id, _key} -> {id, id |> lineage(parents) |> Enum.map(&Map.fetch!(keys, &1))} end)
  end

  # The keyed tickets' keys and the parent each one is ordered under (one that holds a key), by id.
  defp links(records) do
    keyed = for %{issue_id: id, sort_key: key} = record <- records, is_binary(id), is_binary(key), do: record
    keys = Map.new(keyed, &{&1.issue_id, &1.sort_key})

    ids =
      for record <- keyed, identifier = Map.get(record, :issue_identifier), is_binary(identifier), into: %{} do
        {identifier, record.issue_id}
      end

    parents = for record <- keyed, parent_id = Map.get(ids, scope(record)), into: %{}, do: {record.issue_id, parent_id}
    {keys, parents}
  end

  # The ids from the ticket's top-level ancestor down to it; a parent cycle is cut where it closes.
  defp lineage(id, parents, seen \\ []) do
    parent = Map.get(parents, id)

    if is_nil(parent) or parent in seen,
      do: [id],
      else: lineage(parent, parents, [id | seen]) ++ [id]
  end

  @doc """
  Where adding a dependency of the ticket `issue_id` on the ticket `on_id` moves a ticket, from
  `records` (ticket records): a dependency points upward, so when `issue_id` sits above `on_id`,
  `{:below, moved, index, siblings}` puts `moved` at `index` among `siblings` (the other tickets
  ordered where it is, in key order, as `{issue_id, key}`, as `insertion/2` takes them): right after
  `anchor`. The two are compared
  where their scopes meet: `moved` and `anchor` are `issue_id` and `on_id`, or the ancestors of
  each that are sub-tickets of the same parent (or both top-level). `:stay` when `issue_id` already
  sits below, when either holds no place, or when one is the other's ancestor (a parent always sits
  above its sub-tickets).
  """
  @spec dependency_move([map()], String.t(), String.t()) ::
          {:below, String.t(), non_neg_integer(), [{String.t(), SortKey.t()}]} | :stay
  def dependency_move(records, issue_id, on_id) when is_list(records) do
    {keys, parents} = links(records)

    with true <- Map.has_key?(keys, issue_id) and Map.has_key?(keys, on_id),
         {[moved | _], [anchor | _]} <- diverge(lineage(issue_id, parents), lineage(on_id, parents)),
         true <- Map.fetch!(keys, moved) < Map.fetch!(keys, anchor) do
      siblings =
        for {id, key} <- keys, id != moved, Map.get(parents, id) == Map.get(parents, moved) do
          {id, key}
        end
        |> Enum.sort_by(&elem(&1, 1))

      {:below, moved, Enum.find_index(siblings, &(elem(&1, 0) == anchor)) + 1, siblings}
    else
      _stay -> :stay
    end
  end

  defp diverge([same | rest], [same | other]), do: diverge(rest, other)
  defp diverge(lineage, other), do: {lineage, other}

  @doc """
  The scope a ticket's record is ordered in: its parent's identifier, nil for the top level.
  """
  @spec scope(map()) :: String.t() | nil
  def scope(%{parent: %{identifier: identifier}}) when is_binary(identifier), do: identifier
  def scope(_record), do: nil

  @doc """
  The keys to write to put a ticket at `index` among `siblings` (the other tickets of its scope, in
  key order, as `{issue_id, key}`): `[{:placed, key}]` with the key between its two neighbours when
  it stays within `max_key_length/0`, else the placed ticket and a window of siblings around the
  spot, in order, with evenly spaced keys between the keys just outside the window. The window
  starts at `@rebalance_window` tickets on each side and doubles while the keys are still too long.
  """
  @spec insertion([{String.t(), SortKey.t()}], non_neg_integer()) :: [{:placed | String.t(), SortKey.t()}]
  def insertion(siblings, index) when is_list(siblings) and is_integer(index) and index >= 0 do
    index = min(index, length(siblings))
    {:ok, key} = SortKey.key_between(key_at(siblings, index - 1), key_at(siblings, index))

    if byte_size(key) <= @max_key_length, do: [{:placed, key}], else: rebalance(siblings, index, @rebalance_window)
  end

  defp rebalance(siblings, index, window) do
    low = max(index - window, 0)
    high = min(index + window, length(siblings))
    {before, rest} = siblings |> Enum.slice(low, high - low) |> Enum.split(index - low)
    ids = Enum.map(before, &elem(&1, 0)) ++ [:placed] ++ Enum.map(rest, &elem(&1, 0))
    {:ok, keys} = SortKey.n_keys_between(key_at(siblings, low - 1), key_at(siblings, high), length(ids))
    whole = low == 0 and high == length(siblings)

    if whole or Enum.all?(keys, &(byte_size(&1) <= @max_key_length)),
      do: Enum.zip(ids, keys),
      else: rebalance(siblings, index, window * 2)
  end

  defp key_at(_siblings, index) when index < 0, do: nil
  defp key_at(siblings, index), do: siblings |> Enum.at(index) |> then(&(&1 && elem(&1, 1)))

  @doc """
  The one-time placement's order of `records` (queued ticket records, `SymphonyElixir.TicketState`):
  the tickets already started first (a phase past Todo, or an id in `started_ids`, the tickets whose
  ledger has a started run), then the rest; inside each group the order the dispatch pass computed
  before the queue was stored: Merging, Rework, the other active states, then Todo and Backlog, then
  priority (Urgent first, none last), creation time and identifier.
  """
  @spec placement([map()], MapSet.t(String.t())) :: [map()]
  def placement(records, %MapSet{} = started_ids) when is_list(records) do
    Enum.sort_by(records, fn record ->
      phase = normalize(record.phase)

      {if(phase in @unstarted_phases and not MapSet.member?(started_ids, record.issue_id), do: 1, else: 0), stage_rank(phase), priority_rank(record.priority), created_key(record.created_at),
       record.issue_identifier || record.issue_id}
    end)
  end

  defp stage_rank("merging"), do: 0
  defp stage_rank("rework"), do: 2
  defp stage_rank(phase) when phase in @unstarted_phases, do: 4
  defp stage_rank(_resume), do: 3

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp created_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp created_key(_none), do: @last

  defp normalize(phase) when is_binary(phase), do: phase |> String.trim() |> String.downcase()
  defp normalize(_phase), do: ""
end
