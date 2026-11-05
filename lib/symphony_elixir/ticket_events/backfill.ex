defmodule SymphonyElixir.TicketEvents.Backfill do
  @moduledoc """
  Converts each ticket's history from before the event stream existed (`SymphonyElixir.TicketEvents`)
  into events, once, from its snapshot (`SymphonyElixir.TicketState`) and the audit log.

  For every ticket record of every repo, the backfill converts the `signals`, `verdicts` and
  `dispatches` the snapshot kept (`SymphonyElixir.TicketState.legacy_history/1`), and the last 14
  days of `run_stopped` and `director_move` audit records, into the events the live writes record
  for them, so the record's views over its events (`SymphonyElixir.TicketState.signals/1`,
  `verdicts/1`, `dispatches/1`) read what the snapshot held:

    * A signal goes through `SymphonyElixir.TicketSignals.signal_event/2`, the live mapping, with
      its name and details. A signal live writes record next to a pause or a question (a
      held `blocked`, `dispatch_loop`, `ci_wait`, a held `handoff_missing`, `unblocked`, a
      `decision requested`, a review's merge confirmation or escalation, a Decide that moved
      nothing) is a machine `note` naming it, as live; the pauses and questions record their own
      events (`SymphonyElixir.Pauses.Backfill`).
    * A verdict is `verdict.recorded` with its details, a dispatch `run.started` and, once it
      ended, `run.ended`.
    * A stop is the Director's `person.action` `stop`, and an Inbox move the action that names it, as
      the live writes record them; a Decide is none.

  Only entries older than the ticket's first live event (its earliest event the backfill did not
  write) are converted, so a signal already dual-written is not recorded twice; a ticket with no
  live event converts everything. Each event's idempotency key is `backfill:<source>:<hash>` and
  its `at` the entry's own timestamp.

  Each entry of `decisions` is the Director's `decision.recorded`, keyed `decision.recorded:<key>`
  as an answer recorded before the Questions was, so an answer already recorded is never recorded
  twice, and a ticket's history shows every decision it holds. It names no request: requests from
  before the event stream were never events.

  Each ticket's events are appended oldest first in one transaction
  (`SymphonyElixir.RunStore.append_ticket_events/1`), ending with one `note`: "History before <date>
  was backfilled from the ticket's snapshot", where <date> is the cutoff. A ticket already holding
  that note is done. The whole backfill runs once: the run store marker `ticket_events_backfill_v1`
  is set when every ticket is done.

  A record still carrying the snapshot's fields is reconciled against its events before they are
  dropped (`legacy_history: nil`), on every run, marker or not: an earlier release set the marker
  and kept the fields, having written a signal's note with no `signal`, a signal a pause or a
  question mirrored as no event at all, every other signal with no `signal_details` and a verdict
  with no `details`. Each entry, oldest first, claims the event closest in time that says it (the
  live mapping knows what it was written as):

    * An event that lacks the entry's `signal`, `signal_details` or `details` gets them added in
      place (`SymphonyElixir.RunStore.upgrade_ticket_events/2`), and nothing else about it changes.
      An appended correction would read as a second signal, or a second verdict.
    * An entry no event says is appended, keyed `backfill:reconciled:<source>:<hash>` at its own
      time: a signal as a machine `note` naming it, a verdict as its `verdict.recorded`.
    * A second handoff of one head reads as the one attempt the first claimed, as it does when
      converted.

  A record whose reconcile fails keeps its fields for the next start.
  """

  require Logger

  alias SymphonyElixir.{AuditLog, RunStore, TicketEvents, TicketSignals, TicketState}
  alias SymphonyElixir.TicketEvents.Event

  @marker "ticket_events_backfill_v1"
  @prefix "backfill:"
  @note_key "backfill:note:history"
  @audit_days 14
  @audit_types ["run_stopped", "director_move"]
  @director {:person, "the Director"}

  @typedoc "How many tickets the run backfilled and how many events it wrote."
  @type outcome :: %{tickets: non_neg_integer(), events: non_neg_integer()}

  @typedoc """
  `run/1`'s options: `now:` (default the current time), `audit_log:` (the `SymphonyElixir.AuditLog`
  options its reads take, such as `dir:`) and `store:` (default `SymphonyElixir.RunStore`).
  """
  @type opt :: {:now, DateTime.t()} | {:audit_log, keyword()} | {:store, module()}

  @doc "The run store marker the backfill sets once it is done."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Starts `run/1` in a task under `SymphonyElixir.TaskSupervisor`, so the caller (the orchestrator's
  startup) never waits for it; a run that fails is logged. Does nothing when the
  `:ticket_events_backfill` application setting is false (`enabled:` overrides it). `run:` replaces
  the function the task runs and `supervisor:` the task supervisor, for tests; the rest of `opts`
  goes to the run.
  """
  @spec start(keyword()) :: {:ok, pid()} | :disabled | {:error, term()}
  def start(opts \\ []) do
    if Keyword.get(opts, :enabled, Application.get_env(:symphony_elixir, :ticket_events_backfill, true)) do
      run = Keyword.get(opts, :run, &run/1)
      Task.Supervisor.start_child(Keyword.get(opts, :supervisor, SymphonyElixir.TaskSupervisor), fn -> log(run.(opts)) end)
    else
      :disabled
    end
  catch
    :exit, reason ->
      Logger.warning("Failed to start the ticket events backfill: #{inspect(reason)}")
      {:error, reason}
  end

  @doc """
  Backfills every ticket record once (see the module doc): the tickets backfilled and the events
  written, or the first error. A run after the marker is set converts nothing and only reconciles
  a record still carrying its fields. A ticket whose events can't be read or written is logged and
  left for the next run, which leaves the marker unset.
  """
  @spec run([opt()]) :: {:ok, outcome()} | {:error, term()}
  def run(opts) do
    store = Keyword.get(opts, :store, RunStore)

    case store.get_marker(@marker) do
      %DateTime{} -> reconcile_converted(store)
      nil -> backfill(store, Keyword.get(opts, :now) || DateTime.utc_now(), opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp backfill(store, now, opts) do
    with {:ok, records} <- read(store.list_all_ticket_states()),
         {:ok, audit} <- audit_records(now, Keyword.get(opts, :audit_log, [])) do
      results =
        for record <- Enum.map(records, &TicketState.normalize/1), is_binary(record.repo_key) and is_binary(record.issue_id) do
          backfill_ticket(store, record, Map.get(audit, record.issue_id, []), now)
        end

      finish(store, results, now)
    end
  end

  # After the marker every ticket was converted: only a record still carrying its fields is left.
  defp reconcile_converted(store) do
    with {:ok, records} <- read(store.list_all_ticket_states()) do
      results =
        for record <- Enum.map(records, &TicketState.normalize/1), is_binary(record.repo_key) and is_binary(record.issue_id) do
          store |> reconcile(record) |> logged(record)
        end

      outcome(results)
    end
  end

  defp drop_history(store, record) do
    case store.update_ticket_state(record.issue_id, %{legacy_history: nil}) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to drop the converted history of issue_id=#{record.issue_id}: #{inspect(reason)}")
    end
  end

  defp finish(store, results, now) do
    with {:ok, outcome} <- outcome(results),
         :ok <- store.put_marker(@marker, now),
         do: {:ok, outcome}
  end

  defp outcome(results) do
    case Enum.count(results, &match?({:error, _reason}, &1)) do
      0 ->
        counts = for {:ok, count} <- results, do: count
        {:ok, %{tickets: Enum.count(counts, &(&1 > 0)), events: Enum.sum(counts)}}

      failed ->
        {:error, {:tickets_failed, failed}}
    end
  end

  defp log({:ok, %{tickets: tickets, events: events}}) do
    if tickets > 0, do: Logger.info("Backfilled #{events} ticket event(s) on #{tickets} ticket(s) from their snapshots")
  end

  defp log({:error, reason}), do: Logger.warning("Failed to backfill ticket events: #{inspect(reason)}")

  defp read(records) when is_list(records), do: {:ok, records}
  defp read({:error, _reason} = error), do: error

  # The stops and Inbox moves of the last 14 days, by issue id.
  defp audit_records(now, audit_opts) do
    since = DateTime.add(now, -@audit_days * 86_400, :second)
    range = [from: DateTime.to_date(since), to: DateTime.to_date(now), since: since]

    Enum.reduce_while(@audit_types, {:ok, %{}}, fn type, {:ok, acc} ->
      case AuditLog.query(audit_opts ++ range ++ [event_type: type]) do
        {:ok, stream} -> {:cont, {:ok, Enum.reduce(stream, acc, &group_audit/2)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp group_audit(%{"issue_id" => issue_id} = record, acc) when is_binary(issue_id), do: Map.update(acc, issue_id, [record], &[record | &1])
  defp group_audit(_record, acc), do: acc

  defp backfill_ticket(store, record, audit, now) do
    result =
      with {:ok, existing} <- read(store.list_ticket_events(record.issue_id, [])),
           {:ok, converted} <- convert(store, record, existing, audit, now),
           {:ok, reconciled} <- reconcile(store, record) do
        {:ok, converted + reconciled}
      end

    logged(result, record)
  end

  defp convert(store, record, existing, audit, now) do
    if Enum.any?(existing, &(&1.idempotency == @note_key)), do: {:ok, 0}, else: append(store, record, existing, audit, now)
  end

  defp logged({:error, reason} = error, record) do
    Logger.warning("Failed to backfill the ticket events of issue_id=#{record.issue_id}: #{inspect(reason)}")
    error
  end

  defp logged(result, _record), do: result

  defp append(store, record, existing, audit, now) do
    cutoff = existing |> Enum.find(&(not backfilled?(&1))) |> live_cutoff()
    history = record |> entries(audit) |> Enum.filter(&(DateTime.compare(&1.at, cutoff || now) == :lt)) |> Enum.sort_by(& &1.at, DateTime)
    built = build(record, history)

    events =
      (built ++ decisions(record, now))
      |> Enum.sort_by(& &1.at, DateTime)
      |> Kernel.++(note(record, cutoff, now))

    written(store, events)
  end

  defp written(store, events) do
    with {:ok, stored} <- store.append_ticket_events(events) do
      ids = MapSet.new(events, & &1.id)
      {:ok, Enum.count(stored, &MapSet.member?(ids, &1.id))}
    end
  end

  # Brings the events in line with what the record's fields held, then drops the fields (see the
  # module doc): how many events it added or upgraded.
  defp reconcile(_store, %{legacy_history: nil}), do: {:ok, 0}

  defp reconcile(store, record) do
    with {:ok, existing} <- read(store.list_ticket_events(record.issue_id, [])),
         plan = reconcile_plan(TicketState.legacy_history(record), existing),
         {:ok, appended} <- written(store, build(record, Enum.sort_by(plan.missing, & &1.at, DateTime))),
         :ok <- store.upgrade_ticket_events(record.issue_id, plan.upgrades) do
      drop_history(store, record)
      {:ok, appended + map_size(plan.upgrades)}
    end
  end

  defp reconcile_plan(history, existing) do
    # An agent's own note never records a signal.
    unclaimed = Enum.reject(existing, &(&1.actor.kind == :agent))
    plan = %{unclaimed: unclaimed, upgrades: %{}, missing: []}
    plan = history.signals |> timed(:at) |> Enum.reduce(plan, &reconcile_signal/2)
    history.verdicts |> timed(:recorded_at) |> Enum.reduce(plan, &reconcile_verdict/2)
  end

  defp timed(entries, field) do
    entries
    |> Enum.filter(&match?(%DateTime{}, Map.fetch!(&1, field)))
    |> Enum.sort_by(&Map.fetch!(&1, field), DateTime)
  end

  defp reconcile_signal(signal, plan) do
    {_type, payload, _opts} = mapping = TicketSignals.signal_event(signal.name, signal.details)
    missing = fn -> entry(signal.at, "reconciled:signal", signal, TicketSignals.signal_note(signal.name, signal.details)) end
    reconcile_entry(plan, signal.at, mapping, Map.take(payload, [:signal, :signal_details]), missing)
  end

  defp reconcile_verdict(verdict, plan) do
    {_type, payload, _opts} = mapping = TicketSignals.verdict_event(verdict.kind, verdict.outcome, verdict.head_sha, details: verdict.details)
    missing = fn -> entry(verdict.recorded_at, "reconciled:verdict", verdict, mapping) end
    reconcile_entry(plan, verdict.recorded_at, mapping, Map.take(payload, [:details]), missing)
  end

  defp reconcile_entry(plan, at, {type, _payload, _opts} = mapping, fields, missing) do
    says = identity(mapping)

    case plan.unclaimed |> Enum.filter(&says?(&1, type, says)) |> Enum.min_by(&abs(DateTime.diff(&1.at, at, :microsecond)), fn -> nil end) do
      nil -> %{plan | missing: [missing.() | plan.missing]}
      event -> plan |> claim(event, type) |> upgrade(event, fields)
    end
  end

  # What an event of this mapping says whichever release wrote it: a note's text, the head of a
  # push, and otherwise everything but the details, its `signal` or the lack of one included.
  defp identity({"note", payload, _opts}), do: Map.take(payload, [:text])
  defp identity({"attempt.pushed", payload, _opts}), do: Map.take(payload, [:head])
  defp identity({_type, payload, _opts}), do: payload |> Map.drop([:signal_details, :details]) |> Map.put_new(:signal, nil)

  defp says?(%Event{type: type, at: %DateTime{}, payload: payload}, type, says), do: Enum.all?(says, fn {key, value} -> Map.get(payload, key) == value end)
  defp says?(_event, _type, _says), do: false

  # One attempt stands for every handoff of its head; any other event for one entry.
  defp claim(plan, _event, "attempt.pushed"), do: plan
  defp claim(plan, event, _type), do: %{plan | unclaimed: List.delete(plan.unclaimed, event)}

  defp upgrade(plan, event, fields) do
    case Map.drop(fields, Map.keys(event.payload)) do
      fields when map_size(fields) == 0 -> plan
      fields -> %{plan | upgrades: Map.put_new(plan.upgrades, event.seq, fields)}
    end
  end

  defp backfilled?(%Event{idempotency: key}), do: is_binary(key) and String.starts_with?(key, @prefix)

  defp live_cutoff(%Event{at: at}), do: at
  defp live_cutoff(nil), do: nil

  # The snapshot's entries as `%{at, source, hash, mapping}`, each mapping an event's type, payload
  # and options (or nil for an entry that is no event), the ones without a timestamp left out.
  defp entries(record, audit) do
    history = TicketState.legacy_history(record)
    signals = for signal <- history.signals, do: entry(signal.at, "signal", signal, TicketSignals.signal_event(signal.name, signal.details))

    verdicts =
      for verdict <- history.verdicts do
        entry(verdict.recorded_at, "verdict", verdict, TicketSignals.verdict_event(verdict.kind, verdict.outcome, verdict.head_sha, details: verdict.details))
      end

    dispatches = Enum.flat_map(history.dispatches, &dispatch_entries/1)

    moves =
      for move <- audit, matches_repo?(move, record.repo_key) do
        entry(audit_at(move), "audit", move, audit_mapping(move))
      end

    Enum.filter(signals ++ verdicts ++ dispatches ++ moves, &(match?(%DateTime{}, &1.at) and &1.mapping != nil))
  end

  defp entry(at, source, term, mapping), do: %{at: at, source: source, hash: hash(term), mapping: mapping}

  defp dispatch_entries(%{run_id: run_id} = dispatch) when is_binary(run_id) do
    started = {"run.started", compact(%{run_id: run_id, run_kind: dispatch.kind, state: dispatch.state, head: dispatch.head}), compact_opts(phase: dispatch.state, run_id: run_id)}
    [entry(dispatch.at, "dispatch", {:started, dispatch}, started) | ended_entries(dispatch)]
  end

  defp dispatch_entries(_dispatch), do: []

  defp ended_entries(%{outcome: %{} = outcome} = dispatch) do
    payload = %{
      run_id: dispatch.run_id,
      run_kind: dispatch.kind,
      exit: blank_to_nil(outcome.exit) || "ended",
      head: outcome.head,
      duration_ms: duration_ms(dispatch.at, outcome.at)
    }

    [entry(outcome.at, "dispatch", {:ended, dispatch}, {"run.ended", compact(payload), run_id: dispatch.run_id})]
  end

  defp ended_entries(_dispatch), do: []

  defp duration_ms(%DateTime{} = started, %DateTime{} = ended), do: max(DateTime.diff(ended, started, :millisecond), 0)
  defp duration_ms(_started, _ended), do: nil

  # As the live writes record them: a Decide is its `decision.recorded`, a stop, an unblock and a
  # restart are themselves, and any other move is `move` naming it.
  defp audit_mapping(%{"event_type" => "run_stopped"}), do: {"person.action", %{action: "stop"}, actor: @director}
  defp audit_mapping(%{"event_type" => "director_move", "move" => "decide"}), do: nil

  defp audit_mapping(%{"event_type" => "director_move"} = move) do
    name = move["move"]
    action = if name in ["unblock", "restart"], do: %{action: name}, else: %{action: "move", move: name}
    {"person.action", compact(Map.merge(action, %{from: move["from_state"], to: move["to_state"]})), actor: @director}
  end

  defp matches_repo?(move, repo_key), do: move["repo_key"] in [nil, repo_key]

  # The audit query's `since:` keeps only records whose timestamp parses.
  defp audit_at(%{"timestamp" => timestamp}) do
    {:ok, at, _offset} = DateTime.from_iso8601(timestamp)
    at
  end

  # Builds the entries' events oldest first, numbering runs and attempts as the live writes do and
  # carrying the phase the last `phase.entered` named onto the events that name none.
  defp build(record, entries) do
    {events, _acc} = Enum.flat_map_reduce(entries, %{phase: nil, kinds: %{}, runs: %{}, heads: MapSet.new()}, &build_entry(record, &1, &2))
    events
  end

  defp build_entry(record, %{mapping: {type, payload, opts}} = entry, acc) do
    case number(type, payload, acc) do
      :skip ->
        {[], acc}

      {payload, acc} ->
        phase = Keyword.get(opts, :phase) || acc.phase
        acc = if type == "phase.entered", do: %{acc | phase: payload.to}, else: acc
        opts = Keyword.merge(opts, at: entry.at, phase: phase, idempotency: "#{@prefix}#{entry.source}:#{entry.hash}")
        {built(record, type, payload, opts), acc}
    end
  end

  defp number("run.started", payload, acc) do
    run_number = Map.get(acc.kinds, payload.run_kind, 0) + 1
    acc = %{acc | kinds: Map.put(acc.kinds, payload.run_kind, run_number), runs: Map.put(acc.runs, payload.run_id, run_number)}
    {Map.put(payload, :run_number, run_number), acc}
  end

  defp number("run.ended", payload, acc), do: {compact(Map.put(payload, :run_number, acc.runs[payload.run_id])), acc}

  # A second handoff of one head is the same push, as the live key makes it.
  defp number("attempt.pushed", payload, acc) do
    if MapSet.member?(acc.heads, payload.head) do
      :skip
    else
      heads = MapSet.put(acc.heads, payload.head)
      {Map.put(payload, :attempt, MapSet.size(heads)), %{acc | heads: heads}}
    end
  end

  defp number(_type, payload, acc), do: {payload, acc}

  defp built(record, type, payload, opts) do
    case TicketEvents.build(record.repo_key, record.issue_id, type, payload, opts) do
      {:ok, event} ->
        [event]

      {:error, reason} ->
        Logger.warning("Skipped a backfilled #{type} event on issue_id=#{record.issue_id}: #{inspect(reason)}")
        []
    end
  end

  defp decisions(record, now) do
    Enum.flat_map(record.decisions, fn decision ->
      payload = compact(%{answer: decision.answer, title: decision.title, question: decision.question, key: decision.key})
      built(record, "decision.recorded", payload, actor: @director, at: decision_at(decision.date) || record.updated_at || now)
    end)
  end

  defp decision_at(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp decision_at(_date), do: nil

  defp note(record, cutoff, now) do
    at = if cutoff, do: DateTime.add(cutoff, -1, :microsecond), else: now
    text = "History before #{Calendar.strftime(cutoff || now, "%Y-%m-%d %H:%M UTC")} was backfilled from the ticket's snapshot"
    built(record, "note", %{text: text}, at: at, idempotency: @note_key)
  end

  defp hash(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)

  defp compact(payload), do: payload |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  defp compact_opts(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
end
