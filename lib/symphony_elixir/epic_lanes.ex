defmodule SymphonyElixir.EpicLanes do
  @moduledoc """
  Splits `agent.concurrency.max_total` into one lane per active epic and a shared pool.

  An epic is a `breakdown` parent waiting on its sub-tickets. It is active once at least one
  sub-ticket is under way: not terminal and not still in a pre-approval state such as Backlog.
  Active epics are ordered by the parent's priority, then age, and the first
  `agent.concurrency.epic_lanes` of them (default: `max_total`) each reserve one slot.

  A lane only runs its own epic's sub-tickets. It stays reserved while the epic's current part is
  in review or landing, so the next part starts there as soon as it is unblocked. The slots left
  over form the shared pool, dispatched by priority then age as before; it also takes an epic's
  extra parallel sub-tickets and the sub-tickets of epics still waiting for a lane.
  """

  alias SymphonyElixir.Linear.Issue

  # Linear states a sub-ticket sits in before a human approves it into Todo.
  @not_approved_states MapSet.new(["backlog", "triage"])

  @type epic :: %{
          id: String.t(),
          identifier: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          sub_issues: [map()],
          open_parts: [map()],
          sub_issue_ids: MapSet.t(String.t())
        }

  @type t :: %{max_total: non_neg_integer(), shared: non_neg_integer(), lanes: [epic()], queued: [epic()]}

  @type running :: %{
          optional(String.t()) => %{optional(:identifier) => String.t() | nil, optional(:state) => String.t() | nil}
        }

  @doc """
  Plans the lanes for one poll from the candidate issues. `epic_lanes` nil means every slot can be
  a lane; a value above `max_total` is capped there.
  """
  @spec plan([Issue.t() | term()], non_neg_integer(), non_neg_integer() | nil, Enumerable.t(String.t())) :: t()
  def plan(candidates, max_total, epic_lanes, terminal_states) when is_list(candidates) and is_integer(max_total) do
    terminal_states = MapSet.new(terminal_states, &normalize_state/1)
    lane_count = min(epic_lanes || max_total, max_total)

    {lanes, queued} =
      candidates
      |> Enum.filter(&active_epic?(&1, terminal_states))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&epic_sort_key/1)
      |> Enum.map(&epic(&1, terminal_states))
      |> Enum.split(lane_count)

    %{max_total: max_total, shared: max_total - length(lanes), lanes: lanes, queued: queued}
  end

  @doc """
  The slot `issue_id` would use given the issue ids already running: its epic's lane when that is
  free, else a shared slot when one is free, else `:none`. With no plan yet, every slot is shared.
  """
  @spec slot_for(t() | nil, String.t(), [String.t()]) :: {:lane, epic()} | :shared | :none
  def slot_for(nil, _issue_id, _running_ids), do: :shared

  def slot_for(%{lanes: lanes, shared: shared}, issue_id, running_ids) when is_list(running_ids) do
    running_ids = MapSet.new(running_ids)
    occupied = Enum.filter(lanes, &lane_occupied?(&1, running_ids))
    lane = Enum.find(lanes, &MapSet.member?(&1.sub_issue_ids, issue_id))

    cond do
      lane && lane not in occupied -> {:lane, lane}
      MapSet.size(running_ids) - length(occupied) < shared -> :shared
      true -> :none
    end
  end

  @doc "The slot name the dispatch log line uses: `lane:<epic>` or `shared`."
  @spec slot_label(t() | nil, String.t(), [String.t()]) :: String.t()
  def slot_label(plan, issue_id, running_ids) do
    case slot_for(plan, issue_id, running_ids) do
      {:lane, epic} -> "lane:#{epic.identifier}"
      _shared -> "shared"
    end
  end

  @doc """
  The lanes and shared pool for the dashboard and `/api/v1/state`. Each lane shows its epic and
  either the running part or the part it is waiting on.
  """
  @spec snapshot(t() | nil, running()) :: map()
  def snapshot(nil, running) when is_map(running) do
    %{max_total: nil, lanes: [], queued_epics: [], shared: %{slots: nil, used: map_size(running)}}
  end

  def snapshot(%{lanes: lanes, queued: queued, shared: shared, max_total: max_total}, running) when is_map(running) do
    running_ids = running |> Map.keys() |> MapSet.new()
    lane_snapshots = Enum.map(lanes, &lane_snapshot(&1, running))
    occupied = Enum.count(lane_snapshots, &(&1.status == "running"))

    %{
      max_total: max_total,
      lanes: lane_snapshots,
      queued_epics: Enum.map(queued, &epic_summary/1),
      shared: %{slots: shared, used: MapSet.size(running_ids) - occupied}
    }
  end

  defp lane_snapshot(epic, running) do
    case Enum.find(epic.sub_issues, &Map.has_key?(running, &1.id)) do
      %{id: id} = sub_issue ->
        entry = Map.fetch!(running, id)
        epic |> epic_summary() |> Map.merge(%{status: "running", sub_issue: part(sub_issue, Map.get(entry, :state) || sub_issue.state)})

      nil ->
        epic |> epic_summary() |> Map.merge(%{status: "waiting", sub_issue: waiting_part(epic)})
    end
  end

  # The part the idle lane is held for: the one in review or landing ahead of a Todo still blocked on it.
  defp waiting_part(%{open_parts: open_parts}) do
    case Enum.find(open_parts, &(normalize_state(&1.state) != "todo")) || List.first(open_parts) do
      nil -> nil
      sub_issue -> part(sub_issue, sub_issue.state)
    end
  end

  defp part(sub_issue, state), do: %{issue_id: sub_issue.id, identifier: sub_issue.identifier, state: state}

  defp epic_summary(epic), do: %{issue_id: epic.id, identifier: epic.identifier, title: epic.title, url: epic.url}

  defp lane_occupied?(epic, running_ids), do: not MapSet.disjoint?(epic.sub_issue_ids, running_ids)

  defp active_epic?(%Issue{id: id, sub_issues: sub_issues} = issue, terminal_states) when is_binary(id) do
    Issue.waiting_on_sub_issues?(issue, terminal_states) and
      Enum.any?(sub_issues, &under_way?(Map.get(&1, :state), terminal_states))
  end

  defp active_epic?(_issue, _terminal_states), do: false

  # Approved into Todo or later, and not finished.
  defp under_way?(state, terminal_states) when is_binary(state) do
    state = normalize_state(state)
    not MapSet.member?(@not_approved_states, state) and not MapSet.member?(terminal_states, state)
  end

  defp under_way?(_state, _terminal_states), do: false

  defp epic(%Issue{} = issue, terminal_states) do
    sub_issues =
      for %{id: id} = sub_issue <- issue.sub_issues, is_binary(id) do
        %{id: id, identifier: Map.get(sub_issue, :identifier), state: Map.get(sub_issue, :state)}
      end

    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      url: issue.url,
      sub_issues: sub_issues,
      open_parts: Enum.filter(sub_issues, &under_way?(&1.state, terminal_states)),
      sub_issue_ids: MapSet.new(sub_issues, & &1.id)
    }
  end

  defp epic_sort_key(%Issue{} = issue) do
    created_at =
      case issue.created_at do
        %DateTime{} = created_at -> DateTime.to_unix(created_at, :microsecond)
        _ -> :infinity
      end

    {priority_rank(issue.priority), created_at, issue.identifier || issue.id}
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()
end
