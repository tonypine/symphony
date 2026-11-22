defmodule SymphonyElixir.Dispatch.Queue do
  @moduledoc """
  The dispatch queue: one order of every open ticket across all repositories, stored on each
  ticket's record (`queue_position` on `SymphonyElixir.TicketState`), never computed at a pass.

  - A ticket joins at the end the first time its record is written open
    (`SymphonyElixir.RunStore`), and keeps its place until it leaves the queue (a terminal state, a
    removal); reopened, it joins at the end again.
  - Priority decides no place: the `tickets.priorities` filter stays a gate on which tickets may
    start, as blockers, pauses and the other gates do.
  - The dispatch pass walks its candidates in the stored order (`order/2`): a free slot goes to the
    first one that can start, and a ticket a gate holds keeps its place and is skipped.
  - The first start of the release that stored the queue placed the tickets already there in the
    order the pass computed before (`placement/2`): the tickets already started in front, then the
    rest, each group closest to done first (Merging, Rework, the other active states, then Todo and
    Backlog), then by priority, then age, then identifier.
  """

  alias SymphonyElixir.Linear.Issue

  # The phases a ticket that has not started is in.
  @unstarted_phases ["todo", "backlog", "triage"]
  @last 9_223_372_036_854_775_807

  @doc """
  `issues` in the stored order: by each one's place in `positions` (issue id to place, from
  `SymphonyElixir.RunStore.queue_positions/0`), then the ones that hold no place yet (no record) by
  creation time and identifier, then anything that is not an issue. `positions` that are not a map
  (the store could not be read) count as no places.
  """
  @spec order([Issue.t() | term()], %{String.t() => pos_integer()} | term()) :: [Issue.t() | term()]
  def order(issues, positions) when is_list(issues) and is_map(positions), do: Enum.sort_by(issues, &order_key(&1, positions))
  def order(issues, _positions) when is_list(issues), do: order(issues, %{})

  defp order_key(%Issue{id: id} = issue, positions) do
    case Map.get(positions, id) do
      position when is_integer(position) -> {0, position, 0, ""}
      _none -> {1, 0, created_key(issue.created_at), issue.identifier || id || ""}
    end
  end

  defp order_key(_other, _positions), do: {2, 0, 0, ""}

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
