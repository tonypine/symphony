# Stories and journeys: the Director's Mac app

- **Ticket:** [TP-747](https://linear.app/tonypine/issue/TP-747/create-a-native-foreground-dashboard-to-the-macos-app),
  a plan to replace the web dashboard with a native macOS window, the dashboard first. Approved by the Director on
  2026-10-07.
- **Companion documents:** [Design system](design-system.md) (tokens, patterns, components) and
  [Screens](director-app-screens.md) (every screen below, journey by journey, the data each needs, the decisions and
  the build plan). The mock [`journeys/director-app.html`](journeys/director-app.html) shows every screen. It is one
  file with no external assets: open it in any browser, offline.
- **Data:** every repo, ticket and number here and in the screens is made up (repos `billing-api`, `web-shop`,
  `notes-app`, `docs-site`; tickets `BIL-`, `SHOP-`, `NOTE-`, `DOC-`).
- **Screen IDs** (`D0`–`D14`) are defined in [Screens](director-app-screens.md). Each journey step names the screen
  that serves it.

## 1. The Director

The Director runs a software factory: Symphony's agents take Linear tickets and turn them into pull requests across a
handful of repos. The Director doesn't write the code. They:

- **architect**: write plan tickets, read the artifacts a plan produces (journeys, screens, decisions), pick between
  options, approve the split into sub-tickets;
- **steer**: decide what gets worked and when (pause, expedite, force, stop), and how much to hand over (acceptance
  gate Off, Shadow or Enforce);
- **judge**: approve or send back plans and PRs, and check that what shipped meets their standard.

They sit at one Mac with Symphony running in the menu bar. They check the factory a few times a day, between other
work, often for less than a minute. They know git, Linear and the workflow states well, and they don't want to read
JSON, logs or YAML to find out what the factory needs from them.

**Their questions, in the order they ask them:**

1. What waits on me, and what does each one ask?
2. Is the factory moving? Is anything stuck?
3. Is any initiative in trouble?
4. Can I trust the crew more than I do?
5. What does it cost?
6. What shipped?

## 2. What is wrong today

The web dashboard (`dashboard_live.ex`, `/quality`, `/learnings`, `/audit`, the transcript page) and the menu bar app
(SymphonyBar) work. Neither is built around these questions.

1. **It is written for whoever runs the orchestrator, not for the person directing it.** Its header reads "Operations
   Dashboard: current state, retry pressure, token usage, and orchestration health".
2. **It doesn't answer the first question.** Nine metric cards have equal weight (Running, Watching, Human Review,
   Retrying, Conflict, Forced, Daily tokens, Issue budget, Runtime). The one about the Director, "Human Review: needs
   you", is third. It counts the `Human Review` state only, so plans and PRs in `In Review`, open human-action
   requests and quality-gate holds don't count.
3. **Everything shows, always.** Sixteen sections sit in one scroll, and each one shows even when it is empty: "No repo
   conflicts.", "No queued retries", "Nothing is waiting to start.". On a calm day most of the page says that nothing
   happened.
4. **The front page shows internals.** It shows raw rate-limit JSON, Linear requests by caller, webhook relay
   counters, agent lanes, finishing slots and `forced_max`. They matter when debugging Symphony, not when directing
   work.
5. **Problems come without fixes.** A stuck run is a row with an old "Agent update" time. A retry shows its error and
   nothing to do about it. A conflict names two repos without saying how to resolve it.
6. **A ticket's story is spread out.** One ticket can appear in Running sessions, Recent runs, Watching, Retry queue,
   Auto Review, Forced, on the transcript page, on the audit page and in a JSON link.
7. **Steering is split across tools.** Pause is on the web page, Force is only in the menu bar, and approving or
   merging happens only in Linear or GitHub.
8. **The pages don't connect.** Quality, Learnings and Audit each have their own header and no shared navigation. The
   transcript is a raw event list.
9. **It isn't a Mac app.** It is a browser tab, with no notification, no Dock badge, no keyboard path, and no window
   that remembers where it was. The menu bar shows only a count.

## 3. User stories

Must = the app fails without it. Should = expected in the first release. Could = later.

### US1. Know what waits on me (Must)

> As the Director, when I sit down at the Mac, I want one list of everything that waits on my decision, oldest first,
> with what each item asks, so that I clear my queue without searching Linear and nothing sits forgotten.

Done when:

- the list holds tickets in `In Review` and `Human Review`, open human-action requests, and tickets the quality gate
  holds or skipped (they wait on me to rewrite them);
