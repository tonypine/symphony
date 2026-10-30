defmodule SymphonyElixir.Pauses.Backfill do
  @moduledoc """
  Fills the pause (`SymphonyElixir.Pauses`) and the questions (`SymphonyElixir.Questions`) of every
  ticket record once, from what the record already holds: its holds and its stored decisions. It
  reads the record only, never Linear, and leaves the holds as they are.

  Each record converts as `backfill_record/1` maps it:

    * A Blocked hold becomes a pause reason by what it waits on (`waits_on.type`): `dependency`,
      `fix_ticket` and `landing` wait on a `:ticket`, one reason per ticket identifier it names;
      `operator_stop` waits on a `:person` (the Director's Unblock); `access` and `ci_wait` wait on
      the `:environment`, the condition named from the hold's reason; `dispatch_loop` and
      `handoff_missing` become a question Symphony asks ("Run it again", "Start it over from main"
      or "Keep it paused"; the second recommended when the hold's reason speaks of a restart, else
      the first), which pauses the ticket on a `:question` reason.
    * A Needs Decision hold's open request becomes an open question (its title, question, why and
      options from the hold's decision), with its `:question` reason.
    * Each stored decision becomes an answered question (answered by the Director, scope
      `:ticket`, on the day it was stored), keeping the id of its `decision.recorded` event as
      `legacy_event`. They go first, in the order they were recorded.

  Every write goes through `Pauses` and `Questions` with `backfilled: true`: one event per created
  pause reason and question, with `source: "backfill"` and keys that never record it twice. A hold
  the table doesn't cover, and a key that names no ticket, are skipped with the reason. A record
  whose writes all landed is marked (`pause_backfilled_at`) and never converted again; one whose
  write failed is left unmarked for the next run, whose writes find what the first one wrote.

  The operator's pause of all dispatch (`SymphonyElixir.RunStore.get_paused/0`), when set, becomes a
  pause on `:symphony` with a `:person` reason and the stored reason, once (the run store marker
  `pause_backfill_symphony_v1`).

  The backfill runs at startup in the task of the ledger's own backfill, right after it
  (`run_after_ledger/1`): it reads the `decision.recorded` events that backfill writes, and refuses
  to run before its marker is set, so its own events never become the first live event that
  backfill cuts history at. Its summary is logged and kept for the state payload (`summary/0`).
  """

  require Logger

  alias SymphonyElixir.{Pauses, Questions, RunStore, TicketState}
  alias SymphonyElixir.TicketEvents.Backfill, as: LedgerBackfill

  @symphony_marker "pause_backfill_symphony_v1"
  @summary_key {__MODULE__, :summary}
  @director %{kind: :person, name: "Director"}
  # The longest reason line and question title the pause and the ledger take.
  @max_text 300
  @max_title 120
  @listed_skips 20
  @identifier ~r/\A[A-Z][A-Z0-9]*-\d+\z/
  @ticket_types ~w(dependency fix_ticket landing)
  @environment_types ~w(access ci_wait)
  @question_types ~w(dispatch_loop handoff_missing)
  @restart ~r/restart|start(?:s|ed)? (?:it )?over|from main/i
  # A rendered option line: `**Label** (recommended): what it does`.
  @option_line ~r/\A\*\*(.+?)\*\*( \(recommended\))?:?\s*(.*)\z/s

  @typedoc """
  One write of a record's conversion: a pause reason (`Pauses.set/3`'s reason and options), or a
  question (`Questions.ask/3`'s request and options; a stored decision's names the idempotency key
  of its `decision.recorded` event as `legacy_key`, which the run turns into `legacy_event`).
  """
  @type item :: {:reason, Pauses.reason_input(), keyword()} | {:question, map(), keyword()}

  @typedoc "A record's conversion: its writes in order, and what it skipped, with why."
  @type plan :: %{items: [item()], skipped: [String.t()]}

  @typedoc "A record or subject the run skipped, and why."
  @type skip :: %{issue_id: String.t() | nil, issue_identifier: String.t() | nil, reason: String.t()}

  @typedoc """
  What a run did: when it ran, the records it read, converted and found converted already, the
  pauses and questions it created, and what it skipped (the first #{@listed_skips}, and how many).
  """
  @type summary :: %{
          at: DateTime.t(),
          records_read: non_neg_integer(),
          records_converted: non_neg_integer(),
          already_converted: non_neg_integer(),
          pauses_created: non_neg_integer(),
          questions_created: non_neg_integer(),
          skipped_count: non_neg_integer(),
          skipped: [skip()]
        }

  @typedoc "`run/1`'s options: `now:` (default the current time) and `store:` (default `SymphonyElixir.RunStore`)."
  @type opt :: {:now, DateTime.t()} | {:store, module()}

  @doc """
  Runs the ledger's backfill (`ledger:`, default `SymphonyElixir.TicketEvents.Backfill.run/1`), then
  this one with the same options, logging and keeping its summary; returns the ledger's result, for
  the ledger's task to log. The ledger's task runs it (`TicketEvents.Backfill.start/1`'s `run:`).
  """
  @spec run_after_ledger(keyword()) :: {:ok, LedgerBackfill.outcome()} | {:error, term()}
  def run_after_ledger(opts) do
    ledger = Keyword.get(opts, :ledger, &LedgerBackfill.run/1)
    result = ledger.(opts)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    opts |> Keyword.put(:now, now) |> run() |> remember(now) |> log()
    result
  end

  @doc "The summary of the last startup's run (`run_after_ledger/1`), or nil before it ran."
  @spec summary() :: summary() | %{at: DateTime.t(), error: String.t()} | nil
  def summary, do: :persistent_term.get(@summary_key, nil)

  @doc "Forgets the summary, so `summary/0` reads nil until the next run."
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase(@summary_key)
    :ok
  end

  @doc """
  Converts every record not converted yet, then the operator's pause (see the module doc), and
  returns what it did. `{:error, :ledger_backfill_pending}` while the ledger's backfill is not done.
  """
  @spec run([opt()]) :: {:ok, summary()} | {:error, term()}
  def run(opts) do
    store = Keyword.get(opts, :store, RunStore)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    with :ok <- ledger_done(store.get_marker(LedgerBackfill.marker())),
         {:ok, records} <- listed(store.list_all_ticket_states()) do
      records = for record <- Enum.map(records, &TicketState.normalize/1), is_binary(record.repo_key) and is_binary(record.issue_id), do: record
      summary = Enum.reduce(records, empty(now, length(records)), &convert(&2, store, &1, now))
      {:ok, store |> symphony(summary, now) |> Map.update!(:skipped, &(&1 |> Enum.reverse() |> Enum.take(@listed_skips)))}
    end
  end

  @doc """
  How `record` (a `SymphonyElixir.TicketState` record) converts: its writes in order, the stored
  decisions first, then its holds, oldest first; and what it skips, with why. Pure: it writes nothing.
  """
  @spec backfill_record(map()) :: plan()
  def backfill_record(record) do
    record = TicketState.normalize(record)
    holds = Enum.sort_by(record.holds, &(&1.set_at || DateTime.from_unix!(0)), DateTime)
    {items, skipped} = Enum.unzip(Enum.map(record.decisions, &decision(record, &1)) ++ Enum.map(holds, &hold(record, &1)))
    %{items: List.flatten(items), skipped: List.flatten(skipped)}
  end

  defp ledger_done(%DateTime{}), do: :ok
  defp ledger_done(nil), do: {:error, :ledger_backfill_pending}
  defp ledger_done({:error, _reason} = error), do: error

  defp listed(records) when is_list(records), do: {:ok, records}
  defp listed({:error, _reason} = error), do: error

  defp empty(now, read) do
    %{
      at: now,
      records_read: read,
      records_converted: 0,
      already_converted: 0,
      pauses_created: 0,
      questions_created: 0,
      skipped_count: 0,
      skipped: []
    }
  end

  defp convert(summary, _store, %{pause_backfilled_at: %DateTime{}}, _now), do: %{summary | already_converted: summary.already_converted + 1}

  defp convert(summary, store, record, now) do
    plan = backfill_record(record)
    ticket = {:ticket, record.repo_key, record.issue_id}

    with {:ok, legacy} <- legacy_events(store, record),
         {:ok, written} <- write(ticket, plan.items, legacy, now),
         :ok <- store.update_ticket_state(record.repo_key, record.issue_id, %{pause_backfilled_at: now}) do
      asked = MapSet.new(record.questions, & &1.id)
      created = Enum.count(written, &new_question?(&1, asked))

      %{
        skip_all(summary, record, plan.skipped)
        | records_converted: summary.records_converted + 1,
          pauses_created: summary.pauses_created + if(is_nil(record.pause) and Enum.any?(plan.items, &pausing?/1), do: 1, else: 0),
          questions_created: summary.questions_created + created
      }
    else
      {:error, reason} -> skip_all(summary, record, ["could not write it: #{inspect(reason)}"])
    end
  end

  defp new_question?({:question, question}, asked), do: not MapSet.member?(asked, question.id)
  defp new_question?({:reason, _pause}, _asked), do: false

  defp pausing?({:reason, _reason, _opts}), do: true
  defp pausing?({:question, _request, opts}), do: not Keyword.has_key?(opts, :answer)

  # The ids of the ticket's `decision.recorded` events by idempotency key, read only when it has
  # stored decisions.
  defp legacy_events(_store, %{decisions: []}), do: {:ok, %{}}

  defp legacy_events(store, record) do
    with {:ok, events} <- listed(store.list_ticket_events(record.repo_key, record.issue_id, types: ["decision.recorded"])),
         do: {:ok, Map.new(events, &{&1.idempotency, &1.id})}
  end

  # Every write is made, so a failed one leaves the others written for the next run to find.
  defp write(ticket, items, legacy, now) do
    results = Enum.map(items, &write_item(ticket, &1, legacy, now))
    Enum.find(results, {:ok, for({:ok, written} <- results, do: written)}, &match?({:error, _reason}, &1))
  end

  defp write_item(ticket, {:reason, reason, opts}, _legacy, now) do
    with {:ok, pause} <- Pauses.set(ticket, reason, Keyword.put_new(opts, :at, now)), do: {:ok, {:reason, pause}}
  end

  defp write_item(ticket, {:question, request, opts}, legacy, now) do
    {key, opts} = Keyword.pop(opts, :legacy_key)
    opts = opts |> Keyword.put_new(:at, now) |> Keyword.put(:legacy_event, Map.get(legacy, key))
    opts = if answer = opts[:answer], do: Keyword.put(opts, :answer, %{answer | at: answer.at || opts[:at]}), else: opts
    with {:ok, question} <- Questions.ask(ticket, request, opts), do: {:ok, {:question, question}}
  end

  defp skip_all(summary, record, reasons), do: Enum.reduce(reasons, summary, &skip(&2, record.issue_id, record.issue_identifier, &1))

  defp skip(summary, issue_id, identifier, reason) do
    skipped = %{issue_id: issue_id, issue_identifier: identifier, reason: reason}
    %{summary | skipped_count: summary.skipped_count + 1, skipped: [skipped | summary.skipped]}
  end

  # The operator's pause, once: a pause on Symphony when it is set.
  defp symphony(store, summary, now) do
    with nil <- store.get_marker(@symphony_marker),
         %{} = row <- store.get_paused(),
         {:ok, created} <- pause_symphony(row, now),
         :ok <- store.put_marker(@symphony_marker, now) do
      %{summary | pauses_created: summary.pauses_created + created}
    else
      %DateTime{} -> summary
      {:error, reason} -> skip(summary, nil, "Symphony", "could not write the pause of all dispatch: #{inspect(reason)}")
    end
  end

  defp pause_symphony(%{paused: true} = row, now) do
    reason = %{kind: :person, waits_on: %{action: "unblock"}, text: one_line(Map.get(row, :reason)) || "You paused Symphony", releasable: true}
    with {:ok, _pause} <- Pauses.set(:symphony, reason, set_by: @director, at: Map.get(row, :paused_at) || now, backfilled: true), do: {:ok, 1}
  end

  defp pause_symphony(_row, _now), do: {:ok, 0}

  defp remember({:ok, summary}, _now), do: put_summary({:ok, summary}, summary)
  defp remember({:error, reason} = error, now), do: put_summary(error, %{at: now, error: inspect(reason)})

  defp put_summary(result, summary) do
    :persistent_term.put(@summary_key, summary)
    result
  end

  defp log({:ok, summary}) do
    Logger.info(
      "Pause backfill: read #{summary.records_read} record(s), converted #{summary.records_converted}, " <>
        "created #{summary.pauses_created} pause(s) and #{summary.questions_created} question(s), skipped #{summary.skipped_count}"
    )
  end

  defp log({:error, reason}), do: Logger.warning("Failed to backfill pauses and questions: #{inspect(reason)}")

  # Each mapping returns its writes and what it skipped: a stored decision is an answered question,
  # on the day it was stored.
  defp decision(record, decision) do
    title = one_line(decision.title) || one_line(decision.question)

    cond do
      is_nil(title) ->
        {[], ["decision #{decision.key} has no title or question"]}

      is_nil(one_line(decision.answer)) ->
        {[], ["decision #{decision.key} has no answer"]}

      true ->
        at = decision_at(decision.date)
        request = request(title, one_line(decision.question) || title)
        answer = %{text: decision.answer, option: nil, by: @director, at: at, scope: :ticket}
        opts = [backfilled: true, id: id(record, {:decision, decision.key}), answer: answer, legacy_key: "decision.recorded:#{decision.key}"]
        {[{:question, request, with_at(opts, at)}], []}
    end
  end

  defp hold(_record, %{kind: :blocked, waits_on: %{type: type, keys: keys}} = hold) when type in @ticket_types do
    {identifiers, others} = Enum.split_with(keys, &(&1 =~ @identifier))

    reasons =
      for identifier <- identifiers do
        reason = %{kind: :ticket, waits_on: %{identifier: identifier}, text: ticket_text(type, identifier)}
        {:reason, reason, reason_opts(hold)}
      end

    skipped = for key <- others, do: "#{type} key #{key} names no ticket"
    if keys == [], do: {[], ["a #{type} hold that names no ticket"]}, else: {reasons, skipped}
  end

  defp hold(_record, %{kind: :blocked, waits_on: %{type: "operator_stop"}} = hold) do
    reason = %{kind: :person, waits_on: %{action: "unblock"}, text: text(hold.reason)}
    {[{:reason, compact(reason), Keyword.put(reason_opts(hold), :set_by, @director)}], []}
  end

  defp hold(_record, %{kind: :blocked, waits_on: %{type: type}} = hold) when type in @environment_types do
    condition = text(hold.reason) || type
    reason = %{kind: :environment, waits_on: %{condition: condition}, text: condition, releasable: true}
    {[{:reason, reason, reason_opts(hold)}], []}
  end

  defp hold(record, %{kind: :blocked, waits_on: %{type: type}} = hold) when type in @question_types do
    {[{:question, stuck_request(type, record.issue_identifier || "this ticket", hold.reason), question_opts(record, {:blocked, type}, hold.set_at)}], []}
  end

  defp hold(record, %{kind: :needs_decision} = hold) do
    decision = hold.decision || %{}

    case text(decision, :title) || text(decision, :question) || one_line(hold.reason) do
      nil -> {[], ["a Needs Decision hold with no question"]}
      title -> {[open_question(record, hold, decision, title)], []}
    end
  end

  defp hold(_record, %{waits_on: waits_on}) do
    {[], ["a Blocked hold waiting on #{(waits_on && waits_on.type) || "nothing named"}, which no pause reason covers"]}
  end

  # A Needs Decision hold's request as an open question: its fields from the hold's decision.
  defp open_question(record, hold, decision, title) do
    question = text(decision, :question) || one_line(hold.reason) || title

    request = %{
      request(title, question)
      | why: text(decision, :why) || "",
        if_unanswered: text(decision, :if_unanswered) || "",
        recommendation_reason: text(decision, :recommendation_reason) || "",
        options: options(value(decision, :options), value(decision, :unlocks))
    }

    at = datetime(value(decision, :asked_at)) || hold.set_at
    opts = question_opts(record, {:needs_decision, title, question}, at)
    {:question, request, if(confirm = text(decision, :confirm), do: Keyword.put(opts, :confirm, confirm), else: opts)}
  end

  defp reason_opts(hold), do: with_at([backfilled: true], hold.set_at)

  defp question_opts(record, source, at), do: with_at([backfilled: true, id: id(record, source)], at)

  defp with_at(opts, %DateTime{} = at), do: Keyword.put(opts, :at, at)
  defp with_at(opts, nil), do: opts

  defp ticket_text("dependency", identifier), do: "Waiting for #{identifier} to finish"
  defp ticket_text("fix_ticket", identifier), do: "Waiting for #{identifier} to finish: it fixes what stopped this ticket"
  defp ticket_text("landing", identifier), do: "Waiting for #{identifier} to land: it changes the same files"

  # The question Symphony asks for a run that made no progress or ended without its handoff.
  defp stuck_request(type, name, hold_reason) do
    {title, why} = stuck_words(type, name)
    restart? = is_binary(hold_reason) and hold_reason =~ @restart

    %{
      request(title, "#{title}. Should Symphony run it again, start it over from main, or keep it paused?")
      | why: why,
        if_unanswered: "#{name} stays paused and Symphony starts no run on it.",
        recommendation_reason:
          if(restart?, do: "The pause said to start it over: another run where it stopped would likely stop the same way.", else: "Another run picks up where the last one stopped, with nothing lost."),
        options: [
          %{label: "Run it again", effect: "Symphony starts a new run on #{name} where it stopped.", recommended: not restart?},
          %{label: "Start it over from main", effect: "Symphony closes the pull request of #{name} and starts again from the main branch.", recommended: restart?},
          %{label: "Keep it paused", effect: "#{name} stays paused until you decide.", recommended: false}
        ]
    }
  end

  defp stuck_words("dispatch_loop", name),
    do: {"Two runs made no progress on #{name}", "Symphony stopped starting runs on #{name} because its last runs changed nothing: no new state, no new change to its pull request and no decision."}

  defp stuck_words("handoff_missing", name),
    do: {"#{name}'s run ended without a handoff", "The runs on #{name} ended without handing the work on, so Symphony stopped starting runs on it."}

  defp request(title, question) do
    %{title: String.slice(title, 0, @max_title), question: question, why: "", if_unanswered: "", recommendation_reason: "", options: []}
  end

  defp options(options, unlocks) when is_list(options) do
    unlocks = if is_list(unlocks), do: unlocks, else: []
    options |> Enum.with_index() |> Enum.map(fn {option, index} -> option(option, paths(Enum.at(unlocks, index))) end)
  end

  defp options(_options, _unlocks), do: []

  defp option(%{} = option, unlocks) do
    %{
      label: text(option, :label) || "",
      effect: text(option, :effect) || "",
      recommended: value(option, :recommended) == true,
      tradeoffs: List.wrap(value(option, :tradeoffs)),
      unlocks: if(unlocks == [], do: paths(value(option, :unlocks)), else: unlocks)
    }
  end

  defp option(line, unlocks) when is_binary(line) do
    case Regex.run(@option_line, String.trim(line)) do
      [_line, label, marker, effect] -> %{label: String.trim(label), effect: String.trim(effect), recommended: marker != "", unlocks: unlocks}
      nil -> %{label: one_line(line) || "", effect: "", recommended: false, unlocks: unlocks}
    end
  end

  defp option(_option, unlocks), do: %{label: "", effect: "", recommended: false, unlocks: unlocks}

  defp paths(paths) when is_list(paths), do: Enum.filter(paths, &is_binary/1)
  defp paths(_paths), do: []

  defp id(record, source), do: "backfill-" <> hash({record.repo_key, record.issue_id, source})

  defp hash(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp decision_at(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp decision_at(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> decision_at(date)
      {:error, _reason} -> nil
    end
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

  defp text(map, key), do: map |> value(key) |> one_line()

  # A hold's reason as a pause reason's line: one line, at most 300 characters.
  defp text(reason), do: with(line when is_binary(line) <- one_line(reason), do: String.slice(line, 0, @max_text))

  defp one_line(value) when is_binary(value) do
    case value |> String.split() |> Enum.join(" ") do
      "" -> nil
      line -> line
    end
  end

  defp one_line(_value), do: nil

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
