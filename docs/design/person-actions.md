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
| Promote Backlog → Todo | the poll's active states; `Dispatch.Candidates` | Linear until Symphony moves it | Move to… (`/move`) to Todo, but only for a ticket Symphony has a record of (`DirectorMoves.require_tracked/2`) | Records are made only by the active-state poll or a webhook delivery, so a Backlog ticket whose delivery was missed is refused: [TP-1367](https://linear.app/tonypine/issue/TP-1367) (Move to… reads a ticket with no record from Linear and records it first) |
| Promote a split-off ticket from Backlog to Todo, and link it as a blocker | `linear_create_subissue` (`AgentTools.Linear.create_subissue/3`) | Symphony | none needed since [TP-1353](https://linear.app/tonypine/issue/TP-1353): a run of a ticket that is not a plan files its sub-ticket in Todo and marks the ticket blocked by it, so the sub-ticket lands first and the ticket continues on its own; a plan run's sub-tickets stay in Backlog until the plan's approval promotes them | — |
| Approve a plan (Plan Review → Waiting on sub-tickets) | `SymphonyElixir.BreakdownReview` | Symphony | Approve Plan (`/approve_plan`) | — |
| Reject a plan (→ Rework) | `BreakdownReview` | Symphony | Reject Plan (`/rework`) | — |
| Comment on a plan under review | `SymphonyElixir.PlanComments` | Linear (a person's comment) | Ask for Changes (`/changes`) | — |
| Reply under a `## Decision needed:` request | `Pauses.Projector` (the reply is the answer) | Symphony (the Question) | Decide (`/decide`); a plan's answers with Send Decisions (`/decisions`) | — |
| Comment a ruling (`Decision:` / `Ruling:`) | `Linear.IssueNormalizer` rulings; `SymphonyElixir.Decisions` | Linear | none: a note (`/note`) is not a decision | [TP-1357](https://linear.app/tonypine/issue/TP-1357) |
| Answer the quality gate's clarification questions (a comment) | `SymphonyElixir.QualityGate` (comment activity re-scores the ticket) | Linear | none: a note (`/note`) does not re-score | [TP-1360](https://linear.app/tonypine/issue/TP-1360) |
| Comment for the next run | the prompt's recent comments (`SymphonyElixir.PromptBuilder`) | Linear | Note (`/note`): it reaches the ticket history the prompt carries | — |
| Cancel | the observation (phase) | Symphony | Cancel (`/cancel`) | — |
| Park in Backlog | the observation (phase) | Symphony | Backlog (`/backlog`) | — |
| Reopen a Done or Canceled ticket | the observation (phase); a cancelled record follows Linear again | Symphony | Move to… (`/move`) | — |
| Start over (close the PR, fresh branch) | — | Symphony | Restart (`/restart`) | — |
| Move a ticket out of a retired state | `SymphonyElixir.RetiredStates` | Linear | Move to… (`/move`) | the text still says "by hand": [TP-1358](https://linear.app/tonypine/issue/TP-1358) |
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
| Set or clear a blocker (blocked-by link) | the observation (open blockers); `Issue.blocked?/2`; `Pauses.Dependencies` | Linear | none; Unblock removes only the links Symphony added for competing PRs (`PrWatch.Competitors`) | a person can't add or remove one: [TP-1354](https://linear.app/tonypine/issue/TP-1354) (since [TP-1352](https://linear.app/tonypine/issue/TP-1352), an open blocker holds the ticket in every active phase (In Progress, Rework, CI Fix, Code Review, QA, Merging and the other dispatching phases), not only in Todo; the pause lifts by itself once every blocker is terminal, and the ticket continues in its phase) |
| Create a ticket, or a sub-ticket of another (parent) | the poll; the webhook (`observe_delivery/2`); the observation (parent, sub-issues) | Linear (decided: [TP-1359](https://linear.app/tonypine/issue/TP-1359)) | none needed: Symphony follows Linear | — |
| Edit the title or description | the observation; the prompt; `Decisions` (its section is Symphony's, projected) | Linear (decided: TP-1359; the Decisions section: Symphony) | none needed: Symphony follows Linear | — |
| Change team, project or a route label | `Routing.PollScope`; `Linear.Client.repo_scope_filter/1` | Linear (decided: TP-1359) | none needed: Symphony follows Linear | — |
| Assign or unassign | `Dispatch.Candidates` (the assignee filter) | Linear (decided: TP-1359) | none needed: Symphony follows Linear | — |
| Delete or archive | the webhook (`{:issue_removed, …}`) marks the record removed | Linear | Cancel (`/cancel`) | — |

The gap tickets are chained in this order: TP-1352, TP-1353, TP-1354, TP-1355, TP-1356, TP-1357,
TP-1358, TP-1359, TP-1360. TP-1367 (the Backlog record gap) lands before TP-1359.

### Facts a person writes in Linear

[TP-1359](https://linear.app/tonypine/issue/TP-1359) decided (D1) that a ticket's creation, its parent, its title and description,
its team, project and route labels and its assignee stay Linear's: a person writes them in Linear,
Symphony follows them on every read (`TicketObservation`), and a hand edit of them is not drift. They
are authoring and routing, not moves, so the Director has no control for them. The one gap was
promoting a Backlog ticket Symphony has no record of yet; [TP-1367](https://linear.app/tonypine/issue/TP-1367) closes it.

## Texts that send a person to Linear

Each text below tells a person to act on a ticket in Linear, or by hand. [TP-1358](https://linear.app/tonypine/issue/TP-1358)
rewrites them to name the Director move.

How this list was made: every hit of this command, run from the repo root, is either listed below or
named under "Hits that stay"; the texts Code Review named are listed too. A text found later is a row
for TP-1358, not a change to this doc.

```sh
rg -n -i -e 'in linear|by hand' \
  -e '\b(human|person|operator)s?\b[^.;]{0,40}\b(move[sd]?|moving|promote[sd]?|adds?|removes?|attach|file|triages?|comments?|fill|set)\b' \
  lib priv .symphony/instructions \
  | rg -v '^[^:]+:[0-9]+:\s*#' | rg -v '^[^:]+:[0-9]+:\s*(@doc|@moduledoc|@spec)'
```

`lib/`:

- `lib/symphony_elixir/director_moves.ex:1492`, `:1495`, `:1499`: Undo's refusals say "move it in
  Linear instead" and "move them in Linear instead". A hand move like that is drift, and it is undone.
- `lib/symphony_elixir/retired_states.ex:110`, `:113`, `:116`, `:119`, `:122`: "move it by hand to …".
- `lib/symphony_elixir/setup/checks/status_use.ex:90`: "Move each one by hand".
- `lib/symphony_elixir/sub_issue_wait.ex:233`: "stay there until a person promotes them".
- `lib/symphony_elixir/start_now.ex:53`: "the ticket is in Backlog; move it first" (it doesn't name
  Move to…).
- `lib/symphony_elixir/codex/dynamic_tool.ex:2154` ("a person promoted it"), `:2197` ("for a human
  to remove" a blocked-by link), `:2111`, `:2185` and `:2225` ("for a human to add" or "to make" a
  blocked-by link; the replacement is TP-1354's move), `:2020` ("for a human to attach" a document),
  `:1997` ("ask a person to add the issue to a project"), and `:2470` and `:2479` (a human approves
  a merge by moving the issue to `Merging` in Linear; the replacement is Decide on the merge
  Question under manual review, or Move to… Merging).
- `lib/symphony_elixir/quality_gate.ex:367`: "Reply in Linear with 1-2 sentences per question". The
  answer itself has no Director path: [TP-1360](https://linear.app/tonypine/issue/TP-1360).

`priv/playbook/`:

- `status_map.liquid:7`: Backlog "except when a person triages it to `Todo`".
- `parent_tickets.liquid:7`: "The `plan` label is a human's signal" (added in Linear; the move is
  TP-1356's).
- `parent_tickets.liquid:26`, `:32`, `:126`, `:169`: approve or reject a plan "by moving the parent".
- `parent_tickets.liquid:36`, `:119`: "A person comments on the plan under review to ask for a
  change" (a Linear comment; the replacement is Ask for Changes).
- `parent_tickets.liquid:50`, `:109`: "a person already promoted it" (by hand in Linear; the move is
  [TP-1353](https://linear.app/tonypine/issue/TP-1353)'s).
- `parent_tickets.liquid:156`: "so the person approving the plan can set it" (edit the parent's
  description in Linear, which stays Linear's: TP-1359).
- `ticket_types.liquid:16`, `:39`, `:76`: the operator adds the `plan`, `type:bug` or `type:feature`
  label in Linear (the move is TP-1356's).
- `ticket_types.liquid:53`, `:91`: "asks the operator to fill them in and move the ticket back to
  `Todo`" (edit the description, which stays Linear's: TP-1359; the move is Move to… Todo).
- `escape_hatches.liquid:37`: "A person's plain comment that opens with `Decision:` or `Ruling:` is a
  ruling" (a Linear comment; no Director move:
  [TP-1357](https://linear.app/tonypine/issue/TP-1357)).
- `review_brief.liquid:69`, `:76`, `:91`: "move the parent to `Waiting on sub-tickets`", "move the
  parent to `Rework`", "move the ticket to `Canceled`".

`.symphony/instructions/`:

- `051-step-0-route.md:6`: "wait for human to move it to `Todo`".
- `052-step-1-start.md:18`: "say so in the workpad `Confusions` so a human can add the label" (the
  `plan` label, which has no Director move yet: [TP-1356](https://linear.app/tonypine/issue/TP-1356)).
- `091-step-2-execution.md:5`: "The `qa:live` and `qa:fixture` labels are a person's override of
  Symphony's choice" (added in Linear today; the move is TP-1356's).
- `121-priority-vs-expedite.md:5`, `:6`: "they add the `expedite` label"; "`Backlog` -> `Todo` …
  stay with a person".

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