- each item shows its kind (plan, PR, final verification, action, clarify), the ask in one line, and how long it has
  waited;
- a notification, the Dock badge and the menu bar icon tell me when something new arrives, even with the window closed.

### US2. Make the call in one place (Must)

> As the Director, I want to read a plan's or a PR's review, answer its open decisions, and approve it or send it back
> from the same place, so that a decision takes minutes and I don't gather the evidence from Linear, GitHub and the
> dashboard myself.

Done when:

- a plan shows its artifacts, the decisions it needs (options, with the recommended one marked) and its sub-tickets;
- a PR shows its summary, CI, the Auto Review QA result, the acceptance gate's verdict and the size of the change;
- Approve, Send Decisions and Send to Rework each say what will happen before they act, and leave a record in Linear.

### US3. Know the factory is flowing (Must)

> As the Director, I want to see at a glance whether work is moving (queued, being worked, in Auto Review, waiting on
> me, merging, shipped today), in one sentence when all is well, so that a healthy day takes five seconds of my
> attention.

Done when:

- the dashboard leads with one sentence and the flow of tickets through the stages;
- sections with nothing to say are hidden, not shown empty;
- today's spend and active initiatives are visible without scrolling at the default window size.

### US4. Step in when something is stuck (Must)

> As the Director, when a ticket is stuck, failing or looping, I want to be told, see why in the ticket's story, and
> stop it or park it, so that a problem costs minutes and not a day of tokens.

Done when:

- stuck runs (no agent activity for 10 minutes), repeated failures (3 attempts or more), repo conflicts, usage-limit
  holds and stray processes show in one **Needs attention** list, each with its fix;
- a ticket has one page with its runs, the current agent activity, its errors, attempts, tokens, PR and transcript;
- Stop Run says what happens to the run, the workspace and the Linear state.

### US5. Steer what gets worked (Should)

> As the Director, I want to pause and resume the factory with a reason, push a ticket ahead of the queue, and stop a
> run, from where I see the work, so that the factory follows my priorities and not only its queue.

### US6. Follow an initiative to done (Should)

> As the Director, I want to follow each plan I approved (its sub-tickets in landing order, which are done, working,
> waiting on me or blocked, and its final verification), so that I know when an initiative lands and what holds it up.

### US7. Decide how much to trust the crew (Should)

> As the Director, I want to see how often the acceptance gate and QA agree with me, per repo, and which tickets we
> disagreed on, so that I decide where to hand over more (gate to Enforce) and where to keep reviewing myself.

### US8. Keep spend inside the budget (Should)

> As the Director, I want today's tokens against the daily budget, each provider's limits with their reset times, and
> the tickets that cost the most, so that I keep cost in check and catch a runaway ticket early.

### US9. Look back at what shipped (Could)

> As the Director, at the end of a day or a week, I want to see what shipped, grouped by initiative, what the crew
> learned, and the audit record, so that I can report progress and spot patterns.

## 4. Journeys

### J1. Clear the inbox (US1, US2)

1. A notification: "SHOP-330 waits on you. Plan ready: Gift cards." Or the menu bar icon shows a badge and its menu
   lists the items. Clicking either opens the window on the Inbox. → **D14**, **D13** → **D2a**
2. The Inbox lists four items, grouped by kind and oldest first: plan SHOP-330 (3 h), PR BIL-206 (1 h), action NOTE-90
   (20 min), clarify SHOP-341 (5 min). → **D2a**
3. Select the plan. Its review shows what to review (3 documents and the HTML screens), 2 decisions needed with the
   recommended option picked, and 7 sub-tickets in landing order. → **D2a**
4. To change a decision, pick another option and **Send Decisions**: it posts one comment on the plan, and Symphony
   revises the plan. To approve, **Approve Plan…** opens a sheet that names the 7 sub-tickets and the one that starts
   first. → **D2a** → **D12d**
5. Next, the PR. CI is green, QA passed 6 of 6 walkthrough steps, the gate says Approve (Shadow), and the change is
   +412 −120 in 9 files. **Approve and Merge…** asks first, then moves the ticket to `Merging`, where Symphony turns on
   auto-merge. → **D2b** → **D12d**
6. Next, the action: NOTE-90, "Add the App Store Connect key". It shows why it is needed, 4 steps, about 10 minutes.
   **Copy Steps**, **Open in Linear**. A banner confirms the merge a moment ago, with Undo. → **D2c**
