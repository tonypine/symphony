# What a person does on a ticket, and how they do it through Symphony

Under `dispatch.source: record`, a person who edits a fact Symphony owns by hand in Linear has made
drift, and Symphony undoes it. So every action a person used to take on a ticket in Linear needs a
Director move. This table lists those actions. Each one was found from what the code reads of
Linear for a ticket: the observation (`SymphonyElixir.TicketObservation`, `TicketState.observe/4`),
the webhook (`SymphonyElixir.Linear.Webhook`), the start-up reconciler
(`SymphonyElixir.TicketStateReconciler`), the drift rule (`TicketObservation.owned_phase/3`,
`revert/5`), the dispatch read (`SymphonyElixir.Dispatch.Candidates`) and the poll
(`SymphonyElixir.Linear.Client`). Further actions came from the instructions that tell a person to do
something in Linear. The Director moves are `SymphonyElixir.DirectorMoves` and the control endpoints
are `POST /api/v1/control/<move>` (`SymphonyElixirWeb.Router`).

**Owner** says who owns the fact today. *Symphony* means a hand edit is drift and gets reverted or
re-projected. *Linear* means Symphony follows what Linear says.

| Action in Linear | Read by | Owner | Through Symphony | Gap |
| --- | --- | --- | --- | --- |
| Move to a phase (any state) | the observation; `TicketStateReconciler.reconcile/4` | Symphony once Symphony or the Director wrote the phase (`phase_owner: :symphony`); Linear for a phase an observation wrote (`:external`) | Move to… (`/move`) | — |
| Promote Backlog → Todo | the poll's active states; `Dispatch.Candidates` | Linear until Symphony moves it | Move to… (`/move`) to Todo; for a ticket of a configured repository Symphony has no record of yet (a Backlog ticket whose webhook delivery was missed), Move to… reads it from Linear and records it first (`DirectorMoves.require_tracked/2`), since [TP-1367](https://linear.app/tonypine/issue/TP-1367) | — |
| Promote a split-off ticket from Backlog to Todo, and link it as a blocker | `linear_create_subissue` (`AgentTools.Linear.create_subissue/3`) | Symphony | none needed since [TP-1353](https://linear.app/tonypine/issue/TP-1353): a run of a ticket that is not a plan files its sub-ticket in Todo and marks the ticket blocked by it, so the sub-ticket lands first and the ticket continues on its own; a plan run's sub-tickets stay in Backlog until the plan's approval promotes them | — |
| Approve a plan (Plan Review → Waiting on sub-tickets) | `SymphonyElixir.BreakdownReview` | Symphony | Approve Plan (`/approve_plan`) | — |
| Reject a plan (→ Rework) | `BreakdownReview` | Symphony | Reject Plan (`/rework`) | — |
| Comment on a plan under review | `SymphonyElixir.PlanComments` | Linear (a person's comment) | Ask for Changes (`/changes`) | — |
| Reply under a `## Decision needed:` request | `Pauses.Projector` (the reply is the answer) | Symphony (the Question) | Decide (`/decide`); a plan's answers with Send Decisions (`/decisions`) | — |
| Comment a ruling (`Decision:` / `Ruling:`) | `Linear.IssueNormalizer` rulings; `SymphonyElixir.Decisions` | Linear | none: a note (`/note`) is not a decision | [TP-1357](https://linear.app/tonypine/issue/TP-1357) |
| Answer the quality gate's clarification questions | `SymphonyElixir.QualityGate` (an answer, or a reply's comment activity, re-scores the ticket); `QualityGate.Question` | Symphony (the Question); a reply in Linear still re-scores | Decide (`/decide`) on the gate's Question, in an option (Start it as it is, Move it to Backlog) or in the person's own words, since [TP-1360](https://linear.app/tonypine/issue/TP-1360) | — |
| Comment for the next run | the prompt's recent comments (`SymphonyElixir.PromptBuilder`) | Linear | Note (`/note`): it reaches the ticket history the prompt carries | — |
| Cancel | the observation (phase) | Symphony | Cancel (`/cancel`) | — |
| Park in Backlog | the observation (phase) | Symphony | Backlog (`/backlog`) | — |
| Reopen a Done or Canceled ticket | the observation (phase); a cancelled record follows Linear again | Symphony | Move to… (`/move`) | — |
| Start over (close the PR, fresh branch) | — | Symphony | Restart (`/restart`) | — |
| Move a ticket out of a retired state | `SymphonyElixir.RetiredStates` | Linear | Move to… (`/move`); the drain report names it since [TP-1358](https://linear.app/tonypine/issue/TP-1358) | — |
| Approve a merge: answer the manual-review Question, or move to `Merging` by hand | `SymphonyElixir.MergeConfirmation`; the observation (a hand move to `Merging` of a phase Symphony owns is drift, moved back) | Symphony (the Question; the phase) | Decide (`/decide`, target `merging`); Move to… (`/move`) Merging | — |
| Add or remove `Blocked`, `Needs Decision`, the CI labels | `Pauses.Projector.labels/0`; `SymphonyElixir.MachineLabels` | Symphony (projected; a hand edit is put back) | Unblock (`/unblock`), Decide (`/decide`) | — |
| Add or remove the force label (`expedite`) | `Issue.forced?/2` | Linear | Force (`/force`, `clear` removes it); `symphony force` | — |
| Add or remove `plan` / `breakdown` | `Issue.breakdown?/1` | Linear | none | [TP-1356](https://linear.app/tonypine/issue/TP-1356) |
| Add or remove `type:bug` / `type:feature` | `priv/playbook/ticket_types.liquid` (`issue.labels`: the per-type steps and readiness check) | Linear | none | [TP-1356](https://linear.app/tonypine/issue/TP-1356) |
| Add or remove `qa:skip` | `QaAgent.Selection` | Linear | none | [TP-1356](https://linear.app/tonypine/issue/TP-1356) |
| Add or remove `skip-update-hold` | `SymphonyElixir.UpdateHold`; `Pauses.Dependencies` | Linear | none | [TP-1356](https://linear.app/tonypine/issue/TP-1356) |
| Add or remove `qa:live` / `qa:fixture` | `SymphonyElixir.QaPolicy` | Linear | none | [TP-1356](https://linear.app/tonypine/issue/TP-1356) |
| Add or remove an `escalate.labels` label | `EscalationRules.label_detail/2` | Linear | none | [TP-1356](https://linear.app/tonypine/issue/TP-1356) |
| Add `protected-paths-approved` | the Setup labels check only (`SymphonyElixir.StateProvisioning`) | — | the Inbox pick that unlocks the paths (`SymphonyElixir.PathUnlock`, via Decide) | — |
| Set priority | the observation; `Dispatch.Candidates` (the `tickets.priorities` filter and the order) | Linear | none | [TP-1355](https://linear.app/tonypine/issue/TP-1355) |
| Set or clear a blocker (blocked-by link) | the observation (open blockers); `Issue.blocked?/2`; `Pauses.Dependencies` | Linear (a hand edit is followed, not drift) | the Blocked by card on the ticket page (`/control/blocker`, `SymphonyElixir.DirectorBlockers`, [TP-1354](https://linear.app/tonypine/issue/TP-1354)): add or remove a blocker; it refuses a ticket blocking itself, a cycle and a ticket Symphony doesn't track. Unblock still removes the links Symphony added for competing PRs (`PrWatch.Competitors`) | — (since [TP-1352](https://linear.app/tonypine/issue/TP-1352), an open blocker holds the ticket in every active phase (In Progress, Rework, CI Fix, Code Review, QA, Merging and the other dispatching phases), not only in Todo; the pause lifts by itself once every blocker is terminal, and the ticket continues in its phase) |
| Create a ticket, or a sub-ticket of another (parent) | the poll; the webhook (`observe_delivery/2`); the observation (parent, sub-issues) | Linear (decided: [TP-1359](https://linear.app/tonypine/issue/TP-1359)) | none needed: Symphony follows Linear | — |
| Edit the title or description | the observation; the prompt; `Decisions` (its section is Symphony's, projected) | Linear (decided: TP-1359; the Decisions section: Symphony) | none needed: Symphony follows Linear | — |
| Change team, project or a route label | `Routing.PollScope`; `Linear.Client.repo_scope_filter/1` | Linear (decided: TP-1359) | none needed: Symphony follows Linear | — |
| Assign or unassign | `Dispatch.Candidates` (the assignee filter) | Linear (decided: TP-1359) | none needed: Symphony follows Linear | — |
| Delete or archive | the webhook (`{:issue_removed, …}`) marks the record removed | Linear | Cancel (`/cancel`) | — |

The gap tickets are chained in this order: TP-1352, TP-1353, TP-1354, TP-1355, TP-1356, TP-1357,
TP-1358, TP-1359, TP-1360. TP-1367 (the Backlog record gap) landed before TP-1359.

### Facts a person writes in Linear

[TP-1359](https://linear.app/tonypine/issue/TP-1359) decided (D1) that a ticket's creation, its parent, its title and description,
its team, project and route labels and its assignee stay Linear's: a person writes them in Linear,
Symphony follows them on every read (`TicketObservation`), and a hand edit of them is not drift. They
are authoring and routing, not moves, so the Director has no control for them. The one gap was
promoting a Backlog ticket Symphony has no record of yet; [TP-1367](https://linear.app/tonypine/issue/TP-1367) closed it.

## Texts that send a person to Linear

Each text below told a person to act on a ticket in Linear, or by hand.
[TP-1358](https://linear.app/tonypine/issue/TP-1358) fixed each one: it now names the Director move,
or says Symphony does the step itself. The few left as they were are a fact that stays Linear's
(decided by TP-1359) or a statement that tells nobody to act; each says why. A move a later gap
ticket adds (a blocker, a label, a ruling) is named as the ticket page control that ticket builds.

How this list was made: every hit of this command, run from the repo root, is either listed below or
named under "Hits that stay"; the texts Code Review named are listed too. A text found later is a new
gap ticket, not a change to this doc.

```sh
rg -n -i -e 'in linear|by hand' \
  -e '\b(human|person|operator)s?\b[^.;]{0,40}\b(move[sd]?|moving|promote[sd]?|adds?|removes?|attach|file|triages?|comments?|fill|set)\b' \
  lib priv .symphony/instructions \
  | rg -v '^[^:]+:[0-9]+:\s*#' | rg -v '^[^:]+:[0-9]+:\s*(@doc|@moduledoc|@spec)'
```

`lib/`:

- `director_moves.ex` (`undoable/2`), Undo's refusals: fixed. "move it in Linear instead" now reads
  "use Move to… on the ticket page instead", and "move them in Linear instead" reads "use Move to… on
  each sub-ticket's page instead".
- `retired_states.ex` (`wait/1`), each "move it by hand to …": fixed, "move it with Move to… in the
  Director to …".
- `setup/checks/status_use.ex`, "Move each one by hand": fixed, "Move each one with Move to… in the
  Director".
- `sub_issue_wait.ex` (`backlog_note/1`), "stay there until a person promotes them": fixed, "until a
  person moves them to Todo with Move to… in the Director".
- `start_now.ex`, "the ticket is in Backlog; move it first": fixed, "move it to Todo with Move to…
  first".
- `plan_comments.ex` (`reply/1`, found while fixing), "Move MT-1 to Rework instead": fixed, "Move MT-1
  to Rework with Move to… in the Director instead".
- `codex/dynamic_tool.ex`:
  - `issue_not_in_merging_state` and `merging_requires_human_approval`: fixed. A person approves the
    merge in the Director: Decide on the merge Question (manual review), or Move to… Merging.
  - `blocked_by_relation_failed` and `add_blocked_by_failed` ("for a human to add"): fixed. The
    agent adds the link with `linear_add_blocked_by`, or records it in the workpad for a person, who
    adds a blocker from the ticket page in the Director (TP-1354's move).
  - `remove_blocked_by_failed` ("for a human to remove"): fixed, a person removes a blocker from the
    ticket page in the Director (TP-1354's move).
  - `subissue_not_in_backlog` ("a person promoted it"): fixed, "the plan's approval or a person's Move
    to… promoted it".
  - `document_attach_failed` ("for a human to attach"): fixed. No person attaches it: the run records
    the document's id and URL in the workpad, where later runs find it.
  - `issue_has_no_project` ("ask a person to add the issue to a project"): stays. A ticket's project is
    Linear's (TP-1359), so a person sets it in Linear and it is not drift.
- `quality_gate.ex`, "Reply in Linear with 1-2 sentences per question": fixed by
  [TP-1360](https://linear.app/tonypine/issue/TP-1360), "Answer in the Symphony Inbox, or reply here":
  the gate asks its questions as an Inbox Question.

`priv/playbook/`:

- `status_map.liquid`, Backlog "except when a person triages it to `Todo`": fixed, "moves it to
  `Todo` (Move to… in the Director)".
- `parent_tickets.liquid`:
  - "The `plan` label is a human's signal": fixed, a person sets it from the ticket page in the
    Director (TP-1356's move).
  - Approve or reject a plan "by moving the parent": fixed, Approve Plan and Reject Plan in the
    Director; a person who wants a plan outside `Plan Review` revised moves the parent to `Rework` with
    Move to….
  - "A person comments on the plan under review to ask for a change": fixed, Ask for Changes in the
    Director (or a comment on the plan, which still works).
  - "a person already promoted it" (twice): fixed, "the plan's approval or a person's Move to…
    already promoted it".
  - The reply to a comment on an approved plan, "moving the parent to `Rework`": fixed, names Move to….
  - "so the person approving the plan can set it": stays. It edits the parent's description, which is
    Linear's (TP-1359).
- `ticket_types.liquid`:
  - "This ticket has the `plan` / `type:bug` / `type:feature` label": stays. It says what the ticket
    is and tells nobody to act.
  - "asks the operator to fill them in and move the ticket back to `Todo`" (twice): fixed, the move
    back is Move to… in the Director. Filling in the description stays in Linear (TP-1359).
- `escape_hatches.liquid`, a ruling as a plain `Decision:` / `Ruling:` comment: fixed, names Record a
  decision on the ticket page in the Director first
  ([TP-1357](https://linear.app/tonypine/issue/TP-1357)'s move); the comment still works.
- `review_brief.liquid`: fixed. A plan's Approve is Approve Plan, its Reject is Reject Plan, and a
  decision's Reject is Cancel, each in the Director.

`.symphony/instructions/`:

- `051-step-0-route.md`, "wait for human to move it to `Todo`": fixed, "wait for a person to move it
  to `Todo` (Move to… in the Director)".
- `052-step-1-start.md`, "so a human can add the label": fixed, "so a person can set the label from
  the ticket page in the Director" (TP-1356's move).
- `091-step-2-execution.md`, the `qa:live` and `qa:fixture` override: fixed, "set from the ticket page
  in the Director" (TP-1356's move).
- `121-priority-vs-expedite.md`, "they add the `expedite` label": fixed, "they press Force in the
  Director or run `symphony force <ticket>`"; "`Backlog` -> `Todo` … stay with a person": fixed, "stay
  a person's moves in the Director (Move to…, Approve Plan, Decide, Restart)".

`docs/configuration.md` (the `waiting_on_sub_issues` state), "approves the plan by moving the parent":
fixed, Approve Plan and Reject Plan in the Director.

### Hits that stay

Not about a ticket (the Linear workspace, the repo, config or the QA host):
`setup/fixes.ex:94`, `:97`, `:106`, `:109`; `setup/checks/labels.ex:113`, `:139`;
`setup/checks/statuses.ex:139`; `setup/checks/deprecated_labels.ex:90`; `setup/checks/routing.ex:36`;
`state_provisioning.ex:182`;
`control_api_controller.ex:319`, `:325`, `:331`, `:378`; `codex/dynamic_tool.ex:1868` (a project
update); `github/webhook_setup.ex:1003` and `mix/tasks/settings.ui_coverage.ex:45`, `:46` (config
files); `release_build.ex:641`, `pr_decision/apply.ex:974`, `self_heal.ex:572`, `:579`, `:586`,
`:615`, `:616` (a fix ticket's text and Question options, answered with Decide);
`pr_decision/table.ex:15`; `priv/qa_driver/symphony-qa-driver.swift:57`;
`priv/qa_playbooks/macos_app.md:511`; `out_of_scope_backlog.liquid:62` ("for a human to file":
filing a new ticket stays in Linear, decided by TP-1359).

Report what happened, or tell the agent rather than a person: `ticket_events/summary.ex:118`, `:127`
("moved … in Linear by hand"); `ticket_state_reconciler.ex:181` (a log line);
`codex/dynamic_tool.ex:1905` (the agent's blocker comment); `prompt_builder.ex:969`,
`093-step-4-rework.md:10`, `:11`, `status_map.liquid:11` (the agent must not move it by hand;
Restart is already a Director move); `escape_hatches.liquid:11`, `:16`; `review_brief.liquid:78`,
`parent_tickets.liquid:58`, `:165`, `:178` (no person's move); `scoped_tools.liquid:27`;
`workpad_template.liquid:8`.

Module and function docs whose text the filter can't tell from code (a `@moduledoc` or `@doc`
body), describing behaviour to a developer: `agent_tools/github.ex:183`, `agent_tools/linear.ex:990`,
`audit_log.ex:6`, `breakdown_review.ex:6`, `:17`, `:20`, `decision_move.ex:7`, `decisions.ex:113`,
`:385`, `director_moves.ex:12`, `:32`, `:87`, `:99`, `dispatch/shadow.ex:21`, `epic_lanes.ex:189`,
`github/comment_marker.ex:7`, `human_actions/action.ex:9`, `human_actions/request.ex:35`, `:37`,
`linear/client.ex:3`, `linear/issue.ex:107`, `path_unlock.ex:33`, `pauses/projector.ex:14`, `:23`,
`:33`, `:38`, `plan_brief.ex:93`, `plan_comments.ex:6`, `:14`, `:17`, `plan_review.ex:7`,
`pr_watch/repo.ex:11`, `qa_agent.ex:322`, `questions.ex:11`, `:159`, `repo/fetcher.ex:14`,
`retired_states.ex:10`, `run_store.ex:923`, `setup/checks/routing.ex:3`, `setup/checks/secrets.ex:5`,
`state_provisioning.ex:12`, `:16`, `sub_issue_wait.ex:6`, `:18`, `:21`, `:143`, `:174`,
`ticket_events/types.ex:35`, `ticket_observation.ex:3`, `:20`, `:64`, `:150`, `:270`,
`ticket_pull_request/lookup.ex:4`, `ticket_state.ex:15`, `:21`, `:484`,
`ticket_state_reconciler.ex:14`, `:16`, `transition_guard.ex:355`.
