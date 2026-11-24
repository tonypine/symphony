defmodule SymphonyElixir.Dispatch.Slots do
  @moduledoc """
  The dispatch slots: how many tickets Symphony works at once (`execution.max_concurrent_agents`,
  written `execution.concurrency.max_total` in `symphony.yml`), and which ticket holds each.

  - A slot belongs to a ticket, never to one agent turn: a ticket takes a slot when its first run is
    dispatched and holds it until it is done, whatever its phase (coding, review, QA, CI, a build,
    Merging), between its runs, on a machine step and while it waits on the person. A ticket that
    holds a slot is in progress; that is the only meaning of in progress.
  - A ticket gives up its slot only when it is done (a terminal state), leaves the active states (a
    person moved it to Backlog, or it was removed or unassigned), waits on a dependency (a stored
    dependency, a run's block report, a fix ticket, a competing pull request, an app update carrying
    a dependency's fix: `releases?/2`)
    or on its own sub-tickets, or when a person stops it.
  - No agent turn and no machine step runs for a ticket that holds no slot. A ticket without one
    starts only when a slot is free; one that holds a slot always starts its next run.
  - A free slot goes first to a sub-ticket of a ticket that has started (`first_ids/3`), then to the
    first ticket in the stored queue order (`SymphonyElixir.Dispatch.Queue`) that can start.
  - Nothing else limits the slots: landing has no allowance of its own, no phase has a limit of its
    own, and no slot is reserved for epics.

  The holders are kept on the ticket records (`slot_held_since`, `SymphonyElixir.RunStore`), so a
  restart keeps them; the orchestrator holds its copy and decides with it. Everything else asks
  `held?/1` of the record: the pull request upkeep acts only for a ticket that holds a slot
  (`SymphonyElixir.PrWatch.Repo`), and a ticket without one has its upkeep recorded as a wait for
  a slot, which the orchestrator ends by giving it one when one is free.
  """

  # The phases of a ticket that has not started.
  @unstarted_phases ["todo", "backlog", "triage"]

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

  It does when the ticket is no longer a candidate (terminal, out of the active states,
  unassigned), waits on its sub-tickets, waits on a stored dependency that is not met (the
  `:depends_on` gate, `SymphonyElixir.Dispatch.DependsOn`), waits for an app update that carries a
  dependency's fix, or is paused on another ticket (a run's block report, a fix ticket, a competing pull request) or on a person's
  stop. A stop that comes with a question (the Conductor stops a run whose ticket it asked the
  person about) waits on the person, and keeps the slot. Any other gate (a question, a decision,
  CI, a build, a usage limit, a pause of Symphony or a provider, the priority filter) keeps it too.
  """
  @spec releases?({term(), term(), term()} | nil, [map()]) :: boolean()
  def releases?(nil, _pause_reasons), do: false
  def releases?({_reason, _rule, gate}, _pause_reasons) when gate in [:not_candidate, :sub_tickets, :depends_on, :update_hold], do: true
  def releases?({_reason, :not_assigned, _gate}, _pause_reasons), do: true

  def releases?({_reason, _rule, :paused}, pause_reasons) when is_list(pause_reasons) do
    on_ticket? = Enum.any?(pause_reasons, &match?(%{kind: :ticket}, &1))
    question? = Enum.any?(pause_reasons, &match?(%{kind: :question}, &1))
    on_ticket? or (Enum.any?(pause_reasons, &SymphonyElixir.Pauses.stop_reason?/1) and not question?)
  end

  def releases?(_gate, _pause_reasons), do: false

  @doc """
  The ids of the `issues` that are sub-tickets of a ticket that has started, which a free slot goes
  to first. A ticket has started when it holds a slot (its identifier is in `holder_identifiers`) or
  its phase is past Todo (`facts.phases`, by identifier, from the records). A ticket's parent is its
  issue's, else its record's (`facts.parents`, by issue id).
  """
  @spec first_ids([term()], %{parents: map(), phases: map()} | term(), MapSet.t()) :: MapSet.t()
  def first_ids(issues, %{parents: parents, phases: phases}, %MapSet{} = holder_identifiers) when is_list(issues) do
    for %{id: id} = issue <- issues,
        parent = parent_identifier(issue, parents),
        is_binary(parent),
        MapSet.member?(holder_identifiers, parent) or started_phase?(Map.get(phases, parent)),
        into: MapSet.new(),
        do: id
  end

  def first_ids(_issues, _facts, _holder_identifiers), do: MapSet.new()

  defp parent_identifier(%{parent: %{identifier: identifier}}, _parents) when is_binary(identifier), do: identifier
  defp parent_identifier(%{id: id}, parents), do: Map.get(parents, id)

  defp started_phase?(phase) when is_binary(phase), do: String.downcase(String.trim(phase)) not in @unstarted_phases
  defp started_phase?(_phase), do: false

  @doc """
  The slots the reads report (`slots` of `GET /api/v1/dispatch/order` and `GET /api/v1/home`):
  `total` (the slot count), `used`, `free` and the `holders`, the longest held first. It keeps the
  keys the reads had before (`work_used`, `work_free`, `finishing` and `epic_lanes`, the last two
  empty), so a client that reads them still decodes the payload.
  """
  @spec read(non_neg_integer(), [holder()], map()) :: map()
  def read(total, holders, concurrency) when is_integer(total) and is_list(holders) do
    used = length(holders)
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