7. A ticket the quality gate held: what it found, its score, and **Edit in Linear**. → **D2d**
8. The inbox is empty: "Nothing waits on you." The badges clear. → **D2e**

### J2. The glance (US3)

1. Open the window from the Dock, ⌘-Tab, or **Open Symphony** in the menu bar. It opens where it was, on the last
   view. → **D1**
2. The status sentence reads "The factory is flowing." Under it, the flow: Queued 4 → Working 3 → Auto Review 2 →
   Waiting on you 4 → Merging 1 → Shipped today 5. → **D1**
3. Nothing needs attention, so that section isn't shown. **Now working** lists the runs with their phase and last
   activity. → **D1**
4. On the right: today's tokens, 3.1M of a 5M budget; the Claude 5-hour limit at 41%; 2 active initiatives with their
   progress. On a day with nothing to do, the Overview says "The factory is idle." → **D1** (flowing, idle)
5. Clicking **Waiting on you** opens the Inbox (J1). Clicking **Working** opens Tickets filtered to working. → **D2a**,
   **D6**

### J3. Unstick a ticket (US4)

1. A notification: "SHOP-305 looks stuck: no agent activity for 14 min." On the Overview, the sentence reads "2 things
   need attention" and **Needs attention** lists SHOP-305 with **Stop Run…** and **Open**, and a Claude limit holding
   new runs. → **D14**, **D1** (needs attention)
2. Open it. The ticket page shows the current run: implementation run 2, turn 31, last activity "mix test
   test/checkout_test.exs" 14 min ago, 1.4M tokens of its 2M cap. The timeline shows run 1 failed on the same test.
   → **D3**
3. **View Transcript**: the last events show the agent waiting on a test that hangs. → **D4**
4. **Stop Run…**: the sheet says Symphony ends the run and removes its workspace; the ticket stays `In Progress`, so
   Symphony starts it again on its next poll unless it is moved. **Also move to Backlog** is checked, with a note
   field. → **D12c**
5. On the next poll the attention row goes away, and the ticket's timeline reads "Stopped by you, moved to Backlog".
   → **D1**, **D3**

### J4. Steer the factory (US5)

1. Before a deploy freeze: click the dispatch control in the toolbar. A popover shows "Dispatch on", what is working
   and queued, and **Pause Dispatch…**. → **D12a** (popover)
2. The pause sheet asks for a reason ("Deploy freeze") and says runs already working go on, and no new run starts until
   Resume, forced tickets included. → **D12a** (sheet)
3. The toolbar control turns orange, "Paused · Deploy freeze". The sentence reads "Dispatch is paused since 14:03:
   Deploy freeze." The menu bar icon shows the pause. → **D1** (paused)
4. Later, the same control → **Resume Dispatch**. → **D12a**
5. To push a ticket through: **Force a Ticket…** (⇧⌘F, or the Tickets toolbar). Type `SHOP-320`; the sheet shows its
   title and state, and says it skips the queue and the slot limits but still waits on its blockers, on its reviews and
   on a pause. → **D12b**
6. It shows under **Forced** in Tickets, working, and the inspector has **Stop Forcing**. → **D6**, **D3**

### J5. Follow an initiative (US6)

1. **Initiatives** lists active plans: BIL-200 Invoices v2, 4 of 8 done, 1 working, 1 waiting on you, 2 queued.
   → **D5**
2. Select it. Its sub-tickets are listed in landing order with their blocked-by links: BIL-206 waits on you (a PR), and
   BIL-207 and BIL-208 wait on it. → **D5**
3. **Review** on BIL-206 opens its inbox item; approve it. → **D2b**
4. The final verification row reads "Waits on 3 tickets". When the rest are done it runs, and its result shows here.
   → **D5**

### J6. Decide how much to trust the gate (US7)

1. **Quality**: the gate agreed with you on 23 of 25 decisions in the last 30 days: billing-api 12 of 12, web-shop 11
   of 13. → **D7**
2. **Disagreements** lists SHOP-298: the gate approved it, and you sent it to Rework. Open it to see both decisions side
   by side. → **D7** → **D3**
3. billing-api has earned it: **Change Gate…** on its row opens the Repos window's acceptance gate sheet for
   billing-api (TP-695, S9). → **D7** → Repos S9

### J7. Keep spend in check (US8)

1. On the Overview, today's meter is at 82% and has turned orange. → **D1**
2. **Usage**: tokens per day for 14 days; today 4.1M of 5M. **Heaviest tickets**: BIL-212 used 1.8M of its 2M cap over
   4 attempts. → **D8**
