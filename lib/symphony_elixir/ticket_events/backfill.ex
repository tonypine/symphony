defmodule SymphonyElixir.TicketEvents.Backfill do
  @moduledoc """
  Converts each ticket's history from before the event stream existed (`SymphonyElixir.TicketEvents`)
  into events, once, from its snapshot (`SymphonyElixir.TicketState`) and the audit log.

  For every ticket record of every repo, the backfill converts the snapshot's `signals`, `verdicts`
  and `dispatches`, and the last 14 days of `run_stopped` and `director_move` audit records, into the
  events the live writes record for them:

    * A signal goes through `SymphonyElixir.TicketSignals.event/2`, the live mapping. The snapshot
      keeps no hold history, so a signal live writes leave to its hold write becomes the event that
      write records: a held `blocked`, `dispatch_loop`, `ci_wait` or held `handoff_missing` is
      `hold.set` (kind blocked), and `unblocked` is `hold.cleared`. A `decision requested` signal and
      a review's merge confirmation or escalation are a machine `note` ("Decision requested: …"):
      they carry no question and can't be paired with their answers, so `open_decisions: true`
      lists only requests that are really open. A Decide that moved nothing is no event: its answer
      comes from `decisions`.
    * A verdict is `verdict.recorded`, a dispatch `run.started` and, once it ended, `run.ended`.
    * A stop is the Director's `person.action` `stop`, and an Inbox move the action that names it, as
      the live writes record them; a Decide is none.

  Only entries older than the ticket's first live event (its earliest event the backfill did not
  write) are converted, so a signal already dual-written is not recorded twice; a ticket with no
  live event converts everything. Each event's idempotency key is `backfill:<source>:<hash>` and
  its `at` the entry's own timestamp.

  Decisions and holds follow the one-representation rule:

    * Each entry of `decisions` is the Director's `decision.recorded`, keyed `decision.recorded:<key>`
      as a live answer is, so an answer already recorded live is never recorded twice. It names no
      request: requests from before the event stream were never events.
    * A hold still set that the events do not show open becomes its opening event: a Blocked hold
      `hold.set` at its `set_at`, a Needs Decision hold `decision.requested` with the hold's title,
      question, why and options at its `asked_at`, so its live answer closes it.

  Each ticket's events are appended oldest first in one transaction
  (`SymphonyElixir.RunStore.append_ticket_events/1`), ending with one `note`: "History before <date>
  was backfilled from the ticket's snapshot", where <date> is the cutoff. A ticket already holding
  that note is done. The whole backfill runs once: the run store marker `ticket_events_backfill_v1`
  is set when every ticket is done, and a run after it does nothing.
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
  @hold_signals ["blocked", "dispatch_loop", "ci_wait", "handoff_missing"]
  @hold_types ["hold.set", "hold.cleared"]
  @note_max 4_000

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
  written, or the first error. A run after the marker is set backfills nothing. A ticket whose
  events can't be read or written is logged and left for the next run, which leaves the marker unset.
  """
  @spec run([opt()]) :: {:ok, outcome()} | {:error, term()}
  def run(opts) do
    store = Keyword.get(opts, :store, RunStore)

    case store.get_marker(@marker) do
      %DateTime{} -> {:ok, %{tickets: 0, events: 0}}
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

  defp finish(store, results, now) do
    outcome = %{tickets: Enum.count(results, &match?({:ok, _count}, &1)), events: Enum.sum(for {:ok, count} <- results, do: count)}

    case Enum.count(results, &match?({:error, _reason}, &1)) do
      0 ->
        with :ok <- store.put_marker(@marker, now), do: {:ok, outcome}

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
      with {:ok, existing} <- read(store.list_ticket_events(record.repo_key, record.issue_id, [])) do
        if Enum.any?(existing, &(&1.idempotency == @note_key)), do: :done, else: append(store, record, existing, audit, now)
      end

    logged(result, record)
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
    opened = holds(record, existing ++ built, now)

    events =
      (built ++ opened ++ decisions(record, now))
      |> Enum.sort_by(& &1.at, DateTime)
      |> Kernel.++(note(record, cutoff, now))

    with {:ok, stored} <- store.append_ticket_events(events) do
      ids = MapSet.new(events, & &1.id)
      {:ok, Enum.count(stored, &MapSet.member?(ids, &1.id))}
    end
  end

  defp backfilled?(%Event{idempotency: key}), do: is_binary(key) and String.starts_with?(key, @prefix)

  defp live_cutoff(%Event{at: at}), do: at
  defp live_cutoff(nil), do: nil

  # The snapshot's entries as `%{at, source, hash, mapping}`, each mapping an event's type, payload
  # and options (or nil for an entry that is no event), the ones without a timestamp left out.
  defp entries(record, audit) do
    signals = for signal <- record.signals, do: entry(signal.at, "signal", signal, signal_mapping(signal))

    verdicts =
      for verdict <- record.verdicts do
        entry(verdict.recorded_at, "verdict", verdict, TicketSignals.verdict_event(verdict.kind, verdict.outcome, verdict.head_sha))
      end

    dispatches = Enum.flat_map(record.dispatches, &dispatch_entries/1)

    moves =
      for move <- audit, matches_repo?(move, record.repo_key) do
        entry(audit_at(move), "audit", move, audit_mapping(move))
      end

    Enum.filter(signals ++ verdicts ++ dispatches ++ moves, &(match?(%DateTime{}, &1.at) and &1.mapping != nil))
  end

  defp entry(at, source, term, mapping), do: %{at: at, source: source, hash: hash(term), mapping: mapping}

  defp signal_mapping(%{name: name, details: details}) do
    case TicketSignals.event(name, details) do
      :mirrored -> mirrored(name, details)
      mapping -> mapping
    end
  end

  defp mirrored(name, details) when name in @hold_signals,
    do: {"hold.set", compact(%{kind: "blocked", reason: text(details, :reason) || name, signal: name}), []}

  defp mirrored("unblocked" = name, details), do: {"hold.cleared", compact(%{kind: "blocked", by: text(details, :by), signal: name}), []}
  defp mirrored("decision returned", _details), do: nil

  defp mirrored(name, details) do
    reason = text(details, :reason) || text(details, :signal) || name
    {"note", %{text: String.slice("Decision requested: #{reason}", 0, @note_max)}, []}
  end

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

  # A hold still set that the events don't show open is opened at the time it was set.
  defp holds(record, events, now) do
    Enum.flat_map(record.holds, &open_hold(record, &1, events, now))
  end

  defp open_hold(record, %{kind: :blocked} = hold, events, now) do
    if blocked_open?(events) do
      []
    else
      payload = compact(%{kind: "blocked", reason: hold.reason, waits_on: hold.waits_on})
      built(record, "hold.set", payload, at: hold.set_at || now, idempotency: "#{@prefix}hold:#{hash(hold)}")
    end
  end

  defp open_hold(record, %{kind: :needs_decision} = hold, _events, now) do
    decision = hold.decision || %{}
    title = text(decision, :title)
    question = text(decision, :question) || title || hold.reason

    if question_open?(record, title, question) do
      []
    else
      asked = %{question: question, title: title, why: text(decision, :why), confirm: text(decision, :confirm)}
      payload = compact(Map.put(asked, :options, options(decision)))

      at = datetime(value(decision, :asked_at)) || hold.set_at || now
      built(record, "decision.requested", payload, at: at, idempotency: "#{@prefix}hold:#{hash(hold)}")
    end
  end

  # The newest Blocked hold event is a `hold.set`.
  defp blocked_open?(events) do
    events
    |> Enum.filter(&(&1.type in @hold_types))
    |> Enum.sort_by(& &1.at, DateTime)
    |> List.last()
    |> case do
      %Event{type: "hold.set"} -> true
      _cleared_or_none -> false
    end
  end

  # A hold that names no question opens no request.
  defp question_open?(_record, _title, nil), do: true

  defp question_open?(record, title, question) do
    case TicketSignals.open_decision(record.repo_key, record.issue_id, title, question) do
      %Event{payload: payload} -> TicketSignals.same_text?(payload[:question], question)
      nil -> false
    end
  end

  defp options(decision) do
    case value(decision, :options) do
      [_option | _rest] = options -> options
      _none -> nil
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

  defp datetime(%DateTime{} = at), do: at

  defp datetime(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp datetime(_value), do: nil

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp text(map, key), do: map |> value(key) |> string()

  defp string(value) when is_binary(value), do: blank_to_nil(value)
  defp string(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp string(_value), do: nil

  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)

  defp compact(payload), do: payload |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  defp compact_opts(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
end
