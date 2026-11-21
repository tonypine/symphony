defmodule SymphonyElixir.Conductor.Facts do
  @moduledoc """
  The facts the Conductor reads at a junction of a ticket's life (`SymphonyElixir.Conductor`), in one
  deterministic document built only from what Symphony already holds: the ticket's record
  (`SymphonyElixir.TicketState`) and its events (`SymphonyElixir.TicketEvents`), and, when the
  ticket's workspace exists, its git diff stat. `GET /api/v1/tickets/:issue_identifier/facts` serves
  it (`read/3`).

  The document (`schema: "symphony.conductor.facts/1"`):

    * `junction`: the junction it is shaped for, and `focus`, what the turn there is for;
    * `ticket`: identifier, title, URL, the description's `problem`, `acceptance` and `walkthrough`
      sections, the walkthrough steps recorded as proved by a test (`proved_steps`: each step's
      number and test, the newest proof of a step; QA's pre-check runs that test and QA does not
      walk the step), the newest brief, the person's decisions, notes and messages, and answers to
      questions;
    * `standing`: phase, coding attempt (the implementation and rework runs started), the pull
      request and its head;
    * `last_run`: the newest run that ended, other than the Conductor's own: its kind, model, exit,
      tokens, steps and their results (each step's `outcome` is its one word,
      `SymphonyElixir.TicketEvents.StepWord`: a QA check reads what it judged), the files it
      changed with a diff stat (only when the workspace exists), and the findings it marked
      resolved;
    * `findings`: every finding with its state (`open`, `resolved`, `reopened`, `confirmed`), class,
      severity, description, evidence, its resolution, and how many times its class was recorded on
      this ticket (`class_count`);
    * `verdicts`: the newest verdicts;
    * `qa_passes` (at `after_qa_blocked` only): the ticket's QA verdicts, oldest first, each with
      its outcome, head and reason, whether it was a block on CI, and the steps of its pass that
      ended blocked: a stepped pass's step answers (`status`, `expected`, `actual`) and the steps
      the pass's verdict named blocked;
    * `conductor`: the Conductor's earlier updates, instructions (with the route Symphony took on
      them, at `after_qa_blocked`) and the guidance its watch gave running runs on this ticket;
    * `budget`: tokens used against the cap (`execution.limits.tokens_per_issue`), QA passes and
      rework runs so far;
    * `filings`: the Conductor's `ticket` route on this ticket (`SymphonyElixir.Conductor.Filing.facts/3`):
      whether it is open, the tickets it already filed or linked from this ticket, how many filings
      remain, and the repos a ticket may be filed in.

  At `grooming` the ticket is new and no run has worked on it, so the document is another one
  (same `schema`, `junction` and `focus`): `ticket` (identifier, title, URL, `repo` and labels),
  `asks` (every `ask.recorded`, oldest first, word for word: its `source` and where it came
  `from`), the person's `decisions`, `notes` and `answers`, `parent` (when the ticket has one
  Symphony tracks: its identifier, title, current `plan` and the notes a run tagged), `sub_tickets`
  (the sub-tickets the ticket already has, made by hand or by an earlier split: each one's
  identifier, title and state, for a split to adopt), `siblings`
  (the parent's other sub-tickets that hold a tagged note, with those notes), `layers` (the layer
  vocabulary a plan names, each with what it means; a plan may name none), `conductor` (what earlier
  turns wrote), `earlier_tries` (each Grooming try on the ticket that wrote no plan, oldest first:
  the `try`'s number and the `reason` Symphony gave, such as why it refused the answer; empty on a
  first try) and `budget`.

  At `sub_ticket_ended` and `final_check`, on a groomed ticket, the document is the tree's (same
  `schema`, `junction` and `focus`): `ticket` (identifier, title, URL, `repo`, `phase` and its own
  `pull_request`: `merged`, `unmerged` or `none`), `asks`, the ticket's current `plan` and its
  `checks` with where each stands, `sub_tickets` (each one's identifier, title and state, and for
  one Symphony tracks its `phase`, its plan's `summary`, its `checks`, the notes a run tagged, its
  `asks` and whether its `pull_request` merged), `rounds` (how many the final check `made`, the
  `limit` and how many are `left`), the person's `decisions`, `notes` and `answers`, `conductor`
  and `budget`.

  At `message` and `child_message`, on a groomed ticket, the document is the conversation's (same
  `schema`, `junction` and `focus`): `ticket` (as the tree's, with its `parent`'s identifier),
  `conversation` (every `ask.recorded` and every `message.sent`, oldest first: an ask with its
  `source` and where it came `from`, a message with who wrote it and the `reply` the Conductor
  gave it, null while it has none), the current `plan` and its `checks`, `standing`, `last_run`,
  `sub_tickets` (as the tree's, when the ticket has any), the person's `decisions` and `answers`,
  `conductor` and `budget`. `SymphonyElixir.Conductor` adds which message the turn answers.

  On a groomed ticket the other junctions' `ticket` is read through `SymphonyElixir.TicketJourney`
  (`problem` is what was asked, `acceptance` the plan's outcome checks, `walkthrough` its QA
  checks, `proved_steps` the checks a test proved), and the document also holds `checks` (each
  check of the plan with where it stands, and the reason of a waived one), `check_notes` (the
  newest notes the runs wrote, which is where a run says a check cannot be proved) and `waive`
  (the rule for waiving one).

  Each fact read from an event carries the event's id (`event_id`), so a claim built on it can be
  traced. Long texts are cut with a marker (`#{inspect(" [cut by Symphony]")}`), lists keep their
  newest entries, and no transcript is read, so a normal ticket's document stays well under 20,000
  tokens.
  """

  alias SymphonyElixir.Conductor.{Filing, Tree}
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Messages, RunStore, SubIssueWait, TicketBrief, TicketChecks, TicketEvents}
  alias SymphonyElixir.TicketEvents.{Event, StepWord}
  alias SymphonyElixir.{TicketJourney, TicketPlan, TicketState, Walkthrough, Workspace}

  @schema "symphony.conductor.facts/1"
  @cut_marker " [cut by Symphony]"
  @section_max 3_000
  @text_max 1_000
  @max_findings 30
  @verdicts_shown 10
  @max_notes 10
  @max_conductor 10
  @max_files 40
  @max_qa_passes 10
  @max_blocked_steps 4
  @step_text_max 500
  @coding_kinds ["implementation", "rework"]
  @qa_blocked "after_qa_blocked"
  @grooming "grooming"
  @tree_junctions ["sub_ticket_ended", "final_check"]
  @message_junctions ["message", "child_message"]
  @message_text_max 4_000
  @max_check_notes 5
  @waive "A check that is open and that nobody can prove the way the plan says (a `test` check for something no test can " <>
           "reach, an `attached` check for a file that cannot exist) holds the handoff for good. When a run's notes or its " <>
           "failed `plan_checks` step say so and you agree, waive it: " <>
           ~s(`waive: [{"check_id": ..., "reason": ...}]`, ) <>
           "with the reason in plain words. Never waive a check only because it is hard or still unproved. " <>
           "A check of kind `outcome` is what the person asked for: Symphony refuses its waiver, and only the person can waive it."
  @open_checks "These checks of the plan are still open, and the pull request merges next. A merge does not prove them. " <>
                 "Say so in your update. Waive one that nobody can prove the way the plan says, with its reason " <>
                 "(never a check of kind `outcome`: only the person waives one), or send the ticket back with instructions " <>
                 "that name the checks to prove, or ask the person. A check proved by the pull request's own CI run (`proof: ci`) " <>
                 "is proved in Merging from the pull request's checks before the merge: leave it open, and never waive it or send the ticket back for it."
  @plan_text_max 6_000
  @max_siblings 20
  # The key `SymphonyElixir.Conductor.Grooming` counts a failed try under: `grooming.try:<n>`.
  @grooming_try_key "grooming.try:"
  # The layers a plan names (`SymphonyElixir.Conductor.Answer.layers/0`), each with what it means.
  @layers [
    screen: "something a person sees or does in the app changes: a screen, a view, a control",
    gallery: "a reusable component of the app's design system, or its preview or catalog entry, changes",
    api: "an interface other code or programs call changes: an HTTP route, a command, a tool, a public function",
    logic: "what the code does behind the screens changes: its rules, its data, its state, its background work",
    config: "a setting, its schema or its default changes",
    tests: "only tests change: a test is added, fixed or made stable, and what the code does stays the same",
    tooling: "the build, CI, a script or a developer tool changes",
    docs: "documentation changes"
  ]
  @focus %{
    "grooming" => "The ticket is new and no run has worked on it; you write its plan from what was asked.",
    "message" => "A person sent a message on the ticket; you answer it.",
    "sub_ticket_ended" => "A sub-ticket of this ticket ended; you look at what is left of its plan.",
    "final_check" => "The last sub-ticket ended; you check the whole ticket against its plan.",
    "child_message" => "A person sent a message on a sub-ticket of this ticket.",
    "after_coding" => "The implementation run handed off; Code Review or QA judges it next.",
    "after_qa_fail" => "QA failed; a rework run answers its findings next.",
    "after_qa_blocked" =>
      "QA could not judge the change: its newest pass ended blocked or inconclusive. You decide how the ticket gets a real QA result; `qa_passes` holds every pass and why each was blocked.",
    "after_rework" => "The rework run handed off; Code Review or QA judges it again next.",
    "before_merge" => "QA passed or was skipped; the pull request merges next.",
    "during_run" => "A run is working on the ticket now; its live state is under `live`."
  }
  @problem_heading ~r/\A(problem|why|context|background|summary|goal|what)\b/i
  @acceptance_heading ~r/acceptance/i

  @typedoc """
  `build/3`'s options: `events:` (the ticket's events, oldest first), `token_cap:`, `diff_stat:`
  (`(record -> [map()] | nil)`), `conductor:` (the `conductor` settings, default
  `Config.conductor_settings/0`), `repos:` (the managed repo keys, as `Filing.facts/3` takes them)
  and `records:` (every ticket record, where `grooming` finds the parent and its other sub-tickets).
  """
  @type opt ::
          {:events, [Event.t()]}
          | {:token_cap, pos_integer() | nil}
          | {:diff_stat, (map() -> [map()] | nil)}
          | {:conductor, Schema.Conductor.t()}
          | {:repos, [String.t()]}
          | {:records, [map()]}

  @doc "The junctions a document may be shaped for: the Conductor's, and `during_run` for a watch turn."
  @spec junctions() :: [String.t()]
  def junctions, do: Schema.Conductor.junctions() ++ ["during_run"]

  @doc """
  The document for the ticket `name` (its identifier, in any case, or its id) at `junction` (nil for
  none): `{:error, :not_found}` for a ticket Symphony keeps no record of, `{:error, {:invalid,
  message}}` for a junction that is not one.
  """
  @spec read(String.t(), String.t() | nil, [opt()]) :: {:ok, map()} | {:error, :not_found | {:invalid, String.t()}}
  def read(name, junction, opts \\ []) when is_binary(name) do
    with :ok <- check_junction(junction),
         {:ok, record} <- find(name) do
      {:ok, build(record, junction, opts)}
    end
  end

  defp check_junction(junction) when junction in [nil, ""], do: :ok

  defp check_junction(junction) do
    if junction in junctions(), do: :ok, else: {:error, {:invalid, "junction must be one of: #{Enum.join(junctions(), ", ")}"}}
  end

  defp find(name) do
    name = String.trim(name)

    # A store that can't be read lists no record, so its tickets read as unknown.
    with({:error, _reason} <- RunStore.list_all_ticket_states(), do: [])
    |> List.wrap()
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.find(&named?(&1, name))
    |> case do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp named?(%{issue_id: id, issue_identifier: identifier}, name),
    do: is_binary(id) and (id == name or (is_binary(identifier) and String.upcase(identifier) == String.upcase(name)))

  @doc "The document for the ticket `record` at `junction` (see the module doc and `t:opt/0`)."
  @spec build(map(), String.t() | nil, [opt()]) :: map()
  def build(record, junction, opts \\ []) do
    record = TicketState.normalize(record)
    events = Keyword.get_lazy(opts, :events, fn -> events(record.issue_id) end)

    cond do
      junction == @grooming -> grooming(record, events, opts)
      junction in @tree_junctions and TicketPlan.groomed?(events) -> tree(record, junction, events, opts)
      junction in @message_junctions and TicketPlan.groomed?(events) -> conversation(record, junction, events, opts)
      true -> junction_facts(record, junction, events, opts)
    end
  end

  # A groomed ticket and its sub-tickets: what was planned, where each piece stands, what merged.
  defp tree(record, junction, events, opts) do
    records = Keyword.get_lazy(opts, :records, &records/0)
    made = Tree.rounds(events)
    limit = Tree.round_limit(events, Keyword.get_lazy(opts, :conductor, &Config.conductor_settings/0))

    %{
      schema: @schema,
      junction: junction,
      focus: Map.fetch!(@focus, junction),
      ticket: Map.merge(family_ticket(record), %{url: record.url, repo: record.repo_key}),
      asks: asks(events),
      plan: plan_facts(TicketPlan.current(events)),
      checks: checks(events),
      sub_tickets: family(record, records),
      rounds: %{made: made, limit: limit, left: max(limit - made, 0)},
      decisions: Enum.map(record.decisions, &%{title: &1.title, answer: cut(&1.answer, @text_max)}),
      notes: person_notes(events),
      answers: answers(events),
      conductor: conductor(events),
      budget: budget(record, events, opts)
    }
  end

  defp family(record, records) do
    for %{identifier: identifier} = sub <- List.wrap(record.sub_issues), do: sub_ticket(sub, Enum.find(records, &(&1.issue_identifier == identifier)))
  end

  # A groomed ticket's conversation with the person: what was asked, each message and its reply.
  defp conversation(record, junction, events, opts) do
    parent = get_in(record, [:parent, :identifier])

    %{
      schema: @schema,
      junction: junction,
      focus: Map.fetch!(@focus, junction),
      ticket: record |> family_ticket() |> Map.merge(%{url: record.url, repo: record.repo_key, parent: parent}) |> drop_nil(),
      conversation: Enum.flat_map(events, &said(&1, events)),
      plan: plan_facts(TicketPlan.current(events)),
      checks: checks(events),
      standing: standing(record, events),
      last_run: last_run_facts(last_run(events), events, record, opts),
      sub_tickets: family(record, Keyword.get_lazy(opts, :records, &records/0)),
      decisions: Enum.map(record.decisions, &%{title: &1.title, answer: cut(&1.answer, @text_max)}),
      answers: answers(events),
      conductor: conductor(events),
      budget: budget(record, events, opts)
    }
  end

  defp said(%Event{type: "ask.recorded"} = ask, _events) do
    [drop_nil(%{event_id: ask.id, kind: "ask", at: iso8601(ask.at), source: payload(ask, :source), from: payload(ask, :from), text: cut(payload(ask, :text), @plan_text_max)})]
  end

  defp said(%Event{type: "message.sent", id: id} = message, events) do
    reply = Enum.find(events, &match?(%Event{type: "conductor.update", parent: ^id}, &1))
    reply = reply && %{event_id: reply.id, text: cut(payload(reply, :text), @text_max)}
    [%{event_id: id, kind: "message", at: iso8601(message.at), by: Messages.writer(message.actor), text: cut(payload(message, :text), @message_text_max), reply: reply}]
  end

  defp said(_event, _events), do: []

  defp family_ticket(record) do
    pull_request = Atom.to_string(SubIssueWait.pull_request(record.issue_id))
    %{identifier: record.issue_identifier, title: record.title, phase: record.phase, pull_request: pull_request}
  end

  # A sub-ticket as the parent's record lists it, with what its own record and events hold when Symphony tracks it.
  defp sub_ticket(sub, %{issue_id: issue_id} = record) when is_binary(issue_id) do
    plan = TicketPlan.current(issue_id)

    record
    |> family_ticket()
    |> Map.merge(%{state: Map.get(sub, :state), plan: plan && plan.summary, checks: checks(issue_id), notes: tagged_notes(issue_id), asks: asks(issue_id)})
  end

  defp sub_ticket(sub, _untracked), do: %{identifier: sub.identifier, state: Map.get(sub, :state)}

  defp asks(ticket), do: for(ask <- TicketPlan.ask(ticket), do: drop_nil(%{event_id: ask.event_id, source: ask.source, from: ask.from, text: cut(ask.text, @plan_text_max)}))

  defp checks(ticket) do
    for check <- TicketChecks.list(ticket) do
      drop_nil(%{id: check.id, kind: check.kind, statement: check.statement, proof: check.proof, state: Atom.to_string(check.state), waived: check.waived && check.waived.reason})
    end
  end

  defp junction_facts(record, junction, events, opts) do
    last_run = last_run(events)

    %{
      schema: @schema,
      junction: blank_to_nil(junction),
      focus: Map.get(@focus, junction),
      ticket: ticket(record, events),
      standing: standing(record, events),
      last_run: last_run_facts(last_run, events, record, opts),
      findings: findings(events),
      verdicts: verdicts(events),
      conductor: conductor(events),
      budget: budget(record, events, opts),
      filings: Filing.facts(events, Keyword.get_lazy(opts, :conductor, &Config.conductor_settings/0), Keyword.take(opts, [:repos]))
    }
    |> put_qa_passes(junction, events)
    |> put_checks(events)
    |> put_open_checks(junction)
  end

  # Before the merge of a groomed ticket's own pull request, the checks nobody proved or waived.
  defp put_open_checks(facts, "before_merge") do
    case for(%{state: "open"} = check <- Map.get(facts, :checks, []), do: Map.take(check, [:id, :kind, :statement, :proof])) do
      [] -> facts
      open -> Map.put(facts, :open_checks, %{rule: @open_checks, checks: open})
    end
  end

  defp put_open_checks(facts, _junction), do: facts

  # A groomed ticket's checks, what the runs said in their newest notes, and the rule for waiving one.
  defp put_checks(facts, events) do
    if TicketPlan.groomed?(events),
      do: Map.merge(facts, %{checks: checks(events), check_notes: run_notes(events), waive: @waive}),
      else: facts
  end

  defp run_notes(events) do
    events
    |> Enum.filter(&match?(%Event{type: "note", actor: %{kind: :agent}}, &1))
    |> Enum.take(-@max_check_notes)
    |> Enum.map(&drop_nil(%{event_id: &1.id, run_id: &1.run_id, at: iso8601(&1.at), text: cut(payload(&1, :text), @text_max)}))
  end

  @doc """
  The events of the ticket `issue_id`, oldest first; none when the store can't read them. A caller
  that reads "no events" as a fact about the ticket (it never ran, it has no plan) reads them with
  `read_events/1`, which tells a read that failed from a ticket that holds none.
  """
  @spec events(String.t() | nil) :: [Event.t()]
  def events(issue_id) do
    case read_events(issue_id) do
      {:ok, events} -> events
      {:error, _reason} -> []
    end
  end

  @doc "The events of the ticket `issue_id`, oldest first, or why the store could not read them."
  @spec read_events(String.t() | nil) :: {:ok, [Event.t()]} | {:error, term()}
  def read_events(issue_id) do
    case TicketEvents.query(issue_id, limit: :all) do
      events when is_list(events) -> {:ok, events}
      {:error, reason} -> {:error, reason}
    end
  end

  # Grooming: what was asked, and what the ticket's family already knows.

  defp grooming(record, events, opts) do
    records = Keyword.get_lazy(opts, :records, &records/0)
    parent = parent_record(record, records)

    %{
      schema: @schema,
      junction: @grooming,
      focus: Map.fetch!(@focus, @grooming),
      ticket: %{identifier: record.issue_identifier, title: record.title, url: record.url, repo: record.repo_key, labels: record.labels},
      asks: for(ask <- TicketPlan.ask(events), do: drop_nil(%{event_id: ask.event_id, source: ask.source, from: ask.from, text: ask.text})),
      decisions: Enum.map(record.decisions, &%{title: &1.title, answer: cut(&1.answer, @text_max)}),
      notes: person_notes(events),
      answers: answers(events),
      parent: parent && parent_facts(parent),
      sub_tickets: sub_tickets(record, records),
      siblings: siblings(record, parent, records),
      layers: for({name, means} <- @layers, do: %{name: Atom.to_string(name), means: means}),
      conductor: conductor(events),
      earlier_tries: earlier_tries(events),
      budget: budget(record, events, opts)
    }
  end

  # The Grooming tries that wrote no plan, each with the note that says why: the next try reads the
  # reason, so it does not give the answer Symphony refused again.
  defp earlier_tries(events) do
    for %Event{type: "note", idempotency: @grooming_try_key <> try} = event <- events do
      %{event_id: event.id, try: try, at: iso8601(event.at), reason: cut(payload(event, :text), @text_max)}
    end
  end

  defp records do
    with({:error, _reason} <- RunStore.list_all_ticket_states(), do: []) |> List.wrap() |> Enum.map(&TicketState.normalize/1)
  end

  # The sub-tickets the ticket already has, each with the title its own record holds.
  defp sub_tickets(%{sub_issues: sub_issues}, records) do
    titles = Map.new(records, &{&1.issue_identifier, &1.title})
    for %{identifier: identifier} = sub <- List.wrap(sub_issues), do: %{identifier: identifier, title: titles[identifier], state: Map.get(sub, :state)}
  end

  defp parent_record(%{parent: %{identifier: identifier}}, records), do: Enum.find(records, &(&1.issue_identifier == identifier and is_binary(&1.issue_id)))
  defp parent_record(_record, _records), do: nil

  defp parent_facts(parent) do
    %{identifier: parent.issue_identifier, title: parent.title, plan: plan_facts(TicketPlan.current(parent.issue_id)), notes: tagged_notes(parent.issue_id)}
  end

  defp plan_facts(nil), do: nil

  defp plan_facts(plan) do
    %{
      event_id: plan.event_id,
      version: plan.version,
      shape: plan.shape,
      layers: plan.layers,
      summary: plan.summary,
      text: cut(plan.text, @plan_text_max),
      sub_tickets: for(entry <- Map.get(plan, :sub_tickets, []), do: Map.take(entry, [:key, :title, :after, :identifier]))
    }
  end

  # The parent's other sub-tickets that hold a note a run tagged.
  defp siblings(_record, nil, _records), do: []

  defp siblings(record, parent, records) do
    for %{parent: %{identifier: identifier}, issue_id: issue_id} = sibling <- records,
        identifier == parent.issue_identifier and is_binary(issue_id) and issue_id != record.issue_id,
        notes = tagged_notes(issue_id),
        notes != [] do
      %{identifier: sibling.issue_identifier, title: sibling.title, phase: sibling.phase, notes: notes}
    end
    |> Enum.take(@max_siblings)
  end

  defp tagged_notes(issue_id) do
    for note <- issue_id |> TicketPlan.notes() |> Enum.take(-@max_notes), do: %{event_id: note.event_id, tag: note.tag, text: cut(note.text, @text_max)}
  end

  # The ticket.

  defp ticket(record, events) do
    %{
      identifier: record.issue_identifier,
      title: record.title,
      url: record.url
    }
    |> Map.merge(asked(record, events, TicketPlan.groomed?(events)))
    |> Map.merge(ticket_history(record, events))
  end

  # What a groomed ticket asks for is its ask and its plan's checks (`SymphonyElixir.TicketJourney`),
  # never its description, which Symphony writes itself.
  defp asked(record, events, true = _groomed?) do
    numbered = events |> TicketChecks.list() |> Enum.with_index(1)

    %{
      problem: events |> TicketPlan.ask() |> Enum.map_join("\n\n", &to_string(&1.text)) |> cut(@section_max),
      acceptance: record.issue_id |> TicketJourney.acceptance() |> Enum.join("\n") |> cut(@section_max),
      walkthrough: record.issue_id |> TicketJourney.steps() |> Enum.map_join("\n", & &1.text) |> cut(@section_max),
      proved_steps: Enum.flat_map(numbered, &proved_step/1)
    }
  end

  defp asked(record, events, false) do
    sections = sections(record.description)

    %{
      problem: sections |> section(@problem_heading) |> Kernel.||(untitled(sections)) |> cut(@section_max),
      acceptance: sections |> section(@acceptance_heading) |> cut(@section_max),
      walkthrough: record.description |> Walkthrough.section() |> cut(@section_max),
      proved_steps: proved_steps(events)
    }
  end

  defp proved_step({%{proved_by: %{by: "test", test: test, event_id: id}}, step}) when is_binary(test),
    do: [%{step: step, test: cut(test, @step_text_max), event_id: id}]

  defp proved_step(_check), do: []

  defp ticket_history(record, events) do
    %{
      brief: brief(events),
      decisions: Enum.map(record.decisions, &%{title: &1.title, answer: cut(&1.answer, @text_max)}),
      notes: person_notes(events),
      answers: answers(events)
    }
  end

  # The description's sections by heading, in order; the text before the first heading is untitled.
  defp sections(description) when is_binary(description) do
    description
    |> String.split("\n")
    |> Enum.reduce([{nil, []}], fn line, [{heading, lines} | rest] = acc ->
      case Regex.run(~r/^\s*\#{1,6}\s+(.+?)\s*:?\s*$/, line) do
        [_line, title] -> [{title, []} | acc]
        nil -> [{heading, [line | lines]} | rest]
      end
    end)
    |> Enum.map(fn {heading, lines} -> {heading, lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()} end)
    |> Enum.reverse()
  end

  defp sections(_description), do: []

  defp section(sections, pattern) do
    Enum.find_value(sections, fn
      {heading, body} when is_binary(heading) and body != "" -> if Regex.match?(pattern, heading), do: body
      _other -> nil
    end)
  end

  defp untitled([{nil, body} | _rest]) when body != "", do: body
  defp untitled(_sections), do: nil

  # The newest recorded proof of each walkthrough step, by step number (`Walkthrough.proofs_of/1`).
  defp proved_steps(events) do
    events
    |> Enum.flat_map(fn event -> for proof <- Walkthrough.proofs_of([event]), do: Map.put(proof, :event_id, event.id) end)
    |> Enum.reduce(%{}, &Map.put(&2, &1.step, &1))
    |> Map.values()
    |> Enum.sort_by(& &1.step)
    |> Enum.map(&%{&1 | test: cut(&1.test, @step_text_max)})
  end

  defp brief(events) do
    case TicketBrief.current(events) do
      %Event{} = event -> %{event_id: event.id, text: cut(payload(event, :text), @text_max), walkthrough: cut(payload(event, :walkthrough), @section_max)}
      nil -> nil
    end
  end

  defp person_notes(events) do
    events
    |> Enum.filter(&(&1.type in ["note", "message.sent"] and person?(&1)))
    |> Enum.take(-@max_notes)
    |> Enum.map(&%{event_id: &1.id, at: iso8601(&1.at), text: cut(payload(&1, :text), @text_max)})
  end

  defp answers(events) do
    titles =
      for %Event{type: "question.asked"} = asked <- events, into: %{}, do: {payload(asked, :question_id), payload(asked, :title)}

    events
    |> Enum.filter(&(&1.type == "question.answered"))
    |> Enum.take(-@max_notes)
    |> Enum.map(fn answered ->
      %{
        event_id: answered.id,
        question: payload(answered, :title) || Map.get(titles, payload(answered, :question_id)),
        answer: cut(payload(answered, :answer), @text_max),
        option: payload(answered, :option)
      }
    end)
  end

  defp person?(%Event{actor: %{kind: :person}}), do: true
  defp person?(_event), do: false

  # Where it stands.

  defp standing(record, events) do
    pull_request = record.pull_request

    %{
      phase: record.phase,
      attempt: Enum.count(events, &(&1.type == "run.started" and payload(&1, :run_kind) in @coding_kinds)),
      pull_request: pull_request_facts(pull_request),
      head: pull_request && Map.get(pull_request, :head_sha)
    }
  end

  defp pull_request_facts(%{} = pull_request), do: %{number: Map.get(pull_request, :number), url: Map.get(pull_request, :url), state: Map.get(pull_request, :state)}
  defp pull_request_facts(_none), do: nil

  # The last run.

  @doc """
  The newest `run.ended` among `events` (oldest first) of a run other than the Conductor's own, nil
  when no such run ended.
  """
  @spec last_run([Event.t()]) :: Event.t() | nil
  def last_run(events) do
    events
    |> Enum.filter(&(&1.type == "run.ended" and payload(&1, :run_kind) != "conductor"))
    |> List.last()
  end

  defp last_run_facts(nil, _events, _record, _opts), do: nil

  defp last_run_facts(%Event{} = ended, events, record, opts) do
    run_id = payload(ended, :run_id)
    started = Enum.find(events, &(&1.type == "run.started" and payload(&1, :run_id) == run_id))

    %{
      event_id: ended.id,
      started_event_id: started && started.id,
      run_id: run_id,
      kind: payload(ended, :run_kind),
      model: payload(ended, :model) || (started && payload(started, :model)),
      exit: payload(ended, :exit),
      duration_ms: payload(ended, :duration_ms),
      tokens: tokens(payload(ended, :tokens)),
      steps: steps(events, run_id),
      resolved_findings: resolved(events, run_id)
    }
    |> put_files_changed(record, opts)
  end

  defp steps(events, run_id) do
    for %Event{type: "step.completed", run_id: ^run_id} = step <- events do
      %{
        event_id: step.id,
        step_id: payload(step, :step_id),
        title: payload(step, :title),
        mode: payload(step, :mode),
        outcome: StepWord.word(step.payload),
        returns_to: payload(step, :returns_to),
        reason: payload(step, :reason),
        result: result(payload(step, :result)),
        answer: answer(payload(step, :answer)),
        verdict_summary: payload(step, :verdict_summary)
      }
      |> drop_nil()
    end
  end

  # A QA step's answer, as the pass put it on the step's `step.completed`.
  defp result(%{} = result) do
    field = fn key -> Map.get(result, key, Map.get(result, Atom.to_string(key))) end
    %{status: field.(:status), expected: cut(field.(:expected), @text_max), actual: cut(field.(:actual), @text_max)}
  end

  defp result(_none), do: nil

  # A step's structured answer (`SymphonyElixir.PhaseSteps.StepAnswer`), each value cut for the facts.
  defp answer([_ | _] = entries) do
    for %{} = entry <- entries do
      field = fn key -> Map.get(entry, key, Map.get(entry, Atom.to_string(key))) end
      %{label: field.(:label), value: cut(field.(:value), @text_max)}
    end
  end

  defp answer(_none), do: nil

  defp resolved(events, run_id) do
    for %Event{type: "finding.resolved", run_id: ^run_id} = resolution <- events do
      %{event_id: resolution.id, finding_id: payload(resolution, :finding_id), how: cut(payload(resolution, :how), @text_max)}
    end
  end

  # The files the workspace changed against its base, when the workspace exists; left out otherwise.
  defp put_files_changed(facts, record, opts) do
    case Keyword.get(opts, :diff_stat, &workspace_diff_stat/1).(record) do
      files when is_list(files) -> Map.put(facts, :files_changed, Enum.take(files, @max_files))
      _none -> facts
    end
  end

  defp workspace_diff_stat(%{issue_identifier: identifier, repo_key: repo_key}) when is_binary(identifier) and is_binary(repo_key) do
    with {:ok, workspace} <- Workspace.local_path_for_issue(identifier, repo_key),
         true <- File.exists?(Path.join(workspace, ".git")),
         {output, 0} <- Workspace.safe_git(["-C", workspace, "diff", "--numstat", "origin/HEAD...HEAD"]) do
      numstat(output)
    else
      _missing -> nil
    end
  end

  defp workspace_diff_stat(_record), do: nil

  @doc "The files a `git diff --numstat` lists, each with its lines added and removed (nil for a binary file)."
  @spec numstat(String.t()) :: [%{path: String.t(), added: non_neg_integer() | nil, removed: non_neg_integer() | nil}]
  def numstat(output) when is_binary(output) do
    for line <- String.split(output, "\n", trim: true), [added, removed, path] <- [String.split(line, "\t", parts: 3)] do
      %{path: path, added: count(added), removed: count(removed)}
    end
  end

  defp count(text) do
    case Integer.parse(text) do
      {count, ""} -> count
      _binary -> nil
    end
  end

  # Findings.

  defp findings(events) do
    classes = events |> Enum.filter(&(&1.type == "finding.recorded")) |> Enum.frequencies_by(&payload(&1, :class))

    events
    |> TicketEvents.findings()
    |> Enum.take(-@max_findings)
    |> Enum.map(fn %{finding: finding, state: state, resolution: resolution, reopened_by: reopened_by} ->
      class = payload(finding, :class)

      %{
        event_id: finding.id,
        state: Atom.to_string(state),
        class: class,
        class_count: Map.get(classes, class, 1),
        severity: payload(finding, :severity),
        step: payload(finding, :step),
        description: cut(payload(finding, :description), @text_max),
        evidence: finding |> payload(:evidence) |> List.wrap() |> Enum.map(&cut(&1, 300)),
        resolution: resolution && %{event_id: resolution.id, how: cut(payload(resolution, :how), @text_max)},
        reopened_by: reopened_by && reopened_by.id
      }
      |> drop_nil()
    end)
  end

  defp verdicts(events) do
    events
    |> Enum.filter(&(&1.type == "verdict.recorded" and is_nil(payload(&1, :signal))))
    |> Enum.take(-@verdicts_shown)
    |> Enum.map(&drop_nil(%{event_id: &1.id, kind: payload(&1, :kind), outcome: payload(&1, :outcome), head: payload(&1, :head), reason: cut(verdict_reason(&1), @text_max)}))
  end

  # A QA verdict keeps its reason in its details.
  defp verdict_reason(verdict), do: payload(verdict, :reason) || field(payload(verdict, :details) || %{}, :reason)

  # Every QA verdict with the steps of its pass that ended blocked, read from the events its run
  # recorded: a stepped pass's `step.completed` answers, and the `evidence` of each step the pass's
  # verdict named.
  defp put_qa_passes(facts, @qa_blocked, events), do: Map.put(facts, :qa_passes, qa_passes(events))
  defp put_qa_passes(facts, _junction, _events), do: facts

  defp qa_passes(events) do
    events
    |> Enum.filter(&(&1.type == "verdict.recorded" and payload(&1, :kind) == "qa" and is_nil(payload(&1, :signal))))
    |> Enum.take(-@max_qa_passes)
    |> Enum.map(fn verdict ->
      details = payload(verdict, :details) || %{}

      %{
        event_id: verdict.id,
        run_id: verdict.run_id,
        outcome: payload(verdict, :outcome),
        head: payload(verdict, :head),
        reason: cut(verdict_reason(verdict), @text_max),
        on_ci: if(field(details, :component) == "ci", do: true),
        blocked_steps: blocked_steps(events, verdict.run_id)
      }
      |> drop_nil()
    end)
  end

  defp blocked_steps(_events, nil), do: []

  defp blocked_steps(events, run_id) do
    events
    |> Enum.filter(&(&1.run_id == run_id))
    |> Enum.flat_map(&blocked_step/1)
    |> Enum.take(@max_blocked_steps)
  end

  defp blocked_step(%Event{type: "step.completed"} = step) do
    case payload(step, :result) do
      %{} = result ->
        if field(result, :status) == "blocked",
          do: [drop_nil(%{event_id: step.id, step_id: payload(step, :step_id), title: payload(step, :title), result: step_result(result)})],
          else: []

      _none ->
        []
    end
  end

  defp blocked_step(%Event{type: "evidence"} = evidence) do
    if payload(evidence, :status) == "blocked",
      do: [drop_nil(%{event_id: evidence.id, step: payload(evidence, :step), details: cut(payload(evidence, :details), @step_text_max)})],
      else: []
  end

  defp blocked_step(_event), do: []

  defp step_result(result) do
    %{
      status: field(result, :status),
      expected: cut(field(result, :expected), @step_text_max),
      actual: cut(field(result, :actual), @step_text_max)
    }
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp conductor(events) do
    events
    |> Enum.filter(&(&1.type in ["conductor.update", "conductor.instructions", "conductor.steer"]))
    |> Enum.take(-@max_conductor)
    |> Enum.map(fn event ->
      %{
        event_id: event.id,
        type: String.replace_prefix(event.type, "conductor.", ""),
        junction: payload(event, :junction),
        at: iso8601(event.at),
        text: cut(payload(event, :text), @text_max)
      }
      |> Map.merge(drop_nil(%{route: payload(event, :route), when: payload(event, :when), trigger: payload(event, :trigger)}))
    end)
  end

  # Budget.

  defp budget(record, events, opts) do
    started = Enum.filter(events, &(&1.type == "run.started"))

    %{
      tokens_used: events |> Enum.filter(&(&1.type == "run.ended")) |> Enum.map(&(&1 |> payload(:tokens) |> tokens() || 0)) |> Enum.sum(),
      tokens_cap: Keyword.get_lazy(opts, :token_cap, fn -> token_cap(record.repo_key) end),
      qa_passes: Enum.count(started, &(payload(&1, :run_kind) == "qa")),
      rework_runs: Enum.count(started, &(payload(&1, :run_kind) == "rework"))
    }
  end

  defp token_cap(repo_key) when is_binary(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> settings.execution.max_tokens_per_issue
      _error -> nil
    end
  end

  defp token_cap(_repo_key), do: nil

  @doc "A run's tokens as its `run.ended` records them: a count, or a map with `total_tokens`; nil when unknown."
  @spec tokens(term()) :: non_neg_integer() | nil
  def tokens(count) when is_integer(count), do: count
  def tokens(%{total_tokens: count}) when is_integer(count), do: count
  def tokens(%{"total_tokens" => count}) when is_integer(count), do: count
  def tokens(_tokens), do: nil

  # Helpers.

  @doc "`text` cut to `max` characters with a marker, nil for a missing or blank text."
  @spec cut(term(), pos_integer()) :: String.t() | nil
  def cut(text, max) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> nil
      String.length(text) > max -> String.slice(text, 0, max) <> @cut_marker
      true -> text
    end
  end

  def cut(_text, _max), do: nil

  @doc """
  `text` (trimmed) fitted to `max` characters: whole when it fits, else cut at the last sentence end
  (or, failing that, the last word end) that leaves room for the marker, with the marker, so the
  result never goes over `max`.
  """
  @spec fit(String.t(), pos_integer()) :: String.t()
  def fit(text, max) when is_binary(text) do
    text = String.trim(text)

    if String.length(text) <= max do
      text
    else
      room = max - String.length(@cut_marker)
      head = String.slice(text, 0, room)
      kept = boundary(head, ~r/[.!?](?=\s)|\n/u, 1) || boundary(head, ~r/\s/u, 0) || head
      String.trim_trailing(kept) <> @cut_marker
    end
  end

  # `head` up to its last match of `pattern` (plus `extra` characters of it) when that keeps at least
  # half of it.
  defp boundary(head, pattern, extra) do
    case pattern |> Regex.scan(head, return: :index) |> List.last() do
      [{start, length}] when start > div(byte_size(head), 2) -> binary_part(head, 0, start + min(extra, length))
      _none -> nil
    end
  end

  defp payload(%Event{payload: payload}, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp drop_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp iso8601(at), do: at && DateTime.to_iso8601(at)
end
