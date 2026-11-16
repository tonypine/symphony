defmodule SymphonyElixir.Situation do
  @moduledoc """
  Where a ticket stands now, in one situation from the closed vocabulary of the Director's ticket
  page (`docs/design/director-ticket-page.md`, section 3). `kinds/0` lists them in the design's
  precedence: when more than one holds, the first is the situation and `and_more` counts the pause's
  further reasons.

  `compute/4` reads the ticket's record (`SymphonyElixir.TicketState`), its ledger
  (`SymphonyElixir.TicketEvents`) and what the orchestrator holds in memory and publishes
  (`live_facts/2`: the runs working, the retries, the slot waits and the dispatch gates). It never
  reads Linear. `read/3` gives a ticket's situation for a read, and `sync/3` is the same computation
  writing a `situation.changed` event when the kind differs from the last one the ledger holds. A
  read never writes; `SymphonyElixir.Situation.Recorder` is the one caller of `sync/3`.

  A ticket nothing holds and no run works on is read from the same record the machine acts on: the
  run its watcher's decision needs next (`dispatch`, `ci_fix`, `land_agent`; for a ticket the watcher
  doesn't decide on, its phase's run), named with the decision's reason. Symphony's pause reads
  `paused_by_rule` naming that run; every slot in use reads `waiting_for_slot` naming it; a slot free
  reads "Starting" until the watcher finds the run never started (`SymphonyElixir.PrWatch.SilentWait`),
  then "Not started" (`waiting_on_you`), which the Inbox lists too. "Waiting for a slot" is never
  said while a slot is free. A decision that waits on something else says what it waits on in its
  own words: CI or GitHub (`waiting_for_ci`), a person (`waiting_on_you`), Symphony's upkeep, or a
  run that already ended, whose PR the watcher reads next. When Symphony can tell none of that, the
  situation says so ("Not known", `waiting_on_you`) and never borrows another one's words. A plan in
  `Plan Review` reads `waiting_on_you`, a parent in `Waiting on sub-tickets` `blocked_by_ticket` on
  its first open sub-ticket, and a ticket in `Backlog` `paused_by_rule`.

  A dispatch skip reads `paused_by_rule` only when the orchestrator names the rule behind it (its
  entry's `rule`); the others (a run already on it, CI, its own pause) are told by what they wait on.
  A rule stops dispatch and nothing else, so a ticket a run works on is not paused by it. A Merging
  ticket the orchestrator holds until CI settles shows among its slot waits (`ci_wait`) and reads
  `waiting_for_ci`; any other slot wait reads `paused_by_rule` while Symphony's own pause lasts.
  """

  alias SymphonyElixir.{Config, PrDecision, RunStore, TicketEvents, TicketPullRequest, TicketState}
  alias SymphonyElixir.PrWatch.SilentWait
  alias SymphonyElixir.TicketEvents.{Event, Summary}

  @kinds ~w(waiting_on_you retrying blocked_by_ticket paused_by_rule waiting_for_ci waiting_for_build waiting_for_slot working done cancelled)

  # A retry that follows a run's normal end, or a wait on something that is not broken, is no retry
  # to a person: only a failure, or a usage limit, reads as `retrying`.
  @quiet_retries [:continuation, :linear_wait, :ci_wait]
  @handed_off [:code_review, :qa, :merging, :ci_fix]
  @max_cause 300
  # The watcher's decisions a run carries out, which the orchestrator starts.
  @run_kinds [:dispatch, :ci_fix, :land_agent]
  # The phases whose next run is the phase's own when the watcher has no decision on the ticket.
  @phase_runs %{"todo" => "The implementation run", "in progress" => "The implementation run", "rework" => "The rework run"}
  @numbers ~w(one two three four five six seven eight nine ten eleven twelve)

  @doing %{
    "implementation" => "writing the code",
    "rework" => "answering the review's findings",
    "review_feedback" => "answering the review comments",
    "code_review" => "reviewing the PR",
    "qa" => "walking the user journeys",
    "ci_fix" => "repairing the checks",
    "landing" => "landing the PR",
    "breakdown" => "writing the plan",
    "epic_review" => "checking the epic"
  }

  @hand_off %{
    "implementation" => "It hands off to Code Review when it pushes.",
    "rework" => "It hands off to Code Review when it pushes.",
    "review_feedback" => "It hands off to Code Review when it pushes.",
    "code_review" => "It hands off to QA when it gives its verdict.",
    "qa" => "It hands off to Merging when it passes.",
    "landing" => "It hands off to Done when it merges.",
    "breakdown" => "It hands off to Plan Review when the plan is ready.",
    "epic_review" => "It hands off to Done when it passes."
  }

  @type kind :: String.t()

  @typedoc """
  One situation: its `kind`, the pattern's first words (`word`), one sentence of fact (`cause`), what
  moves it (`next`, nil once it ended), since when, what it waits on, how many further reasons pause
  it, and for `working` the `step` and the `run`, for `retrying` the try k of n and its time.
  """
  @type t :: %{
          kind: kind(),
          word: String.t(),
          cause: String.t(),
          next: String.t() | nil,
          since: DateTime.t() | nil,
          waits_on: map() | nil,
          and_more: non_neg_integer(),
          step: %{id: String.t(), title: String.t() | nil} | nil,
          run:
            %{
              id: String.t() | nil,
              kind: String.t() | nil,
              number: non_neg_integer() | nil,
              label: String.t()
            }
            | nil,
          retry: %{try: pos_integer(), of: pos_integer() | nil, at: DateTime.t() | nil} | nil
        }

  @typedoc """
  What the orchestrator holds, by ticket, as `live_facts/2` keeps it from a snapshot: small enough to
  send to another process.
  """
  @type live_facts :: %{
          running: %{optional(String.t()) => map()},
          retrying: %{optional(String.t()) => map()},
          slot_waiting: %{optional(String.t()) => map()},
          skipped: %{optional(String.t()) => map()},
          limit: pos_integer() | nil,
          symphony_pause: %{optional(:reason) => String.t() | nil, optional(:paused_at) => DateTime.t() | nil} | nil,
          max_tries: pos_integer(),
          terminal_states: [String.t()]
        }

  @typedoc "The phase of a ticket named by its identifier, when Symphony knows it."
  @type phase_of :: (String.t() -> String.t() | nil)

  @doc "The closed vocabulary, in the design's precedence."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The facts `compute/4` reads from an orchestrator snapshot. `now` turns a retry's remaining time into
  the time it starts.
  """
  @spec live_facts(map(), DateTime.t()) :: live_facts()
  def live_facts(snapshot, now \\ DateTime.utc_now()) do
    settings = Config.settings!()

    %{
      running: by_issue(snapshot, :running, &Map.take(&1, [:run_kind, :started_at, :step])),
      retrying: by_issue(snapshot, :retrying, &retry_facts(&1, now)),
      slot_waiting: by_issue(snapshot, :slot_waiting, &Map.take(&1, [:since, :reason, :ci_wait])),
      skipped: by_issue(snapshot, :dispatch_skipped, &Map.take(&1, [:since, :reason, :rule])),
      limit: snapshot |> Map.get(:concurrency) |> max_total(),
      symphony_pause: snapshot |> Map.get(:pause) |> symphony_pause(),
      max_tries: settings.watchdog.dispatch_loop_runs,
      terminal_states: settings.tracker.terminal_states
    }
  end

  defp max_total(%{max_total: max_total}), do: max_total
  defp max_total(_concurrency), do: nil

  defp symphony_pause(%{paused: true} = pause), do: Map.take(pause, [:reason, :paused_at])
  defp symphony_pause(_pause), do: nil

  defp by_issue(snapshot, list, facts), do: snapshot |> Map.get(list, []) |> Map.new(&{&1.issue_id, facts.(&1)})

  defp retry_facts(retry, now) do
    due_at = if is_integer(Map.get(retry, :due_in_ms)), do: DateTime.add(now, retry.due_in_ms, :millisecond)

    %{attempt: Map.get(retry, :attempt), error: Map.get(retry, :error), delay_type: Map.get(retry, :delay_type), due_at: due_at}
  end

  @doc """
  What decides each ticket's kind in `live_facts`: a change of it is a reason to compute the ticket's
  situation again (`SymphonyElixir.Situation.Recorder`).
  """
  @spec live_signature(live_facts()) :: %{optional(String.t()) => tuple()}
  def live_signature(live) do
    [live.running, live.retrying, live.slot_waiting, live.skipped]
    |> Enum.flat_map(&Map.keys/1)
    |> Map.new(fn issue_id ->
      slot = slot_signature(Map.get(live.slot_waiting, issue_id), live)
      rule = get_in(live.skipped, [issue_id, :rule])

      {issue_id, {Map.has_key?(live.running, issue_id), failure_retry?(Map.get(live.retrying, issue_id)), slot, rule}}
    end)
  end

  defp slot_signature(nil, _live), do: nil
  defp slot_signature(%{ci_wait: true}, _live), do: :ci
  defp slot_signature(_slot, %{symphony_pause: nil}), do: :slot
  defp slot_signature(_slot, _live), do: :paused

  @doc """
  The situation of `record` for a read, from its ledger and `live`. `records` are the ticket records
  the caller already read, for the phase of a ticket it waits on; without them the store is read only
  when one is needed. A ledger that cannot be read reads as empty.
  """
  @spec read(map() | nil, live_facts(), [map()] | nil) :: t()
  def read(record, live, records \\ nil) do
    record = TicketState.normalize(record)
    compute(record, ledger(record), live, phase_of(records))
  end

  defp ledger(%{issue_id: issue_id}) do
    case TicketEvents.query(issue_id, limit: :all) do
      events when is_list(events) -> events
      {:error, _reason} -> []
    end
  end

  defp phase_of(records) do
    fn identifier ->
      (records || stored_records())
      |> Enum.find_value(&(&1.issue_identifier == identifier && &1.phase))
    end
  end

  defp stored_records, do: RunStore.list_all_ticket_states() |> List.wrap() |> Enum.map(&TicketState.normalize/1)

  @doc """
  Writes the `situation.changed` event of `record` when its kind differs from the last one its ledger
  holds, with the old and the new kind and the cause: `{:ok, event}` when it wrote one, `:unchanged`
  when the kind is the same. The key names the change it follows, so a second writer of one change
  writes nothing.
  """
  @spec sync(map(), live_facts(), [map()] | nil) :: {:ok, Event.t()} | :unchanged | {:error, term()}
  def sync(record, live, records \\ nil) do
    record = TicketState.normalize(record)

    with events when is_list(events) <- TicketEvents.query(record.issue_id, limit: :all) do
      situation = compute(record, events, live, phase_of(records))
      last = events |> Enum.filter(&(&1.type == "situation.changed")) |> List.last()
      write_change(record, situation, last)
    end
  end

  defp write_change(_record, %{kind: kind}, %Event{payload: %{to: kind}}), do: :unchanged

  defp write_change(record, situation, last) do
    payload = %{
      from: last && Map.get(last.payload, :to),
      to: situation.kind,
      word: situation.word,
      cause: situation.cause,
      since: iso8601(situation.since)
    }

    key = "situation.changed:#{(last && last.id) || "first"}:#{situation.kind}"
    TicketEvents.record(record.repo_key, record.issue_id, "situation.changed", payload, phase: record.phase, idempotency: key)
  end

  @doc "A situation as the API serves it: its times in ISO 8601."
  @spec payload(t()) :: map()
  def payload(situation) do
    %{situation | since: iso8601(situation.since), retry: retry_payload(situation.retry)}
  end

  defp retry_payload(nil), do: nil
  defp retry_payload(retry), do: %{retry | at: iso8601(retry.at)}

  @doc "A time as a situation's sentences say it: the hour and minute on this host's clock."
  @spec clock(DateTime.t()) :: String.t()
  def clock(%DateTime{} = at) do
    universal = at |> DateTime.to_naive() |> NaiveDateTime.to_erl()
    {_date, {hour, minute, _second}} = :calendar.universal_time_to_local_time(universal)
    "#{pad(hour)}:#{pad(minute)}"
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  The one situation of a normalized `record` holding `events` (oldest first): the first kind of
  `kinds/0` that holds. `phase_of` names the phase of a ticket it waits on.
  """
  @spec compute(TicketState.t(), [Event.t()], live_facts(), phase_of()) :: t()
  def compute(record, events, live, phase_of \\ fn _identifier -> nil end) do
    issue_id = record.issue_id
    running = Map.get(live.running, issue_id)

    ctx = %{
      record: record,
      events: events,
      live: live,
      phase_of: phase_of,
      reasons: reasons(record),
      phase: normalized(record.phase),
      running: running,
      retry: live.retrying |> Map.get(issue_id) |> failure_retry(),
      slot: Map.get(live.slot_waiting, issue_id),
      skipped: live.skipped |> Map.get(issue_id) |> rule_skip(running),
      facts: facts(record)
    }

    (Enum.find(@kinds, &holds?(&1, ctx)) || :nothing)
    |> situation(ctx)
    |> finish(ctx)
  end

  defp reasons(%{pause: %{reasons: reasons}}), do: reasons
  defp reasons(_record), do: []

  defp facts(%{pr_watch: %{facts: %PrDecision.Facts{} = facts}}), do: facts
  defp facts(_record), do: nil

  defp rule_skip(%{rule: rule} = skip, nil) when not is_nil(rule), do: skip
  defp rule_skip(_skip, _running), do: nil

  defp failure_retry(retry), do: if(failure_retry?(retry), do: retry)

  defp failure_retry?(%{delay_type: delay_type}), do: delay_type not in @quiet_retries
  defp failure_retry?(_retry), do: false

  defp holds?("waiting_on_you", ctx), do: open_questions(ctx) != [] or reason(ctx, :question) != nil or ctx.phase == "plan review"
  defp holds?("retrying", ctx), do: ctx.retry != nil
  defp holds?("blocked_by_ticket", ctx), do: reason(ctx, :ticket) != nil or open_sub_issue(ctx) != nil
  defp holds?("paused_by_rule", ctx), do: rule_reason(ctx) != nil or ctx.phase == "backlog" or ctx.skipped != nil or pause_holds_slot?(ctx)
  defp holds?("waiting_for_ci", ctx), do: waiting_for_ci?(ctx)
  defp holds?("waiting_for_build", ctx), do: reason(ctx, :build) != nil
  defp holds?("waiting_for_slot", ctx), do: ctx.slot != nil
  defp holds?("working", ctx), do: ctx.running != nil
  defp holds?("done", ctx), do: ctx.phase == "done" or match?(%{pr: :merged}, ctx.facts)
  defp holds?("cancelled", ctx), do: ctx.record.phase != nil and ctx.phase in Enum.map(ctx.live.terminal_states, &normalized/1)

  defp open_questions(ctx), do: Enum.filter(ctx.record.questions, &(&1.state == :open))

  defp reason(ctx, kind), do: Enum.find(ctx.reasons, &(&1.kind == kind))

  defp rule_reason(ctx), do: Enum.find(ctx.reasons, &(&1.kind in [:person, :environment]))

  defp pause_holds_slot?(%{slot: %{ci_wait: true}}), do: false
  defp pause_holds_slot?(ctx), do: ctx.slot != nil and ctx.live.symphony_pause != nil

  defp open_sub_issue(%{phase: "waiting on sub-tickets"} = ctx) do
    terminal = Enum.map(ctx.live.terminal_states, &normalized/1)
    Enum.find(ctx.record.sub_issues, &(is_binary(&1.identifier) and normalized(&1.state) not in terminal))
  end

  defp open_sub_issue(_ctx), do: nil

  # A head handed off waits for its checks whatever else runs on the ticket; a run still writing the
  # next head on a ticket not yet handed off is working, not waiting.
  defp waiting_for_ci?(%{slot: %{ci_wait: true}}), do: true

  # A head Code Review has yet to judge waits for no check: the review reads the code whatever CI says.
  defp waiting_for_ci?(%{facts: %{phase: :code_review, review: :pending}}), do: false

  # Nor does a head a changes verdict stands on: the code is about to change, and the rework run is next.
  defp waiting_for_ci?(%{facts: %{phase: :rework, review: :changes_requested}}), do: false

  defp waiting_for_ci?(%{facts: %{pr: pr, ci: :pending} = facts} = ctx) when pr in [:open, :draft],
    do: facts.phase in @handed_off or ctx.running == nil

  defp waiting_for_ci?(%{facts: %{pr: pr, ci: :red, red_kind: :run_in_progress} = facts} = ctx) when pr in [:open, :draft],
    do: facts.phase in @handed_off or ctx.running == nil

  defp waiting_for_ci?(_ctx), do: false

  defp situation("waiting_on_you", ctx) do
    case open_questions(ctx) do
      [question | _] -> asked(question, ctx)
      [] -> waiting_on_you_without_question(reason(ctx, :question), ctx)
    end
  end

  defp situation("retrying", %{retry: retry} = ctx) do
    k = (retry.attempt || 0) + 1
    n = if k <= ctx.live.max_tries, do: ctx.live.max_tries
    tries = if n, do: "Try #{k} of #{n}", else: "Try #{k}"
    time = if retry.due_at, do: " starts at #{clock(retry.due_at)}.", else: " starts soon."

    base("retrying", "Retrying", stopped(retry.error), tries <> time, last_run_end(ctx) || ctx.record.phase_at)
    |> Map.put(:retry, %{try: k, of: n, at: retry.due_at})
  end

  defp situation("blocked_by_ticket", ctx) do
    case reason(ctx, :ticket) do
      nil ->
        link = open_sub_issue(ctx)
        blocked(link.identifier, phase_of_ticket(link.identifier, ctx) || link.state, "It is waiting on its sub-tickets.", ctx.record.phase_at)

      reason ->
        identifier = Map.get(reason.waits_on, :identifier, "another ticket")
        blocked(identifier, phase_of_ticket(identifier, ctx), reason.text, reason.set_at)
    end
  end

  defp situation("paused_by_rule", ctx) do
    case rule_reason(ctx) do
      nil -> paused_without_reason(ctx)
      reason -> base("paused_by_rule", "Paused", sentence(reason.text), lifts(reason), reason.set_at, reason.waits_on)
    end
  end

  defp situation("waiting_for_ci", ctx) do
    number = ticket_pr_number(ctx)
    subject = if number, do: "PR ##{number}", else: "its PR"

    base("waiting_for_ci", "Waiting for CI", "Checks are running on #{subject}.", "#{next_phase(ctx)} starts when they pass.", checks_started(ctx), %{
      pr: number,
      check: first_check(ctx.facts)
    })
  end

  defp situation("waiting_for_build", ctx) do
    reason = reason(ctx, :build)

    if ctx.phase == "qa" do
      base("waiting_for_build", "Waiting for a build", "The app for this commit is being built for QA.", "QA starts when the build is ready.", reason.set_at, reason.waits_on)
    else
      base("waiting_for_build", "Waiting for a build", sentence(reason.text), "It starts when the build is ready.", reason.set_at, reason.waits_on)
    end
  end

  defp situation("waiting_for_slot", ctx) do
    ahead = runs_ahead(ctx)
    cause = slots_sentence(ahead, ctx.live.limit)
    cause = if run = due_run(ctx), do: "#{next_words(run)} #{cause}", else: cause

    base("waiting_for_slot", "Waiting for a slot", cause, "Starts when a slot frees.", ctx.slot[:since], %{slot: ctx.slot[:reason]})
  end

  defp situation("working", %{running: running} = ctx) do
    started = open_run(ctx.events)
    run_kind = run_kind(started, running)
    label = run_label(started, run_kind)
    step = current_step(started, ctx.events) || live_step(running)
    word = if step, do: "Working on the #{step.id} step", else: "Working"
    run = %{id: started && Map.get(started.payload, :run_id), kind: run_kind, number: started && Map.get(started.payload, :run_number), label: label}

    base("working", word, "#{label} is #{Map.get(@doing, run_kind, "working on it")}.", hand_off(run_kind, ctx), (step && step.at) || running[:started_at], step && %{step: step.id, run_id: run.id})
    |> Map.merge(%{run: run, step: step && Map.take(step, [:id, :title])})
  end

  defp situation("done", ctx) do
    at = done_at(ctx)
    number = ticket_pr_number(ctx)

    cause =
      case {number, at} do
        {nil, _at} -> "It is done."
        {number, nil} -> "Merged as PR ##{number}."
        {number, at} -> "Merged as PR ##{number} at #{clock(at)}."
      end

    base("done", "Shipped", cause, nil, at)
  end

  defp situation("cancelled", ctx) do
    event = ctx.events |> Enum.filter(&(&1.type == "ticket.cancelled")) |> List.last()
    base("cancelled", "Cancelled", cancelled_sentence(event), nil, (event && event.at) || ctx.record.phase_at)
  end

  # Nothing holds the ticket and no run works on it: what it waits on is read from the watcher's
  # decision and its outcome, the run store and the slots, the record the machine acts on.
  defp situation(:nothing, ctx) do
    case due_run(ctx) do
      nil -> undecided(decision(ctx), ctx)
      run -> due(run, ctx)
    end
  end

  # The run the watcher's decision needs next and why, or the phase's own run for a ticket the watcher
  # has no decision on (a Todo ticket, an In Progress one before its PR). Nil when the decision waits
  # on something else.
  defp due_run(ctx) do
    case decision(ctx) do
      %{kind: kind} = decision when kind in @run_kinds ->
        %{label: run_label_for(decision, ctx), why: decision[:reason], since: decision[:since], silent?: silent?(ctx)}

      nil ->
        phase_run(ctx)

      _wait ->
        nil
    end
  end

  defp phase_run(ctx) do
    case Map.fetch(@phase_runs, ctx.phase) do
      {:ok, label} -> %{label: label, why: nil, since: ctx.record.phase_at, silent?: false}
      :error -> nil
    end
  end

  defp decision(%{record: %{pr_watch: %{decision: %{} = decision}}}), do: decision
  defp decision(_ctx), do: nil

  defp silent?(%{record: %{pr_watch: watch}}), do: SilentWait.listed?(Map.get(watch, :silent))

  defp run_label_for(%{kind: :ci_fix, args: %{cause: :conflict}}, _ctx), do: "The conflict fix run"
  defp run_label_for(%{kind: :ci_fix}, _ctx), do: "The CI Fix run"
  defp run_label_for(%{kind: :land_agent}, _ctx), do: "The landing run"
  defp run_label_for(%{args: %{phase: phase}}, _ctx), do: phase_run_label(phase)
  defp run_label_for(_decision, ctx), do: phase_run_label(ctx.facts && ctx.facts.phase)

  defp phase_run_label(:code_review), do: "The review"
  defp phase_run_label(:qa), do: "The QA run"
  defp phase_run_label(:rework), do: "The rework run"
  defp phase_run_label(:in_progress), do: "The implementation run"
  defp phase_run_label(_phase), do: "The next run"

  defp next_words(%{label: label, why: why}) when is_binary(why), do: "#{label} is next: #{sentence(why)}"
  defp next_words(%{label: label}), do: "#{label} is next."

  # A run is due. Symphony's pause holds it; every slot in use holds it; with a slot free it starts on
  # the next dispatch pass, unless the watcher found it never started.
  defp due(run, %{live: %{symphony_pause: %{} = pause}}) do
    stop = if pause[:reason], do: "Dispatch is paused: #{sentence(pause.reason)}", else: "Dispatch is paused."
    base("paused_by_rule", "Paused", "#{stop} #{next_words(run)}", rule_lifts(:symphony_pause), pause[:paused_at] || run.since)
  end

  defp due(run, ctx) do
    cond do
      slots_full?(ctx) ->
        base("waiting_for_slot", "Waiting for a slot", "#{next_words(run)} #{slots_sentence(map_size(ctx.live.running), ctx.live.limit)}", "Starts when a slot frees.", run.since)

      run.silent? ->
        why = if is_binary(run.why), do: ": #{sentence(run.why)}", else: "."
        base("waiting_on_you", "Not started", "#{run.label} is due and a slot is free, but no run started#{why}", "It is listed in the Inbox until a run starts.", run.since)

      true ->
        why = if is_binary(run.why), do: ": #{sentence(run.why)}", else: "."
        base("waiting_for_slot", "Starting", "#{run.label} is next and a slot is free#{why}", "It starts on the next dispatch pass.", run.since)
    end
  end

  defp slots_full?(%{live: %{limit: limit, running: running}}), do: is_integer(limit) and map_size(running) >= limit

  # The decision waits on something that is not a run, and says on what in its own words.
  defp undecided(%{owner: owner, reason: reason, clears_when: clears_when} = decision, _ctx) when owner in [:ci, :github] and is_binary(reason) do
    word = if owner == :ci, do: "Waiting for CI", else: "Waiting on GitHub"
    base("waiting_for_ci", word, sentence(reason), clears(clears_when), decision[:since])
  end

  defp undecided(%{owner: :person, reason: reason, clears_when: clears_when} = decision, _ctx) when is_binary(reason) do
    base("waiting_on_you", "Waiting on you", sentence(reason), clears(clears_when), decision[:since])
  end

  defp undecided(%{owner: :symphony, reason: reason, clears_when: clears_when} = decision, _ctx) when is_binary(reason) do
    base("waiting_for_ci", "Waiting on Symphony", sentence(reason), clears(clears_when), decision[:since])
  end

  # The decision was made while a run worked, and that run ended: the watcher reads the PR next.
  defp undecided(%{owner: :agent} = decision, ctx) do
    ended = last_run_end(ctx)
    cause = if ended, do: "The last run ended at #{clock(ended)}; Symphony reads the PR again next.", else: "No run is working on it; Symphony reads the PR again next."
    base("waiting_for_ci", "Reading the PR", cause, "The next step follows that read.", ended || decision[:since])
  end

  defp undecided(_decision, ctx) do
    base("waiting_on_you", "Not known", "Symphony can't tell what it waits on.", "Check it now from its page.", ctx.record.phase_at)
  end

  defp clears(when_text) when is_binary(when_text) and when_text != "", do: "It moves on when #{String.trim_trailing(when_text, ".")}."
  defp clears(_when_text), do: nil

  defp base(kind, word, cause, next, since, waits_on \\ nil) do
    %{
      kind: kind,
      word: word,
      cause: cause,
      next: next,
      since: since,
      waits_on: waits_on,
      and_more: 0,
      step: nil,
      run: nil,
      retry: nil
    }
  end

  # The pause's reasons the situation does not already name, and a cause within what the event keeps.
  defp finish(situation, ctx) do
    %{situation | and_more: length(ctx.reasons) - if(headline_reason?(situation, ctx), do: 1, else: 0), cause: cut(situation.cause)}
  end

  defp headline_reason?(%{kind: kind}, ctx) do
    case kind do
      "waiting_on_you" -> reason(ctx, :question) != nil
      "blocked_by_ticket" -> reason(ctx, :ticket) != nil
      "paused_by_rule" -> rule_reason(ctx) != nil
      "waiting_for_build" -> reason(ctx, :build) != nil
      _other -> false
    end
  end

  defp asked(question, ctx) do
    title = Map.get(question, :title) || Map.get(question, :question) || "a question"

    base("waiting_on_you", "Waiting on you", "#{asker(question, ctx)} asked: #{title}.", "Answer below; the next run starts at once.", Map.get(question, :asked_at), %{question_id: question.id})
  end

  defp waiting_on_you_without_question(%{} = reason, _ctx) do
    base("waiting_on_you", "Waiting on you", sentence(reason.text), "Answer below; the next run starts at once.", reason.set_at, reason.waits_on)
  end

  defp waiting_on_you_without_question(nil, ctx) do
    base("waiting_on_you", "Waiting on you", "The plan is ready for your review.", "Approve it or ask for changes.", ctx.record.phase_at, %{phase: ctx.record.phase})
  end

  # Who asked: the run by its name in the ledger, else who the question names.
  defp asker(%{asked_by: %{run_id: run_id}} = _question, ctx) when is_binary(run_id) do
    case Enum.find(ctx.events, &(&1.type == "run.started" and Map.get(&1.payload, :run_id) == run_id)) do
      %Event{payload: payload} -> Summary.run_name(payload)
      nil -> "A run"
    end
  end

  defp asker(%{asked_by: %{kind: :person}}, _ctx), do: "You"
  defp asker(%{asked_by: %{name: name}}, _ctx) when is_binary(name), do: name
  defp asker(_question, _ctx), do: "Symphony"

  defp stopped(error) when is_binary(error) and error != "", do: "The run stopped: #{error |> String.split("\n") |> hd() |> sentence()}"
  defp stopped(_error), do: "The run stopped."

  defp last_run_end(ctx) do
    case ctx.events |> Enum.filter(&(&1.type == "run.ended")) |> List.last() do
      %Event{at: at} -> at
      nil -> nil
    end
  end

  defp blocked(identifier, phase, fallback, since) do
    cause = if is_binary(phase), do: "It is in #{phase}.", else: sentence(fallback)
    base("blocked_by_ticket", "Blocked by #{identifier}", cause, "Starts when #{identifier} lands.", since, %{ticket: identifier})
  end

  # The ticket's own record says its phase; the link Linear's last read saw is older.
  defp phase_of_ticket(identifier, ctx) do
    ctx.phase_of.(identifier) || Enum.find_value(ctx.record.blockers, &(&1.identifier == identifier && &1.state))
  end

  defp lifts(%{waits_on: %{action: action}}) when is_binary(action), do: "Starts when you #{action} it."
  defp lifts(_reason), do: "Starts when that clears."

  defp paused_without_reason(%{phase: "backlog"} = ctx) do
    base("paused_by_rule", "Paused", "It is in Backlog.", "Starts when you move it to Todo.", ctx.record.phase_at)
  end

  defp paused_without_reason(%{skipped: %{} = skipped}) do
    base("paused_by_rule", "Paused", (skipped[:reason] || "Dispatch passed over it") |> capitalized() |> sentence(), rule_lifts(skipped.rule), skipped[:since])
  end

  defp paused_without_reason(%{live: %{symphony_pause: pause}}) do
    cause = if pause[:reason], do: "Dispatch is paused: #{sentence(pause.reason)}", else: "Dispatch is paused."
    base("paused_by_rule", "Paused", cause, rule_lifts(:symphony_pause), pause[:paused_at])
  end

  defp rule_lifts(:repository_pause), do: "Starts when you resume the repository."
  defp rule_lifts(:symphony_pause), do: "Starts when you resume dispatch."
  defp rule_lifts(_rule), do: "Starts when that clears."

  defp first_check(%PrDecision.Facts{missing_checks: missing, running_checks: running}), do: List.first(missing ++ running)
  defp first_check(nil), do: nil

  # The phase that starts when the checks pass: the one the ticket is in, once it was handed off; a
  # CI Fix returns where it came from.
  defp next_phase(%{slot: %{ci_wait: true}}), do: "Merging"
  defp next_phase(%{facts: %{phase: :code_review, review: :approved}}), do: "QA"
  defp next_phase(%{facts: %{phase: :ci_fix}} = ctx), do: ctx.record.ci_fix_origin || "Code Review"
  defp next_phase(%{facts: %{phase: phase}} = ctx) when phase in @handed_off, do: ctx.record.phase || "Code Review"
  defp next_phase(_ctx), do: "Code Review"

  # The push of the head under check is when its checks started; a head no push of Symphony's
  # recorded reads from when the watcher first decided to wait on it. A Merging hold the watcher has
  # no read of reads from when the hold began.
  defp checks_started(%{record: %{pr_watch: nil}, slot: slot}), do: slot[:since]

  defp checks_started(%{record: %{pr_watch: watch}} = ctx) do
    pushed =
      ctx.events
      |> Enum.filter(&(&1.type == "attempt.pushed" and Map.get(&1.payload, :head) == watch.head_sha))
      |> List.last()

    (pushed && pushed.at) || (watch.decision || %{})[:since] || watch[:read_at]
  end

  defp runs_ahead(%{slot: slot, live: live}) do
    waiting_before =
      Enum.count(live.slot_waiting, fn {_issue_id, other} ->
        other[:ci_wait] != true and match?(%DateTime{}, other[:since]) and match?(%DateTime{}, slot[:since]) and DateTime.compare(other.since, slot.since) == :lt
      end)

    map_size(live.running) + waiting_before
  end

  defp slots_sentence(ahead, limit) do
    ahead_words =
      case ahead do
        0 -> "No runs are ahead of it"
        1 -> "One run is ahead of it"
        n -> "#{String.capitalize(number(n))} runs are ahead of it"
      end

    if limit, do: "#{ahead_words}; Symphony runs #{number(limit)} at a time.", else: "#{ahead_words}."
  end

  defp number(n) when n in 1..12, do: Enum.at(@numbers, n - 1)
  defp number(n), do: Integer.to_string(n)

  # The newest `run.started` no `run.ended` names.
  defp open_run(events) do
    ended = for %Event{type: "run.ended", payload: payload} <- events, into: MapSet.new(), do: Map.get(payload, :run_id)

    events
    |> Enum.filter(&(&1.type == "run.started" and not MapSet.member?(ended, Map.get(&1.payload, :run_id))))
    |> List.last()
  end

  defp run_kind(%Event{payload: %{run_kind: run_kind}}, _running), do: run_kind
  defp run_kind(_started, running), do: name(running[:run_kind])

  defp run_label(%Event{payload: payload}, _run_kind), do: Summary.run_name(payload)
  defp run_label(nil, run_kind), do: Summary.run_name(%{run_kind: run_kind})

  # The step the run started and did not complete.
  defp current_step(nil, _events), do: nil

  defp current_step(%Event{payload: %{run_id: run_id}}, events) do
    steps = Enum.filter(events, &(&1.run_id == run_id and &1.type in ["step.started", "step.completed"]))

    case List.last(steps) do
      %Event{type: "step.started", payload: payload, at: at} -> %{id: payload.step_id, title: Map.get(payload, :title), at: at}
      _none_or_completed -> nil
    end
  end

  defp live_step(%{step: %{id: id} = step}) when is_binary(id), do: %{id: id, title: Map.get(step, :title), at: Map.get(step, :started_at)}
  defp live_step(_running), do: nil

  defp hand_off("ci_fix", ctx), do: "It hands back to #{ctx.record.ci_fix_origin || "Code Review"} when it pushes."
  defp hand_off(run_kind, _ctx), do: Map.get(@hand_off, run_kind, "It hands off when it ends.")

  # A ticket in Done merged when it got there, as a merged PR closes its ticket out at once. Before
  # that the merge is known from the watcher's read of it, and the phase's time is only when the ticket
  # entered Merging.
  defp done_at(%{phase: "done"} = ctx), do: ctx.record.phase_at
  defp done_at(%{record: %{pr_watch: watch}} = ctx), do: watch[:read_at] || ctx.record.phase_at

  # The ticket's PR: the watcher's last read, else the push the ledger holds, else the ticket's pull
  # request.
  defp ticket_pr_number(ctx) do
    (ctx.facts && ctx.facts.pr_number) || pushed_pr_number(ctx.events) || recorded_pr_number(ctx.record)
  end

  defp pushed_pr_number(events) do
    events
    |> Enum.filter(&(&1.type == "attempt.pushed"))
    |> Enum.find_value(&pr_number(Map.get(&1.payload, :pr_url)))
  end

  defp recorded_pr_number(%{repo_key: repo_key, issue_id: issue_id}) when is_binary(issue_id) do
    case TicketPullRequest.get(repo_key, issue_id) do
      %{pr_url: url} -> pr_number(url)
      _none -> nil
    end
  end

  defp recorded_pr_number(_record), do: nil

  defp pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_url, number] -> String.to_integer(number)
      nil -> nil
    end
  end

  defp pr_number(_url), do: nil

  defp cancelled_sentence(nil), do: "It was cancelled."

  defp cancelled_sentence(%Event{payload: payload, actor: actor}) do
    who = if match?(%{kind: :person}, actor), do: "You cancelled it", else: "It was cancelled"

    case payload |> Map.get(:pull_requests_closed, []) |> Enum.find_value(&pr_number/1) do
      nil -> who <> "."
      number -> "#{who}; PR ##{number} was closed."
    end
  end

  defp sentence(text) do
    text = String.trim(text)
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  defp capitalized(text) do
    {first, rest} = String.split_at(text, 1)
    String.upcase(first) <> rest
  end

  defp cut(text), do: if(String.length(text) > @max_cause, do: String.slice(text, 0, @max_cause - 1) <> "…", else: text)

  defp normalized(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalized(_value), do: nil

  defp name(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp name(value), do: value

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_at), do: nil
end
