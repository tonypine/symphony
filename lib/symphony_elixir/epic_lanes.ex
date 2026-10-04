defmodule SymphonyElixir.EpicLanes do
  @moduledoc """
  Splits `agent.concurrency.max_total` into one lane per active epic and a shared pool.

  An epic is a `breakdown` parent waiting on its sub-tickets. It is active once at least one
  sub-ticket is under way: not terminal and not still in a pre-approval state such as Backlog.
  Active epics are ordered by the parent's priority, then age, and the first
  `agent.concurrency.epic_lanes` of them (default: `max_total`) each reserve one slot.

  A lane runs the tickets on its epic's path: the epic's sub-tickets, their sub-tickets at any depth,
  and the open blockers of any of those, transitively. The walk follows the candidate issues, so a
  ticket Symphony did not fetch is a leaf. The nearest ticket goes first: the epic's next part, then
  a blocker or sub-ticket of it, and so on; priority and age only break ties. A ticket on the path
  of two epics runs in whichever lane is free first and holds only one of them.

  A lane stays reserved while its path waits on Symphony, for example on a part that is landing, so
  the next part starts there as soon as it is unblocked. An epic whose path only waits on people
  yields its lane to the next queued epic or the shared pool: every open ticket on the path is in
  review, not yet approved, a `breakdown` parent waiting on its own sub-tickets, or a `Todo` held by
  open blockers. Lanes are planned again on every poll, so the epic takes a lane back once a ticket
  on its path can run.

  The slots left over form the shared pool, dispatched by priority then age as before; it also takes
  an epic's extra parallel tickets and the tickets of epics still waiting for a lane.
  """

  alias SymphonyElixir.HumanReview
  alias SymphonyElixir.Linear.Issue

  # Linear states a sub-ticket sits in before a human approves it into Todo.
  @not_approved_states MapSet.new(["backlog", "triage"])

  # States in which a ticket on the path waits for a person rather than for Symphony.
  # A renamed Human Review state is read from the settings (`human_gated_state?/1`).
  @human_gated_states MapSet.union(@not_approved_states, MapSet.new(["in review", "human review"]))

  @type epic :: %{
          id: String.t(),
          identifier: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          sub_issues: [map()],
          open_parts: [map()],
          members: %{optional(String.t()) => member()},
          yield_reason: String.t() | nil
        }

  @typedoc "A ticket on the epic's path: how far from the epic, and the ticket it blocks or is a sub-ticket of."
  @type member :: %{
          identifier: String.t() | nil,
          state: String.t() | nil,
          depth: pos_integer(),
          via: %{relation: String.t(), identifier: String.t() | nil} | nil
        }

  @type t :: %{
          max_total: non_neg_integer(),
          shared: non_neg_integer(),
          lanes: [epic()],
          queued: [epic()],
          yielded: [epic()]
        }

  @type running :: %{
          optional(String.t()) => %{optional(:identifier) => String.t() | nil, optional(:state) => String.t() | nil}
        }

  @doc """
  Plans the lanes for one poll from the candidate issues. `epic_lanes` nil means every slot can be
  a lane; a value above `max_total` is capped there. Active epics with nothing on their path that
  can run are `yielded` and take no lane.
  """
  @spec plan([Issue.t() | term()], non_neg_integer(), non_neg_integer() | nil, Enumerable.t(String.t())) :: t()
  def plan(candidates, max_total, epic_lanes, terminal_states) when is_list(candidates) and is_integer(max_total) do
    terminal_states = MapSet.new(terminal_states, &normalize_state/1)
    lane_count = min(epic_lanes || max_total, max_total)

    by_id = for %Issue{id: id} = issue <- candidates, is_binary(id), into: %{}, do: {id, issue}

    {waiting, yielded} =
      candidates
      |> Enum.filter(&active_epic?(&1, terminal_states))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&epic_sort_key/1)
      |> Enum.map(&epic(&1, by_id, terminal_states))
      |> Enum.split_with(&is_nil(&1.yield_reason))

    {lanes, queued} = Enum.split(waiting, lane_count)

    %{max_total: max_total, shared: max_total - length(lanes), lanes: lanes, queued: queued, yielded: yielded}
  end

  @doc """
  The slot `issue_id` would use given the issue ids already running: the first free lane whose path
  it is on, else a shared slot when one is free, else `:none`. With no plan yet, every slot is shared.
  """
  @spec slot_for(t() | nil, String.t(), [String.t()]) :: {:lane, epic()} | :shared | :none
  def slot_for(nil, _issue_id, _running_ids), do: :shared

  def slot_for(%{lanes: lanes, shared: shared}, issue_id, running_ids) when is_list(running_ids) do
    running_ids = running_ids |> Enum.uniq() |> List.delete(issue_id)
    occupancy = occupancy(lanes, running_ids)
    lane = candidate_lane(lanes, issue_id, running_ids, occupancy, shared)

    cond do
      lane -> {:lane, lane}
      length(running_ids) - map_size(occupancy) < shared -> :shared
      true -> :none
    end
  end

  # Placing the candidate together with the running tickets lets a ticket on two paths move to its
  # other lane rather than take the one lane the candidate could use. That counts only when the
  # running tickets left without a lane still fit the shared pool; otherwise the candidate takes a
  # lane the running tickets leave free.
  defp candidate_lane(lanes, issue_id, running_ids, occupancy, shared) do
    with_candidate = occupancy(lanes, [issue_id | running_ids])

    case Enum.find(lanes, &(Map.get(with_candidate, &1.id) == issue_id)) do
      %{} = lane when length(running_ids) - (map_size(with_candidate) - 1) <= shared -> lane
      _no_lane -> Enum.find(lanes, &(Map.has_key?(&1.members, issue_id) and not Map.has_key?(occupancy, &1.id)))
    end
  end

  @doc """
  Reorders `issues`, already in dispatch order, so each lane's tickets go nearest first: they swap
  places among the positions they already hold, so the rest of the order is unchanged. Only tickets
  of the same lane and the same `group_by` value (the dispatch stage) swap. A ticket on two paths
  counts for the lane it is nearest to.
  """
  @spec order(t() | nil, [Issue.t() | term()], (Issue.t() -> term())) :: [Issue.t() | term()]
  def order(nil, issues, _group_by), do: issues

  def order(%{lanes: lanes}, issues, group_by) when is_list(issues) and is_function(group_by, 1) do
    indexed = Enum.with_index(issues)

    placed =
      indexed
      |> Enum.flat_map(fn {issue, index} ->
        case home_lane(lanes, issue) do
          {lane_id, depth} -> [{{lane_id, group_by.(issue)}, {depth, index}, index, issue}]
          nil -> []
        end
      end)
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.flat_map(fn {_lane_and_group, entries} ->
        positions = entries |> Enum.map(&elem(&1, 2)) |> Enum.sort()
        nearest_first = entries |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 3))
        Enum.zip(positions, nearest_first)
      end)
      |> Map.new()

    Enum.map(indexed, fn {issue, index} -> Map.get(placed, index, issue) end)
  end

  defp home_lane(lanes, %Issue{id: id}) when is_binary(id) do
    lanes
    |> Enum.with_index()
    |> Enum.flat_map(fn {lane, lane_index} ->
      case lane.members do
        %{^id => %{depth: depth}} -> [{depth, lane_index, lane.id}]
        _members -> []
      end
    end)
    |> Enum.min(fn -> nil end)
    |> case do
      {depth, _lane_index, lane_id} -> {lane_id, depth}
      nil -> nil
    end
  end

  defp home_lane(_lanes, _issue), do: nil

  @doc """
  The tickets on the path of the active epic `epic_id`, whether it holds a lane, is queued for one or
  has yielded it; an empty map when the plan has no such epic.
  """
  @spec members(t() | nil, String.t()) :: %{optional(String.t()) => member()}
  def members(%{lanes: lanes, queued: queued, yielded: yielded}, epic_id) do
    case Enum.find(lanes ++ queued ++ yielded, &(&1.id == epic_id)) do
      %{members: members} -> members
      nil -> %{}
    end
  end

  def members(nil, _epic_id), do: %{}

  @doc "True when a ticket in `state` waits for a person: not yet approved (Backlog, Triage), In Review or Human Review."
  @spec human_gated_state?(String.t() | nil) :: boolean()
  def human_gated_state?(state) when is_binary(state),
    do: MapSet.member?(@human_gated_states, normalize_state(state)) or HumanReview.in_state?(state)

  def human_gated_state?(_state), do: false

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
  either the running part or the part it is waiting on. Yielded epics follow the lanes, with
  `status: "yielded"`, the part they wait on and the `reason` nothing on their path can run.
  """
  @spec snapshot(t() | nil, running()) :: map()
  def snapshot(nil, running) when is_map(running) do
    %{max_total: nil, lanes: [], queued_epics: [], shared: %{slots: nil, used: map_size(running)}}
  end

  def snapshot(%{lanes: lanes, queued: queued, yielded: yielded, shared: shared, max_total: max_total}, running) when is_map(running) do
    occupancy = occupancy(lanes, Map.keys(running))

    %{
      max_total: max_total,
      lanes: Enum.map(lanes, &lane_snapshot(&1, Map.get(occupancy, &1.id), running)) ++ Enum.map(yielded, &yielded_snapshot/1),
      queued_epics: Enum.map(queued, &epic_summary/1),
      shared: %{slots: shared, used: map_size(running) - map_size(occupancy)}
    }
  end

  defp lane_snapshot(epic, nil, _running) do
    epic |> epic_summary() |> Map.merge(%{status: "waiting", sub_issue: waiting_part(epic)})
  end

  defp lane_snapshot(epic, issue_id, running) do
    member = Map.fetch!(epic.members, issue_id)
    entry = Map.fetch!(running, issue_id)
    part = %{issue_id: issue_id, identifier: member.identifier, state: Map.get(entry, :state) || member.state}

    epic |> epic_summary() |> Map.merge(%{status: "running", sub_issue: Map.put(part, :via, member.via)})
  end

  defp yielded_snapshot(epic) do
    epic |> epic_summary() |> Map.merge(%{status: "yielded", reason: epic.yield_reason, sub_issue: waiting_part(epic)})
  end

  # Each running ticket holds at most one lane, of those whose path it is on: tickets with fewer
  # lanes to choose from are placed first, so a ticket shared by two epics never takes both.
  defp occupancy(lanes, running_ids) do
    running_ids
    |> Enum.map(fn issue_id -> {issue_id, Enum.filter(lanes, &Map.has_key?(&1.members, issue_id))} end)
    |> Enum.reject(fn {_issue_id, member_of} -> member_of == [] end)
    |> Enum.sort_by(fn {issue_id, member_of} -> {length(member_of), issue_id} end)
    |> Enum.reduce(%{}, fn {issue_id, member_of}, occupancy ->
      case Enum.find(member_of, &(not Map.has_key?(occupancy, &1.id))) do
        nil -> occupancy
        lane -> Map.put(occupancy, lane.id, issue_id)
      end
    end)
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

  defp epic(%Issue{} = issue, by_id, terminal_states) do
    sub_issues =
      for %{id: id} = sub_issue <- issue.sub_issues, is_binary(id) do
        %{id: id, identifier: Map.get(sub_issue, :identifier), state: Map.get(sub_issue, :state)}
      end

    members = walk(path_links(issue, terminal_states, nil), 1, MapSet.new([issue.id]), %{}, by_id, terminal_states)

    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      url: issue.url,
      sub_issues: sub_issues,
      open_parts: Enum.filter(sub_issues, &under_way?(&1.state, terminal_states)),
      members: members,
      yield_reason: yield_reason(members, by_id, terminal_states)
    }
  end

  # Nil while a ticket on the path can run; otherwise each open ticket on it and what it waits on.
  defp yield_reason(members, by_id, terminal_states) do
    held = Enum.map(members, fn {id, member} -> {member, held_by(member, Map.get(by_id, id), terminal_states)} end)

    if Enum.all?(held, &elem(&1, 1)) do
      waits =
        held
        |> Enum.sort_by(fn {member, _held_by} -> {member.depth, member.identifier || ""} end)
        |> Enum.map_join(", ", fn {member, held_by} -> "#{member.identifier} (#{held_by})" end)

      "Nothing on its path can run: " <> waits
    end
  end

  # What keeps a ticket on the path from running, or nil when Symphony can run it. A ticket Symphony
  # did not fetch is judged by its state alone. A blocked ticket's blockers are on the path too, so
  # the lane stays while one of them can run.
  defp held_by(member, issue, terminal_states) do
    state = fetched_state(issue) || member.state

    cond do
      not is_binary(state) -> "state unknown"
      human_gated_state?(state) -> state
      waiting_parent?(issue, terminal_states) -> "#{state}, waiting on its sub-tickets"
      Issue.blocked?(issue, terminal_states) -> "#{state}, blocked by #{blocker_names(issue, terminal_states)}"
      true -> nil
    end
  end

  defp fetched_state(%Issue{state: state}) when is_binary(state), do: state
  defp fetched_state(_not_fetched), do: nil

  defp waiting_parent?(%Issue{} = issue, terminal_states),
    do: Issue.waiting_on_sub_issues?(issue, terminal_states) and not Issue.replanning?(issue)

  defp waiting_parent?(_not_fetched, _terminal_states), do: false

  defp blocker_names(issue, terminal_states) do
    issue |> Issue.open_blockers(terminal_states) |> Enum.map_join(", ", &(Map.get(&1, :identifier) || "an unnamed ticket"))
  end

  # Breadth-first from the epic's sub-tickets, so each ticket keeps its shortest distance to the epic.
  defp walk([], _depth, _seen, members, _by_id, _terminal_states), do: members

  defp walk(level, depth, seen, members, by_id, terminal_states) do
    {next, seen, members} =
      Enum.reduce(level, {[], seen, members}, fn {%{id: id} = ticket, via}, {next, seen, members} ->
        if MapSet.member?(seen, id) do
          {next, seen, members}
        else
          member = %{identifier: Map.get(ticket, :identifier), state: Map.get(ticket, :state), depth: depth, via: via}
          {[path_links(Map.get(by_id, id), terminal_states, ticket) | next], MapSet.put(seen, id), Map.put(members, id, member)}
        end
      end)

    next |> Enum.reverse() |> List.flatten() |> walk(depth + 1, seen, members, by_id, terminal_states)
  end

  # The open sub-tickets and blockers of a fetched ticket, each with how it relates to the ticket.
  # The epic's own sub-tickets (`ticket` nil) are its direct parts and carry no relation.
  defp path_links(%Issue{} = epic, terminal_states, nil), do: Enum.map(open_links(epic.sub_issues, terminal_states), &{&1, nil})

  defp path_links(%Issue{} = issue, terminal_states, ticket) do
    of = Map.get(ticket, :identifier)

    Enum.map(open_links(issue.sub_issues, terminal_states), &{&1, %{relation: "sub_ticket_of", identifier: of}}) ++
      Enum.map(open_links(issue.blocked_by, terminal_states), &{&1, %{relation: "blocks", identifier: of}})
  end

  defp path_links(_not_fetched, _terminal_states, _ticket), do: []

  defp open_links(links, terminal_states) do
    for %{id: id} = link <- links, is_binary(id), not terminal?(Map.get(link, :state), terminal_states), do: link
  end

  defp terminal?(state, terminal_states) when is_binary(state), do: MapSet.member?(terminal_states, normalize_state(state))
  defp terminal?(_state, _terminal_states), do: false

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
