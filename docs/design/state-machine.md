# Ticket state machine (v0)

- **Status:** approved (2026-10-10). Design only; no implementation yet.
- **How this is used:** the design of record for the state-machine redesign: the contract the implementation follows and the reference for future changes to ticket flow. Behavior changes edit this document first.
- **Scope:** the ticket lifecycle: states, holds, owners, entry signals, exits, guards, exceptions. Not in scope: run-loop internals (turns, sessions, retries), prompts, token accounting.
- **State ownership:** Symphony's store is the canonical state — phases, holds, verdicts, CI state. Linear is a projected window. The long-term direction is to own the ticketing flow end-to-end, with Linear as an optional view.

## Principles

1. **Explicit signals, never silence.** Every transition is triggered by a named signal. A run that ends without its signal never advances the ticket; the machinery retries or escalates it. (Inverts today's catch-handler: quiet no longer means done.)
2. **Deterministic first.** The machine moves what it can: claims, merges, branch updates, blocker watches, CI state, verdict forwarding. Agents run only where judgment is needed; people only for decisions.
3. **One writer.** Agents and people *request* transitions; Symphony validates the guards and performs them. One authority defines what is legal.
4. **Verdicts bind to a head.** A review or QA verdict attaches to a specific commit. Mechanical repair (CI Fix) carries it forward; substantive change (Rework) invalidates it and re-enters review.
5. **People decide, never check.** Person-facing requests are structured decisions (one question, 2–4 options, one recommended, custom answer allowed), never runbooks, plans-as-walls-of-text, or manual tests.
6. **No silent freezes.** Every waiting ticket is visible (a phase state or a hold label), has an owner, and has a clearing condition.
7. **One focus per state.** Each phase state is one actor doing one kind of work — implementation, review, verification, mechanical repair — or a determinate wait owned by the machine. A state that would mix unrelated work or actors gets split, never widened.
8. **Self-heal first.** When a flow is blocked by broken tooling or environment, the first resolution is always to repair it: bounded retries for transient failures, then a high-priority fix ticket; the affected ticket takes a Blocked hold and resumes automatically when the fix lands. Fixes target the root cause. People decide; the machine repairs its own instruments. Applies to every flow — QA, review, CI Fix, merging.
9. **Holds overlay, never relocate.** Blocked and Needs Decision are attributes (labels), not states: the ticket stays in its phase, gains the label plus a recorded reason or decision payload, and the machine pauses dispatch while the hold is set. A hold clears when its condition clears and the ticket continues in place — always from where it stopped. Runs happen in states; holds pause them.
10. **Symphony owns the state; Linear is a window.** Every phase, hold and attribute persists at the Symphony layer. Linear is a projection written from that store; its state and labels are read back only as requests (e.g., a human drag), validated like any other signal. Guards and the dispatcher consult the Symphony store, never the board. Long-term direction: own the ticketing flow end-to-end — Linear becomes an optional view.

## At a glance

```
ticket path: Backlog → Todo → In Progress → Code Review → QA → Merging → Done
epic path:   Backlog → Todo → In Progress → Plan Review → Waiting on sub-tickets → Epic Review → Done

phases:      Rework · CI Fix
overlays:    Blocked · Needs Decision   (labels — tickets stay in their phase)
```

CI state is **not** a state: it is an attribute (`running` / `green` / `red`) tracked per PR head.

## Pipeline states

| State | Owner | Waits on | Enters from | Exits to |
|---|---|---|---|---|
| **Backlog** | Person | A priority decision; parked work, never picked | Person only (deprioritization; an agent may move it only when explicitly asked by a person) | Triage → Todo |
| **Todo** | Machine | A free slot; the ready queue | Triage from Backlog; sub-tickets promoted by plan approval | Deterministic claim (pre-first-turn) → In Progress; open blockers → Blocked hold |
| **In Progress** | Agent | First implementation (net-new work on this ticket) | Claim from Todo; Restart (fresh re-implementation) | Handoff → Code Review; blocked report → Blocked hold; decision request → Needs Decision hold |
| **Code Review** | Agent (reviewer) | Implementation judgment on the PR: correctness, scope, criteria, intent | Handoff; Rework done (re-review); CI Fix return | Approve → QA (or → Merging when QA is skipped by policy); rework → Rework; escalate → Needs Decision hold; CI red → CI Fix |
| **QA** | Agent (QA) | User-journey validation: the change exercised end to end from the user's point of view | Code Review approve | Pass → Merging; fail → Rework; blocked (tooling/env) → bounded retries, then fix ticket + Blocked hold; CI red → CI Fix |
| **Merging** | Machine | The merge to land; deterministic, no agent on the happy path | QA pass, or review approve when QA is skipped (with manual review on, confirmed first via a Needs Decision hold) | Merged → Done; CI red or conflict → CI Fix |
| **Done** | — | Terminal: merged. Epic parents: after the epic review | Merge settled; epic review pass; a no-op close decided via a Needs Decision hold | — |

## Phase states

Rework and CI Fix run agent work.

| State | Owner | Waits on | Enters from | Exits to |
|---|---|---|---|---|
| **Rework** | Agent | Returned-for-changes work; continues the existing PR. Not from scratch | Code Review rework; QA fail; CI Fix (substantive); a return from a Needs Decision hold; review comments | Changes done → Code Review (re-review of the new head); for epic parents → Plan Review (revised plan) |
| **CI Fix** | Agent (mechanical lane) | Red checks or a merge conflict; minimal repair only | Any phase whose head goes red (Code Review, QA, Merging, Rework) | Fixed → origin state (returns where it came from; approvals carried forward); substantive → Rework; cannot fix → Rework or Needs Decision hold (needs access or a secret) |

## Epic path

Epic parents (breakdown) have a distinct path: **Backlog → Todo → In Progress → Plan Review → Waiting on sub-tickets → Epic Review → Done**. They skip Code Review and QA — their checks are the plan review (a person) and the epic review (automatic).

| State | Owner | Waits on | Enters from | Exits to |
|---|---|---|---|---|
| **Plan Review** | Person | The plan: designs, screens, user stories, proposed sub-tickets | Breakdown done (In Progress) | Approve → sub-tickets promoted to Todo, parent → Waiting on sub-tickets; changes → Rework (re-plan) → Plan Review |
| **Waiting on sub-tickets** | Machine | The children to finish | Plan approved | All children terminal → Epic Review |
| **Epic Review** | Machine + agent | Epic integrity: artifacts, comments and PRs verified against the epic's intent | Children terminal | Pass → Done; gaps → follow-ups filed in Todo (same epic), parent → Waiting on sub-tickets; blocked → self-heal |

## Holds

Holds pause a ticket in its current phase. They are attributes persisted at the Symphony layer and surfaced as machine-owned labels — the label is the projection; the store is the truth. The machine performs every set and clear, and dispatch gates on the store, never the board. A hold never moves a ticket.

| Hold | Label | Recorded with it | Set when | Clears when |
|---|---|---|---|---|
| **Blocked** | `Blocked` | The reason and what it waits on (a dependency key, an access need, or the fix ticket) | A dependency opens on a Todo ticket; an agent reports a block from In Progress or Rework; self-heal files a fix ticket | The dependency or fix ticket goes terminal, or access is granted — automatically; the ticket continues in place |
| **Needs Decision** | `Needs Decision` | One question, 2–4 options, one recommended (custom answer allowed) | The machine needs a person's decision or confirmation: escalations, product calls, access, a merge gate with manual review on, a repair with no clear next step | The decision is recorded; the phase continues, or the decision directs a move (e.g., → Rework) |

## Human-only actions

| Action | Effect |
|---|---|
| **Triage** | Backlog → Todo (the routine human move). |
| **Approve Plan** | Resolve Plan Review: approve promotes sub-tickets and moves the parent to Waiting on sub-tickets; changes → Rework (re-plan). |
| **Deprioritize** | Any active phase → Backlog. Never automatic. |
| **Unblock** | Clear an access hold; the ticket continues. |
| **Decide** | Resolve a Needs Decision hold: it clears and the phase continues, or the decision directs a move. |
| **Restart** | Full reset: close the PR, fresh branch from main, supersede the workpad → In Progress. The old "Rework" meaning, kept rare and deliberate. |

## Attributes (not states)

- **CI state** — `running` / `green` / `red` per PR head. Owned by the machinery, derived from GitHub (webhooks primary, slow poll as reconciliation). Gates agent dispatch: Code Review and QA agents run only on a green head; red routes to CI Fix. Interim visualization: machine-owned `CI green` / `CI red` / `CI running` labels on the ticket.
- **Manual review** — per repo, `on` / `off`; default `off`. Controls decision authority on the ticket path, not verification: the machine verifies the same way either way — same agents, same evidence. The epic path is unaffected: plan review is always a person, epic review always automatic.
  - `off` (default): verdicts move the ticket — Code Review approve → QA; QA pass → Merging. The machine stops for a person only on escalations and holds.
  - `on`: the final step into Merging pauses with a Needs Decision hold carrying the summary — recommendation, Code Review reasons, QA result, PR link. Confirming continues into Merging exactly as when off; a redirect directs a move (e.g., → Rework). Everything else runs unchanged: rework verdicts never wait on a person, and CI Fix and holds behave the same.
- **Verdict binding** — verdicts (Code Review, QA) record against the head SHA. CI Fix preserves; Rework invalidates.
- **Signals** — the transition vocabulary, e.g.: `handoff`, `blocked` / `unblocked`, `review verdict`, `QA verdict`, `fix verdict` (mechanical vs substantive), `plan verdict` (approve / changes), `epic verdict` (pass / gaps), `decision requested` / `decision returned`, `merge settled`, `restart`, `deprioritized`. Emitted mechanically where possible (tool hooks for push/PR events, GitHub webhooks for CI); requested by agents where judgment is involved. The audit ledger is the timeline both the machinery and agents read.

## Guards and exceptions

- **Handoff.** In Progress → Code Review happens on the session's explicit handoff signal (with the PR), not when a run merely goes quiet.
- **CI gating.** A verdict on a red head is not actionable: red anywhere in Code Review / QA / Merging → CI Fix → return to origin once green.
- **Mechanical vs substantive.** CI Fix is constrained to minimal repairs; if the fixing agent judges the repair needs a substantive change, it says so and the ticket goes to Rework.
- **No re-traversal for repairs.** CI Fix returns to where it came from and approvals survive; only Rework re-enters review.
- **Escalation rules route or deepen — they never queue.** A rule that needs a person (protected files, access, product calls) sets a Needs Decision hold; risk rules (size, sensitive areas) deepen the Code Review run instead of routing anywhere; an inconclusive review retries boundedly, then sets a Needs Decision hold.
- **QA is journey-driven.** QA verifies the user stories and journeys the change delivers or updates (from the epic plan where one exists; otherwise derived from the ticket's walkthrough and acceptance criteria). It exercises the product end to end from the user's point of view and judges the outcome with critical thinking — what a careful engineer does when testing their own feature before shipping. It is not script execution: automated end-to-end suites (Playwright and friends) belong to CI. Changes that deliver or update no user journey (docs-only, internal-only) skip QA; the Code Review verdict carries them.
- **Hold gating and clearing.** Dispatch and any run pickup consult the holds in the Symphony store — a set hold pauses the flow. A hold never moves a ticket; it clears automatically when its condition clears (dependency or fix terminal, access granted, decision recorded) and the ticket continues from where it stopped.
- **Self-heal on environment blocks.** A flow blocked by tooling or environment retries transient failures boundedly; if still blocked, the machine files one high-priority fix ticket per broken component (deduplicated; affected tickets link to it as blocked-by), sets a Blocked hold on each, and they resume automatically when the fix lands. No decision request and no check for a person — unless the fix itself needs a person (hardware, accounts, licenses), in which case that surfaces through the fix ticket's own flow.
- **Fix-ticket scope.** The fix ticket lands in the repo that owns the broken component: **Symphony** for the orchestration itself (dispatch, agents, QA environments, tracking) and for structural causes; a **managed project's repo** (cycle, job-search-hub) for that project's own build, test or run setup. A block surfaced through a managed repo still lands in Symphony when the cause is structural there.
- **Repairs iterate on new information.** A recurring block is not a dead end. After each repair lands and the flow retries, the machine compares the new failure against the old one: a changed or narrowed failure is progress — more information, a better hypothesis — and justifies another targeted repair attempt. The machine keeps repairing while it has a clear option to try, and sets a Needs Decision hold only when it is genuinely stuck: the same failure recurs with no new information and no concrete next step.
- **Needs Decision content.** Decisions only, as structured options. Checks are not a decision: a check belongs to CI (automate it) or QA (cover it); one neither can run is a coverage gap to close, never a task handed to a person.
- **Epic gaps.** Follow-ups for an epic are filed in Todo within the same epic — never Backlog, which freezes the epic without anyone noticing. If all phases pass, the ticket moves on by itself.
- **Parent handoffs.** Breakdown parents hand off to **Plan Review** — an epic-only state for a person's plan review (approving top-level designs is a person's job). Approval promotes sub-tickets into Todo and moves the parent to Waiting on sub-tickets; changes go back through Rework to re-plan.

## The review skill, diluted

Every duty the review skill performed has exactly one home. No state is added for it — and none of the homes is ambiguous.

| Duty | Home |
|---|---|
| PR judgment: correctness, security, criteria, intent | **Code Review** (inputs: the QA report and the workpad) |
| Approve → merge | **Code Review** verdict → **QA** → **Merging**; the machinery arms auto-merge, and no run touches it by hand |
| Changes on the same PR | **Rework** |
| Full reset / re-plan | **Restart** (human); parents re-plan via **Rework** |
| Epic plan approval | **Plan Review** state — approve promotes sub-tickets; changes → **Rework** |
| Final epic integrity check | **Epic Review** state (automatic) |
| Person items: product calls, keys, protected files | **Needs Decision** hold (structured decision) |
| Checks an implementation run can't do (host, device, DB-backed) | **QA** (its VM, emulator, and host driver) or **CI** (write the test) — a coverage gap to close; when it blocks work, the self-heal rule applies |
| Review modes (decide / advise / watch) | The **manual review** setting: decide → `off`; advise → `on`; watch → operator monitoring |
| Queue discipline ("a reviewed ticket never stays") | Machine routing: states are pass-through; holds are the only overlay; nothing rests in a queue |
| Factory duties: error watching, config, restarts, Linear usage, runaway processes | Operator layer — outside this machine, unchanged |

The active consequence: QA coverage absorbs the host and device checks the review skill used to run, driven by user journeys; each capability is either automated into CI, brought into a QA playbook, or consciously left out.

## Retired

| Old | New |
|---|---|
| `Auto Review` state (CI wait + QA + gate bundled) | Split: CI attribute + **Code Review** (before QA) + **QA** state |
| `In Review` (informal mix: post-QA approvals, escalations, plan handoffs, checks) | No resting queue: routine approvals flow automatically; escalations and confirmations become Needs Decision holds; checks go to CI or QA |
| Gate `escalate` → In Review / Human Review | Escalations → Needs Decision hold (structured decision); risk rules deepen the review instead |
| `Rework` = full reset (close PR, fresh branch) | **Rework** = continue and improve the existing work; full reset becomes **Restart** (human-only) |
| Blocked → `Backlog` escape hatch; blockers held invisibly in Todo | **Blocked** hold: a label that pauses the ticket in its phase with the reason recorded; clears and resumes automatically |
| `Human Review` (a state named like a review) | **Needs Decision** hold for decisions; **Plan Review** state for epic plans |
| Breakdown plans promoted by a supervisor session | **Plan Review** state: the person approves (promotes sub-tickets) or sends to **Rework** to re-plan |
| Quiet "done" heuristic (infer completion from inactivity) | Explicit **handoff** signal; silence never advances a ticket |
| `Final verification:` tickets, sign-offs | **Epic Review** state for parents; follow-ups in Todo; no sign-offs |
| `human-action` label; manual tests handed to a person | Structured decisions (Needs Decision holds); checks are CI's or QA's |

## Board states

Every phase is a board-visible Linear state; holds are labels, not states.

- **New states to create:** `Code Review`, `QA`, `Plan Review`, `Epic Review`, `CI Fix`.
- **States kept:** `Backlog`, `Todo`, `In Progress`, `Rework`, `Waiting on sub-tickets`, `Merging`, `Done` (and the terminal states).
- **States retired after migration:** `Auto Review`, `In Review`, `Human Review`.
- **Labels (machine-owned):** `Blocked`, `Needs Decision`, plus the CI state labels (`CI green` / `CI red` / `CI running`).
- Migrating in-flight tickets out of retired states is an implementation concern.
