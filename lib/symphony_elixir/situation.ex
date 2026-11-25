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
  then "Not started", which Symphony tries again. "Starting" is said only of a ticket the dispatch
  order would start (`live_facts/2`'s `order`, `SymphonyElixir.Dispatch.Order.place/1`): one the
  order leaves waiting reads `waiting_for_slot` with its place in line and the ticket just ahead of
  it, as the order read says, whatever the count of runs (a slot held with no run is not free). Once the dispatch pass paused it for that
  (`SymphonyElixir.PrWatch.StalledRun`), the pause itself reads "Not started" (`waiting_on_you`) and
  the Inbox lists it from that pause. "Waiting for a slot" is never said while a slot is free. A
  decision that waits on something else says what it waits on in its own words: CI or GitHub
  (`waiting_for_ci`), a person (`waiting_on_you`), Symphony's upkeep, or a run that already ended,
  whose PR the watcher reads next. A ticket in `Code Review`, `QA` or `Merging` the watcher has not
  decided on yet reads "Reading the PR", as the dispatch gate says. When Symphony can tell none of
  that, the situation says so ("Not known", `unknown`) and never borrows another one's words, and
  `sync/3` logs a warning naming the ticket and its phase when a ticket comes to it;
  `not_known?/2` is the same reading, and the Inbox lists the ticket from it
  (`SymphonyElixir.Inbox.FromRecord`). A plan in `Plan Review` reads `waiting_on_you`, a parent the
  dispatch pass held for its sub-tickets, or one in `Waiting on sub-tickets` with one still open,
  `waiting_on_sub_tickets` ("2 of 5 done", `waits_on` the open ones), and a ticket in `Backlog`
  `paused_by_rule`. A ticket the dispatch pass held on a stored dependency that is not met (the
  `:depends_on` gate, `SymphonyElixir.Dispatch.DependsOn`) reads `blocked_by_ticket` exactly as one
  paused on a blocker does: "Blocked by TP-1", `waits_on` that ticket, its phase as the cause; the
  ticket named is the first dependency whose ticket is not Done, else the first that needs a
  Symphony update including it, whose cause says so. A ticket that is no plan, which its PR's merge put in `Waiting on sub-tickets`
  and whose sub-tickets all ended, reads `waiting_for_ci` "Closing": Symphony moves it to `Done` on
  its next poll. Only a plan there has "The epic review" next.

  A ticket the dispatch pass held because the Director paused its run's provider and no fallback of
  its run can take it (its skip's `rule` is `:provider_pause`, naming the `provider`) reads
  `waiting_for_provider`, "Waiting: you paused Anthropic", never a slot's or a rule's words; one held
  because its provider is at its reserve (a `:usage_limit` skip naming the `provider` and its
  `reserve`) reads `waiting_for_provider` too, "Waiting: Anthropic is at its 90% reserve", and so
  does one held, or whose retry is held, because no agent can sign in to its provider (a skip or a
  retry with `cause: :sign_in`, `SymphonyElixir.UsageLimit.sign_in_failed?/1`): "Waiting: the agent
  can't sign in to Anthropic", with the provider's message and since when, never "Retrying".

  `waiting_for_slot` is said only of a ticket that passed every dispatch condition but a free slot.
  A dispatch skip reads `paused_by_rule` only when the orchestrator names the rule behind it (its
  entry's `rule`); any other skip is told by the gate that closed (its entry's `gate`), never by the
  slot: a run already on it, a claim in flight ("Starting"), Linear's relations or a plan being
  replaced, CI, a build, its own pause, and one the pass can't tell apart reads "Not started"
  (`unknown`). A rule stops dispatch and nothing else, so a ticket a run works on is not paused by
  it. A Merging ticket the orchestrator holds until CI settles shows among its slot waits
  (`ci_wait`) and reads `waiting_for_ci`; any other slot wait reads `paused_by_rule` while
  Symphony's own pause lasts. A ticket paused on a wait for CI on a commit (an epic review held for
  CI on its base branch, `SymphonyElixir.EpicReview.MainCi`) and one whose run ended on CI still
  running and starts again after it read `waiting_for_ci` in the wait's own words: the commit and the
  workflows still running.
  """

  require Logger

  alias SymphonyElixir.AgentProviders
  alias SymphonyElixir.{CiWait, Config, PrDecision, RunStore, TicketEvents, TicketPullRequest, TicketState}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Dispatch.{DependsOn, Order}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrWatch.{SilentWait, StalledRun}
  alias SymphonyElixir.TicketEvents.{Event, Summary}

  @kinds ~w(waiting_on_you retrying blocked_by_ticket waiting_on_sub_tickets waiting_for_provider paused_by_rule waiting_for_ci waiting_for_build waiting_for_slot working done cancelled unknown)

  # A retry that follows a run's normal end, or a wait on something that is not broken, is no retry
  # to a person: only a failure, or a usage limit, reads as `retrying`.
  @quiet_retries [:continuation, :linear_wait, :ci_wait]
  @handed_off [:code_review, :qa, :merging, :ci_fix]
  @max_cause 300
  # The watcher's decisions a run carries out, which the orchestrator starts.
  @run_kinds [:dispatch, :ci_fix, :land_agent]
  # The phases whose next run is the phase's own when the watcher has no decision on the ticket.
  # A parent whose sub-tickets all ended moves to Epic Review, where its epic review runs.
  @phase_runs %{
    "todo" => "The implementation run",
    "in progress" => "The implementation run",
    "rework" => "The rework run",
    "ci fix" => "The CI Fix run",
    "waiting on sub-tickets" => "The epic review",
    "epic review" => "The epic review"
  }
  # The phases whose run waits on the watcher's decision on the PR (`SymphonyElixir.PrWatch.dispatch_reason/2`).
  @watched_phases ["code review", "qa", "merging"]
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
          order: %{optional(String.t()) => place_in_line()},
          limit: pos_integer() | nil,
          symphony_pause: %{optional(:reason) => String.t() | nil, optional(:paused_at) => DateTime.t() | nil} | nil,
          max_tries: pos_integer(),
          terminal_states: [String.t()]
        }

  @typedoc "A ticket's place in the dispatch order while it waits in line."
  @type place_in_line :: %{position: pos_integer(), wait: String.t() | nil, behind: String.t() | nil}

  @typedoc "The phase of a ticket named by its identifier, when Symphony knows it."
  @type phase_of :: (String.t() -> String.t() | nil)

  @doc "The closed vocabulary, in the design's precedence."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The facts `compute/4` reads from an orchestrator snapshot. `now` turns a retry's remaining time into
  the time it starts; `settings` give the tries and the terminal states (the workflow's by default).
  """
  @spec live_facts(map(), DateTime.t(), Schema.t() | nil) :: live_facts()
  def live_facts(snapshot, now \\ DateTime.utc_now(), settings \\ nil) do
    settings = settings || Config.settings!()

    %{
      running: by_issue(snapshot, :running, &Map.take(&1, [:run_kind, :started_at, :step])),
      retrying: by_issue(snapshot, :retrying, &retry_facts(&1, now)),
      slot_waiting: by_issue(snapshot, :slot_waiting, &Map.take(&1, [:since, :reason, :ci_wait])),
      skipped: by_issue(snapshot, :dispatch_skipped, &Map.take(&1, [:since, :reason, :rule, :gate, :provider, :reserve, :cause, :error, :sign_in_since])),
      order: snapshot |> Map.get(:dispatch_order) |> waiting_in_line(),
      limit: snapshot |> Map.get(:concurrency) |> max_total(),
      symphony_pause: snapshot |> Map.get(:pause) |> symphony_pause(),
      max_tries: settings.watchdog.dispatch_loop_runs,
      terminal_states: settings.tracker.terminal_states
    }
  end

  # The tickets the dispatch order leaves waiting in line (`SymphonyElixir.Dispatch.Order.place/1`),
  # each with its place, why it waits and the ticket just ahead of it.
  defp waiting_in_line(%{entries: entries}) when is_list(entries) do
    for %{issue_id: issue_id, outcome: :waits, position: position} = entry <- entries,
        is_integer(position),
        into: %{} do
      {issue_id, %{position: position, wait: Map.get(entry, :wait), behind: Map.get(entry, :behind)}}
    end
  end

  defp waiting_in_line(_order), do: %{}

  defp max_total(%{max_total: max_total}), do: max_total
  defp max_total(_concurrency), do: nil

  defp symphony_pause(%{paused: true} = pause), do: Map.take(pause, [:reason, :paused_at])
  defp symphony_pause(_pause), do: nil

  defp by_issue(snapshot, list, facts), do: snapshot |> Map.get(list, []) |> Map.new(&{&1.issue_id, facts.(&1)})

  defp retry_facts(retry, now) do
    due_at = if is_integer(Map.get(retry, :due_in_ms)), do: DateTime.add(now, retry.due_in_ms, :millisecond)

    %{
      attempt: Map.get(retry, :attempt),
      error: Map.get(retry, :error),
      delay_type: Map.get(retry, :delay_type),
      due_at: due_at,
      sign_in: Map.get(retry, :sign_in)
    }
  end

  @doc """
  Whether `issue_id` waits for a slot in `live`, as its situation reads it (Waiting for a slot): the
  orchestrator holds it for one (`slot_waiting`, not a wait for CI), the dispatch order leaves it in
  line behind a ticket that takes the free slot, or every slot is in use. The PR and CI watcher's
  silent-wait detector (`SymphonyElixir.PrWatch.SilentWait`) reads the same fact, so a ticket whose
  decided run waits for a slot is never a silent wait.
  """
  @spec waits_for_slot?(live_facts(), String.t()) :: boolean()
  def waits_for_slot?(live, issue_id) do
    slot_held?(Map.get(live.slot_waiting, issue_id)) or place_in_line(live, issue_id) != nil or slots_full?(live)
  end

  defp slot_held?(%{ci_wait: true}), do: false
  defp slot_held?(slot), do: slot != nil

  @doc """
  What decides each ticket's kind in `live_facts`: a change of it is a reason to compute the ticket's
  situation again (`SymphonyElixir.Situation.Recorder`).
  """
  @spec live_signature(live_facts()) :: %{optional(String.t()) => tuple()}
  def live_signature(live) do
    order = Map.get(live, :order, %{})

    [live.running, live.retrying, live.slot_waiting, live.skipped, order]
    |> Enum.flat_map(&Map.keys/1)
    |> Map.new(fn issue_id ->
      slot = slot_signature(Map.get(live.slot_waiting, issue_id), live) || place_signature(Map.get(order, issue_id))
      skip = Map.get(live.skipped, issue_id) || %{}
      retry = Map.get(live.retrying, issue_id)

      running? = Map.has_key?(live.running, issue_id)

      {issue_id, {running?, failure_retry?(retry), ci_retry?(retry), slot, skip[:rule], skip[:gate]}}
    end)
  end

  defp slot_signature(nil, _live), do: nil
  defp slot_signature(%{ci_wait: true}, _live), do: :ci
  defp slot_signature(_slot, %{symphony_pause: nil}), do: :slot
  defp slot_signature(_slot, _live), do: :paused

  defp place_signature(nil), do: nil
  defp place_signature(place), do: {:in_line, place.position, place.behind}

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

  @typedoc "A situation's kind and since when it holds: what a list of tickets shows and sorts by."
  @type headline :: %{kind: kind(), since: DateTime.t() | nil}

  # The kinds whose since a ledger event says (a run's end, its step, a push, the cancel): every other
  # kind's since is its record's or the live facts', but for a ticket nothing holds whose watcher
  # waits on a run that ended.
  @ledger_kinds ["retrying", "waiting_for_ci", "working", "cancelled"]

  @doc """
  The kind and the since of `record`'s situation, as `read/3` gives them, read without its ledger
  unless the kind's since comes from it: a list of every ticket (`SymphonyElixir.TicketList`) then
  reads only the ledgers of the few tickets working, retrying, waiting for CI or cancelled.
  """
  @spec headline(map() | nil, live_facts(), [map()] | nil) :: headline()
  def headline(record, live, records \\ nil) do
    record = TicketState.normalize(record)
    ctx = context(record, [], live, phase_of(records))
    kind = Enum.find(@kinds, &holds?(&1, ctx)) || :nothing
    ctx = if ledger_since?(kind, ctx), do: %{ctx | events: ledger(record)}, else: ctx
    situation = situation(kind, ctx)
    %{kind: situation.kind, since: situation.since}
  end

  defp ledger_since?(:nothing, ctx), do: match?({:wait, %{owner: :agent}}, next_of(ctx))
  defp ledger_since?(kind, _ctx), do: kind in @ledger_kinds

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

    warn_unknown(record, situation)
    key = "situation.changed:#{(last && last.id) || "first"}:#{situation.kind}"
    TicketEvents.record(record.repo_key, record.issue_id, "situation.changed", payload, phase: record.phase, idempotency: key)
  end

  # A ticket Symphony can tell nothing of is a gap in what it knows: said once, when it starts.
  defp warn_unknown(record, %{kind: "unknown"} = situation) do
    Logger.warning("Situation not known: issue_id=#{record.issue_id} issue_identifier=#{record.issue_identifier} repo_key=#{record.repo_key} phase=#{inspect(record.phase)}; #{situation.cause}")
  end

  defp warn_unknown(_record, _situation), do: :ok

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
    ctx = context(record, events, live, phase_of)

    (Enum.find(@kinds, &holds?(&1, ctx)) || :nothing)
    |> situation(ctx)
    |> finish(ctx)
  end

  @doc """
  Whether Symphony can't tell what a normalized `record` of a ticket in a phase waits on with `live`
  (`live_facts/2`): the "Not known" situation `compute/4` gives it, read by the same derivation
  without its ledger, which only words a situation and never picks one. The Inbox lists such a
  ticket.
  """
  @spec not_known?(TicketState.t(), live_facts()) :: boolean()
  def not_known?(record, live) do
    ctx = context(record, [], live, fn _identifier -> nil end)
    watched_or_unskipped? = is_nil(ctx.gate_skip) or ctx.gate_skip[:gate] == :watch
    is_binary(record.phase) and watched_or_unskipped? and not Enum.any?(@kinds, &holds?(&1, ctx)) and next_of(ctx) == :unknown
  end

  defp context(record, events, live, phase_of) do
    issue_id = record.issue_id
    running = Map.get(live.running, issue_id)

    %{
      record: record,
      events: events,
      live: live,
      phase_of: phase_of,
      reasons: reasons(record),
      phase: normalized(record.phase),
      running: running,
      retry: live.retrying |> Map.get(issue_id) |> failure_retry(),
      ci_retry: live.retrying |> Map.get(issue_id) |> ci_retry(),
      slot: Map.get(live.slot_waiting, issue_id),
      skipped: live.skipped |> Map.get(issue_id) |> rule_skip(running),
      provider_skip: provider_skip(Map.get(live.skipped, issue_id)) || sign_in_retry(Map.get(live.retrying, issue_id)),
      gate_skip: live.skipped |> Map.get(issue_id) |> gate_skip(running),
      facts: facts(record)
    }
  end

  defp reasons(%{pause: %{reasons: reasons}}), do: reasons
  defp reasons(_record), do: []

  defp facts(%{pr_watch: %{facts: %PrDecision.Facts{} = facts}}), do: facts
  defp facts(_record), do: nil

  # A skip for a paused provider names it; nil for any other.
  defp provider_skip(%{rule: :provider_pause, provider: provider} = skip) when is_binary(provider), do: skip
  defp provider_skip(%{rule: :usage_limit, provider: provider} = skip) when is_binary(provider), do: skip
  defp provider_skip(_skip), do: nil

  # A retry held on an agent that can't sign in waits for the provider, as a skip for it does.
  defp sign_in_retry(%{sign_in: %{provider: provider} = sign_in}) when is_binary(provider),
    do: %{
      rule: :usage_limit,
      provider: provider,
      cause: :sign_in,
      error: sign_in[:error],
      sign_in_since: sign_in[:sign_in_since]
    }

  defp sign_in_retry(_retry), do: nil

  defp rule_skip(%{rule: rule} = skip, nil) when not is_nil(rule), do: skip
  defp rule_skip(_skip, _running), do: nil

  # A skip no rule is behind, on a ticket no run works on: what closed is its `gate`.
  defp gate_skip(%{} = skip, nil), do: if(is_nil(skip[:rule]), do: skip)
  defp gate_skip(_skip, _running), do: nil

  # A run that ended on CI still going on its commit starts again once CI had a while more: it waits
  # for CI, which is no failure.
  defp ci_retry(retry), do: if(ci_retry?(retry), do: retry)

  defp ci_retry?(%{delay_type: :ci_wait}), do: true
  defp ci_retry?(_retry), do: false

  defp failure_retry(retry), do: if(failure_retry?(retry), do: retry)

  defp failure_retry?(%{sign_in: %{}}), do: false
  defp failure_retry?(%{delay_type: delay_type}), do: delay_type not in @quiet_retries
  defp failure_retry?(_retry), do: false

  defp holds?("waiting_on_you", ctx), do: open_questions(ctx) != [] or reason(ctx, :question) != nil or ctx.phase == "plan review"
  defp holds?("retrying", ctx), do: ctx.retry != nil
  defp holds?("blocked_by_ticket", ctx), do: reason(ctx, :ticket) != nil or depends_on_skip?(ctx)
  defp holds?("waiting_on_sub_tickets", ctx), do: waits_on_sub_tickets?(ctx)
  defp holds?("waiting_for_provider", ctx), do: ctx.provider_skip != nil
  defp holds?("paused_by_rule", ctx), do: rule_reason(ctx) != nil or ctx.phase == "backlog" or ctx.skipped != nil or pause_holds_slot?(ctx)
  defp holds?("waiting_for_ci", ctx), do: ci_wait_reason(ctx) != nil or ctx.ci_retry != nil or waiting_for_ci?(ctx)
  defp holds?("waiting_for_build", ctx), do: reason(ctx, :build) != nil
  defp holds?("waiting_for_slot", ctx), do: ctx.slot != nil
  defp holds?("working", ctx), do: ctx.running != nil
  defp holds?("done", ctx), do: ctx.phase == "done" or match?(%{pr: :merged}, ctx.facts)
  defp holds?("cancelled", ctx), do: ctx.record.phase != nil and ctx.phase in Enum.map(ctx.live.terminal_states, &normalized/1)
  # Never true of its own: it is what a ticket reads when Symphony can tell nothing (`situation(:nothing, ctx)`).
  defp holds?("unknown", _ctx), do: false

  defp open_questions(ctx), do: Enum.filter(ctx.record.questions, &(&1.state == :open))

  defp reason(ctx, kind), do: Enum.find(ctx.reasons, &(&1.kind == kind))

  # The pause a run that never started set says nothing once a run works on the ticket. A wait for
  # CI on a commit is no rule's: it reads as the wait for CI it is.
  defp rule_reason(ctx) do
    Enum.find(ctx.reasons, &(&1.kind in [:person, :environment] and not CiWait.reason?(&1) and not (ctx.running != nil and StalledRun.reason?(&1))))
  end

  # The pause of a ticket waiting for CI on a commit: an epic review held for CI on its base branch
  # (`SymphonyElixir.EpicReview.MainCi`), or a wait past its limit (`SymphonyElixir.CiWait`).
  defp ci_wait_reason(ctx), do: Enum.find(ctx.reasons, &CiWait.reason?/1)

  defp pause_holds_slot?(%{slot: %{ci_wait: true}}), do: false
  defp pause_holds_slot?(ctx), do: ctx.slot != nil and ctx.live.symphony_pause != nil

  # A parent waits on its sub-tickets when the dispatch pass held it for them, or when it is in the
  # waiting state with one still open. One whose sub-tickets all ended has its epic review next.
  # A ticket that is no plan, waiting with every sub-ticket ended, is closing instead (`closing?/1`),
  # even when the dispatch pass held it in the moment before its close.
  defp waits_on_sub_tickets?(%{gate_skip: %{gate: :sub_tickets}} = ctx), do: not closing?(ctx)
  defp waits_on_sub_tickets?(%{phase: "waiting on sub-tickets"} = ctx), do: open_sub_issues(ctx) != []
  defp waits_on_sub_tickets?(_ctx), do: false

  # Its merge put it there (`SymphonyElixir.RunStore.merged_wait?/1`): one a person moved there
  # waits for them, and the close leaves it alone.
  defp closing?(%{phase: "waiting on sub-tickets"} = ctx),
    do: not plan?(ctx) and open_sub_issues(ctx) == [] and RunStore.merged_wait?(ctx.record.issue_id) == true

  defp closing?(_ctx), do: false

  defp plan?(ctx), do: Enum.any?(ctx.record.labels, &Issue.breakdown_label?/1)

  # A sub-ticket without a known state counts as open, as the dispatch gate counts it.
  defp open_sub_issues(ctx) do
    terminal = Enum.map(ctx.live.terminal_states, &normalized/1)
    Enum.filter(ctx.record.sub_issues, &(normalized(&1.state) not in terminal))
  end

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
      %{} = reason ->
        identifier = Map.get(reason.waits_on, :identifier, "another ticket")
        blocked(identifier, phase_of_ticket(identifier, ctx), reason.text, reason.set_at)

      nil ->
        depends_on_blocked(ctx)
    end
  end

  defp situation("waiting_on_sub_tickets", ctx) do
    subs = ctx.record.sub_issues
    open = open_sub_issues(ctx)
    cause = if subs == [], do: "Its sub-tickets are still open.", else: "#{length(subs) - length(open)} of #{length(subs)} done."
    since = (ctx.gate_skip && ctx.gate_skip[:since]) || ctx.record.phase_at

    base("waiting_on_sub_tickets", "Waiting on its sub-tickets", cause, "It moves on when every sub-ticket has ended.", since, %{
      sub_tickets: open |> Enum.map(& &1.identifier) |> Enum.filter(&is_binary/1)
    })
  end

  defp situation("waiting_for_provider", %{provider_skip: %{rule: :usage_limit, cause: :sign_in, provider: provider} = skip} = ctx) do
    name = AgentProviders.display_name(provider)
    since = skip[:sign_in_since]
    message = if is_binary(skip[:error]) and skip[:error] != "", do: " It answered: #{sentence(skip[:error])}", else: ""
    since_words = if since, do: " since #{clock(since)}", else: ""

    base(
      "waiting_for_provider",
      "Waiting: the agent can't sign in to #{name}",
      "#{next_run_label(ctx)} runs on #{name}, and no agent has been able to sign in to it#{since_words}.#{message}",
      "Starts by itself once a sign-in to #{name} works again.",
      since || skip[:since],
      %{provider: provider}
    )
  end

  defp situation("waiting_for_provider", %{provider_skip: %{rule: :usage_limit, provider: provider} = skip} = ctx) do
    name = AgentProviders.display_name(provider)
    reserve = if is_number(skip[:reserve]), do: "its #{round(skip[:reserve] * 100)}% reserve", else: "its reserve"

    base(
      "waiting_for_provider",
      "Waiting: #{name} is at #{reserve}",
      "#{next_run_label(ctx)} runs on #{name}, which stops new runs at #{reserve}, and none of its fallbacks can take it.",
      "Starts when #{name}'s usage resets.",
      skip[:since],
      %{provider: provider}
    )
  end

  defp situation("waiting_for_provider", ctx) do
    %{provider: provider} = skip = ctx.provider_skip
    name = AgentProviders.display_name(provider)

    base(
      "waiting_for_provider",
      "Waiting: you paused #{name}",
      "#{next_run_label(ctx)} runs on #{name}, and none of its fallbacks can take it.",
      "Starts when you resume #{name}.",
      skip[:since],
      %{provider: provider}
    )
  end

  defp situation("paused_by_rule", ctx) do
    case {stalled_reason(ctx), rule_reason(ctx)} do
      {%{} = stalled, _reason} -> not_started(stalled)
      {nil, nil} -> paused_without_reason(ctx)
      {nil, reason} -> base("paused_by_rule", "Paused", sentence(reason.text), lifts(reason), reason.set_at, reason.waits_on)
    end
  end

  defp situation("waiting_for_ci", %{ci_retry: nil} = ctx) do
    case ci_wait_reason(ctx) do
      nil -> pr_checks(ctx)
      reason -> base("waiting_for_ci", "Waiting for CI", sentence(reason.text), "#{next_run_label(ctx)} starts when CI finishes.", reason.set_at, reason.waits_on)
    end
  end

  # The run ended on CI still going on its commit, and starts again after it: the run's words name
  # the commit and the workflows still running.
  defp situation("waiting_for_ci", %{ci_retry: retry} = ctx) do
    cause = if is_binary(retry.error) and retry.error != "", do: retry.error |> capitalized() |> sentence(), else: "CI is still running on its commit."
    time = if retry.due_at, do: " at #{clock(retry.due_at)}.", else: " soon."

    base("waiting_for_ci", "Waiting for CI", cause, "#{next_run_label(ctx)} starts again#{time}", last_run_end(ctx) || ctx.record.phase_at)
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

  # A ticket that is no plan, waiting on sub-tickets that all ended, has no epic review next:
  # Symphony moves it to Done itself on its next poll, with no run (`SymphonyElixir.SubIssueWait.close?/3`).
  defp situation(:nothing, ctx) do
    if closing?(ctx),
      do: base("waiting_for_ci", "Closing", "Every sub-ticket has ended, so Symphony moves it to Done; no run is needed.", "It moves to Done on the next poll.", ctx.record.phase_at),
      else: nothing(ctx)
  end

  # Nothing holds the ticket and no run works on it. When the dispatch pass passed it over, what
  # closed (the skip's `gate`) says what it waits on: it passed no condition but a slot, so it never
  # waits for one. The watcher's own gate is read from its decision, as for a ticket nothing skipped.
  defp nothing(%{gate_skip: %{} = skip} = ctx) do
    case skip[:gate] do
      :watch -> watched(skip, ctx)
      gate -> skipped(gate, skip, ctx)
    end
  end

  # What it waits on is read from the watcher's decision and its outcome, the run store and the
  # slots, the record the machine acts on.
  defp nothing(ctx), do: from_record(ctx)

  defp from_record(ctx) do
    case next_of(ctx) do
      {:run, run} -> due(run, ctx)
      {:wait, decision} -> undecided(decision, ctx)
      :reading -> base("waiting_for_ci", "Reading the PR", "The PR watcher reads its PR next.", "The next step follows that read.", ctx.record.phase_at)
      :unknown -> base("unknown", "Not known", "Symphony can't tell what it waits on.", unknown_next(ctx.record), ctx.record.phase_at)
    end
  end

  # The watcher's gate closed while its record names a run: the gate is the newer read, and the
  # watcher reads the PR again next. Under Symphony's pause the pause holds it.
  defp watched(skip, ctx) do
    case {next_of(ctx), ctx.live.symphony_pause} do
      {{:run, _run}, nil} -> base("waiting_for_ci", "Reading the PR", skip_cause(skip), "The next step follows that read.", skip[:since])
      _other -> from_record(ctx)
    end
  end

  defp skipped(:claimed, skip, ctx) do
    case ctx.live.retrying |> Map.get(ctx.record.issue_id) do
      %{delay_type: :linear_wait} = retry -> base("waiting_for_ci", "Waiting on Linear", linear_cause(retry), retry_next(retry), skip[:since])
      _retry_or_dispatch -> base("working", "Starting", "#{run_label_now(ctx)} is starting.", "It is working in a moment.", skip[:since])
    end
  end

  defp skipped(:settle, skip, _ctx) do
    base("waiting_for_ci", "Waiting on Linear", "Linear created it a moment ago; Symphony reads its relations first.", "It starts on the next dispatch pass.", skip[:since])
  end

  defp skipped(:replan, skip, _ctx) do
    base("waiting_for_ci", "Waiting on Symphony", skip_cause(skip), "It starts once the new plan is in.", skip[:since])
  end

  defp skipped(:running, skip, _ctx), do: base("working", "Working", "A run is working on it.", nil, skip[:since])
  defp skipped(:merging_ci, skip, _ctx), do: base("waiting_for_ci", "Waiting for CI", skip_cause(skip), "Merging starts when they pass.", skip[:since])

  defp skipped(gate, skip, _ctx) when gate in [:paused, :not_candidate] do
    base("paused_by_rule", "Paused", skip_cause(skip), "Starts when that clears.", skip[:since])
  end

  defp skipped(gate, skip, _ctx) when gate in [:instructions_hold, :update_hold, :qa_build] do
    base("waiting_for_build", "Waiting for a build", skip_cause(skip), "It starts when the build is ready.", skip[:since])
  end

  # The run was due and did not start, for a reason the pass could not tell apart.
  defp skipped(_gate, skip, _ctx) do
    base("unknown", "Not started", skip_cause(skip), "Symphony tries again on its next poll.", skip[:since])
  end

  defp skip_cause(skip), do: (skip[:reason] || "Dispatch passed over it") |> capitalized() |> sentence()

  defp linear_cause(%{error: error}) when is_binary(error) and error != "", do: error |> String.split("\n") |> hd() |> capitalized() |> sentence()
  defp linear_cause(_retry), do: "Linear did not answer."

  defp retry_next(%{due_at: %DateTime{} = at}), do: "It starts again at #{clock(at)}."
  defp retry_next(_retry), do: "It starts again soon."

  defp run_label_now(ctx) do
    case due_run(ctx) do
      %{label: label} -> label
      nil -> "A run"
    end
  end

  # What a ticket nothing holds waits on next: a run, a wait the decision names, the watcher's first
  # decision on its PR (the dispatch gate's reason), or nothing Symphony can tell.
  defp next_of(ctx) do
    decision = decision(ctx)

    cond do
      run = due_run(ctx) -> {:run, run}
      known_wait?(decision) -> {:wait, decision}
      is_nil(decision) and ctx.phase in @watched_phases -> :reading
      true -> :unknown
    end
  end

  # A ticket with a phase is one Symphony tracks, and the Inbox lists it (`not_known?/2`).
  defp unknown_next(%{phase: phase}) when is_binary(phase), do: "It is listed in the Inbox; check it now from its page."
  defp unknown_next(_record), do: "Check it now from its page."

  defp known_wait?(%{owner: owner, reason: reason}) when owner in [:ci, :github, :person, :symphony] and is_binary(reason), do: true
  defp known_wait?(%{owner: :agent}), do: true
  defp known_wait?(_decision), do: false

  # The pause a dispatch pass set on a run that never started (`SymphonyElixir.PrWatch.StalledRun`):
  # the Inbox lists the ticket from it, and the Director's Unblock starts the run.
  defp stalled_reason(%{running: nil} = ctx), do: Enum.find(ctx.reasons, &StalledRun.reason?/1)
  defp stalled_reason(_ctx), do: nil

  defp not_started(reason) do
    base("waiting_on_you", "Not started", sentence(reason.text), "It is listed in the Inbox; Unblock starts the run.", reason.set_at, reason.waits_on)
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

  # Only a plan has an epic review: a ticket that is no plan waiting on sub-tickets has no run next.
  defp phase_run(%{phase: "waiting on sub-tickets"} = ctx) do
    if plan?(ctx), do: %{label: @phase_runs["waiting on sub-tickets"], why: nil, since: ctx.record.phase_at, silent?: false}
  end

  defp phase_run(ctx) do
    case Map.fetch(@phase_runs, ctx.phase) do
      {:ok, label} -> %{label: label, why: nil, since: ctx.record.phase_at, silent?: false}
      :error -> nil
    end
  end

  # The watcher's decision on the ticket in the phase it is in. A decision made in another phase (R25
  # moved it back from CI Fix) is done: the watcher reads the PR in the new phase next.
  defp decision(%{record: %{pr_watch: %{decision: %{} = decision}}} = ctx), do: if(decided_here?(ctx), do: decision)
  defp decision(_ctx), do: nil

  defp decided_here?(%{facts: %PrDecision.Facts{phase: phase}, phase: current}) when is_atom(phase) and not is_nil(phase),
    do: phase |> Atom.to_string() |> String.replace("_", " ") == current

  defp decided_here?(_ctx), do: true

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
      place = in_line(ctx) ->
        base("waiting_for_slot", "Waiting for a slot", "#{next_words(run)} #{place_sentence(place)}", "Starts when a slot frees.", run.since)

      slots_full?(ctx) ->
        base("waiting_for_slot", "Waiting for a slot", "#{next_words(run)} #{slots_sentence(map_size(ctx.live.running), ctx.live.limit)}", "Starts when a slot frees.", run.since)

      run.silent? ->
        why = if is_binary(run.why), do: ": #{sentence(run.why)}", else: "."
        base("waiting_for_slot", "Not started", "#{run.label} is due and a slot is free, but no run started yet#{why}", "Symphony tries to start it again on its next poll.", run.since)

      true ->
        why = if is_binary(run.why), do: ": #{sentence(run.why)}", else: "."
        base("waiting_for_slot", "Starting", "#{run.label} is next and a slot is free#{why}", "It starts on the next dispatch pass.", run.since)
    end
  end

  defp slots_full?(%{live: live}), do: slots_full?(live)
  defp slots_full?(%{limit: limit, running: running}), do: is_integer(limit) and map_size(running) >= limit

  # The ticket's place when the dispatch order leaves it waiting: a ticket ahead of it takes the free
  # slot, or every slot is taken, by a run or by a ticket that holds one with no run.
  defp in_line(%{live: live, record: record}), do: place_in_line(live, record.issue_id)

  defp place_in_line(live, issue_id), do: live |> Map.get(:order, %{}) |> Map.get(issue_id)

  defp place_sentence(%{position: 1, wait: wait}), do: "It is next in line: #{sentence(to_string(wait))}"
  defp place_sentence(%{position: position, behind: behind}), do: "It is #{Order.ordinal(position)} in line, behind #{behind}."

  # The decision waits on something that is not a run, and says on what in its own words.
  defp undecided(%{owner: owner, reason: reason} = decision, _ctx) when owner in [:ci, :github] do
    word = if owner == :ci, do: "Waiting for CI", else: "Waiting on GitHub"
    base("waiting_for_ci", word, sentence(reason), clears(decision[:clears_when]), decision[:since])
  end

  defp undecided(%{owner: :person, reason: reason} = decision, _ctx) do
    base("waiting_on_you", "Waiting on you", sentence(reason), clears(decision[:clears_when]), decision[:since])
  end

  defp undecided(%{owner: :symphony, reason: reason} = decision, _ctx) do
    base("waiting_for_ci", "Waiting on Symphony", sentence(reason), clears(decision[:clears_when]), decision[:since])
  end

  # The decision was made while a run worked, and that run ended: the watcher reads the PR next.
  defp undecided(%{owner: :agent} = decision, ctx) do
    ended = last_run_end(ctx)
    cause = if ended, do: "The last run ended at #{clock(ended)}; Symphony reads the PR again next.", else: "No run is working on it; Symphony reads the PR again next."
    base("waiting_for_ci", "Reading the PR", cause, "The next step follows that read.", ended || decision[:since])
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
      "waiting_on_you" -> reason(ctx, :question) != nil or stalled_reason(ctx) != nil
      "blocked_by_ticket" -> reason(ctx, :ticket) != nil
      "paused_by_rule" -> rule_reason(ctx) != nil
      "waiting_for_ci" -> ctx.ci_retry == nil and ci_wait_reason(ctx) != nil
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

  # A ticket the dispatch pass held on its stored dependencies (the `:depends_on` gate).
  defp depends_on_skip?(%{gate_skip: %{gate: :depends_on}}), do: true
  defp depends_on_skip?(_ctx), do: false

  # The dependency it waits on, named as a blocker is: the first whose ticket is not Done, else the
  # first that waits for a Symphony update including its Done ticket.
  defp depends_on_blocked(ctx) do
    since = ctx.gate_skip[:since] || ctx.record.phase_at
    dependencies = Enum.map(ctx.record.depends_on, &{&1, &1.identifier && ctx.phase_of.(&1.identifier)})

    cond do
      waited = Enum.find(dependencies, fn {_dependency, phase} -> normalized(phase) != "done" end) ->
        {dependency, phase} = waited
        blocked(dependency_name(dependency), phase, skip_cause(ctx.gate_skip), since)

      released = Enum.find(dependencies, &match?({%{kind: :released}, _phase}, &1)) ->
        {dependency, _done} = released
        identifier = dependency_name(dependency)
        cause = [dependency] |> DependsOn.reason() |> capitalized() |> sentence()
        base("blocked_by_ticket", "Blocked by #{identifier}", cause, "Starts when a Symphony update includes #{identifier}.", since, %{ticket: identifier})

      # A skip the records no longer bear out names what the pass said.
      true ->
        blocked(dependency_name(List.first(ctx.record.depends_on)), nil, skip_cause(ctx.gate_skip), since)
    end
  end

  defp dependency_name(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp dependency_name(_dependency), do: "another ticket"

  # The ticket's own record says its phase.
  defp phase_of_ticket(identifier, ctx), do: ctx.phase_of.(identifier)

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
  defp rule_lifts(:release_gate), do: "Starts when the release gate on main passes, or its fix ticket lands."
  defp rule_lifts(_rule), do: "Starts when that clears."

  defp first_check(%PrDecision.Facts{missing_checks: missing, running_checks: running}), do: List.first(missing ++ running)
  defp first_check(nil), do: nil

  # Checks running on the ticket's PR, or a Merging hold until CI settles.
  defp pr_checks(ctx) do
    number = ticket_pr_number(ctx)
    subject = if number, do: "PR ##{number}", else: "its PR"

    base("waiting_for_ci", "Waiting for CI", "Checks are running on #{subject}.", "#{next_phase(ctx)} starts when they pass.", checks_started(ctx), %{
      pr: number,
      check: first_check(ctx.facts)
    })
  end

  # The run that waits for CI on a commit: its phase's own (the epic review), else the next run.
  defp next_run_label(ctx) do
    case phase_run(ctx) do
      %{label: label} -> label
      nil -> "The next run"
    end
  end

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