3. Open BIL-212: every attempt fails at the same test. **Stop Run…** and move it to Backlog with a note. → **D3** →
   **D12c**
4. **Provider limits**: Claude 7-day at 71%, resets Thursday. When a limit holds new runs, the Overview says so in
   Needs attention, with the resume time. → **D8**, **D1**

### J8. Look back (US9)

1. **Shipped**: 14 tickets in the last 7 days, by day and initiative, each with its PR and time from Todo to Done.
   → **D9**
2. **Learnings** (a tab in the same view): what the crew recorded, by repo. → **D9** (Learnings)
3. **Audit**: filter by ticket or kind; the chain is verified; **Export…** writes NDJSON. → **D10**

### J9. Mac routines (platform baseline)

1. First launch with no config: the window says so, with **Open Settings…**. → **D0**
2. Symphony stopped: every view shows one placeholder with **Start Symphony**, not a page of "unavailable". Starting
   and not answering read the same way. → **D0**
3. ⌘W closes the window. The app goes back to the menu bar only, the Dock icon goes away, and Symphony keeps running.
   → **D13**
4. Reopening restores the window's size, position, view and selection. → **D1**
5. Keyboard: ⌘1–⌘8 switch views, ⌘F searches, ⌘R refreshes, ⌥⌘I shows the inspector, Return opens, ⌘[ goes back.
   → all
6. When Symphony itself seems off, **Diagnostics** shows connection, capacity, integrations and processes. → **D11**

## 5. Every current feature has a home

### Web dashboard (`/`)

| Today | New home | Why |
| --- | --- | --- |
| Header, "Live"/"Offline" badge | Toolbar connection state (**D1**, **D0**) | The window title says what it is; the state shows only when it isn't "connected" |
| Links to Audit, Quality, Learnings | Sidebar (**D7**, **D9**, **D10**) | One navigation |
| "System paused" banner | Toolbar dispatch control and the status sentence (**D1** paused, **D12a**) | Said once, where you resume it |
| "Snapshot unavailable" | **D0** | One placeholder |
| Usage limit banner | Needs attention (**D1**), Usage provider limits (**D8**) | A hold is something to know about now; the limits are context |
| Stray processes banner | Needs attention (**D1**), Diagnostics (**D11**) | Problem with its fix |
| Dispatch active/paused with blockers; Pause All / Resume All (click twice) | Dispatch control and sheet (**D12a**), with a reason | One click to open, the consequence stated |
| Repo filter | Toolbar scope pop-up, applied to every view | Set once |
| Metric: Running | Flow strip: Working (**D1**) | |
| Metric: Watching | Flow strip stages; Tickets "Waiting on" (**D6**) | "Watching" is Symphony's word, not a stage of work |
| Metric: Human Review | Flow strip: Waiting on you, and the Inbox (**D1**, **D2**) | Counts every kind of wait (US1) |
| Metric: Retrying, Conflict | Needs attention when they need a person (**D1**); Tickets "Waiting on" (**D6**) | Shown when they matter |
| Metric: Forced (n/`forced_max`) | Tickets filter "Forced" (**D6**); allowance in Diagnostics (**D11**) | |
| Metric: Daily tokens | Today meter (**D1**), Usage (**D8**) | |
| Metric: Issue budget | Usage, per-ticket cap (**D8**) | |
| Metric: Runtime (completed + active) | Dropped | No decision rides on it; per-ticket runtime stays on **D3** |
| Rate limits (raw JSON) | Provider limit meters (**D8**) | Raw JSON dropped; Copy State JSON in **D11** |
| Linear requests by caller | Diagnostics (**D11**) | Debugging Symphony |
| GitHub webhooks | Diagnostics (**D11**) | Debugging Symphony |
| Agent lanes | Initiatives, one slot line per initiative (**D5**); capacity in Diagnostics (**D11**) | Lanes exist for initiatives |
| Finishing runs, waiting to start, waiting on blockers, auto-merge status | Tickets "Waiting on" column (**D6**), ticket page (**D3**) | Why a ticket waits belongs to the ticket |
| Auto Review: gate runner, agreement, recent verdicts | Quality (**D7**); the verdict per ticket on **D2b** and **D3** | |
| Forced: phase, waiting on, forced for, stale | Tickets "Forced" (**D6**), ticket page (**D3**), Needs attention when stale (**D1**) | |
| Running sessions: issue, state, session, runtime/turns, agent update, tokens | Now working (**D1**), Tickets (**D6**), ticket page (**D3**) | |
| Running sessions links: PR, Transcript, Audit, JSON | Ticket page actions (**D3**); JSON as **Copy API URL** in its ⋯ menu | |
| Running sessions: Stop (click twice) | **Stop Run…** sheet (**D12c**) from Needs attention and the ticket page | |
| Recent runs (kind, model/effort, status, tokens) | Ticket timeline (**D3**), Quality runs table (**D7**) | |
| Watching | Inbox for states waiting on you (**D2**); Tickets "Waiting on" for the rest (**D6**) | |
| Conflict | Needs attention with **Open in Linear** to fix the labels (**D1**) | |
| Retry queue (attempt, due at, error) | Tickets "Waiting on: retry at 14:05" (**D6**); Needs attention at 3 attempts (**D1**) | |
| Awaiting clarification (quality-gate holds) | Inbox, kind "Clarify" (**D2d**) | It waits on the Director |
| Skipped (quality gate) | Inbox, kind "Clarify" (**D2d**) | Same |
| "Updating…" indicator | Toolbar progress while a refresh runs | |

### Other web pages

| Today | New home |
| --- | --- |
| `/quality`: PR-opened rate, average tokens, tests-run rate, error rate; filters (agent, outcome, dates); last 50 runs | Quality (**D7**): tiles, outcome chart, and **Show All Runs** with the same filters |
| `/learnings`: filters and records | Shipped, Learnings tab (**D9**) |
| `/audit`: filters, timeline, chain verification, NDJSON export | Audit (**D10**) |
| Transcript: events of a session | Run transcript (**D4**), grouped by turn, with filters and search |

### Menu bar (SymphonyBar)

| Today | New home |
| --- | --- |
| Status line, counts line, "N in Human Review" | Menu header and **Waiting on you** list (**D13**), badge on the icon |
| Start, Stop, Restart, Restart Now Anyway, Cancel Restart | Kept in the menu (**D13**); also in the app menu |
| Pause Dispatch / Resume Dispatch | Kept (**D13**); same sheet as **D12a** |
| Forced list, Force a ticket…, Stop forcing | Kept (**D13**); same sheet as **D12b** |
| Open Dashboard | **Open Symphony** (the window); the web dashboard stays reachable at its URL (decision DD6) |
| Open Dashboard in Terminal, Open Logs | Kept, under a **Developer** submenu |
| Updates (available, install, skip, notes, check) | Kept (**D13**) |
| Repos…, Settings…, Quit | Kept; Repos is also in the sidebar |
| Usage limit notices | Needs attention (**D1**) and the menu header |

## 6. Platform baseline (Must-be for any Mac app of this kind)

| Need | How the design meets it |
| --- | --- |
| A real window: Dock icon, ⌘-Tab, main menu, while open | Switches to a regular app while the window is open (decision DD2) |
| Remembers size, position, view and selection | Window frame autosave and scene state |
| Fits the smallest supported screen | Minimum 960×600; sheets ≤ 560 pt tall with a fixed footer |
| Keyboard for everything | Sidebar ⌘1–⌘8, ↑↓ in lists, Return to open, ⌘[ back, ⌘F, ⌘R, ⌥⌘I, Esc in sheets |
| VoiceOver | Every row reads its ticket, title, state and age; status is never color alone |
| Light, dark, Increase Contrast, Reduce Transparency, Reduce Motion | System colors and materials only ([Design system](design-system.md)) |
| Empty, loading and error states with a way out | **D0**, **D1** idle, **D2e** |
| Destructive actions confirmed and named | Stop Run, Send to Rework, Pause (**D12**) |
| Notification control | Notifications are on per kind in Settings; macOS Focus respected (**D14**) |
| Search | ⌘F on Tickets, Inbox, Audit, Learnings, transcript |
| Undo where a move can be undone | A Linear move from the app shows "Moved to Merging · Undo" for 10 s (**D2c**, **D12d**) |
| Privacy | The app talks to the local Symphony API (and to Linear, as Settings and Repos already do); nothing else leaves the Mac |

## 7. Out of scope

- Writing or editing tickets in the app: the Director writes them in Linear, from the templates in
  `docs/ticket-templates/`.
- Settings and Repos: their windows stay; the Repos redesign is TP-695 ([repos.md](repos.md)). The sidebar links to
  Repos.
- A remote or iOS client. The saved Linear view "Waiting on me" (ADR 0001) covers being away from the Mac.
- Code review inside the app: the PR diff stays on GitHub; the app links to it.
