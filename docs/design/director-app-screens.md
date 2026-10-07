# Screens: Symphony for Mac

- **Ticket:** [TP-747](https://linear.app/tonypine/issue/TP-747/create-a-native-foreground-dashboard-to-the-macos-app),
  approved by the Director on 2026-10-07. Companion documents: [Stories and journeys](director-app.md) (stories
  US1–US9, journeys J1–J9, every current feature mapped) and [Design system](design-system.md) (tokens, patterns
  P1–P11, components C1–C22).
- **Mock:** [`journeys/director-app.html`](journeys/director-app.html). One self-contained file: the design system
  specimen, then every screen below, journey by journey, at the window's real size, with a Light/Dark switch. Open it
  in any browser, offline.
- **Data:** every repo, ticket and number is made up.

## 0. The window

One main window, **Symphony**, next to the menu bar item that exists today. Settings (⌘,) and Repos stay their own
windows; Repos is also reachable from the sidebar.

| Part | What it is |
| --- | --- |
| Structure | `NavigationSplitView`: sidebar, content, and an inspector (`.inspector`) on views with selectable rows. Inbox and Initiatives use three columns (list and detail), as Mail does |
| Sidebar | Inbox (badge), Overview (badge when something needs attention), Initiatives, Tickets · **Insights:** Quality, Usage · **Records:** Shipped, Audit · **Factory:** Repos, Diagnostics. ⌘1–⌘8 in that order. Footer: Symphony's version and state |
| Toolbar | Title and subtitle of the view; the scope pop-up (all repos or one); the dispatch control (the one custom glass element); search; view-specific actions on glass |
| Size | Default 1200 × 760, minimum 960 × 600; frame, view and selection restored |
| Presence | While the window is open the app is a regular app (Dock icon, ⌘-Tab, main menu); closing it returns to the menu bar only (decision DD2) |
| Design | macOS 26+ Liquid Glass for navigation (sidebar, toolbar, popovers, sheets) and solid surfaces for data, from the [Design system](design-system.md) |

## 1. Journeys, screen by screen

Each journey lists its steps and the screen that serves each one. Each screen is described once, at its first journey;
later journeys point back to it. The mock draws every screen under its ID.

### J1. Clear the inbox (US1, US2)

| Step | The Director | Screen |
| --- | --- | --- |
| 1 | Gets a notification, or sees the badge on the menu bar icon and opens its list | D14, D13 |
| 2 | Opens the Inbox: 4 items, grouped by kind, oldest first | D2a |
| 3 | Reads the plan SHOP-330: what to review, 2 decisions, 7 sub-tickets | D2a |
| 4 | Approves it as is (or changes a decision and sends it) | D12d |
| 5 | Reads PR BIL-206: CI, QA, gate, size; approves and merges | D2b → D12d |
| 6 | Reads the action NOTE-90 and its steps; the banner confirms the merge, with Undo | D2c |
| 7 | Reads the held ticket SHOP-341 and edits it in Linear | D2d |
| 8 | Inbox empty; badges clear | D2e |

#### D14 · Notifications

- **Shows:** one notification per new Inbox item ("BIL-206 waits on you · PR ready: …") and per new problem ("SHOP-305
  looks stuck"). Actions: **Open**, and **Approve and Merge…** on a PR whose checks are green (it opens the app on
  D12d, never approves from the banner).
- **States:** grouped by kind; each kind can be turned off in Settings; Focus applies. Nothing for routine progress.
- **Conventions:** `UNUserNotificationCenter` with categories and actions; the app icon; no sound by default.
- **Data:** new entries in the Inbox list (section 2) and in Needs attention.

#### D13 · Menu bar menu

- **Shows:** status line with counts; **Waiting on you** (the oldest 5, each with its kind symbol and age; a click
  opens the window on it); **Open Symphony** (⌘O); Pause Dispatch…, Force a Ticket…, Forced ›; Start/Stop/Restart;
  updates; Repos…, Settings…; **Developer ›** (Open Dashboard in Terminal, Open Logs, Open Web Dashboard); Quit.
- **States:** a badge dot on the icon while the Inbox isn't empty; stopped, starting, paused and usage-limit lines as
  today.
- **Conventions:** `NSStatusItem` menu (AppKit, as today); title-case items, "…" for items that ask more.
- **Data:** what the menu reads today plus the Inbox list.

#### D2a · Inbox: a plan to review

- **Shows:** the list grouped as Plans, Pull requests, Actions, Clarify (and Final verifications), each row with
  identifier, title, one-line ask and age. The review: header with kind, wait and state badges; the brief's headline;
  **What to review** (the plan's Linear documents and HTML); **Decisions needed** as radio groups with the recommended
  option marked and picked; **Sub-tickets** in landing order with their Kano class or blocker.
- **Actions:** **Approve Plan…** (prominent), **Send Decisions** (enabled when a pick changes; posts one comment, which
  starts Symphony's plan revision run), **Open in Linear**, ⋯ **Send to Rework…**.
- **States:** a final verification item shows its checklist with each requirement's evidence, and **Sign Off…** (moves
  it to Done) instead of Approve. A scope that hides items says "2 more in other repos".
- **Conventions:** three-column `NavigationSplitView` like Mail; after an answer the selection moves to the next item;
  ↑↓ and Return work in the list.
- **Data:** the Inbox list and the review brief (section 2).

#### D12d · Approve: the consequence sheet

- **Shows:** the question as the title; what happens in Linear ("moves SHOP-330 to Waiting on sub-tickets and promotes
  its 7 sub-tickets… SHOP-331 starts first"); the decisions posted with it; how to change the plan instead.
- **States:** for a PR: "Move BIL-206 to Merging? Symphony turns on auto-merge, and GitHub merges once checks pass."
  For Send to Rework: a required reason field and "Symphony closes the PR and starts over" in the destructive style.
- **Conventions:** sheet with a default button; afterwards a banner "Moved to Merging · Undo" for 10 s (seen on D2c).
- **Data:** writes through Symphony's control API (decision DD4).

#### D2b · Inbox: a pull request to approve

- **Shows:** the PR's purpose in one sentence; **Checks**: CI, Auto Review QA (with its report), the acceptance gate's
  verdict and its agreement record on this repo, the review agent; **Change**: files and lines, the largest files;
  **QA screenshots**.
- **Actions:** **Approve and Merge…** (prominent), **Send to Rework…**, **Open PR**. The diff stays on GitHub.
- **States:** a red check turns its row red and makes Open PR the default button; with the gate in Enforce, the PR
  reaches the Inbox only on the gate's escalations, and says so.
- **Data:** the ticket's PR, CI checks, QA result and gate verdict (section 2).

#### D2c · Inbox: an action only the Director can do

- **Shows:** a `linear_request_human_action` request: why, the numbered steps, about how long, what it unblocks, which
  run asked. The banner at the bottom is the Undo after D12d.
- **Actions:** **Open in Linear** (prominent), **Copy Steps**.
- **Data:** the open human-action requests (section 2).

#### D2d · Inbox: a ticket to clarify

- **Shows:** a ticket the quality gate held or skipped: its score and round, each thing it found, the ticket as
  written, what happens next.
- **Actions:** **Edit in Linear**.
- **Data:** `awaiting_clarification` and `skipped` in `/api/v1/state` (they exist today).

#### D2e · Inbox: empty

- `ContentUnavailableView`: "Nothing waits on you.", how many were answered today, and **Open Overview**.

### J2. The glance (US3)

| Step | The Director | Screen |
| --- | --- | --- |
| 1 | Opens the window; it comes back on the last view | D1 |
| 2 | Reads the sentence and the flow strip | D1 |
| 3 | Sees what is working now; Needs attention isn't drawn | D1 |
| 4 | Checks today's spend and the initiatives | D1 |
| 5 | Clicks a tile: Waiting on you → Inbox; Working → Tickets filtered | D2a, D6 |

#### D1 · Overview: flowing

- **Shows:** the status sentence (P1); the flow strip (P2): Queued → Working → Auto Review → Waiting on you → Merging →
  Shipped today, each tile a count with one line of context, only Waiting on you tinted; **Now working** (agent runs,
  QA passes and landings, with phase, turn, last activity, time and tokens); **Next up**; on the right **Today**
  (tokens against the daily budget and each provider's limit), **Initiatives** (progress by state), repos health in
  one line.
- **States:** flowing (here), needs attention (J3), paused (J4), idle (below). Sections with nothing to say are not
  drawn.
- **Conventions:** solid cards on the window background; tiles are buttons with focus rings; values change in place
  with `.contentTransition(.numericText())`.
- **Data:** `/api/v1/state` gives counts, running entries, budget, usage limits, epic lanes; the Inbox count needs the
  Inbox list (section 2).

#### D1 · Overview: idle

- Nothing queued or working: stages keep their place in tertiary text, so nothing jumps when work arrives; the main
  column shows "All caught up." with **Show Shipped**.

### J3. Unstick a ticket (US4)

| Step | The Director | Screen |
| --- | --- | --- |
| 1 | Gets "SHOP-305 looks stuck", or sees Needs attention on the Overview | D14, D1 (attention) |
| 2 | Opens the ticket: run 2, no activity for 14 min; run 1 failed on the same test | D3 |
| 3 | Reads the transcript: a test that hangs | D4 |
| 4 | Stops the run and moves it to Backlog with a note | D12c |
| 5 | The attention row leaves on the next poll; the timeline says what was done | D1, D3 |

#### D1 · Overview: needs attention

- **Shows:** the sentence names the problems; **Needs attention** (P3) goes above everything, one row per problem with
  its fix; the sidebar's Overview item carries the count; a usage-limit hold also shows in the dispatch control
  ("Holding · Claude limit").
- **Problems and their fixes:** no agent activity for 10 min (**Stop Run…**, **Open**); 3 failed attempts or more
  (**Open**, **Stop Run…**); a repo conflict (**Open in Linear** to fix labels); a usage-limit hold (**Open Usage**,
  with the resume time); a forced ticket gone stale (**Open**, **Stop Forcing**); stray processes (**Open
  Diagnostics**).
- **Data:** running entries' `last_event_at`, retry attempts, `conflicts`, `usage_limits`, `forced[].stale`,
  `stray_processes`, all in `/api/v1/state` today.

#### D3 · Ticket page

- **Shows:** header with repo, initiative and badges; **Now** (run, model and effort, running time, turn, last
  activity, workspace with Reveal, tokens against the per-ticket cap); **Timeline** of every run and event (C14);
  **Ticket** facts (state, type, initiative, PR, gate verdict, forced); the agent's last message; links (Linear,
  transcript, audit records).
- **Actions:** View Transcript, Open in Linear, **Stop Run…**; ⋯ Copy API URL, Show Audit Records, Reveal Worktree,
  Force / Stop Forcing.
- **States:** working, waiting (says on what: you, CI, a blocker, a slot, a retry at a time), in review (gate and QA
  results), done (PR and when it merged).
- **Conventions:** opens from any row with Return or a double-click, ⌘[ goes back; a single click shows the same facts
  in the inspector (D6).
- **Data:** `/api/v1/:issue_identifier`, `run_history`, `/api/v1/runs`.

#### D4 · Run transcript

- **Shows:** events grouped by turn: the agent's messages, each tool call with its result and duration; the selected
  event in full below, monospaced and selectable; a call that hasn't returned says how long it has been silent.
- **Actions:** All / Messages / Tools / Errors, search, **Copy Session ID**.
- **Conventions:** its own window (⌘-click opens another).
- **Data:** the transcript endpoint that exists today.

#### D12c · Stop Run: the consequence sheet

- **Shows:** what Stop does, from the code: it ends the agent and removes its workspace; the ticket keeps its Linear
  state, so Symphony starts it again on its next poll. **Also move to Backlog** (on by default from Needs attention)
  with a note posted as a comment.
- **Data:** `POST /stop` exists; the Backlog move and comment go through DD4.

### J4. Steer the factory (US5)

| Step | The Director | Screen |
| --- | --- | --- |
| 1 | Clicks the dispatch control | D12a (popover) |
| 2 | Pauses with a reason | D12a (sheet) |
| 3 | Sees the pause said once, with Resume | D1 (paused) |
| 4 | Resumes from the same control | D12a |
| 5 | Forces SHOP-320 | D12b |
| 6 | Sees it working on the forced allowance, with Stop Forcing | D6, D3 |

#### D12a · Dispatch control: popover

- **Shows:** dispatch state with what is working and queued, **Pause Dispatch…** and **Force a Ticket…**. While
  paused: who paused, when, why, and **Resume Dispatch** (no sheet: resuming changes nothing already running). While a
  limit holds: which limit and when it resets.

#### D12a · Pause Dispatch: the consequence sheet

- **Shows:** no new run starts in any repo, forced tickets included; runs working go on to their end; an optional
  reason shown wherever the pause shows. Replaces the web dashboard's click-twice Pause All.
- **Data:** `POST /pause` with its reason, `POST /resume` (both exist).

#### D1 · Overview: dispatch paused

- The sentence says since when and why, with **Resume Dispatch**; the dispatch control turns orange; Queued says "held
  by the pause", Working says "finishing".

#### D12b · Force a ticket

- **Shows:** a field that finds the ticket as you type; what forcing skips (the queue, the slot limits; it runs on the
  forced allowance) and what it doesn't (its blockers, its reviews, a pause, the per-ticket cap; it never moves a
  ticket or approves a review), from the workflow's rules.
- **Data:** `POST /force` (exists).

#### D6 · Tickets, with the inspector

- **Shows:** every ticket Symphony tracks in one sortable `Table`: ticket, title, repo, stage, what it waits on, since
  when; a scope bar by stage (All, Working, Review, Waiting on you, Merging, Queued, Needs attention, Forced; the last
  ones fold into **More** when the inspector is open). The inspector shows the selected ticket's facts in short.
- **Replaces:** Running sessions, Watching, Retry queue, Finishing runs, Waiting to start, Waiting on blockers,
  Conflict and Forced.
- **Data:** `running`, `watching`, `retrying`, `slot_waiting`, `blocked`, `conflicts`, `forced` in `/api/v1/state`
  (all exist).

### J5. Follow an initiative (US6)

| Step | The Director | Screen |
| --- | --- | --- |
| 1 | Opens Initiatives: BIL-200, 4 of 8 | D5 |
| 2 | Reads its sub-tickets in landing order; BIL-206 waits on them | D5 |
| 3 | Clicks Review on BIL-206 | D2b |
| 4 | Sees the final verification waiting on 3 tickets | D5 |

#### D5 · Initiatives

- **Shows:** plan tickets grouped as Active, In review, Done recently, each with a progress bar by state; the detail's
  sentence ("4 of 8 done. BIL-206 waits on you, and 2 tickets wait on it."), the bar with its legend, and the
  sub-tickets in landing order with what each waits on.
- **Replaces:** Agent lanes (each initiative's slot line); slot counts move to Diagnostics.
- **Data:** parent tickets with their sub-tickets and blocked-by links: a new endpoint (section 2); `epic_lanes` gives
  the slots today.

### J6. Decide how much to trust the gate (US7)

| Step | The Director | Screen |
| --- | --- | --- |
| 1 | Opens Quality: the gate agreed with them 23 of 25 times | D7 |
| 2 | Opens a disagreement | D7 → D3 |
| 3 | Changes billing-api's gate | D7 → Repos window, TP-695 S9 |

#### D7 · Quality

- **Shows:** four tiles (gate agreement, QA passed first time, runs that opened a PR, PRs sent to Rework); **Gate
  agreement by repo** (bars, with mode and **Change Gate…**); **Runs by outcome** per day (status colors with a
  legend); **Disagreements** with both decisions.
- **Actions:** period pop-up, **Show All Runs** (the `/quality` table with its agent, outcome and date filters).
- **Data:** `acceptance_gate.agreement` and `recent` (verdicts with the human decision), `/api/v1/runs` and the run
  quality reports (exist).

### J7. Keep spend in check (US8)

| Step | The Director | Screen |
| --- | --- | --- |
| 1 | Sees the Today meter turn orange at 82% | D1 |
| 2 | Opens Usage; BIL-212 is at 90% of its cap after 4 attempts | D8 |
| 3 | Opens it and stops it into Backlog | D3 → D12c |
| 4 | Reads the provider limits and their resets | D8, D1 |

#### D8 · Usage

- **Shows:** tokens per day by provider (categorical palette with a legend) against the daily budget line; today
  against the budget with the per-ticket cap; each provider limit with its reset; **Heaviest tickets** with attempts
  and a meter against the cap.
- **Replaces:** Daily tokens and Issue budget cards, the raw rate-limit JSON.
- **Data:** `budget` and `usage_limits` exist; tokens per day and per ticket over a period need a history endpoint
  (section 2).

### J8. Look back (US9)

| Step | The Director | Screen |
| --- | --- | --- |
| 1 | Opens Shipped: 14 in 7 days | D9 |
| 2 | Switches to Learnings | D9 (Learnings) |
| 3 | Opens Audit, filters, exports | D10 |

#### D9 · Shipped

- **Shows:** the sentence, shipped per day, merged tickets by day with initiative, PR and time from Todo to Done.
- **Data:** merged tickets over a period: a new endpoint (section 2).

#### D9 · Learnings

- The run-end reflections from merged PRs (today's `/learnings`), newest first, by repo, searchable, each linking to
  its ticket and PR.

#### D10 · Audit

- **Shows:** the local audit records (today's `/audit`): kind and date filters, search, chain verification,
  **Export…** (NDJSON). Moves made from the app are recorded like any other.
- **Data:** `/api/v1/audit` (exists).

### J9. Mac routines (platform baseline)

| Step | The Director | Screen |
| --- | --- | --- |
| 1–2 | First launch, or Symphony stopped, starting, not answering | D0 |
| 3 | Closes the window; the app goes back to the menu bar | D13 |
| 4–5 | Reopens; keyboard everywhere | D1 |
| 6 | Checks Symphony's own health | D11 |

#### D0 · Window states

- **Stopped:** one placeholder per view with **Start Symphony**; badges hidden because counts are unknown.
- **Starting:** "Symphony is starting…" with a spinner. **Not answering:** "Symphony isn't answering." with Open Logs
  and Restart Symphony. **Older Symphony:** "Update Symphony to see this view." on views its API can't serve. **First
  launch:** "Symphony doesn't know where its config is." with Open Settings….

#### D11 · Diagnostics

- **Shows:** connection (version, API, uptime, last update); capacity (agent slots, landing slots, forced allowance,
  initiative slots); Linear requests by caller; GitHub webhooks and the CI poller; stray processes.
- **Actions:** Copy State JSON, Open Logs, Open Web Dashboard.
- **Data:** `linear_usage`, `pollers`, `concurrency`, `finishing`, `epic_lanes`, `stray_processes` in `/api/v1/state`
  (exist).

### Design system specimen

The first two pages of the mock, DS1 Foundations and DS2 Components, render every token and component of the
[Design system](design-system.md) in light and dark.

## 2. What the screens need from Symphony

Most of the dashboard reads data `/api/v1/state` already serves. These are the gaps:

| Need | Screens | Today | Gap |
| --- | --- | --- | --- |
| **Inbox list**: `In Review` and `Human Review` tickets, open human-action requests, quality-gate holds and skips, each with kind, ask and age | D1, D2, D13, D14 | `human_review` counts `Human Review` only; holds and skips are listed | A list endpoint: ADR 0001's "Waiting on you" (TP-617) plus the Clarify kind |
| **Review content**: a plan's documents, decisions with options and recommendation, sub-tickets; a PR's checks, QA result, gate verdict and size | D2a, D2b | Agents write a `## Review brief` comment at each handoff (TP-723); it isn't served | The brief in a structured form, per ticket |
| **Director's moves**: approve a plan, approve and merge a PR, send to Rework with a reason, send decisions, move to Backlog with a note, sign off a final verification | D2, D12c, D12d | Pause, resume, stop and force exist in the control API | New control API endpoints that make the Linear move and write the audit record (DD4) |
| **Initiatives**: plan tickets with sub-tickets, states and blocked-by links | D5, D1 | `epic_lanes` (slots only) | An initiatives endpoint |
| **History**: tokens per day and per ticket, merged tickets per day | D8, D9, D1 | Today's budget only | A history endpoint over the run records |

## 3. Decisions

The Director approved the recommended option of every decision on 2026-10-07.

### DD1. One window or a bigger menu bar popover

**Approved: A.**

- **A. One main window with a sidebar, next to the menu bar item (recommended).** Room for the Inbox's three panes,
  tables and charts; the menu bar keeps the quick glance (D13).
- B. A larger menu bar popover only. Quick, but no room for reviews, tables or an inspector, and popovers close on any
  click elsewhere.
- C. A window per view (Inbox, Overview, Tickets). More window management for one person.

### DD2. Dock presence

**Approved: A.**

- **A. A menu bar app that becomes a regular app while its window is open (recommended):** Dock icon, ⌘-Tab and a main
  menu while open; menu bar only when closed. `NSApp.setActivationPolicy(.regular)` / `.accessory`.
- B. Always in the Dock. Simple, but a Dock icon all day for an app that mostly sits in the menu bar.
- C. Never in the Dock (`LSUIElement`, as today). The window can't be found with ⌘-Tab or Mission Control's app
  switching.

### DD3. Minimum macOS version

**Approved: A.**

- **A. macOS 26 for the whole app (recommended).** Liquid Glass and the current SwiftUI (glass effects, concentric
  shapes, inspector, Table, Charts) without fallbacks. The package targets macOS 13 today, so Macs on 13–15 would stop
  getting updates, and the QA machine must run 26 or later.
- B. Keep macOS 13, build with the macOS 26 SDK, and add availability checks. Older systems get the pre-glass look;
  every custom component needs a fallback path and its own QA.

### DD4. How the app makes Linear moves

**Approved: A.**

- **A. Through new Symphony control API endpoints (recommended).** Symphony already holds the Linear key and the audit
  log; one writer means every move is audited the same way and the web dashboard could use the same endpoints. The
  endpoints are local and operator-only, like Pause and Stop.
- B. The app writes to Linear itself with the key it already stores for Settings and Repos. Less server work, but a
  second writer, and the audit record would have to be sent separately.
- C. Only links that open Linear. No new writes, but the Director leaves the app for every decision, which is what US2
  asks to avoid.

### DD5. How the app stays live

**Approved: A.**

- **A. Poll the local API while the window is visible (every 2 s) and slowly when it isn't (every 30 s, for the badge)
  (recommended).** The menu bar app polls today; nothing new to run.
- B. A server-sent events stream from Symphony. Lower latency and less polling, but a new long-lived connection to
  build and keep healthy.

### DD6. What happens to the web dashboard

**Approved: A.**

- **A. Keep it at its URL with no new features, a banner pointing to the Mac app, and Open Web Dashboard in
  Diagnostics and the menu's Developer submenu (recommended).** Symphony also runs on Linux hosts and over SSH, where
  there is no Mac app. Remove it later, by its own decision, once nothing depends on it.
- B. Remove it when the app ships. Leaves Linux and remote use with only the terminal dashboard.
- C. Rebuild it with the same layout as the app. Two UIs to keep in step.

### DD7. When a run counts as stuck

**Approved: A.**

- **A. No agent activity for 10 minutes (recommended),** the threshold the Repos redesign uses (TP-695 D6): twice
  Symphony's default stall timeout.
- B. The configured stall timeout. More exact, but the API would have to serve it.

### DD8. What notifies

**Approved: A.**

- **A. New Inbox items and new problems only, each kind switchable in Settings (recommended).**
- B. Also every merge. Pleasant on a quiet day, noise on a busy one.
- C. Nothing; badges only. Misses the point of US1 when the window is closed.

## 4. Self-check

- Every story has a journey: US1 → J1; US2 → J1; US3 → J2; US4 → J3; US5 → J4; US6 → J5; US7 → J6; US8 → J7; US9 →
  J8; the platform baseline → J9.
- Every journey step names a screen, and every screen named is in this document and in the mock: D0, D1 (flowing,
  idle, needs attention, paused), D2a–D2e, D3, D4, D5, D6, D7, D8, D9 (Shipped, Learnings), D10, D11, D12a (popover,
  sheet), D12b, D12c, D12d, D13, D14.
- Every section of the web dashboard, its other pages and the menu bar has a new home or is dropped with a reason:
  [Stories and journeys](director-app.md), section 5.
- The chart palette passed the dataviz validator in light and dark; status colors always come with a symbol and a
  word.

## 5. Build plan

The sub-tickets of TP-747, in landing order. Each is one PR with its own acceptance criteria and user walkthrough.

| # | Ticket | Delivers | Blocked by |
| --- | --- | --- | --- |
| 1 | [TP-774](https://linear.app/tonypine/issue/TP-774/land-the-director-app-design-documents-in-docsdesign) Land the Director app design documents in docs/design | These documents and the mock | |
| 2 | [TP-775](https://linear.app/tonypine/issue/TP-775/open-a-symphony-window-from-the-menu-bar-on-macos-26) Open a Symphony window from the menu bar, on macOS 26 | DD2, DD3, DD5; the window, sidebar and toolbar; design tokens in code; D0; D11 Diagnostics; Open Symphony and the Developer submenu (D13); an API fixture mode for QA | TP-774 |
| 3 | [TP-776](https://linear.app/tonypine/issue/TP-776/show-the-overview-in-the-symphony-window) Show the Overview in the Symphony window | D1 in its four states; P1–P3; the scope pop-up | TP-775 |
| 4 | [TP-777](https://linear.app/tonypine/issue/TP-777/list-what-waits-on-the-director-in-an-inbox) List what waits on the Director in an Inbox | The Inbox endpoint; D2a–D2e read-only; the Waiting on you list and badges (D13); D14 | TP-776 |
| 5 | [TP-778](https://linear.app/tonypine/issue/TP-778/approve-merge-send-back-and-answer-decisions-from-the-inbox) Approve, merge, send back and answer decisions from the Inbox | The move endpoints (DD4); D12d; the Undo banner | TP-777 |
| 6 | [TP-779](https://linear.app/tonypine/issue/TP-779/show-a-tickets-story-ticket-page-run-transcript-and-stop-run) Show a ticket's story: ticket page, run transcript and Stop Run | D3, D4, D12c | TP-778 |
| 7 | [TP-780](https://linear.app/tonypine/issue/TP-780/list-every-ticket-and-steer-dispatch-from-the-symphony-window) List every ticket and steer dispatch from the Symphony window | D6 with the inspector; the dispatch control, D12a, D12b | TP-779 |
| 8 | [TP-781](https://linear.app/tonypine/issue/TP-781/follow-initiatives-in-the-symphony-window) Follow initiatives in the Symphony window | The initiatives endpoint; D5; the Overview's Initiatives card | TP-779 |
| 9 | [TP-782](https://linear.app/tonypine/issue/TP-782/show-quality-and-usage-and-point-the-web-dashboard-to-the-mac-app) Show Quality and Usage, and point the web dashboard to the Mac app | The history endpoint; D7, D8; the DD6 banner | TP-780, TP-781 |
| 10 | [TP-783](https://linear.app/tonypine/issue/TP-783/final-verification-create-a-native-foreground-dashboard-to-the-macos) Final verification | Checks every requirement and acceptance criterion on `main` | TP-774 to TP-782 |

**Deferred:** US9 (Could): D9 Shipped and Learnings, D10 Audit, and the sidebar's Records group. One run files at most
10 sub-tickets, and the stories rank US9 "later". Until they are built, the web dashboard keeps `/learnings` and
`/audit` (DD6), and the app links to them (the ticket page's Show Audit Records opens the web audit page). The
Overview's idle state leaves out Show Shipped until D9 exists.
