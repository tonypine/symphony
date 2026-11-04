/*
 * The facts of one ticket's life, shared by the three ticket page prototypes.
 *
 * The ticket is TP-1244, "The paused line on the ticket page", merged as PR #741 on Fri 30 Oct
 * 2026 at 21:05 (commit da402827). Its blocker TP-1251 merged as PR #728 at 15:22 that day, and the
 * snapshots its QA pass shows are the ones the PR committed (macos/Tests/Snapshots). The run-by-run
 * detail in between (the times, the tokens, the agent's lines, the review finding, the QA finding
 * and the question) is a faithful reconstruction of how such a ticket moves through Symphony, so
 * the page has one of each thing it must show: an implementation run, a CI fix, a review round, a
 * QA pass with a finding and a screenshot, a question asked and answered, a pause, and a merge.
 *
 * A prototype never reads this file's times as strings to decide anything: every view is drawn
 * from the events and runs below, up to the moment the page shows (see moments).
 */
window.TICKET_LIFE = (function () {
  "use strict";

  const SNAP = "../../../../macos/Tests/Snapshots/";

  const ticket = {
    ident: "TP-1244",
    title: "The paused line on the ticket page",
    repo: "symphony",
    epic: { ident: "", title: "Pauses", part: "15 of 19", done: 14, total: 19 },
    priority: "Urgent",
    labels: ["director", "pauses"],
    workspace: "/Users/tonypine/symphony-workspaces/symphony/TP-1244",
    brief: "A paused ticket's page says why under its title, from Symphony's own pause block: “Paused: waiting for your answer”, or “Paused for 2 reasons” with one row per reason in the order they were set. Each row says since when, and a reason the Director may release has a Release button.",
    walkthrough: [
      "Open a ticket paused for one reason: the line under the title names it and says since when.",
      "Open a ticket paused for two reasons: the line says “Paused for 2 reasons” and lists both, oldest first.",
      "Press Release on a reason you may release: the row says Releasing, then the line goes.",
    ],
  };

  const relations = {
    blockedBy: [{ ident: "TP-1251", title: "The Symphony pause's reasons in the header", state: "Done", role: "done", note: "Merged as PR #728 at 15:22", resolvedAt: "2026-10-30T15:22" }],
    blocks: [{ ident: "TP-1253", title: "Inbox rows name their question and read pause reasons", state: "Todo", role: "idle", note: "Waits for this ticket" }],
  };

  /* Steps: { id, name, state, start, end, msgs: [{ at, kind: say | tool | result, text, failed }] } */
  const runs = {
    r1: {
      kind: "Implementation", n: 1, title: "Implementation run 1", model: "Claude Opus 5.5", start: "2026-10-30T15:24", end: "2026-10-30T16:02", tokens: 2.4, verdict: "passed", outcome: "Pushed and opened PR #741",
      steps: [
        { id: "code", name: "Writing the code", state: "passed", start: "15:24", end: "15:46", msgs: [
          { at: "15:24", kind: "say", text: "Reading the ticket, TP-1251's pause block and the ticket page." },
          { at: "15:27", kind: "tool", text: "read macos/Sources/SymphonyBarCore/TicketPage.swift" },
          { at: "15:31", kind: "say", text: "The page will read the server's pause block: one reason, or a count with one row per reason, oldest first." },
          { at: "15:38", kind: "tool", text: "edit TicketPage.swift, TicketPageView.swift" },
          { at: "15:44", kind: "tool", text: "add fixtures: paused-ticket (four tickets, one to three reasons)" },
        ] },
        { id: "build", name: "Build", state: "passed", start: "15:46", end: "15:51", msgs: [
          { at: "15:46", kind: "tool", text: "swift build --disable-sandbox --build-system native" },
          { at: "15:51", kind: "result", text: "Build complete (4 min 52 s)" },
        ] },
        { id: "checks", name: "Checks", state: "passed", start: "15:51", end: "15:52", msgs: [
          { at: "15:51", kind: "tool", text: "swift format lint --strict" },
          { at: "15:52", kind: "result", text: "No issues" },
        ] },
        { id: "tests", name: "Tests", state: "passed", start: "15:52", end: "15:58", msgs: [
          { at: "15:52", kind: "tool", text: "swift test --filter TicketPageTests" },
          { at: "15:57", kind: "result", text: "130 tests passed" },
          { at: "15:58", kind: "tool", text: "record snapshots: paused-line one, two, three, releasing" },
        ] },
        { id: "handoff", name: "Handoff", state: "passed", start: "15:58", end: "16:02", msgs: [
          { at: "16:00", kind: "tool", text: "git push origin auto/TP-1244" },
          { at: "16:02", kind: "result", text: "Opened PR #741" },
        ] },
      ],
    },
    r2: {
      kind: "CI fix", n: 1, title: "CI fix run 1", model: "Claude Opus 5.5", start: "2026-10-30T16:12", end: "2026-10-30T16:21", tokens: 0.5, verdict: "passed", outcome: "Fixed the snapshots and pushed",
      steps: [
        { id: "code", name: "Reading the failure", state: "passed", start: "16:12", end: "16:15", msgs: [
          { at: "16:12", kind: "tool", text: "read the Snapshots job's log" },
          { at: "16:13", kind: "result", text: "paused-line-two-laptop-light.png and -dark.png differ by 2 px", failed: true },
          { at: "16:15", kind: "say", text: "The rows moved 2 pt when the reasons got their own lines; the change is intended. Re-recording both." },
        ] },
        { id: "tests", name: "Tests", state: "passed", start: "16:15", end: "16:19", msgs: [
          { at: "16:15", kind: "tool", text: "record snapshots: paused-line-two" },
          { at: "16:19", kind: "result", text: "14 snapshots match" },
        ] },
        { id: "handoff", name: "Handoff", state: "passed", start: "16:19", end: "16:21", msgs: [{ at: "16:21", kind: "tool", text: "git push" }] },
      ],
    },
    r3: {
      kind: "Code Review", n: 1, title: "Code Review run 1", model: "Claude Opus 5.5", start: "2026-10-30T16:30", end: "2026-10-30T16:38", tokens: 0.6, verdict: "sent-back", outcome: "Sent back with one finding", finding: "f1",
      steps: [
        { id: "read", name: "Reading the change", state: "passed", start: "16:30", end: "16:35", msgs: [
          { at: "16:30", kind: "say", text: "Checking the page against the ticket and the pause block's contract." },
          { at: "16:33", kind: "say", text: "A reason the server sends without words falls through to its raw code: the page would say “ci_wait”." },
        ] },
        { id: "verdict", name: "Verdict", state: "passed", stateWord: "Sent back", start: "16:35", end: "16:38", msgs: [{ at: "16:38", kind: "result", text: "Rework: 1 finding", failed: true }] },
      ],
    },
    r4: {
      kind: "Implementation", n: 2, title: "Implementation run 2", model: "Claude Opus 5.5", start: "2026-10-30T16:39", end: "2026-10-30T16:58", tokens: 1.1, verdict: "passed", outcome: "Answered the finding and pushed",
      steps: [
        { id: "code", name: "Writing the code", state: "passed", start: "16:39", end: "16:43", msgs: [
          { at: "16:39", kind: "say", text: "Code Review found a reason without words shows its raw code. I'll fall back to “Paused”." },
          { at: "16:39", kind: "say", text: "Your note says to keep the button word Release; it stays." },
          { at: "16:40", kind: "tool", text: "edit TicketPage.swift: pausedReasonText(_:)" },
          { at: "16:42", kind: "tool", text: "add test pausedLineFallsBackToPaused" },
        ] },
        { id: "build", name: "Build", state: "passed", start: "16:43", end: "16:44", msgs: [
          { at: "16:43", kind: "tool", text: "swift build" },
          { at: "16:44", kind: "result", text: "Build complete (58 s)" },
        ] },
        { id: "checks", name: "Checks", state: "passed", start: "16:44", end: "16:44", msgs: [{ at: "16:44", kind: "result", text: "format and lint clean" }] },
        { id: "tests", name: "Tests", state: "passed", start: "16:44", end: "16:55", msgs: [
          { at: "16:44", kind: "tool", text: "swift test --filter TicketPageTests" },
          { at: "16:46", kind: "result", text: "131 tests passed" },
          { at: "16:47", kind: "say", text: "The fallback works. Now recording the one snapshot it changes." },
          { at: "16:49", kind: "tool", text: "record snapshots: paused-line-one" },
          { at: "16:53", kind: "result", text: "4 snapshots recorded, 14 match" },
          { at: "16:55", kind: "say", text: "Every test and snapshot passes. Handing off." },
        ] },
        { id: "handoff", name: "Handoff", state: "passed", start: "16:55", end: "16:58", msgs: [{ at: "16:57", kind: "tool", text: "git push" }, { at: "16:58", kind: "result", text: "PR #741 updated" }] },
      ],
    },
    r5: {
      kind: "Code Review", n: 2, title: "Code Review run 2", model: "Claude Opus 5.5", start: "2026-10-30T17:06", end: "2026-10-30T17:12", tokens: 0.4, verdict: "approved", outcome: "Approved, on to QA",
      steps: [
        { id: "read", name: "Reading the change", state: "passed", start: "17:06", end: "17:10", msgs: [{ at: "17:08", kind: "say", text: "The fallback answers the finding and has its test." }] },
        { id: "verdict", name: "Verdict", state: "passed", stateWord: "Approved", start: "17:10", end: "17:12", msgs: [{ at: "17:12", kind: "result", text: "Approve" }] },
      ],
    },
    r6: {
      kind: "QA", n: 1, title: "QA run 1", model: "Claude Sonnet 5.5", start: "2026-10-30T17:13", end: "2026-10-30T17:31", tokens: 0.9, verdict: "failed", outcome: "Failed one walkthrough step", finding: "f2",
      steps: [
        { id: "build", name: "Build for QA", state: "passed", start: "17:13", end: "17:19", msgs: [{ at: "17:19", kind: "result", text: "App built for this commit" }] },
        { id: "walk", name: "Walkthrough", state: "failed", start: "17:19", end: "17:29", msgs: [
          { at: "17:20", kind: "tool", text: "launch the app, laptop size, light" },
          { at: "17:22", kind: "say", text: "Step 1 and 2 pass in light: the line names the reasons, oldest first." },
          { at: "17:25", kind: "tool", text: "launch the app, laptop size, dark; screenshot the paused line" },
          { at: "17:27", kind: "say", text: "In dark the “since” times are hard to read: 2.9 to 1 against the page." },
        ] },
        { id: "report", name: "Report", state: "passed", stateWord: "Failed", start: "17:29", end: "17:31", msgs: [{ at: "17:31", kind: "result", text: "Fail: step 2, the times are too faint in dark", failed: true }] },
      ],
    },
    r7: {
      kind: "Implementation", n: 3, title: "Implementation run 3", model: "Claude Opus 5.5", start: "2026-10-30T17:32", end: "2026-10-30T17:44", tokens: 0.6, verdict: "asked", outcome: "Asked you how the times should read", question: "q1",
      steps: [
        { id: "code", name: "Writing the code", state: "asked", start: "17:32", end: "17:44", msgs: [
          { at: "17:32", kind: "say", text: "QA found the times too faint in dark. The design system has two ways to fix it, and they look different." },
          { at: "17:38", kind: "tool", text: "measure contrast: tertiary 2.9:1, secondary 7.0:1 (dark)" },
          { at: "17:44", kind: "say", text: "This is a call about how the page looks, so I'm asking the Director." },
        ] },
        { id: "build", name: "Build", state: "pending", msgs: [] },
        { id: "tests", name: "Tests", state: "pending", msgs: [] },
        { id: "handoff", name: "Handoff", state: "pending", msgs: [] },
      ],
    },
    r8: {
      kind: "Implementation", n: 4, title: "Implementation run 4", model: "Claude Opus 5.5", start: "2026-10-30T18:21", end: "2026-10-30T18:33", tokens: 0.7, verdict: "passed", outcome: "Applied your answer and pushed",
      steps: [
        { id: "code", name: "Writing the code", state: "passed", start: "18:21", end: "18:24", msgs: [
          { at: "18:21", kind: "say", text: "Your answer: use the secondary text colour. Changing the times' colour role." },
          { at: "18:22", kind: "tool", text: "edit TicketPageView.swift" },
        ] },
        { id: "build", name: "Build", state: "passed", start: "18:24", end: "18:25", msgs: [{ at: "18:25", kind: "result", text: "Build complete" }] },
        { id: "tests", name: "Tests", state: "passed", start: "18:25", end: "18:31", msgs: [{ at: "18:31", kind: "result", text: "131 tests passed, 14 snapshots re-recorded" }] },
        { id: "handoff", name: "Handoff", state: "passed", start: "18:31", end: "18:33", msgs: [{ at: "18:33", kind: "tool", text: "git push" }] },
      ],
    },
    r9: {
      kind: "Code Review", n: 3, title: "Code Review run 3", model: "Claude Opus 5.5", start: "2026-10-30T18:41", end: "2026-10-30T18:46", tokens: 0.4, verdict: "approved", outcome: "Approved, on to QA",
      steps: [
        { id: "read", name: "Reading the change", state: "passed", start: "18:41", end: "18:44", msgs: [{ at: "18:43", kind: "say", text: "Matches decision D1; one colour role changed." }] },
        { id: "verdict", name: "Verdict", state: "passed", stateWord: "Approved", start: "18:44", end: "18:46", msgs: [{ at: "18:46", kind: "result", text: "Approve" }] },
      ],
    },
    r10: {
      kind: "QA", n: 2, title: "QA run 2", model: "Claude Sonnet 5.5", start: "2026-10-30T18:47", end: "2026-10-30T19:05", tokens: 1.0, verdict: "passed", outcome: "Every walkthrough step passed",
      steps: [
        { id: "build", name: "Build for QA", state: "passed", start: "18:47", end: "18:52", msgs: [{ at: "18:52", kind: "result", text: "App built for this commit" }] },
        { id: "walk", name: "Walkthrough", state: "passed", start: "18:52", end: "19:03", msgs: [
          { at: "18:55", kind: "say", text: "Steps 1 to 3 pass in light and dark, at laptop and desktop sizes." },
          { at: "19:01", kind: "tool", text: "screenshot: two reasons, laptop, light; three reasons, desktop, dark" },
        ] },
        { id: "report", name: "Report", state: "passed", stateWord: "Passed", start: "19:03", end: "19:05", msgs: [{ at: "19:05", kind: "result", text: "Pass: 3 of 3 steps" }] },
      ],
    },
  };

  const findings = {
    f1: { run: "r3", at: "2026-10-30T16:38", by: "Code Review", title: "A reason without words shows its raw code", text: "When the server sends a pause reason it has no words for, the page shows its code (“ci_wait”). It should fall back to “Paused”.", resolvedBy: "r4" },
    f2: { run: "r6", at: "2026-10-30T17:31", by: "QA", title: "The times are too faint in dark", text: "Walkthrough step 2, dark, laptop size: the “since” times read at 2.9 to 1 against the page; the design system asks for 4.5 to 1.", shot: "a2", resolvedBy: "r8" },
  };

  const attachments = {
    a2: { name: "Paused line, two reasons, laptop, dark", src: SNAP + "paused-line-two-laptop-dark.png", at: "2026-10-30T17:27", by: "QA run 1", finding: "f2" },
    a3: { name: "Two reasons, laptop, light", src: SNAP + "paused-line-two-laptop-light.png", at: "2026-10-30T19:01", by: "QA run 2" },
    a4: { name: "Three reasons, desktop, dark", src: SNAP + "paused-line-three-desktop-dark.png", at: "2026-10-30T19:01", by: "QA run 2" },
  };

  const questions = {
    q1: {
      asked: "2026-10-30T17:44", by: "Implementation run 3", answered: "2026-10-30T18:20", answer: 0, answeredBy: "Tony, in the Inbox",
      title: "How should the times on the paused line read in dark mode?",
      why: ["QA found the times on the paused line too faint in dark mode at laptop size: 2.9 to 1 against the page.", "The design system asks for 4.5 to 1. Two of the fixes below meet it; they differ in how busy the line looks."],
      unanswered: "TP-1244 stays paused and nothing runs on it.",
      options: [
        { label: "Use the secondary text colour", effect: "The times read at 7 to 1 in dark and 5.7 to 1 in light. The line looks a little busier.", recommended: true, why: "It meets the contrast rule in both appearances with one colour change.", good: "Meets the contrast rule in light and dark", cost: "The times compete a little with the reasons" },
        { label: "Keep the light colour, one size up", effect: "The times grow from 11 to 12 pt; their contrast stays at 2.9 to 1.", risk: "Still under the contrast rule: QA would fail it again" },
        { label: "Drop the times from the line", effect: "Each reason keeps only its words; since-when moves to the timeline.", cost: "You lose since-when at a glance" },
      ],
      decision: "D1: Use the secondary text colour for the paused line's times.",
    },
  };

  /* Ticket events, oldest first. kind is a timeline class of the catalog (phase, pause-set,
     pause-cleared, question-asked, question-answered, person, rule, verdict). Runs are drawn from
     runs above, at their start. */
  const events = [
    { at: "2026-10-29T21:40", kind: "phase", to: "Todo", from: "Backlog", head: "Moved to Todo", rest: "from Backlog", actor: "Tony, with Move to…" },
    { at: "2026-10-29T21:40", kind: "pause-set", head: "Paused:", rest: "waiting for TP-1251 to finish", detail: "Its blocked-by link holds it", actor: "Rule: blockers first", pause: "p1" },
    { at: "2026-10-30T15:22", kind: "rule", head: "TP-1251 landed", rest: "as PR #728", actor: "Symphony" },
    { at: "2026-10-30T15:23", kind: "pause-cleared", head: "Pause cleared:", rest: "TP-1251 is done", actor: "Symphony", pause: "p1" },
    { at: "2026-10-30T15:23", kind: "phase", to: "In Progress", from: "Todo", head: "Moved to In Progress", rest: "from Todo", actor: "Symphony" },
    { at: "2026-10-30T16:02", kind: "phase", to: "Code Review", from: "In Progress", head: "Moved to Code Review", rest: "from In Progress", detail: "The push opened PR #741", actor: "Symphony" },
    { at: "2026-10-30T16:11", kind: "verdict", role: "problem", glyph: "problem", head: "Checks failed", rest: "on PR #741: Snapshots", detail: "2 of 14 snapshots differ", actor: "GitHub" },
    { at: "2026-10-30T16:11", kind: "phase", to: "CI Fix", from: "Code Review", head: "Moved to CI Fix", rest: "from Code Review", actor: "Rule: a red check goes to CI Fix" },
    { at: "2026-10-30T16:21", kind: "phase", to: "Code Review", from: "CI Fix", head: "Back to Code Review", rest: "from CI Fix", detail: "Checks pass on the new commit", actor: "Symphony" },
    { at: "2026-10-30T16:36", kind: "person", head: "Note for the next run:", rest: "“Keep the button word Release, not Unblock.”", actor: "Tony", note: "n1" },
    { at: "2026-10-30T16:38", kind: "phase", to: "Rework", from: "Code Review", head: "Sent back to Rework", rest: "by Code Review", detail: "1 finding: a reason without words shows its raw code", actor: "Code Review run 1", finding: "f1" },
    { at: "2026-10-30T16:58", kind: "phase", to: "Code Review", from: "Rework", head: "Moved to Code Review", rest: "from Rework", actor: "Symphony" },
    { at: "2026-10-30T17:12", kind: "phase", to: "QA", from: "Code Review", head: "Moved to QA", rest: "from Code Review", detail: "Approved", actor: "Code Review run 2" },
    { at: "2026-10-30T17:31", kind: "phase", to: "Rework", from: "QA", head: "Sent back to Rework", rest: "by QA", detail: "1 finding, with a screenshot", actor: "QA run 1", finding: "f2" },
    { at: "2026-10-30T17:44", kind: "question-asked", head: "Question asked:", rest: "How should the times on the paused line read in dark mode?", detail: "3 options, one recommended", actor: "Implementation run 3", question: "q1" },
    { at: "2026-10-30T17:44", kind: "pause-set", head: "Paused:", rest: "waiting for your answer", actor: "Rule: a question holds the ticket", pause: "p2" },
    { at: "2026-10-30T18:20", kind: "question-answered", head: "Answered:", rest: "“Use the secondary text colour”", detail: "Recorded as decision D1", actor: "Tony, in the Inbox", question: "q1" },
    { at: "2026-10-30T18:20", kind: "pause-cleared", head: "Pause cleared:", rest: "you answered", actor: "Symphony", pause: "p2" },
    { at: "2026-10-30T18:33", kind: "phase", to: "Code Review", from: "Rework", head: "Moved to Code Review", rest: "from Rework", actor: "Symphony" },
    { at: "2026-10-30T18:46", kind: "phase", to: "QA", from: "Code Review", head: "Moved to QA", rest: "from Code Review", detail: "Approved", actor: "Code Review run 3" },
    { at: "2026-10-30T19:05", kind: "phase", to: "Merging", from: "QA", head: "Moved to Merging", rest: "from QA", detail: "QA passed 3 of 3 steps", actor: "QA run 2" },
    { at: "2026-10-30T19:06", kind: "rule", head: "Auto-merge turned on", rest: "for PR #741", detail: "It merges once main's queue reaches it", actor: "Rule: Merging lands with auto-merge" },
    { at: "2026-10-30T20:41", kind: "rule", head: "Branch updated", rest: "with the newest main", detail: "Rule: keep the branch current while in Merging", actor: "Symphony" },
    { at: "2026-10-30T21:05", kind: "phase", to: "Done", from: "Merging", head: "Merged", rest: "as PR #741", detail: "Commit da402827 on main", actor: "GitHub" },
  ];

  const notes = { n1: { at: "2026-10-30T16:36", by: "Tony", text: "Keep the button word Release, not Unblock.", readBy: "r4", readAt: "2026-10-30T16:39" } };

  const CHECKS = [
    { group: "CI", items: [["Format", "18 s"], ["Compile", "1 min 4 s"], ["Lint", "42 s"], ["Tests", "6 min 12 s"], ["Coverage", "7 min 30 s"], ["Dialyzer", "3 min 8 s"]] },
    { group: "macOS", items: [["Swift build", "5 min 2 s"], ["Swift tests", "3 min 40 s"], ["Snapshots", "2 min 15 s"]] },
    { group: "Pull request", items: [["Body", "4 s"], ["Protected paths", "3 s"]] },
  ];

  /* The moments a prototype can show. Each names the time the page is drawn at, when the person
     last looked, and the live facts that are not events: the run that is running and how far it
     got, the pull request's checks, and what is left of the tokens. */
  const moments = {
    running: {
      label: "Running", now: "2026-10-30T16:47", lastSeen: "2026-10-30T16:20",
      situation: { role: "working", glyph: "working", word: "Working on the tests step", cause: "Implementation run 2 is answering Code Review's finding.", waits: "It hands off to Code Review when it pushes.", since: "2026-10-30T16:39" },
      phase: "Rework",
      live: { run: "r4", step: "tests", upto: "16:47", stream: ["16:49", "16:53"] },
      pr: { number: 741, title: "TP-1244 The paused line on the ticket page", head: "8b03e51", state: "open", checks: "passed", checkedAt: "16:29", note: "Checks passed on the commit the CI fix pushed. The run will push a new one." },
    },
    waiting: {
      label: "Waiting on you", now: "2026-10-30T17:52", lastSeen: "2026-10-30T16:50",
      situation: { role: "you", glyph: "you", word: "Waiting on you", cause: "Implementation run 3 asked how the paused line's times should read.", waits: "Answer below; the next run starts at once.", since: "2026-10-30T17:44" },
      phase: "Rework",
      openQuestion: "q1",
      pr: { number: 741, title: "TP-1244 The paused line on the ticket page", head: "5d2e7a0", state: "open", checks: "passed", checkedAt: "17:05", note: "Checks passed. QA sent it back for one finding." },
    },
    shipped: {
      label: "Shipped", now: "2026-10-30T21:30", lastSeen: "2026-10-30T17:52",
      situation: { role: "done", glyph: "done", word: "Shipped", cause: "Merged as PR #741 at 21:05.", waits: "", since: "2026-10-30T21:05" },
      phase: "Done",
      pr: { number: 741, title: "TP-1244 The paused line on the ticket page", head: "da40282", state: "merged", checks: "passed", checkedAt: "20:58", note: "Merged into main as commit da402827." },
    },
  };

  /* What the situation becomes the moment the person answers the open Question on the page. */
  const afterAnswer = {
    situation: { role: "working", glyph: "working", word: "Starting a run", cause: "Implementation run 4 starts with your answer.", waits: "It applies your pick, then hands off to Code Review.", since: "now" },
  };

  return { ticket: ticket, relations: relations, runs: runs, findings: findings, attachments: attachments, questions: questions, events: events, notes: notes, checks: CHECKS, moments: moments, afterAnswer: afterAnswer, tokenCap: 8 };
})();
