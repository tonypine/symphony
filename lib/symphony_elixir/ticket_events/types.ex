defmodule SymphonyElixir.TicketEvents.Types do
  @moduledoc """
  The closed vocabulary of ticket events (`SymphonyElixir.TicketEvents`): for each type, who may
  write it (`:machine`, `:agent`, `:person`), which agent run kinds may (`:any` or a list of
  `SymphonyElixir.RunKind` names), the payload schema (required and optional fields) and the
  idempotency rule.

  Field specs:

    * `:string` - a non-blank string; `{:string, max}` also bounds its length in characters.
    * `{:prose, max}` - a `{:string, max}` written for a person to read, which holds no backtick.
    * `{:enum, values}` - one of `values`, given as a string or an atom, stored as a string.
    * `:non_neg_integer`, `:boolean`, `:map`, `{:list, :string}`, `:list`.
    * `{:any_of, specs}` - the first spec that accepts the value.
    * `{:map, fields}` - a map holding exactly `fields` (a keyword of specs, each required), its keys
      as atoms.

  An optional field given as nil is left out. A field the type does
  not name is rejected. Every type a machine or a person writes, and `note`, also takes an optional
  `signal`, the name of the signal it records (`SymphonyElixir.TicketSignals`), and
  `signal_details`, the details the signal was recorded with, so readers of the signals ledger can
  move over to events. A `verdict.recorded` also takes the `details` the verdict carries. A tool's
  caller sees neither (`schema/1`).

  The idempotency rule names the payload fields a key is derived from when the writer passes none
  (`{:fields, fields}`, used only when every field is present); `:writer` dedupes only on a key the
  writer passes.

  `hold.set`, `hold.cleared`, `decision.requested`, `decision.recorded` and `decision.withdrawn` are
  legacy (`legacy_types/0`): the holds they recorded are retired, what pauses a ticket is recorded
  by the `pause.*` types, and a decision a person must make is a Question, recorded by the
  `question.*` types. They stay in the catalog so a ticket's history still reads them (the summary
  renderer keeps their lines, `SymphonyElixir.TicketEvents.Summary`); no live writer and no backfill
  records them any more, but for one: a ruling the Director records on a ticket's page, which no
  Question asked for, is a `decision.recorded` with no `request` (`SymphonyElixir.DirectorRulings`). `hold.set` and `hold.cleared` take only the `blocked` kind, and
  `person.action` has no `decide`.
  State is machinery-only: an agent claims `finding.resolved`, it never records a verdict. A QA
  `pass` confirms the claim with a machine `finding.confirmed` naming the finding, the resolution
  and the head the pass judged (`SymphonyElixir.QaVerification`), keyed by the resolution.

  An agent records through `ticket_record` (`SymphonyElixir.AgentTools.TicketLedger`) only the types
  `agent_types/1` lists for its run kind: `finding.recorded` in a QA run; `finding.resolved`,
  `step.started`, `step.completed`, `evidence`, `checklist.answered` and `note` in any run. Every other type is the
  machine's or a person's (a question is asked through the question tool), and a legacy type is
  never an agent's. An `evidence` may carry a `proof`: the walkthrough step it proves and the test.
  A QA pass's step evidence also names the step (`step`), its result (`status`), what QA saw
  (`details`), the environment it was proved in (`environment`: `fixture` or `live`) and the
  entries that name no kept file (`links`, a CI run's URL); the QA report renders its steps from
  them (`SymphonyElixir.QaAgent.Report`).

  A run's steps are `step.started` and `step.completed`, each naming the step (`step_id`, `title`)
  and how it runs (`mode`): `machine` (a command Symphony runs, `command`), `orchestrated` (an agent
  turn Symphony drives from a prompt, `prompt_ref`) or `delegated` (work the agent does and reports
  itself). Symphony records the machine and orchestrated steps; an agent records only delegated
  ones (`agent_values`). `step.completed` says how the step ended (`outcome`): `passed`; `failed`,
  with the step the run goes back to (`returns_to`, and its title in `returns_to_title`); `paused`,
  with the Question it waits on (`question_id`, from `SymphonyElixir.Questions`); or `skipped`, with
  why (`reason`); and how long it took (`duration_ms`). Those fields are `conditional`: each is
  required exactly when its outcome holds and refused otherwise, as `command` and `prompt_ref` are
  by mode. A machine step's output is kept as an artifact of the `step_output` kind
  (`SymphonyElixir.Artifacts`) on its `step.completed`; an agent step's slice of the session
  transcript is a `transcript` artifact on its `step.completed` (`SymphonyElixir.PhaseSteps.Transcript`).
  A skipped step is a `step.completed` with
  `outcome: skipped`: there is no `step.skipped` type. A `question.answered` naming the question a
  paused step waits on is what resumes that step.

  A person's cancel of a ticket Symphony owns is one `ticket.cancelled` (`SymphonyElixir.DirectorMoves`):
  the phase it left and the canceled state, the Director's note, whether a run was stopped and the
  pull requests closed with it. A person's free move of one into any phase is one `ticket.moved`:
  the phase it left and the one it entered, the Director's note and whether a run was stopped.

  Drift is machinery-only too: `drift.detected` when Linear shows a state other than the phase
  Symphony owns, then `drift.reverted` or `drift.revert_failed` for the move back, each with the
  record's phase and Linear's (`SymphonyElixir.TicketObservation`).

  A pause is machinery-only as well (`SymphonyElixir.Pauses`): `pause.set` for its first reason,
  `pause.reason_added` for each further one, `pause.reason_cleared` for a reason cleared while
  others remain and `pause.cleared` when none is left, with the reasons it cleared. A reason event
  names its kind (`reason`), its one line of plain words (`text`) and what it waits on, and
  `source: "backfill"` when the backfill from the holds wrote it (`SymphonyElixir.Pauses.Backfill`),
  as `question.asked` does for a question it wrote.

  `workspace.synced` is machinery-only: before a review, QA, landing or rework run, the heads
  `SymphonyElixir.WorkspaceSync` compared (the workspace's, the PR's and the unpushed head the
  newest run recorded), the one that won, what was done (`none`, `reset`, `pushed`,
  `reset_and_pushed`, `blocked`, `failed`), the head the run stands on and the run kind.

  `workspace.rebuilt` is machinery-only: a ticket's workspace made again (`reclaim`, `missing_folder`,
  `host_change`) started on the newest known head of its branch (`SymphonyElixir.WorkspaceRebuild`):
  the heads compared (the open PR's, the branch's on `origin`, the unpushed head the newest run
  recorded), the one chosen (`winner`, `main` when none exists) and the head the workspace starts on.

  `park.backfilled` is machinery-only: a ticket an idle run parked before parks asked a question was
  brought up to date at start-up (`SymphonyElixir.IdlePark.Backfill`), with what it was given in
  `added` (`question`, `releasable_reason`, `push`), the question's id, the branch pushed and the
  phase it was parked from.

  A question to a person is machinery-only too (`SymphonyElixir.Questions`): `question.asked`, then
  `question.answered` (the answer as given, and the option it picked) or `question.withdrawn` (with
  the reason and its `cause`: `ticket_moved`, `restarted`, `hold_cleared`, `superseded`, `superseded_by_move`, or
  `run_ended` for a question that holds nothing), each naming the question by `question_id`, and `question.reopened` when the Director
  takes an answer back, after which the question is open again and its next answer is a new
  `question.answered`. `question.not_asked` is the request a run was refused because it reached its
  limit of requests (`cap`), with the `title` and `question` it would have asked: nothing is asked and
  nothing pauses, and a plan's Inbox item lists it (`SymphonyElixir.TicketState.unasked_choices/1`).

  `situation.changed` is machinery-only: the ticket's situation (`SymphonyElixir.Situation`) took
  another kind, with the old kind (`from`, none on the first), the new one (`to`), the pattern's
  first words (`word`), its cause and since when it holds. A timeline reads how long each situation
  lasted from these events, without parsing.

  `rule.action` is machinery-only: a rule of Symphony's acted on the ticket (`SymphonyElixir.RuleActions`):
  the rule's name (`rule`: "PR watcher R22", "CI wait", "Self-heal", "Dispatch-loop guard", "Idle
  park"), what it did (`action`: `rerun`, `paused`, `parked`, `filed_ticket`, `lifted_pause`, `moved`,
  `updated_branch`, `auto_merge`, `asked`, `other`), its line in plain words (`text`) and the ticket
  it filed (`filed`). The audit records the rules write stay as they are.

  `ticket.filed` is machinery-only: a ticket split off from this one was filed in Linear, by a run's
  `linear_create_subissue` (`kind: split_off`) or as an epic review's follow-up (`follow_up`), with
  its identifier and title.

  `note.read` is machinery-only: the first run whose prompt carried a person's note (`note_id`, the
  `note` event's id) read it (`run_id`), keyed by the note so only the first read is kept
  (`SymphonyElixir.Marks`).

  `report.published` is machinery-only: a status report a report run published through its one tool
  (`SymphonyElixir.Reports`), recorded on the reports ledger and never on a ticket's: the period, the
  tickets and the events it rests on, its sentences, their text, each sentence's citations, the run,
  its model and the Question it raised (`question_id`).

  `brief.written` is an agent's, in an implementation, rework or review-feedback run: what the ticket
  does and why, in a person's words (`text`, at most 1,200 characters), and its walkthrough as the
  steps a person takes (`walkthrough`, at most 4,000), both prose with no backtick. The newest one is
  the ticket's brief (`SymphonyElixir.TicketBrief`).
  """

  alias SymphonyElixir.RunKind

  @type actor_kind :: :machine | :agent | :person
  @type field_spec ::
          :string
          | {:string, pos_integer()}
          | {:prose, pos_integer()}
          | {:enum, [String.t()]}
          | :non_neg_integer
          | :boolean
          | :map
          | :list
          | {:list, :string}
          | {:any_of, [field_spec()]}
          | {:map, keyword(field_spec())}
  @type idempotency_rule :: :writer | {:fields, [atom()]}
  @type entry :: %{
          required(:writers) => [actor_kind()],
          required(:run_kinds) => :any | [String.t()],
          required(:required) => keyword(field_spec()),
          required(:optional) => keyword(field_spec()),
          required(:idempotency) => idempotency_rule(),
          optional(:conditional) => keyword({atom(), String.t()}),
          optional(:agent_values) => keyword([String.t()])
        }
  @type error :: {:unknown_type, term()} | {:invalid_payload, [atom() | String.t()]} | {:not_allowed, String.t()}

  @verdict_kinds ~w(code_review qa ci_fix plan_review epic_review)
  @person_actions ~w(stop move force unblock restart add_blocker remove_blocker set_priority add_label remove_label)
  @step_modes ~w(machine orchestrated delegated)
  @evidence {:any_of, [:string, {:list, :string}]}
  # A QA step's result and the environment it was proved in (`fixture`: the committed state
  # fixtures; `live`: Symphony's own server on the QA host), as a QA pass's step evidence carries them.
  @evidence_statuses ~w(pass fail blocked skipped unprovable)
  @environments ~w(fixture live)
  @tokens {:any_of, [:non_neg_integer, :map]}
  # The signal an event records (`SymphonyElixir.TicketSignals.signal_event/2`) and the details it
  # was recorded with.
  @signal [signal: :string, signal_details: :map]
  # The model and effort the run profile resolved at dispatch (`run.started`, copied onto `run.ended`).
  @run_profile [model: :string, effort: :string]
  @drift [record_phase: :string, linear_phase: :string]
  @pause_reasons ~w(question ticket build person environment)
  # `SymphonyElixir.Situation.kinds/0`, which reads the record and so may not be read here.
  @situation_kinds ~w(waiting_on_you retrying blocked_by_ticket paused_by_rule waiting_for_ci waiting_for_build waiting_for_slot working done cancelled)
  # Where a pause's or a question's event came from when no live write recorded it: the backfill
  # from the holds and decisions (`SymphonyElixir.Pauses.Backfill`).
  @source {:enum, ~w(backfill)}
  @pause_reason [reason: {:enum, @pause_reasons}, text: {:string, 300}]
  @pause_reason_set %{
    writers: [:machine],
    run_kinds: [],
    required: @pause_reason,
    optional: [waits_on: :map, set_by: :map, releasable: :boolean, source: @source] ++ @signal,
    idempotency: :writer
  }

  @step_outcomes ~w(passed failed paused skipped)
  @step [step_id: {:string, 200}, title: {:string, 200}, mode: {:enum, @step_modes}]
  # An agent records only a delegated step; Symphony records the machine and orchestrated ones.
  @agent_steps [mode: ["delegated"]]

  @rule_actions ~w(rerun paused parked filed_ticket lifted_pause moved updated_branch auto_merge asked other)

  @legacy_types ["hold.set", "hold.cleared", "decision.requested", "decision.recorded", "decision.withdrawn"]

  @catalog %{
    "phase.entered" => %{
      writers: [:machine],
      run_kinds: [],
      required: [to: :string],
      optional: [from: :string, via: :string, reason: :string] ++ @signal,
      idempotency: :writer
    },
    "hold.set" => %{
      writers: [:machine],
      run_kinds: [],
      required: [kind: {:enum, ["blocked"]}],
      optional: [reason: :string, waits_on: :map] ++ @signal,
      idempotency: :writer
    },
    "hold.cleared" => %{
      writers: [:machine],
      run_kinds: [],
      required: [kind: {:enum, ["blocked"]}],
      optional: [by: :string] ++ @signal,
      idempotency: :writer
    },
    "run.started" => %{
      writers: [:machine],
      run_kinds: [],
      required: [run_id: :string, run_kind: :string],
      optional: [run_number: :non_neg_integer, state: :string, head: :string] ++ @run_profile ++ @signal,
      idempotency: {:fields, [:run_id]}
    },
    # The run a person started at once (`SymphonyElixir.Orchestrator.start_issue/3`), by the
    # Director with their note, next to the machine's own `run.started`.
    "run.started_by_person" => %{
      writers: [:person],
      run_kinds: [],
      required: [by: :string],
      optional: [note: {:string, 500}, run_id: :string] ++ @signal,
      idempotency: {:fields, [:run_id]}
    },
    "run.ended" => %{
      writers: [:machine],
      run_kinds: [],
      required: [run_id: :string, exit: :string],
      optional:
        [
          run_kind: :string,
          run_number: :non_neg_integer,
          model: :string,
          effort: :string,
          duration_ms: :non_neg_integer,
          tokens: @tokens,
          head: :string,
          unpushed_head: :string,
          counted: :boolean,
          transcript: :string,
          budget_exhausted: :map
        ] ++ @signal,
      idempotency: {:fields, [:run_id]}
    },
    "attempt.pushed" => %{
      writers: [:machine],
      run_kinds: [],
      required: [head: :string],
      optional: [attempt: :non_neg_integer, intent: :string, pr_url: :string] ++ @signal,
      idempotency: :writer
    },
    "verdict.recorded" => %{
      writers: [:machine],
      run_kinds: [],
      required: [kind: {:enum, @verdict_kinds}, outcome: :string],
      optional: [head: :string, reason: :string, details: :map] ++ @signal,
      idempotency: :writer
    },
    "decision.requested" => %{
      writers: [:machine, :agent],
      run_kinds: :any,
      required: [question: :string],
      optional: [title: :string, why: :string, options: :list, confirm: :string] ++ @signal,
      idempotency: :writer
    },
    "decision.withdrawn" => %{
      writers: [:machine, :agent],
      run_kinds: :any,
      required: [title: :string],
      optional: [question: :string, request: :string] ++ @signal,
      idempotency: {:fields, [:request]}
    },
    "decision.recorded" => %{
      writers: [:person],
      run_kinds: [],
      required: [answer: :string],
      optional: [title: :string, question: :string, key: :string, request: :string] ++ @signal,
      idempotency: {:fields, [:key]}
    },
    "question.asked" => %{
      writers: [:machine],
      run_kinds: [],
      required: [question_id: :string, title: {:string, 120}, question: :string],
      optional:
        [
          why: :string,
          if_unanswered: :string,
          options: :list,
          recommendation_reason: :string,
          confirm: :string,
          step: :string,
          asked_by: :map,
          source: @source
        ] ++ @signal,
      idempotency: {:fields, [:question_id]}
    },
    "question.answered" => %{
      writers: [:machine],
      run_kinds: [],
      required: [question_id: :string, answer: :string],
      optional:
        [title: :string, option: :string, option_number: :non_neg_integer, scope: {:enum, ~w(run ticket always)}, by: :map] ++
          @signal,
      idempotency: {:fields, [:question_id]}
    },
    "question.withdrawn" => %{
      writers: [:machine],
      run_kinds: [],
      required: [question_id: :string, reason: :string],
      optional: [title: :string, by: :map, cause: {:enum, ~w(ticket_moved restarted hold_cleared superseded superseded_by_move run_ended)}] ++ @signal,
      idempotency: {:fields, [:question_id]}
    },
    "question.reopened" => %{
      writers: [:machine],
      run_kinds: [],
      required: [question_id: :string],
      optional: [title: :string, by: :map] ++ @signal,
      idempotency: :writer
    },
    "question.not_asked" => %{
      writers: [:machine],
      run_kinds: [],
      required: [title: {:string, 120}, question: :string, cap: :non_neg_integer],
      optional: @signal,
      idempotency: :writer
    },
    "person.action" => %{
      writers: [:person],
      run_kinds: [],
      required: [action: {:enum, @person_actions}],
      optional:
        [move: :string, from: :string, to: :string, blocker: :string, label: :string, run_stopped: :boolean] ++
          @signal,
      idempotency: :writer
    },
    "step.started" => %{
      writers: [:machine, :agent],
      run_kinds: :any,
      required: @step,
      optional: [command: {:string, 2_000}, prompt_ref: {:string, 200}] ++ @signal,
      conditional: [command: {:mode, "machine"}, prompt_ref: {:mode, "orchestrated"}],
      agent_values: @agent_steps,
      idempotency: :writer
    },
    "step.completed" => %{
      writers: [:machine, :agent],
      run_kinds: :any,
      required: @step ++ [outcome: {:enum, @step_outcomes}],
      optional:
        [
          returns_to: {:string, 200},
          returns_to_title: {:string, 200},
          question_id: :string,
          reason: {:string, 300},
          duration_ms: :non_neg_integer
        ] ++ @signal,
      conditional: [returns_to: {:outcome, "failed"}, question_id: {:outcome, "paused"}, reason: {:outcome, "skipped"}],
      agent_values: @agent_steps,
      idempotency: :writer
    },
    "evidence" => %{
      writers: [:agent],
      run_kinds: :any,
      required: [caption: {:string, 500}],
      optional: [
        artifacts: {:list, :string},
        proof: {:map, [step: :non_neg_integer, test: {:string, 500}]},
        step: {:string, 200},
        status: {:enum, @evidence_statuses},
        details: {:string, 2_000},
        environment: {:enum, @environments},
        links: {:list, :string}
      ],
      idempotency: :writer
    },
    "finding.recorded" => %{
      writers: [:agent],
      run_kinds: ["qa"],
      required: [class: {:string, 100}, severity: {:string, 50}, description: {:string, 2_000}],
      optional: [viewport: {:string, 100}, step: {:string, 200}, evidence: @evidence],
      idempotency: :writer
    },
    "finding.resolved" => %{
      writers: [:agent],
      run_kinds: :any,
      required: [finding_id: :string, how: {:string, 2_000}],
      optional: [head: :string, evidence: @evidence],
      idempotency: :writer
    },
    "finding.confirmed" => %{
      writers: [:machine],
      run_kinds: [],
      required: [finding_id: :string, resolution: :string, head: :string],
      optional: @signal,
      idempotency: {:fields, [:resolution]}
    },
    "checklist.answered" => %{
      writers: [:agent],
      run_kinds: :any,
      required: [item: {:string, 500}, answer: {:string, 2_000}],
      optional: [],
      idempotency: :writer
    },
    "ticket.cancelled" => %{
      writers: [:person],
      run_kinds: [],
      required: [from: :string, to: :string],
      optional: [note: {:string, 4_000}, run_stopped: :boolean, pull_requests_closed: {:list, :string}] ++ @signal,
      idempotency: :writer
    },
    "ticket.moved" => %{
      writers: [:person],
      run_kinds: [],
      required: [from: :string, to: :string],
      optional: [note: {:string, 4_000}, run_stopped: :boolean] ++ @signal,
      idempotency: :writer
    },
    "drift.detected" => %{writers: [:machine], run_kinds: [], required: @drift, optional: @signal, idempotency: :writer},
    "drift.reverted" => %{writers: [:machine], run_kinds: [], required: @drift, optional: @signal, idempotency: :writer},
    "drift.revert_failed" => %{
      writers: [:machine],
      run_kinds: [],
      required: @drift,
      optional: [error: :string] ++ @signal,
      idempotency: :writer
    },
    "pause.set" => @pause_reason_set,
    "pause.reason_added" => @pause_reason_set,
    "pause.reason_cleared" => %{
      writers: [:machine],
      run_kinds: [],
      required: @pause_reason,
      optional: [waits_on: :map, by: :map] ++ @signal,
      idempotency: :writer
    },
    "pause.cleared" => %{
      writers: [:machine],
      run_kinds: [],
      required: [cleared: :list],
      optional: [by: :map] ++ @signal,
      idempotency: :writer
    },
    "situation.changed" => %{
      writers: [:machine],
      run_kinds: [],
      required: [to: {:enum, @situation_kinds}, word: {:string, 300}, cause: {:string, 300}],
      optional: [from: {:enum, @situation_kinds}, since: :string] ++ @signal,
      idempotency: :writer
    },
    "park.backfilled" => %{
      writers: [:machine],
      run_kinds: [],
      required: [added: {:list, :string}],
      optional: [question_id: :string, branch: :string, from: :string] ++ @signal,
      idempotency: :writer
    },
    "workspace.synced" => %{
      writers: [:machine],
      run_kinds: [],
      required: [
        workspace_head: :string,
        pr_head: :string,
        winner: {:enum, ~w(equal workspace pull_request recorded none)},
        action: {:enum, ~w(none reset pushed reset_and_pushed blocked failed)}
      ],
      optional: [recorded_head: :string, head: :string, run_kind: :string, reason: {:string, 2_000}] ++ @signal,
      idempotency: :writer
    },
    "workspace.rebuilt" => %{
      writers: [:machine],
      run_kinds: [],
      required: [
        reason: {:enum, ~w(reclaim stop terminal cleanup missing_folder host_change)},
        branch: :string,
        winner: {:enum, ~w(pull_request branch recorded local main)}
      ],
      optional:
        [head: :string, pr_head: :string, branch_head: :string, recorded_head: :string] ++
          [local_head: :string, orphaned_head: :string] ++ @signal,
      idempotency: :writer
    },
    "workspace.removed" => %{
      writers: [:machine],
      run_kinds: [],
      required: [reason: {:enum, ~w(age_gc stop terminal cleanup)}],
      optional: @signal,
      idempotency: :writer
    },
    "rule.action" => %{
      writers: [:machine],
      run_kinds: [],
      required: [rule: {:string, 200}, action: {:enum, @rule_actions}],
      optional: [text: {:string, 500}, filed: :string, head: :string] ++ @signal,
      idempotency: :writer
    },
    "ticket.filed" => %{
      writers: [:machine],
      run_kinds: [],
      required: [identifier: :string, kind: {:enum, ~w(split_off follow_up)}],
      optional: [title: {:string, 300}] ++ @signal,
      idempotency: {:fields, [:identifier]}
    },
    "brief.written" => %{
      writers: [:agent],
      run_kinds: ~w(implementation rework review_feedback),
      required: [text: {:prose, 1_200}, walkthrough: {:prose, 4_000}],
      optional: [],
      idempotency: :writer
    },
    # A status report (`SymphonyElixir.Reports`), on the reports ledger of its own: the period it
    # covers, the tickets and the events it rests on, its sentences and their joined text, which
    # events each sentence cites (`citations`, by the sentence's index), the run and its model, and
    # the Question it raised, if any.
    "report.published" => %{
      writers: [:machine],
      run_kinds: [],
      required: [
        run_id: :string,
        model: :string,
        period: {:map, [from: :string, to: :string]},
        tickets: {:list, :string},
        events: {:list, :string},
        sentences: {:list, :string},
        text: {:string, 20_000},
        citations: :list
      ],
      optional: [question_id: :string] ++ @signal,
      idempotency: {:fields, [:run_id]}
    },
    "note.read" => %{
      writers: [:machine],
      run_kinds: [],
      required: [note_id: :string, run_id: :string],
      optional: @signal,
      idempotency: {:fields, [:note_id]}
    },
    "note" => %{
      writers: [:machine, :agent, :person],
      run_kinds: :any,
      required: [text: {:string, 4_000}],
      optional: @signal,
      idempotency: :writer
    }
  }

  @doc "What a `rule.action` may say a rule did."
  @spec rule_actions() :: [String.t()]
  def rule_actions, do: @rule_actions

  @doc "The legacy types: kept so history reads them, never recorded by a live writer (see the moduledoc)."
  @spec legacy_types() :: [String.t()]
  def legacy_types, do: @legacy_types

  @doc "Whether `type` is a legacy type (`legacy_types/0`)."
  @spec legacy?(term()) :: boolean()
  def legacy?(type), do: type in @legacy_types

  @doc "Every event type with its writers, agent run kinds, payload schema and idempotency rule."
  @spec catalog() :: %{String.t() => entry()}
  def catalog, do: @catalog

  @doc "The run kinds an agent actor may carry: every `SymphonyElixir.RunKind` name."
  @spec agent_run_kinds() :: [String.t()]
  def agent_run_kinds, do: RunKind.names()

  @doc """
  The types an agent of `run_kind` may record, sorted: the ones an agent writes whose run kinds
  include it, never a legacy type. Empty for a name that is not an agent run kind.
  """
  @spec agent_types(String.t() | atom() | nil) :: [String.t()]
  def agent_types(run_kind) do
    run_kind = run_kind_name(run_kind)

    types =
      for {type, %{writers: writers, run_kinds: kinds}} <- @catalog,
          run_kind in agent_run_kinds(),
          :agent in writers and not legacy?(type),
          kinds == :any or run_kind in kinds,
          do: type

    Enum.sort(types)
  end

  @doc """
  The payload schema of `type` as plain data a tool can return: its `required` and `optional`
  fields, each `%{name, type}` with a `max` length, a character it `forbids`, the enum `values`, the
  `item` spec of a list, the `of` specs of a choice or the `fields` of a map, and `required_when` (`%{field, equals}`) for
  a field the type requires exactly when another field holds a value (and refuses otherwise). Nil
  for an unknown type. The fields only the machinery passes (`signal`, `signal_details`) are left out.
  """
  @spec schema(term()) :: %{required: [map()], optional: [map()]} | nil
  def schema(type) do
    case fetch(type) do
      {:ok, entry} ->
        optional = entry.optional |> Keyword.drop(Keyword.keys(@signal)) |> describe_fields(Map.get(entry, :conditional, []))
        %{required: describe_fields(entry.required), optional: optional}

      {:error, _reason} ->
        nil
    end
  end

  defp describe_fields(fields, conditional \\ []) do
    Enum.map(fields, fn {name, spec} ->
      described = Map.put(describe(spec), :name, Atom.to_string(name))

      case Keyword.fetch(conditional, name) do
        {:ok, {field, value}} -> Map.put(described, :required_when, %{field: Atom.to_string(field), equals: value})
        :error -> described
      end
    end)
  end

  defp describe(:string), do: %{type: "string"}
  defp describe({:string, max}), do: %{type: "string", max: max}
  defp describe({:prose, max}), do: %{type: "string", max: max, forbids: "`"}
  defp describe({:enum, values}), do: %{type: "enum", values: values}
  defp describe({:list, spec}), do: %{type: "list", item: describe(spec)}
  defp describe({:any_of, specs}), do: %{type: "any_of", of: Enum.map(specs, &describe/1)}
  defp describe({:map, fields}), do: %{type: "map", fields: describe_fields(fields)}
  defp describe(spec) when is_atom(spec), do: %{type: Atom.to_string(spec)}

  @doc """
  Validates a payload of `type` written by an actor of `actor_kind` (an agent also names its
  `run_kind`). Returns the payload with its keys as atoms, its enums as strings and nil optional
  fields left out, or the first error: the type is unknown, the actor may not write it, or the
  payload's fields are missing, out of bounds or not in the schema (each named, in schema order).
  """
  @spec validate(term(), map() | term(), actor_kind(), String.t() | atom() | nil) :: {:ok, map()} | {:error, error()}
  def validate(type, payload, actor_kind, run_kind) do
    with {:ok, entry} <- fetch(type),
         :ok <- allowed(type, entry, actor_kind, run_kind),
         {:ok, normalized} <- validate_payload(entry, payload),
         :ok <- agent_values(type, entry, normalized, actor_kind) do
      {:ok, normalized}
    end
  end

  # A value of a field only some writers may record: an agent records only a delegated step, and
  # never the signal a machine's event records.
  defp agent_values(type, entry, normalized, :agent) do
    case Enum.filter(Keyword.keys(@signal), &Map.has_key?(normalized, &1)) do
      [] -> agent_field_values(type, entry, normalized)
      fields -> {:error, {:invalid_payload, fields}}
    end
  end

  defp agent_values(_type, _entry, _normalized, _actor_kind), do: :ok

  defp agent_field_values(type, entry, normalized) do
    Enum.reduce_while(Map.get(entry, :agent_values, []), :ok, fn {field, values}, :ok ->
      if Map.get(normalized, field) in values,
        do: {:cont, :ok},
        else: {:halt, {:error, {:not_allowed, "An agent records #{type} only with #{field} #{Enum.join(values, ", ")}; Symphony records the others"}}}
    end)
  end

  @doc """
  The idempotency key of an event of `type`: the writer's key when it passes one, else the key the
  type's rule derives from the payload (`type:value…`), else nil.
  """
  @spec idempotency_key(String.t(), map(), String.t() | nil) :: String.t() | nil
  def idempotency_key(type, payload, given) do
    case blank_to_nil(given) do
      nil -> derived_key(type, Map.get(@catalog, type), payload)
      key -> key
    end
  end

  defp fetch(type) when is_binary(type) do
    case Map.fetch(@catalog, type) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_type, type}}
    end
  end

  defp fetch(type), do: {:error, {:unknown_type, type}}

  defp allowed(type, %{writers: writers, run_kinds: run_kinds}, actor_kind, run_kind) do
    run_kind = run_kind_name(run_kind)

    cond do
      actor_kind not in writers ->
        {:error, {:not_allowed, "#{type} is not written by #{actor_name(actor_kind)}"}}

      actor_kind != :agent ->
        :ok

      run_kind not in agent_run_kinds() ->
        {:error, {:not_allowed, "#{inspect(run_kind)} is not an agent run kind"}}

      run_kinds == :any or run_kind in run_kinds ->
        :ok

      true ->
        {:error, {:not_allowed, "#{type} is written only by #{Enum.join(run_kinds, ", ")} runs, not #{run_kind}"}}
    end
  end

  defp actor_name(kind) when kind in [:machine, :agent, :person], do: "a #{kind}"
  defp actor_name(kind), do: inspect(kind)

  defp run_kind_name(kind) when is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind)
  defp run_kind_name(kind), do: kind

  defp validate_payload(entry, payload) when is_map(payload) do
    fields = Keyword.keys(entry.required) ++ Keyword.keys(entry.optional)
    {payload, unknown} = atomize(payload, fields)

    {normalized, invalid} =
      Enum.reduce(entry.required, {%{}, []}, &check_required(&1, payload, &2))

    {normalized, invalid} = Enum.reduce(entry.optional, {normalized, invalid}, &check_optional(&1, payload, &2))
    invalid = Enum.reduce(Map.get(entry, :conditional, []), invalid, &check_conditional(&1, normalized, &2))

    case Enum.reverse(invalid) ++ Enum.sort(unknown) do
      [] -> {:ok, normalized}
      fields -> {:error, {:invalid_payload, fields}}
    end
  end

  defp validate_payload(_entry, _payload), do: {:error, {:invalid_payload, [:payload]}}

  # Payload keys arrive as atoms from the machinery and as strings from a tool's JSON; a string
  # that names a schema field becomes its atom, and any other key is unknown.
  defp atomize(payload, fields) do
    names = Map.new(fields, &{Atom.to_string(&1), &1})

    Enum.reduce(payload, {%{}, []}, fn {key, value}, {known, unknown} ->
      case field_name(key, fields, names) do
        nil -> {known, [key | unknown]}
        field -> {Map.put(known, field, value), unknown}
      end
    end)
  end

  defp field_name(key, fields, _names) when is_atom(key), do: if(key in fields, do: key)
  defp field_name(key, _fields, names) when is_binary(key), do: Map.get(names, key)
  defp field_name(_key, _fields, _names), do: nil

  defp check_required({field, spec}, payload, {normalized, invalid}) do
    case check(spec, Map.get(payload, field)) do
      {:ok, nil} -> {normalized, [field | invalid]}
      {:ok, value} -> {Map.put(normalized, field, value), invalid}
      :error -> {normalized, [field | invalid]}
    end
  end

  defp check_optional({field, spec}, payload, acc) do
    case Map.fetch(payload, field) do
      {:ok, nil} -> acc
      {:ok, value} -> put_checked(check(spec, value), field, acc)
      :error -> acc
    end
  end

  # A conditional field is required exactly when its condition holds and refused otherwise: a step
  # that failed names the step it returns to, and a step that passed names none. A condition on a
  # field that is itself invalid is not judged.
  defp check_conditional({field, {on, value}}, normalized, invalid) do
    holds = Map.get(normalized, on) == value

    cond do
      not Map.has_key?(normalized, on) -> invalid
      holds == Map.has_key?(normalized, field) -> invalid
      field in invalid -> invalid
      true -> [field | invalid]
    end
  end

  defp put_checked({:ok, value}, field, {normalized, invalid}), do: {Map.put(normalized, field, value), invalid}
  defp put_checked(:error, field, {normalized, invalid}), do: {normalized, [field | invalid]}

  defp check(_spec, nil), do: {:ok, nil}

  defp check(:string, value) when is_binary(value), do: if(String.trim(value) == "", do: :error, else: {:ok, value})

  defp check({:string, max}, value) when is_binary(value) do
    if String.length(value) > max, do: :error, else: check(:string, value)
  end

  defp check({:prose, max}, value) when is_binary(value) do
    if String.contains?(value, "`"), do: :error, else: check({:string, max}, value)
  end

  defp check({:enum, values}, value) when is_atom(value), do: check({:enum, values}, Atom.to_string(value))
  defp check({:enum, values}, value) when is_binary(value), do: if(value in values, do: {:ok, value}, else: :error)
  defp check(:non_neg_integer, value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp check(:boolean, value) when is_boolean(value), do: {:ok, value}
  defp check(:map, value) when is_map(value), do: {:ok, value}
  defp check(:list, value) when is_list(value), do: {:ok, value}

  defp check({:map, fields}, value) when is_map(value) do
    names = Keyword.keys(fields)

    case atomize(value, names) do
      {given, []} when map_size(given) == length(names) ->
        Enum.reduce_while(fields, {:ok, %{}}, &check_field(&1, given, &2))

      _missing_or_unknown ->
        :error
    end
  end

  defp check({:list, :string}, value) when is_list(value) do
    if Enum.all?(value, &match?({:ok, _}, check(:string, &1))), do: {:ok, value}, else: :error
  end

  defp check({:any_of, specs}, value) do
    Enum.find_value(specs, :error, fn spec ->
      case check(spec, value) do
        {:ok, checked} -> {:ok, checked}
        :error -> nil
      end
    end)
  end

  defp check(_spec, _value), do: :error

  defp check_field({field, spec}, given, {:ok, acc}) do
    case check(spec, Map.get(given, field)) do
      {:ok, checked} when not is_nil(checked) -> {:cont, {:ok, Map.put(acc, field, checked)}}
      _invalid -> {:halt, :error}
    end
  end

  defp derived_key(type, %{idempotency: {:fields, fields}}, payload) when is_map(payload) do
    values = Enum.map(fields, &Map.get(payload, &1))

    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      Enum.join([type | values], ":")
    end
  end

  defp derived_key(_type, _entry, _payload), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
