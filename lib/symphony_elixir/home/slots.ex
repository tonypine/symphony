defmodule SymphonyElixir.Home.Slots do
  @moduledoc """
  The slot entries of the Home read (`slots.entries` of `GET /api/v1/home`,
  `docs/design/prototypes/home-queue/README.md`, section In progress): one entry per slot, in slot
  number order, an empty slot included, each with what its card shows.

  - The slots are numbered from 1 to the slot count. A holder keeps its number when the count is
    lowered (`SymphonyElixir.Dispatch.Slots`), so a number above the count that a ticket still holds
    is an entry too, until the ticket gives the slot up.
  - The holders and their numbers are the ticket records' (`slot_held_since` and `slot_number`); a
    holder stored before slots had numbers gets one as the orchestrator gives it
    (`SymphonyElixir.Dispatch.Slots.number_holders/1`).
  - A slot belongs to the ticket that took it first: a sub-ticket that runs through its ancestor's
    slot, at any depth, shares that slot's number. When tickets run through the slot, the card is
    the one being worked on (a run works on it, else the one that joined the slot last) and the
    owner is its `epic`; otherwise the card is the owner's own and `epic` is nil.
  - A card carries the ticket, its situation (`SymphonyElixir.Situation`) and whether it waits on
    the person with the move it then allows, since when it is in the slot, its stages with the
    tokens of each (`SymphonyElixir.Lifecycle`, without their timings), its tokens against the
    budget, its plan's summary (`SymphonyElixir.TicketPlan`), its checks proved out of total and the
    next open one (`SymphonyElixir.TicketChecks`) and its pull request: number, files, diff size,
    branch, CI and review state. A part the ticket does not have yet is nil.

  Everything is read at the call from the records and the ledgers; the entries carry times, never
  durations, so an unchanged slot reads the same.
  """

  alias SymphonyElixir.{Dispatch, Lifecycle, Situation, TicketChecks, TicketEvents, TicketPlan, TicketPullRequest}
  alias SymphonyElixir.TicketEvents.Event

  @failed ["failed", "cancelled_no_machine"]
  @pending ["running", "waiting"]
  @cancelled ["canceled", "cancelled", "duplicate"]

  @doc """
  The entries over the ticket `records` (normalized, `SymphonyElixir.TicketState`), the
  orchestrator's `live` facts (`SymphonyElixir.Situation.live_facts/2`) and `opts`:

  - `:total`: the slot count;
  - `:parents`: each ticket's parent, by issue id, as its parent's identifier
    (`SymphonyElixir.Dispatch.Queue.parents/1`), for an epic's sub-ticket counts;
  - `:moves`: as `SymphonyElixir.Home.read/4` takes it;
  - `:runs`: the orchestrator's running entries (the snapshot's `running`), whose tokens so far
    count in the stages;
  - `:pull_request`: a function from a record to its pull request read
    (`SymphonyElixirWeb.PullRequestPayload.read/1`); without it no card has one;
  - `:now`: the time the stages are read at.
  """
  @spec entries([map()], Situation.live_facts(), keyword()) :: [map()]
  def entries(records, live, opts) do
    holders = holders(records)
    groups = Enum.group_by(holders, & &1.slot)
    top = groups |> Map.keys() |> Enum.max(fn -> 0 end)
    total = Keyword.fetch!(opts, :total)

    for number <- 1..max(total, top)//1 do
      case Map.get(groups, number) do
        nil -> %{slot: number, empty: true, since: nil, epic: nil, ticket: nil}
        group -> entry(number, group, records, live, opts)
      end
    end
  end

  # Every record that holds a slot, with its number: the stored one, else one given in the order the
  # holders took their slots.
  defp holders(records) do
    held =
      for %{slot_held_since: %DateTime{} = since} = record <- records,
          do: %{record: record, since: since, slot: record.slot_number}

    numbers = held |> Map.new(&{&1.record.issue_id, &1}) |> Dispatch.Slots.number_holders()
    Enum.map(held, &%{&1 | slot: &1.slot || Map.fetch!(numbers, &1.record.issue_id)})
  end

  defp entry(number, group, records, live, opts) do
    [owner | through] =
      Enum.sort_by(group, &{DateTime.to_unix(&1.since, :microsecond), &1.record.issue_identifier || ""})

    card =
      Enum.max_by(
        through,
        &{Map.has_key?(live.running, &1.record.issue_id), DateTime.to_unix(&1.since, :microsecond)},
        fn -> nil end
      )

    %{
      slot: number,
      empty: false,
      since: owner.since,
      epic: card && epic(owner, records, live, opts),
      ticket: card(card || owner, records, live, opts)
    }
  end

  defp epic(%{record: record, since: since}, records, live, opts) do
    terminal = MapSet.new(live.terminal_states, &normalize/1)
    {done, total} = sub_ticket_counts(record, records, terminal, Keyword.get(opts, :parents, %{}))

    %{issue_id: record.issue_id, identifier: record.issue_identifier, title: record.title, repo_key: record.repo_key, since: since, done: done, total: total}
  end

  # The epic's sub-tickets, done and in all, a cancelled one counting in neither: the records it is
  # the parent of, and the sub-issues its record lists that Symphony holds no record of.
  defp sub_ticket_counts(epic, records, terminal, parents) do
    kids = Enum.filter(records, &(Map.get(parents, &1.issue_id) == epic.issue_identifier))
    known = MapSet.new(kids, & &1.issue_id)
    phases = Enum.map(kids, & &1.phase) ++ for(link <- epic.sub_issues, not MapSet.member?(known, link.id), do: link.state)
    phases = phases |> Enum.map(&normalize/1) |> Enum.reject(&(&1 in @cancelled))
    {Enum.count(phases, &MapSet.member?(terminal, &1)), length(phases)}
  end

  defp card(%{record: record, since: since}, records, live, opts) do
    situation = record |> Situation.read(live, records) |> Situation.payload()
    events = record.issue_id |> TicketEvents.query(limit: :all) |> List.wrap() |> Enum.filter(&is_struct(&1, Event))
    %{lifecycle: lifecycle} = lifecycle(events, record, opts)
    plan = TicketPlan.current(events)

    %{
      issue_id: record.issue_id,
      identifier: record.issue_identifier,
      title: record.title,
      repo_key: record.repo_key,
      phase: record.phase,
      situation: situation,
      since: since,
      working: Map.has_key?(live.running, record.issue_id),
      waits_on_you: situation.kind == "waiting_on_you",
      move: SymphonyElixir.Home.move(record, situation, Keyword.get(opts, :moves)),
      stages: Enum.map(lifecycle.stages, &Map.take(&1, [:id, :name, :state, :tokens, :runs])),
      current_stage: lifecycle.current,
      tokens: %{used: lifecycle.tokens.total, budget: lifecycle.tokens.cap},
      plan: plan && %{summary: Map.get(plan, :summary)},
      checks: checks(events),
      pull_request: pull_request(record, Keyword.get(opts, :pull_request))
    }
  end

  defp lifecycle(events, record, opts) do
    running = opts |> Keyword.get(:runs, []) |> Enum.find(&(Map.get(&1, :issue_id) == record.issue_id))
    facts = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> Lifecycle.facts()
    Lifecycle.compute(events, Map.merge(facts, %{running: running, held?: match?(%{pause: %{reasons: _}}, record)}))
  end

  defp checks(events) do
    case TicketChecks.list(events) do
      [] ->
        nil

      checks ->
        next = Enum.find(checks, &(&1.state == :open))

        %{
          proved: Enum.count(checks, &(&1.state == :proved)),
          waived: Enum.count(checks, &(&1.state == :waived)),
          total: length(checks),
          next: next && %{id: next.id, statement: next.statement}
        }
    end
  end

  defp pull_request(record, read) when is_function(read, 1) do
    case read.(record) do
      %{} = pull_request ->
        pull_request
        |> Map.take([:number, :url, :state, :draft, :files_changed, :additions, :deletions, :review_state])
        |> Map.merge(%{branch: branch(record), ci: ci(Map.get(pull_request, :checks, []))})

      nil ->
        nil
    end
  end

  defp pull_request(_record, _read), do: nil

  defp branch(record) do
    case TicketPullRequest.get(record.repo_key, record.issue_id) do
      %{branch: branch} -> branch
      _none -> nil
    end
  end

  # The head's CI in one word, from its checks by workflow: `failed` when one failed, `running` while
  # one has not finished, `passed` when all passed; nil with no check.
  defp ci(workflows) do
    states = for %{checks: checks} <- workflows, %{state: state} <- checks, do: state

    cond do
      states == [] -> nil
      Enum.any?(states, &(&1 in @failed)) -> "failed"
      Enum.any?(states, &(&1 in @pending)) -> "running"
      true -> "passed"
    end
  end

  defp normalize(state), do: state |> to_string() |> String.trim() |> String.downcase()
end
