defmodule SymphonyElixir.Dispatch.Slots do
  @moduledoc """
  The dispatch slots: how many tickets Symphony works at once (`execution.max_concurrent_agents`,
  written `execution.concurrency.max_total` in `symphony.yml`), and which ticket holds each.

  - A slot belongs to a ticket, never to one agent turn: a ticket takes a slot when its first run is
    dispatched and holds it until it is done, whatever its phase (coding, review, QA, CI, a build,
    Merging), between its runs, on a machine step, while it waits on the person and while it waits
    on another ticket (its own sub-tickets, a stored dependency, a run's block report, a fix ticket,
    a competing pull request, an app update carrying a dependency's fix). A ticket that holds a slot
    is in progress; that is the only meaning of in progress.
  - A ticket gives up its slot only when it is done (a terminal state), leaves the active states (a
    person moved it to Backlog, or it was removed or unassigned), or when a person stops it without
    a question (`releases?/2`).
  - A ticket's sub-tickets run through its slot, whether or not it has work of its own: a sub-ticket
    whose nearest ancestor in progress holds a slot (`through/3`) starts on that slot, and the
    ticket and its first sub-ticket in progress count as one. Each further sub-ticket in progress at
    the same time takes one extra slot, returned when that sub-ticket is done; the ticket keeps
    exactly one slot between its sub-tickets and through its waits (`used/2`, `cost/3`). A fix ticket
    filed for a ticket in the middle of its work is its sub-ticket, so it runs through that slot too.
  - No agent turn and no machine step runs for a ticket that holds no slot. A ticket without one
    starts only on a free slot or through its ancestor's; one that holds a slot always starts its
    next run.
  - A free slot goes in the stored queue order (`SymphonyElixir.Dispatch.Queue`), where sub-tickets
    sit right after their parent, to the first ticket that can start: for the parent at the top, its
    next sub-ticket whose dependencies are met; when it has none ready, the next ticket down. The
    first ticket of the queue, when it holds no slot and cannot start only because it waits on a
    stored dependency or on its sub-tickets (`waits_in_slot?/1`), takes the free slot with no run and
    waits there; its run starts once the wait is over.
  - Nothing else limits the slots: landing has no allowance of its own, no phase has a limit of its
    own, and no slot is reserved for epics.

  The holders are kept on the ticket records (`slot_held_since`, `SymphonyElixir.RunStore`), so a
  restart keeps them; the orchestrator holds its copy and decides with it. Everything else asks
  `held?/1` of the record: the pull request upkeep acts only for a ticket that holds a slot
  (`SymphonyElixir.PrWatch.Repo`), and a ticket without one has its upkeep recorded as a wait for
  a slot, which the orchestrator ends by giving it one when one is free.
  """

  @typedoc "A slot holder as the reads show it."
  @type holder :: %{
          issue_id: String.t(),
          identifier: String.t() | nil,
          state: String.t() | nil,
          repo_key: String.t() | nil,
          since: DateTime.t() | nil,
          running: boolean()
        }

  @doc """
  Whether the ticket of `record` holds a slot: its record says since when it holds one
  (`slot_held_since`), as the orchestrator writes it when it gives the slot and when it takes it
  back. The one answer every caller outside the orchestrator reads; no record holds none.
  """
  @spec held?(map() | nil) :: boolean()
  def held?(%{slot_held_since: %DateTime{}}), do: true
  def held?(_record), do: false

  @doc """
  Whether a dispatch gate closed on a ticket that holds a slot gives the slot up: the gate's
  `{reason, rule, gate}` (`nil` when every gate is open) and the reasons of the ticket's pause.

  It does only when the ticket is no longer a candidate (terminal, out of the active states,
  unassigned) or a person stopped it. A stop that comes with a question (the Conductor stops a run
  whose ticket it asked the person about) waits on the person, and keeps the slot. Every wait on
  another ticket keeps it too: its sub-tickets, a stored dependency (`:depends_on`,
  `SymphonyElixir.Dispatch.DependsOn`), an app update carrying a dependency's fix, a pause on
  another ticket (a run's block report, a fix ticket, a competing pull request). So does any other
  gate (a question, a decision, CI, a build, a usage limit, a pause of Symphony or a provider, the
  priority filter).
  """
  @spec releases?({term(), term(), term()} | nil, [map()]) :: boolean()
  def releases?(nil, _pause_reasons), do: false
  def releases?({_reason, _rule, :not_candidate}, _pause_reasons), do: true
  def releases?({_reason, :not_assigned, _gate}, _pause_reasons), do: true

  def releases?({_reason, _rule, :paused}, pause_reasons) when is_list(pause_reasons) do
    Enum.any?(pause_reasons, &SymphonyElixir.Pauses.stop_reason?/1) and not Enum.any?(pause_reasons, &match?(%{kind: :question}, &1))
  end

  def releases?(_gate, _pause_reasons), do: false

  @doc """
  Whether the gate a ticket without a slot is held by lets it take the free slot with no run and
  wait there when it is the first of the queue: it waits on a stored dependency or on its own
  sub-tickets.
  """
  @spec waits_in_slot?({term(), term(), term()} | nil) :: boolean()
  def waits_in_slot?({_reason, nil, gate}) when gate in [:depends_on, :sub_tickets], do: true
  def waits_in_slot?(_gate), do: false

  @doc """
  The ticket `issue_id` runs through: its nearest ancestor that is `in_progress` (holds a slot or
  has a run), from `parents` (issue id to its parent's issue id); nil when none is. A ticket in a
  parent cycle has no ancestors.
  """
  @spec through(String.t(), MapSet.t(), %{String.t() => String.t()}) :: String.t() | nil
  def through(issue_id, %MapSet{} = in_progress, parents) when is_map(parents) do
    issue_id |> ancestors(parents) |> Enum.find(&MapSet.member?(in_progress, &1))
  end

  # The ids from the ticket's parent up to its top-level ancestor; none when the walk meets a cycle.
  defp ancestors(issue_id, parents), do: ancestors(issue_id, parents, [issue_id], [])

  defp ancestors(issue_id, parents, seen, acc) do
    case Map.get(parents, issue_id) do
      nil -> Enum.reverse(acc)
      parent -> if parent in seen, do: [], else: ancestors(parent, parents, [parent | seen], [parent | acc])
    end
  end

  @doc """
  The slots the tickets `in_progress` use, with `parents` (issue id to its parent's issue id): a
  ticket that runs through an ancestor's slot (`through/3`) adds none for the first of them, so each
  ticket in progress with no other running through it uses one. A parent and its one sub-ticket in
  progress use one slot; two sub-tickets in progress at once use two.
  """
  @spec used(Enumerable.t(), %{String.t() => String.t()}) :: non_neg_integer()
  def used(in_progress, parents) when is_map(parents) do
    set = MapSet.new(in_progress)
    throughs = for id <- set, through = through(id, set, parents), into: MapSet.new(), do: through
    Enum.count(set, &(not MapSet.member?(throughs, &1)))
  end

  @doc """
  The slots `issue_id` would add to the ones the tickets `in_progress` use (`used/2`) if it started
  now: 0 when it is in progress already, or runs through an ancestor's slot no other sub-ticket uses;
  1 otherwise.
  """
  @spec cost(String.t(), Enumerable.t(), %{String.t() => String.t()}) :: non_neg_integer()
  def cost(issue_id, in_progress, parents) when is_map(parents) do
    set = MapSet.new(in_progress)
    if MapSet.member?(set, issue_id), do: 0, else: max(used(MapSet.put(set, issue_id), parents) - used(set, parents), 0)
  end

  @doc """
  The slots the reads report (`slots` of `GET /api/v1/dispatch/order` and `GET /api/v1/home`):
  `total` (the slot count), `used` (`used/2`: a parent and the sub-ticket running through its slot
  use one; one per holder when not given), `free` and the `holders`, the longest held first. It
  keeps the keys the reads had before (`work_used`, `work_free`, `finishing` and `epic_lanes`, the
  last two empty), so a client that reads them still decodes the payload.
  """
  @spec read(non_neg_integer(), [holder()], map(), non_neg_integer() | nil) :: map()
  def read(total, holders, concurrency, used \\ nil) when is_integer(total) and is_list(holders) do
    used = used || length(holders)
    free = max(total - used, 0)

    %{
      total: total,
      used: used,
      free: free,
      holders: Enum.sort_by(holders, &{since_key(&1.since), &1.identifier || &1.issue_id}),
      concurrency: concurrency,
      work_used: used,
      work_free: free,
      finishing: %{slots: 0, used: 0, running: []},
      epic_lanes: %{max_total: nil, lanes: [], queued_epics: [], shared: %{slots: nil, used: used}}
    }
  end

  defp since_key(%DateTime{} = at), do: {0, DateTime.to_unix(at, :microsecond)}
  defp since_key(_none), do: {1, 0}

  @doc "The issue ids of the holders in a `read/3` (nil before the first walk), as a map of id to true: the tickets in progress."
  @spec holder_ids(map() | nil) :: %{optional(term()) => true}
  def holder_ids(%{holders: holders}) when is_list(holders), do: Map.new(holders, &{&1.issue_id, true})
  def holder_ids(_slots), do: %{}
end
