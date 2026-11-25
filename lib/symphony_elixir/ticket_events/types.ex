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
    * `{:map, fields}` - a map holding exactly `fields` (a keyword of specs, each required unless
      wrapped as `{:optional, spec}`), its keys as atoms.
    * `{:list, spec}` - a list whose every item satisfies `spec`.

  An optional field given as nil is left out. A field the type does
  not name is rejected. Every type a machine or a person writes, and `note`, also takes an optional
  `signal`, the name of the signal it records (`SymphonyElixir.TicketSignals`), and
  `signal_details`, the details the signal was recorded with, so readers of the signals ledger can
  move over to events. A `note` also takes `status`, true on a note Symphony wrote itself as a wait
  or status message, which the Director's timeline lists only under "Show all events". A
  `verdict.recorded` also takes the `details` the verdict carries. A tool's caller sees none of
  them, and an agent records none (`schema/1`).

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
  `agent_types/1` lists for its run kind: `finding.recorded` in a QA run (Symphony also records one
  as a Conductor turn's when a person picks its option to send the ticket to Rework,
  `SymphonyElixir.DecisionMove`, and as its own when the QA seed and fixtures on a head miss a QA
  check's walked-on state, `SymphonyElixir.QaState`); `finding.resolved`,
  `step.started`, `step.completed`, `evidence`, `checklist.answered`, `check.proved` and `note` in any run. Every other type is the
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
  ones (`agent_values`). An agent step's `step.started` may say what its turn runs with: `model`,
  `effort` and `session`, and `model_ignored` (with `model_ignored_reason`) when a run on a fallback
  provider kept its own model (`SymphonyElixir.QaAgent.Steps`). `step.completed` says how the step ended (`outcome`): `passed`; `failed`,
  with the step the run goes back to (`returns_to`, and its title in `returns_to_title`) and why (`reason`); `paused`,
  with the Question it waits on (`question_id`, from `SymphonyElixir.Questions`); or `skipped`, with
  why (`reason`); and how long it took (`duration_ms`). Those fields are `conditional`: each is
  required exactly when its outcome holds and refused otherwise, as `command` and `prompt_ref` are
  by mode. A machine step's output is kept as an artifact of the `step_output` kind
  (`SymphonyElixir.Artifacts`) on its `step.completed`; an agent step's slice of the session
  transcript is a `transcript` artifact on its `step.completed` (`SymphonyElixir.PhaseSteps.Transcript`).

  A stepped QA pass puts each agent step's answer on its own `step.completed`
  (`SymphonyElixir.QaAgent.StepPayload`), each key optional and bounded: `result` (a check step's
  `status`, `expected` up to 1,500 characters and `actual` up to 1,500); `plan` (the plan step's
  `checks`, each a `title` up to 120 and an `expect` up to 400, its `skips`, each a `title` and the
  `why`, and a `summary` up to 600); `recheck` (on the review that asks for rechecks: one entry per
  brief, a `title` up to 120, its `do` instructions one string each up to 400, `expect` up to 1,500
  and an optional `design` up to 600); and `verdict_summary` (the review's own summary, up to 600).
  A step whose answer Symphony could not take ends `failed` with its `reason`.

  In every other run kind a step's structured answer is its `answer` (`SymphonyElixir.PhaseSteps.StepAnswer`):
  a list of at most 12 `label` (up to 60 characters) and `value` (up to 1,500, as text) entries in
  the answer's key order. Symphony never writes a machine `note` to carry a step's output: what a
  step answered and why it failed live on its `step.completed`. A `paused` step may say why too
  (`reason`). The Window tests step's (`SymphonyElixir.PhaseSteps.WindowTests.details/1`), failed
  or paused, names in `failures` each test that failed in the QA VM, at most 10: its `script` and
  `title` (up to 500), its `exit_status`, the last lines it `printed` (up to 1,200) and, when it ran
  again on the base branch, the same there (`base`).
  Symphony's check of the QA seed and fixtures before QA (`SymphonyElixir.QaState`, step
  `qa_state`) puts its result in `qa_state`: for each QA check (`check_id`, at most 30) its `status`
  (`held`, `missing`, or `unjudged` when the check names no state) and each path it names, with
  what the plan said of it (`holds`: `present`, `added`, or `fixture` for its setting's fixture
  directory), whether the head holds it (`held`) and, when not, why (`why`: `absent`, `empty`, or
  `unchanged` for an `added` path the pull request does not change).
  A skipped step is a `step.completed` with
  `outcome: skipped`: there is no `step.skipped` type. A `question.answered` naming the question a
  paused step waits on is what resumes that step.

  A person's cancel of a ticket Symphony owns is one `ticket.cancelled` (`SymphonyElixir.DirectorMoves`):
  the phase it left and the canceled state, the Director's note, whether a run was stopped and the
  pull requests closed with it. A person's free move of one into any phase is one `ticket.moved`:
  the phase it left and the one it entered, the Director's note and whether a run was stopped. The
  Conductor's own move of its ticket, made through the same free move, is one too, its actor the
  Conductor's turn (an agent of run kind `conductor`) and its note the turn's reason; Symphony
  records it for the turn, and no run records it through `ticket_record` (`tool: false`).

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

  `message.sent` is the person's: what they wrote to the ticket (`text`, as long as an ask: at most
  100,000 characters), through the control API's
  note endpoint, each message its own event (`SymphonyElixir.Messages`); one that answers, in the
  person's own words, the question the ticket is held on names it (`question_id`,
  `SymphonyElixir.DirectorMoves.answer_held_question/4`). `message.read` is
  machinery-only: the run (`run_id`) whose prompt was given the message (`message_id`, the
  `message.sent` event's id) as new, keyed by the message so it is given to one run only.

  `report.published` is machinery-only: a status report a report run published through its one tool
  (`SymphonyElixir.Reports`), recorded on the reports ledger and never on a ticket's: the period, the
  tickets and the events it rests on, its sentences, their text, each sentence's citations, the run,
  its model and the Question it raised (`question_id`).

  `conductor.update` and `conductor.instructions` are machine-only: what the Conductor's turn at a
  junction of the ticket's life wrote (`SymphonyElixir.Conductor`), naming the junction
  (`grooming`, `after_coding`, `after_qa_fail`, `after_qa_blocked`, `after_rework`, `before_merge`,
  `message`, `sub_ticket_ended`, `final_check`, `child_message`). The update
  is for the person (`text`, at most 900 characters) with the ids of the events it rests on
  (`refs`); the instructions are advice for the next run's prompt (`text`, at most 3,000), and at
  `after_qa_blocked` carry the route Symphony took on the turn's answer (`route`: `rerun`, QA runs
  again, or `rework`, the ticket went to Rework with the turn's finding). A turn that watched a
  running run names the junction `during_run`. `conductor.steer` is machine-only too: guidance the
  Conductor's watch gave a running run (`SymphonyElixir.Conductor.Watch`), under that run's
  `run_id`: its `text` (at most 1,500 characters), when it asked for it (`when`: `next_turn`, `now`
  or `stop`), what made it look (`trigger`) and how and when it reached the run (`delivered`: `how`,
  `next_turn`, `now` or `stopped`, and `at`).

  `brief.written` is an agent's, in an implementation, rework or review-feedback run: what the ticket
  does and why, in a person's words (`text`, at most 1,200 characters), and its walkthrough as the
  steps a person takes (`walkthrough`, at most 4,000), both prose with no backtick. The newest one is
  the ticket's brief (`SymphonyElixir.TicketBrief`).

  A groomed ticket's four shapes are the ask, the plan, its checks and its notes. `ask.recorded` is
  the machine's or a person's: what a person asked for, word for word (`text`, at most 100,000
  characters), where it came from (`source`: `linear`, the description at entry; `message`, a
  message that changed what is asked; `parent`, the parent ticket's plan) and the parent ticket or
  the message event it came `from`. `plan.written` is machine-only: one version of the ticket's plan
  (`SymphonyElixir.TicketPlan`), with its `version` (1 for Grooming's), why it was written
  (`reason`, at most 1,000) and `by` what (`grooming`, `recalibration`, `parent`, `run`), its
  `shape` (`single` or `split`), the `layers` it touches (none or more of `screen`, `gallery`,
  `api`, `logic`, `config`, `tests`, `tooling`, `docs`, and `engine`, `logic`'s older name), a `summary` for a person (at most 600), the plan's `text` for agents
  (at most 12,000), its `checks` (at most 30), its `size` (`tokens` and `runs`) and, for a split, its
  `sub_tickets` (at most 12). A check has an `id` that is its alone across versions (`c1`, `c2`; a new check gets one no
  version used, and a check whose `statement` changed starts unproved), a `kind`
  (`outcome`, `qa`, `evidence`), a `statement` (at most 600) and how it is proved (`proof`: `test`,
  `qa`, `design`, `attached`); a `qa` check also says the app `state` it needs, the `action` and
  what to `expect` (at most 400 each), the `size` it is walked at (`normal`, `wide`) and the Gallery
  `story` a design proof compares, and, as data, where it is walked (`setting`: its `source`,
  `fixture` or `live`, the repo-relative `fixture` directory, the `page`, the `window` `width` and
  `height` and the `appearance`, `light` or `dark`) and the state it is walked on (`walked_on`: each
  repo-relative seed or fixture `path` and whether it `holds` it already, `present`, or the change
  adds it, `added`). Both are optional, so a plan written before them still reads. A sub-ticket entry has a `key` (`s1`), a `title` (at most 120),
  an `ask` (at most 4,000), the sibling keys whose merge it waits on (`after`), a `repo` when it is
  not the parent's and the `identifier` Symphony fills once the ticket exists.

  `check.proved` is an agent's, in any run, or the machine's: a check of the current plan
  (`check_id`) proved `by` a `test`, `qa`, the `design`, something `attached`, the pull request's
  `ci` or its `sub_tickets` (the machine's, when a split ticket's final check passed on them), with the `test`
  that proves it (at most 500), the event that is its `evidence` and `details` (at most 2,000). It
  is recorded once per check and head (`SymphonyElixir.TicketChecks`). `check.waived` is
  machine-only: a check (`check_id`) nobody has to prove any more, and why (`reason`, at most
  1,000). `conductor.intervention` is machine-only: what the Conductor of the ticket `by` did to
  this one (`action`: `stopped`, `replanned`, `canceled`, `replaced`, `added`, `reordered` (put at
  another place among its siblings), `rewired` (what it waits on set again)), why (`reason`, at
  most 1,000) and the ticket it names (`target`). A `note` may carry a `tag` an agent writes:
  `discovery` (something a run found that is not its own to solve) or `base_fault` (a fault of the
  base branch).
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
          | {:list, field_spec()}
          | {:any_of, [field_spec()]}
          | {:map, keyword(field_spec() | {:optional, field_spec()})}
  @type idempotency_rule :: :writer | {:fields, [atom()]}
  @type entry :: %{
          required(:writers) => [actor_kind()],
          required(:run_kinds) => :any | [String.t()],
          required(:required) => keyword(field_spec()),
          required(:optional) => keyword(field_spec()),
          required(:idempotency) => idempotency_rule(),
          optional(:conditional) => keyword({atom(), String.t()} | {atom(), String.t(), [String.t()]}),
          optional(:agent_values) => keyword([String.t()]),
          optional(:tool) => boolean()
        }
  @type error :: {:unknown_type, term()} | {:invalid_payload, [atom() | String.t()]} | {:not_allowed, String.t()}

  @verdict_kinds ~w(code_review qa ci_fix plan_review epic_review)
  @person_actions ~w(stop move unblock restart add_blocker remove_blocker add_dependency remove_dependency set_priority add_label remove_label)
  @step_modes ~w(machine orchestrated delegated)
  @evidence {:any_of, [:string, {:list, :string}]}
  # A QA step's result and the environment it was proved in (`fixture`: the committed state
  # fixtures; `live`: Symphony's own server on the QA host), as a QA pass's step evidence carries them.
  @evidence_statuses ~w(pass fail blocked skipped unprovable)
  @environments ~w(fixture live)
  @qa_answer_statuses ~w(pass fail blocked plan_mismatch)
  @tokens {:any_of, [:non_neg_integer, :map]}
  # The signal an event records (`SymphonyElixir.TicketSignals.signal_event/2`) and the details it
  # was recorded with.
  @signal [signal: :string, signal_details: :map]
  # A note Symphony wrote itself as a wait or status message (`SymphonyElixir.TicketSignals`, the PR
  # head sync): the Director's timeline lists it only with "Show all events".
  @status [status: :boolean]
  # The fields only the machinery passes: an agent never records them and a tool's caller never sees
  # them. A note's `status` is the machinery's; evidence has a `status` of its own an agent records.
  @machine_fields Keyword.keys(@signal)
  @note_machine_fields @machine_fields ++ Keyword.keys(@status)
  # The model and effort the run profile resolved at dispatch (`run.started`, copied onto `run.ended`).
  @run_profile [model: :string, effort: :string]
  @drift [record_phase: :string, linear_phase: :string]
  @pause_reasons ~w(question ticket build person environment)
  # `SymphonyElixir.Situation.kinds/0`, which reads the record and so may not be read here.
  @situation_kinds ~w(waiting_on_you retrying blocked_by_ticket waiting_on_sub_tickets waiting_for_provider paused_by_rule waiting_for_ci waiting_for_build waiting_for_slot working done cancelled unknown)
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

  # The junctions of a ticket's life the Conductor runs at (`SymphonyElixir.Config.Schema.Conductor.junctions/0`).
  @conductor_junctions ~w(grooming after_coding after_qa_fail after_qa_blocked after_rework before_merge message sub_ticket_ended final_check child_message during_run)
  # What made the Conductor's watch look at a running run (`SymphonyElixir.Conductor.Watch`).
  @watch_triggers ~w(step_failed step_failed_twice qa_step_answer run_minutes run_tokens message)

  # How a check of a plan is proved (`SymphonyElixir.TicketChecks`). `ci`: by the pull request's
  # own CI run, after the handoff and before the merge; its `ci_check` names the one CI check that
  # proves it when that check passing is all it asks.
  @check_proofs ~w(test qa design attached ci)
  # How a check was proved: as a plan says, or by the sub-tickets a split ticket finished through
  # (the machine's, when its final check passed on them).
  @proved_by_kinds @check_proofs ++ ~w(sub_tickets)
  # Where a `qa` check is walked and the state it is walked on (`SymphonyElixir.Conductor.Answer`
  # checks the paths are repo-relative and the window within the playbook limits).
  @check_setting {:map,
                  [
                    source: {:enum, ~w(fixture live)},
                    fixture: {:optional, {:string, 300}},
                    page: {:string, 200},
                    window: {:map, [width: :non_neg_integer, height: :non_neg_integer]},
                    appearance: {:enum, ~w(light dark)}
                  ]}
  @walked_on {:map, [path: {:string, 300}, holds: {:enum, ~w(present added)}]}
  # Symphony's check of a QA check's walked-on state on a head (`SymphonyElixir.QaState`): each path
  # the plan names (a `walked_on` entry, or the `fixture` directory of its setting), whether the head
  # holds it and, when not, why.
  @qa_state_check {:map,
                   [
                     check_id: {:string, 20},
                     status: {:enum, ~w(held missing unjudged)},
                     paths:
                       {:list,
                        {:map,
                         [
                           path: {:string, 300},
                           holds: {:enum, ~w(present added fixture)},
                           held: :boolean,
                           why: {:optional, {:enum, ~w(absent empty unchanged)}}
                         ]}}
                   ]}
  @plan_check {:map,
   [
     id: {:string, 20},
     kind: {:enum, ~w(outcome qa evidence)},
     statement: {:string, 600},
     proof: {:enum, @check_proofs},
     state: {:optional, {:string, 400}},
     action: {:optional, {:string, 400}},
     expect: {:optional, {:string, 400}},
     size: {:optional, {:enum, ~w(normal wide)}},
     story: {:optional, {:string, 200}},
     ci_check: {:optional, {:string, 200}},
     # Optional, so a plan written before a QA check named them still reads.
     setting: {:optional, @check_setting},
     walked_on: {:optional, {:list, @walked_on}}
   ]}
  @plan_sub_ticket {:map,
                    [
                      key: {:string, 20},
                      title: {:string, 120},
                      ask: {:string, 4_000},
                      after: {:optional, {:list, {:string, 20}}},
                      repo: {:optional, {:string, 200}},
                      identifier: {:optional, {:string, 50}}
                    ]}

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
        [
          move: :string,
          from: :string,
          to: :string,
          blocker: :string,
          kind: {:enum, ~w(done released)},
          label: :string,
          run_stopped: :boolean
        ] ++
          @signal,
      idempotency: :writer
    },
    "step.started" => %{
      writers: [:machine, :agent],
      run_kinds: :any,
      required: @step,
      optional:
        [
          command: {:string, 2_000},
          prompt_ref: {:string, 200},
          model: {:string, 200},
          effort: {:string, 20},
          session: {:string, 100},
          model_ignored: {:string, 200},
          model_ignored_reason: {:string, 300}
        ] ++ @signal,
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
          duration_ms: :non_neg_integer,
          result: {:map, [status: {:enum, @qa_answer_statuses}, expected: {:string, 1_500}, actual: {:string, 1_500}]},
          results:
            {:list,
             {:map,
              [
                step: :non_neg_integer,
                status: {:enum, @qa_answer_statuses},
                expected: {:string, 1_500},
                actual: {:string, 1_500}
              ]}, 20},
          plan:
            {:map,
             [
               checks: {:list, {:map, [title: {:string, 120}, expect: {:string, 400}]}},
               skips: {:list, {:map, [title: {:string, 120}, why: {:string, 400}]}},
               summary: {:string, 600}
             ]},
          recheck:
            {:list,
             {:map,
              [
                title: {:string, 120},
                do: {:list, {:string, 400}},
                expect: {:string, 1_500},
                design: {:optional, {:string, 600}}
              ]}},
          verdict_summary: {:string, 600},
          answer: {:list, {:map, [label: {:string, 60}, value: {:string, 1_500}]}},
          qa_state: {:list, @qa_state_check, 30},
          failures:
            {:list,
             {:map,
              [
                script: {:string, 500},
                title: {:string, 500},
                exit_status: :non_neg_integer,
                printed: {:optional, {:string, 1_200}},
                base: {:optional, {:map, [exit_status: :non_neg_integer, printed: {:optional, {:string, 1_200}}]}}
              ]}, 10}
        ] ++ @signal,
      conditional: [returns_to: {:outcome, "failed"}, question_id: {:outcome, "paused"}, reason: {:outcome, "skipped", ["failed", "paused"]}],
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
      writers: [:agent, :machine],
      run_kinds: ["qa", "conductor"],
      required: [class: {:string, 100}, severity: {:string, 50}, description: {:string, 2_000}],
      optional: [viewport: {:string, 100}, step: {:string, 200}, evidence: @evidence] ++ @signal,
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
      writers: [:person, :agent],
      run_kinds: ["conductor"],
      tool: false,
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
        reason: {:enum, ~w(reclaim terminal cleanup missing_folder host_change)},
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
      required: [reason: {:enum, ~w(age_gc terminal cleanup)}],
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
      optional:
        [title: {:string, 300}, by: {:enum, ~w(conductor)}, repo: :string, url: :string] ++
          [reason: {:string, 600}, existing: :boolean] ++ @signal,
      idempotency: {:fields, [:identifier]}
    },
    # On a ticket the Conductor filed (`SymphonyElixir.Conductor.Filing`): the ticket it came from,
    # so a ticket it filed never files one of its own.
    "ticket.filed_from" => %{
      writers: [:machine],
      run_kinds: [],
      required: [from: :string, by: {:enum, ~w(conductor)}],
      optional: [kind: {:enum, ~w(split_off follow_up)}] ++ @signal,
      idempotency: {:fields, [:from]}
    },
    "conductor.update" => %{
      writers: [:machine],
      run_kinds: [],
      required: [junction: {:enum, @conductor_junctions}, text: {:string, 1_200}],
      optional: [refs: {:list, :string}, watch: :map, blocks: :list] ++ @signal,
      idempotency: :writer
    },
    "conductor.instructions" => %{
      writers: [:machine],
      run_kinds: [],
      required: [junction: {:enum, @conductor_junctions}, text: {:string, 3_000}],
      optional: [route: {:enum, ~w(rerun rework ticket hold)}] ++ @signal,
      idempotency: :writer
    },
    "conductor.steer" => %{
      writers: [:machine],
      run_kinds: [],
      required: [text: {:string, 1_500}, when: {:enum, ~w(next_turn now stop)}, trigger: {:enum, @watch_triggers}],
      optional: [delivered: {:map, how: {:enum, ~w(next_turn now stopped)}, at: :string}] ++ @signal,
      idempotency: :writer
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
    "message.sent" => %{
      writers: [:person],
      run_kinds: [],
      required: [text: {:string, 100_000}],
      optional: [question_id: :string, source: {:enum, ~w(linear_description)}] ++ @signal,
      idempotency: :writer
    },
    "message.read" => %{
      writers: [:machine],
      run_kinds: [],
      required: [message_id: :string, run_id: :string],
      optional: @signal,
      idempotency: {:fields, [:message_id]}
    },
    "note" => %{
      writers: [:machine, :agent, :person],
      run_kinds: :any,
      required: [text: {:string, 4_000}],
      optional: [tag: {:enum, ~w(discovery base_fault)}] ++ @status ++ @signal,
      idempotency: :writer
    },
    # What a person asked for, never rewritten (`SymphonyElixir.TicketPlan.ask/1`).
    "ask.recorded" => %{
      writers: [:machine, :person],
      run_kinds: [],
      required: [text: {:string, 100_000}, source: {:enum, ~w(linear message parent)}],
      optional: [from: {:string, 200}] ++ @signal,
      idempotency: :writer
    },
    # One version of the ticket's plan (`SymphonyElixir.TicketPlan`), which assigns `version`.
    "plan.written" => %{
      writers: [:machine],
      run_kinds: [],
      required: [
        version: :non_neg_integer,
        reason: {:string, 1_000},
        by: {:enum, ~w(grooming recalibration parent run)},
        shape: {:enum, ~w(single split)},
        layers: {:list, {:enum, ~w(screen gallery api logic config tests tooling docs engine)}},
        summary: {:string, 600},
        text: {:string, 12_000},
        checks: {:list, @plan_check, 30},
        size: {:map, [tokens: :non_neg_integer, runs: :non_neg_integer]}
      ],
      optional: [sub_tickets: {:list, @plan_sub_ticket, 12}] ++ @signal,
      idempotency: :writer
    },
    # A check of the current plan, proved (`SymphonyElixir.TicketChecks`): once per check and head,
    # on the key its writer passes.
    "check.proved" => %{
      writers: [:machine, :agent],
      run_kinds: :any,
      required: [check_id: {:string, 20}, by: {:enum, @proved_by_kinds}],
      optional: [test: {:string, 500}, evidence: {:string, 200}, details: {:string, 2_000}] ++ @signal,
      idempotency: :writer
    },
    "check.waived" => %{
      writers: [:machine],
      run_kinds: [],
      required: [check_id: {:string, 20}, reason: {:string, 1_000}],
      optional: @signal,
      idempotency: :writer
    },
    "conductor.intervention" => %{
      writers: [:machine],
      run_kinds: [],
      required: [action: {:enum, ~w(stopped replanned canceled replaced added reordered rewired)}, reason: {:string, 1_000}, by: {:string, 200}],
      optional: [target: {:string, 200}] ++ @signal,
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
  include it, never a legacy type, and never one Symphony records for the agent only (`tool:
  false`: a Conductor turn's `ticket.moved`). Empty for a name that is not an agent run kind.
  """
  @spec agent_types(String.t() | atom() | nil) :: [String.t()]
  def agent_types(run_kind) do
    run_kind = run_kind_name(run_kind)

    types =
      for {type, %{writers: writers, run_kinds: kinds} = entry} <- @catalog,
          run_kind in agent_run_kinds(),
          :agent in writers and not legacy?(type) and Map.get(entry, :tool, true),
          kinds == :any or run_kind in kinds,
          do: type

    Enum.sort(types)
  end

  @doc """
  The payload schema of `type` as plain data a tool can return: its `required` and `optional`
  fields, each `%{name, type}` with a `max` length, a character it `forbids`, the enum `values`, the
  `item` spec of a list, the `of` specs of a choice or the `fields` of a map, and `required_when` (`%{field, equals}`) for
  a field the type requires exactly when another field holds a value (and refuses otherwise). Nil
  for an unknown type. The fields only the machinery passes (`signal`, `signal_details`, a note's `status`) are left out.
  """
  @spec schema(term()) :: %{required: [map()], optional: [map()]} | nil
  def schema(type) do
    case fetch(type) do
      {:ok, entry} ->
        optional = entry.optional |> Keyword.drop(machine_fields(type)) |> describe_fields(Map.get(entry, :conditional, []))
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
        {:ok, {field, value, _allowed}} -> Map.put(described, :required_when, %{field: Atom.to_string(field), equals: value})
        :error -> described
      end
    end)
  end

  defp describe(:string), do: %{type: "string"}
  defp describe({:string, max}), do: %{type: "string", max: max}
  defp describe({:prose, max}), do: %{type: "string", max: max, forbids: "`"}
  defp describe({:enum, values}), do: %{type: "enum", values: values}
  defp describe({:list, spec}), do: %{type: "list", item: describe(spec)}
  defp describe({:list, spec, max}), do: %{type: "list", item: describe(spec), max_items: max}
  defp describe({:any_of, specs}), do: %{type: "any_of", of: Enum.map(specs, &describe/1)}
  defp describe({:map, fields}), do: %{type: "map", fields: fields |> Enum.map(&unwrap_optional/1) |> describe_fields()}
  defp describe(spec) when is_atom(spec), do: %{type: Atom.to_string(spec)}

  defp unwrap_optional({name, {:optional, spec}}), do: {name, spec}
  defp unwrap_optional(field), do: field

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
  # never the signal a machine's event records or the status a machine's note is.
  defp agent_values(type, entry, normalized, :agent) do
    case Enum.filter(machine_fields(type), &Map.has_key?(normalized, &1)) do
      [] -> agent_field_values(type, entry, normalized)
      fields -> {:error, {:invalid_payload, fields}}
    end
  end

  defp agent_values(_type, _entry, _normalized, _actor_kind), do: :ok

  defp machine_fields("note"), do: @note_machine_fields
  defp machine_fields(_type), do: @machine_fields

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
  # A third element lists the other values of the field that merely allow it.
  defp check_conditional({field, {on, value}}, normalized, invalid), do: check_conditional({field, {on, value, []}}, normalized, invalid)

  defp check_conditional({field, {on, value, allowed}}, normalized, invalid) do
    current = Map.get(normalized, on)
    holds = current == value
    present = Map.has_key?(normalized, field)

    cond do
      not Map.has_key?(normalized, on) -> invalid
      holds == present -> invalid
      not holds and present and current in allowed -> invalid
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
    case atomize(value, Keyword.keys(fields)) do
      {given, []} -> Enum.reduce_while(fields, {:ok, %{}}, &check_field(&1, given, &2))
      _unknown -> :error
    end
  end

  defp check({:list, spec, max}, value) when is_list(value) and length(value) <= max, do: check({:list, spec}, value)

  defp check({:list, spec}, value) when is_list(value) do
    case Enum.reduce_while(value, {:ok, []}, &check_item(spec, &1, &2)) do
      {:ok, checked} -> {:ok, Enum.reverse(checked)}
      :error -> :error
    end
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

  defp check_item(spec, item, {:ok, acc}) do
    case check(spec, item) do
      {:ok, checked} when not is_nil(checked) -> {:cont, {:ok, [checked | acc]}}
      _invalid -> {:halt, :error}
    end
  end

  defp check_field({field, {:optional, spec}}, given, {:ok, acc}) do
    case check(spec, Map.get(given, field)) do
      {:ok, nil} -> {:cont, {:ok, acc}}
      {:ok, checked} -> {:cont, {:ok, Map.put(acc, field, checked)}}
      :error -> {:halt, :error}
    end
  end

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
