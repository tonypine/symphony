defmodule SymphonyElixir.Initiatives.Initiative do
  @moduledoc """
  One parent Symphony split, followed to done, for the Mac app's Initiatives
  (`GET /api/v1/initiatives`).

  `from_record/3` reads it from Symphony's own records: its group (`active`, `in_review` or `done`,
  from its record's phase), when Symphony split it and when it finished, and its sub-tickets (the
  records under it and the links its record lists, `SymphonyElixir.Home.SubTickets`), each with
  when it landed (the time its record entered a terminal phase). A done sub-ticket stays under its
  parent; a cancelled one is left out. `live/2` adds, from what Symphony knows at GET time, the
  tickets each sub-ticket depends on (its stored dependencies, `depends_on`, each open while
  `SymphonyElixir.Dispatch.DependsOn.open/2` finds it unmet), the landing order and what each open
  sub-ticket waits on (the running tickets, the Inbox), so a read never asks Linear:

  - `done`: the sub-ticket is completed;
  - `working`: an agent, QA pass or landing runs it;
  - `you`: it waits on the Director (an Inbox item, `Plan Review`, or Backlog: not promoted yet);
  - `blocker`: an open sub-ticket or ticket it depends on;
  - `ci`: a machine-owned phase (Code Review, QA, Merging, CI Fix) with nothing running yet;
  - `slot`: it can run and waits for a free slot.

  Landing order is dependency order between the sub-tickets, then creation order. `incomplete` is
  always false: the records hold every sub-ticket.
  """

  alias SymphonyElixir.Dispatch.DependsOn
  alias SymphonyElixir.{PlanReview, RunStore, TicketState}

  @machine_states MapSet.new(["code review", "qa", "merging", "ci fix", "epic review"])
  @stages ~w(done working you queued blocked)

  @type sub_ticket :: %{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          state: String.t() | nil,
          state_type: String.t() | nil,
          created_at: String.t() | nil,
          completed_at: String.t() | nil,
          blocked_by: [blocker()]
        }

  @type blocker :: %{
          identifier: String.t() | nil,
          state: String.t() | nil,
          open: boolean(),
          completed_at: String.t() | nil
        }

  @type t :: %{
          id: String.t(),
          identifier: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          state: String.t() | nil,
          repo_key: String.t(),
          group: String.t(),
          started_at: String.t() | nil,
          completed_at: String.t() | nil,
          sub_tickets: [sub_ticket()],
          incomplete: boolean()
        }

  @typedoc """
  What Symphony knows locally at GET time: running and waiting-on-you issue ids, the human-gated
  states, and optionally each ticket's stored dependencies with the record of the ticket each names
  (`:dependencies`, default `SymphonyElixir.RunStore.dependencies/1`).
  """
  @type live :: %{
          required(:running) => MapSet.t(String.t()),
          required(:you) => MapSet.t(String.t()),
          required(:settings) => term(),
          optional(:dependencies) => (String.t() | nil -> [{TicketState.dependency(), map() | nil}])
        }

  @doc "The stages counted on each initiative, in the bar's order."
  @spec stages() :: [String.t()]
  def stages, do: @stages

  @doc """
  The initiative of the parent `record` (a normalized ticket record, `SymphonyElixir.TicketState`)
  Symphony split, over its `subs` (`SymphonyElixir.Home.SubTickets.of/2`: the records under it and
  the links of those Symphony holds no record of, a cancelled one left out), or nil for one outside
  the three groups (in Backlog or Triage, cancelled, or done more than 7 days before `now`).
  `context` gives the repo's `settings` (the review and terminal states), `now` and `started_at`,
  when Symphony split it.
  """
  @spec from_record(
          map(),
          %{records: [map()], links: [map()]},
          %{settings: term(), now: DateTime.t(), started_at: DateTime.t() | nil}
        ) :: t() | nil
  def from_record(%{issue_id: id} = record, %{records: records, links: links}, %{settings: settings, now: %DateTime{} = now} = context)
      when is_binary(id) do
    terminal = terminal(settings)

    case group(record, terminal, settings, now) do
      nil ->
        nil

      group ->
        children = Enum.map(records, &record_sub_ticket(&1, terminal)) ++ Enum.map(links, &link_sub_ticket(&1, terminal))

        %{
          id: id,
          identifier: record.issue_identifier,
          title: record.title,
          url: record.url,
          state: record.phase,
          repo_key: record.repo_key,
          group: group,
          started_at: iso8601(context.started_at),
          completed_at: if(group == "done", do: iso8601(record.phase_at)),
          sub_tickets: landing_order(children),
          incomplete: false
        }
    end
  end

  def from_record(_record, _subs, _context), do: nil

  @recent_days 7
  @cancelled ["canceled", "cancelled", "duplicate"]
  @default_terminal ["closed", "cancelled", "canceled", "duplicate", "done"]

  defp group(record, terminal, settings, now) do
    case state_type(record.phase, terminal) do
      "completed" -> if recent?(record.phase_at, now), do: "done"
      type when type in ["canceled", "backlog"] -> nil
      _type -> if in_review?(record.phase, settings), do: "in_review", else: "active"
    end
  end

  # The kind of state a phase is: `canceled`, `completed` (terminal, not cancelled), `backlog`
  # (Backlog or Triage: not promoted yet) or `started`.
  defp state_type(phase, terminal) do
    name = normalize(phase)

    cond do
      name in @cancelled -> "canceled"
      MapSet.member?(terminal, name) -> "completed"
      name in ["backlog", "triage"] -> "backlog"
      true -> "started"
    end
  end

  defp terminal(settings) do
    states =
      case settings do
        %{tracker: %{terminal_states: [_ | _] = states}} -> states
        _settings -> @default_terminal
      end

    MapSet.new(states, &normalize/1)
  end

  defp recent?(%DateTime{} = at, now), do: DateTime.diff(now, at, :second) <= @recent_days * 86_400
  defp recent?(_at, _now), do: false

  defp in_review?(state, settings) do
    PlanReview.in_state?(state, settings) or normalize(state) == "epic review"
  end

  defp record_sub_ticket(record, terminal) do
    type = state_type(record.phase, terminal)

    %{
      id: record.issue_id,
      identifier: record.issue_identifier,
      title: record.title,
      url: record.url,
      state: record.phase,
      state_type: type,
      created_at: iso8601(record.created_at),
      completed_at: if(type == "completed", do: iso8601(record.phase_at)),
      blocked_by: []
    }
  end

  defp link_sub_ticket(link, terminal) do
    %{
      id: link.id,
      identifier: link.identifier,
      title: nil,
      url: nil,
      state: link.state,
      state_type: state_type(link.state, terminal),
      created_at: nil,
      completed_at: nil,
      blocked_by: []
    }
  end

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_at), do: nil

  # The tickets the sub-ticket `id` depends on, as Symphony stores them, each with the phase its
  # record holds, whether it is still open and when it was done.
  defp blockers(id, dependencies) do
    entries = dependencies.(id)
    records = for {entry, %{} = record} <- entries, into: %{}, do: {entry.issue_id, record}
    open = entries |> Enum.map(&elem(&1, 0)) |> DependsOn.open(records)

    for {entry, record} <- entries do
      record = if record, do: TicketState.normalize(record)
      open? = entry in open

      %{
        identifier: entry.identifier || (record && record.issue_identifier),
        state: record && record.phase,
        open: open?,
        # A dependency is open while Symphony holds no record of it, so a met one has a record.
        completed_at: if(not open?, do: record.phase_at && DateTime.to_iso8601(record.phase_at))
      }
    end
  end

  defp stored_dependencies(id) do
    for {%{} = _entry, _record} = dependency <- List.wrap(RunStore.dependencies(id)), do: dependency
  end

  # Kahn's walk over the stored dependencies between siblings, taking the oldest ready ticket each step.
  # A cycle is broken by creation order.
  defp landing_order(parts) do
    parts = Enum.sort_by(parts, &{&1.created_at || "", &1.identifier || ""})
    siblings = MapSet.new(parts, & &1.identifier)

    deps =
      Map.new(parts, fn part ->
        {part.identifier, part.blocked_by |> Enum.map(& &1.identifier) |> Enum.filter(&MapSet.member?(siblings, &1)) |> MapSet.new()}
      end)

    walk(parts, deps, [])
  end

  defp walk([], _deps, acc), do: Enum.reverse(acc)

  defp walk(remaining, deps, acc) do
    next = Enum.find(remaining, &MapSet.equal?(deps[&1.identifier], MapSet.new())) || hd(remaining)
    deps = Map.new(deps, fn {identifier, blockers} -> {identifier, MapSet.delete(blockers, next.identifier)} end)
    walk(List.delete(remaining, next), deps, [next | acc])
  end

  @doc """
  The initiative with what each sub-ticket waits on, the counts by stage and the waiting-on-you headline, from what Symphony knows locally.
  """
  @spec live(t(), live()) :: map()
  def live(initiative, live) do
    dependencies = Map.get(live, :dependencies, &stored_dependencies/1)

    sub_tickets =
      initiative.sub_tickets
      |> Enum.map(&Map.put(&1, :blocked_by, blockers(&1.id, dependencies)))
      |> landing_order()
      |> Enum.map(&with_wait(&1, live))

    counts = Map.new(@stages, &{&1, 0})
    counts = Enum.reduce(sub_tickets, counts, &Map.update!(&2, stage(&1.waits_on), fn count -> count + 1 end))

    initiative
    |> Map.merge(%{sub_tickets: sub_tickets, counts: Map.put(counts, "total", length(sub_tickets))})
  end

  defp with_wait(sub_ticket, live) do
    open_blockers = for %{open: true, identifier: identifier} <- sub_ticket.blocked_by, do: identifier
    waits_on = waits_on(sub_ticket, open_blockers, live)

    sub_ticket
    |> Map.put(:waits_on, waits_on)
    |> Map.put(:waiting_for, if(waits_on == "blocker", do: open_blockers, else: []))
  end

  defp waits_on(%{state_type: "completed"}, _open_blockers, _live), do: "done"

  defp waits_on(%{id: id, state: state, state_type: type}, open_blockers, live) do
    cond do
      MapSet.member?(live.running, id) -> "working"
      MapSet.member?(live.you, id) or type == "backlog" -> "you"
      PlanReview.in_state?(state, live.settings) -> "you"
      open_blockers != [] -> "blocker"
      MapSet.member?(@machine_states, normalize(state)) -> "ci"
      true -> "slot"
    end
  end

  defp stage("done"), do: "done"
  defp stage(working) when working in ["working", "ci"], do: "working"
  defp stage("you"), do: "you"
  defp stage("blocker"), do: "blocked"
  defp stage("slot"), do: "queued"

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: nil
end
