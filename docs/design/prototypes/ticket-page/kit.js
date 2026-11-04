/*
 * What the three ticket page prototypes share: the page controls (moment, width, theme, motion),
 * the view of the ticket drawn from fixtures.js at a moment, the pieces of the page built from the
 * catalog's components, and the interactions every prototype has.
 *
 * A prototype calls PROTO.start({ id, name, idea, render, after }) where render(view, ui) returns
 * the page's HTML. The kit redraws the page when the moment changes or the person answers the
 * Question; everything else (folds, selection, the live run's new lines) changes the page in
 * place, so it animates.
 */
window.PROTO = (function () {
  "use strict";

  const K = window.CATALOG.kit;
  const L = window.TICKET_LIFE;
  const esc = K.esc;
  const icon = K.icon;

  /* ---------- Time ---------- */

  const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const parse = (s) => { const m = /^(\d+)-(\d+)-(\d+)T(\d+):(\d+)/.exec(s); return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]); };
  const hm = (s) => s.slice(11, 16);
  const day = (s) => s.slice(0, 10);
  const dayLabel = (s) => { const d = parse(s); return DAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]; };
  const mins = (a, b) => Math.max(0, Math.round((parse(b) - parse(a)) / 60000));
  const dur = (m) => (m < 1 ? "under a minute" : m < 60 ? m + " min" : Math.floor(m / 60) + " h" + (m % 60 ? " " + (m % 60) + " min" : ""));
  const at = (run, clock) => run.start.slice(0, 11) + clock;
  const tok = (n) => (Math.round(n * 10) / 10).toFixed(1) + "M tokens";

  /* ---------- The view of the ticket at a moment ---------- */

  const VERDICTS = {
    running: { role: "working", word: "Running", glyph: "run-start" },
    passed: { role: "done", word: "Passed", glyph: "done" },
    approved: { role: "done", word: "Approved", glyph: "done" },
    failed: { role: "problem", word: "Failed", glyph: "problem" },
    "sent-back": { role: "you", word: "Sent back", glyph: "undo" },
    asked: { role: "you", word: "Asked you", glyph: "question" },
  };

  function cutRun(run, m) {
    const r = Object.assign({}, run);
    r.live = !!(m.live && m.live.run === run.id);
    r.now = m.now;
    if (!r.live) { r.minutes = mins(r.start, r.end); return r; }
    const upto = m.live.upto;
    let reached = false;
    r.queue = [];
    r.steps = run.steps.map((st) => {
      if (st.id === m.live.step) {
        reached = true;
        r.queue = st.msgs.filter((x) => x.at > upto && m.live.stream.indexOf(x.at) >= 0).map((x) => Object.assign({ step: st.id }, x));
        return Object.assign({}, st, { state: "current", end: null, msgs: st.msgs.filter((x) => x.at <= upto) });
      }
      return reached ? Object.assign({}, st, { state: "pending", start: null, end: null, msgs: [] }) : st;
    });
    r.verdict = "running";
    r.end = null;
    r.minutes = mins(r.start, m.now);
    r.tokens = Math.round(run.tokens * (r.minutes / mins(run.start, run.end)) * 10) / 10;
    r.outcome = "Running: on the " + (run.steps.find((s) => s.id === m.live.step) || {}).name.toLowerCase() + " step";
    return r;
  }

  const ORDER = ["Todo", "In Progress", "Code Review", "QA", "Merging", "Done"];

  function phasePathOf(events, now, role) {
    const moves = events.filter((e) => e.kind === "phase");
    const seen = {};
    const list = [];
    moves.forEach((e, i) => {
      const end = moves[i + 1] ? moves[i + 1].at : e.to === "Done" ? e.at : now;
      if (!seen[e.to]) { seen[e.to] = { name: e.to, visits: 0, minutes: 0 }; list.push(seen[e.to]); }
      seen[e.to].visits += 1;
      seen[e.to].minutes += mins(e.at, end);
    });
    const current = moves.length ? moves[moves.length - 1].to : "Todo";
    const phases = list.map((p) => ({ name: p.name, visits: p.visits, time: p.name === "Done" ? "" : dur(p.minutes) + (p.name === current ? " so far" : ""), state: p.name === current ? "current" : "passed", role: role }));
    ORDER.forEach((name) => { if (!seen[name] && current !== "Done") phases.push({ name: name, visits: 0, state: "later" }); });
    const back = moves.filter((e) => e.to === "Rework").length;
    return { phases: phases, current: current, moves: moves.length, sentBack: back };
  }

  function derive(key, ui) {
    const m = L.moments[key];
    const now = m.now;
    let events = L.events.filter((e) => e.at <= now).map((e, i) => Object.assign({ id: "e" + i }, e));
    const runs = Object.keys(L.runs).map((id) => Object.assign({ id: id }, L.runs[id])).filter((r) => r.start <= now).map((r) => cutRun(r, m));
    let situation = m.situation;
    let openQuestion = m.openQuestion ? Object.assign({ id: m.openQuestion }, L.questions[m.openQuestion]) : null;
    const decisions = Object.keys(L.questions).map((id) => Object.assign({ id: id }, L.questions[id])).filter((q) => q.answered && q.answered <= now);
    if (ui.answered && openQuestion) {
      const q = openQuestion;
      const said = ui.answered.own ? "“" + ui.answered.text + "”" : "“" + q.options[ui.answered.pick].label + "”";
      events = events.concat([
        { id: "x1", at: now, kind: "question-answered", head: "Answered:", rest: said, detail: "Recorded as decision D1", actor: "You, on this page", fresh: true },
        { id: "x2", at: now, kind: "pause-cleared", head: "Pause cleared:", rest: "you answered", actor: "Symphony", fresh: true },
      ]);
      decisions.push(Object.assign({}, q, { answered: now, answerText: said, decision: "D1: " + said.replace(/[“”]/g, "") + "." }));
      situation = L.afterAnswer.situation;
      openQuestion = null;
    }
    const live = runs.find((r) => r.live) || null;
    const since = situation.since === "now" ? now : situation.since;
    const findings = Object.keys(L.findings).map((id) => Object.assign({ id: id }, L.findings[id])).filter((f) => f.at <= now)
      .map((f) => Object.assign(f, { resolved: !!(f.resolvedBy && runs.some((r) => r.id === f.resolvedBy && !r.live)) }));
    const attachments = Object.keys(L.attachments).map((id) => Object.assign({ id: id }, L.attachments[id])).filter((a) => a.at <= now);
    const notes = Object.keys(L.notes).map((id) => Object.assign({ id: id }, L.notes[id])).filter((n) => n.at <= now)
      .map((n) => Object.assign(n, { read: n.readAt <= now }));
    runs.forEach((r) => { r.findings = findings.filter((f) => f.run === r.id); });
    const path = phasePathOf(events, now, situation.role);
    const stage = { code: 0, review: 0, qa: 0 };
    runs.forEach((r) => { stage[r.kind === "Code Review" ? "review" : r.kind === "QA" ? "qa" : "code"] += r.tokens; });
    const items = events.map((e, i) => ({ type: "event", at: e.at, order: i * 2, e: e })).concat(runs.map((r, i) => ({ type: "run", at: r.start, order: i * 2 + 1, r: r })));
    items.sort((a, b) => (a.at === b.at ? b.order - a.order : a.at < b.at ? 1 : -1));
    items.forEach((it) => { it.unseen = it.at > m.lastSeen || (it.type === "run" && it.r.live); it.id = it.type === "run" ? it.r.id : it.e.id; });
    const pausedNow = events.filter((e) => e.kind === "pause-set" && !events.some((c) => c.kind === "pause-cleared" && c.pause === e.pause));
    return {
      key: key, moment: m, now: now, lastSeen: m.lastSeen, ticket: L.ticket, relations: L.relations, checks: L.checks, pr: m.pr,
      situation: Object.assign({}, situation, { age: dur(mins(since, now)) }),
      openQuestion: openQuestion, decisions: decisions, live: live, runs: runs, events: events, items: items, findings: findings,
      attachments: attachments, notes: notes, path: path, pausedNow: pausedNow,
      tokens: { label: "Tokens", code: Math.round(stage.code * 10) / 10, review: Math.round(stage.review * 10) / 10, qa: Math.round(stage.qa * 10) / 10, merge: 0, cap: L.tokenCap, unit: "M tokens" },
      totalMinutes: runs.reduce((a, r) => a + r.minutes, 0),
      unseenCount: items.filter((it) => it.unseen && !(it.type === "run" && it.r.live)).length,
    };
  }

  /* ---------- Pieces of the page, from the catalog ---------- */

  function situation(v, size) {
    const s = v.situation;
    return K.situation({ role: s.role, glyph: s.glyph, word: s.word, cause: s.cause, waits: s.waits, age: s.age, size: size || "regular" });
  }

  function disabled(label, reason, variant, glyph, size) {
    return K.button({ label: label, variant: variant || "secondary", glyph: glyph, size: size, disabled: true, reason: reason, showReason: false }).replace("<button ", '<button data-reason="' + esc(reason) + '" ');
  }

  /* The moves of the ticket. Each is always there; one that cannot act now says why. */
  function actionRail(v, o) {
    o = o || {};
    const moves = [];
    if (v.openQuestion) moves.push(K.button({ label: "Answer", variant: "primary", glyph: "question" }).replace("<button ", '<button data-jump="question" '));
    moves.push(K.button({ label: v.pr.state === "merged" ? "Open Pull Request" : "Open PR #" + v.pr.number, glyph: "pr" }).replace("<button ", '<button data-flash="Opens PR #' + v.pr.number + ' on GitHub (not in a prototype)" '));
    if (o.timeline) moves.push(o.timeline);
    const startReason = v.live ? "A run is already working on it." : v.openQuestion ? "It waits on your answer first." : v.path.current === "Done" ? "It is done." : "";
    moves.push(startReason ? disabled("Start Now", startReason, "secondary", "play") : K.button({ label: "Start Now", glyph: "play" }).replace("<button ", '<button data-flash="Starts a run now (not in a prototype)" '));
    moves.push(v.live ? K.button({ label: "Stop Run…", variant: "destructive", glyph: "stop" }).replace("<button ", '<button data-flash="Asks before it stops the run (not in a prototype)" ') : disabled("Stop Run…", "No run is working.", "destructive", "stop"));
    const items = [["Move to…", ""], ["Force ahead of the queue", ""], ["Restart…", ""], ["Copy Link", "⌘ L"]];
    moves.push('<span class="menu-wrap"><button type="button" class="menu-btn" aria-haspopup="menu" aria-expanded="false" data-menu>More' + icon("chevron-down", "chev") + "</button>" +
      '<ul class="menu" role="menu" hidden>' + items.map((it) => '<li class="menu-item" role="menuitem" tabindex="-1"' + (v.path.current === "Done" && it[0] !== "Copy Link" ? ' aria-disabled="true" data-reason="The ticket is done."' : ' data-flash="' + esc(it[0]) + ' (not in a prototype)"') + ">" + esc(it[0]) + (it[1] ? K.kbd(it[1], true) : "") + "</li>").join("") + "</ul></span>");
    return '<div class="action-rail" role="toolbar" aria-label="Moves">' + moves.join("") + "</div>";
  }

  function identLine(v) {
    const t = v.ticket;
    return '<div class="ident-line"><span class="ident">' + esc(t.ident) + "</span>" + K.chip({ kind: "repo", text: t.repo, interactive: false }) +
      K.chip({ kind: "epic", text: t.epic.title + " · " + t.epic.part, interactive: false }) + K.badge("problem", t.priority, "small", true) + "</div>";
  }

  function header(v, o) {
    o = o || {};
    return '<header class="page-header"><div class="head-main">' + identLine(v) + "<h1>" + esc(v.ticket.title) + "</h1>" +
      (o.noStatus ? "" : '<div class="head-status">' + situation(v, "large") + (o.statusExtra || "") + "</div>") + "</div>" + actionRail(v, o) + "</header>";
  }

  function phasePath(v, o) {
    o = o || {};
    const p = v.path;
    const sum = p.moves + " moves" + (p.sentBack ? " · sent back " + (p.sentBack === 1 ? "once" : p.sentBack === 2 ? "twice" : p.sentBack + " times") : "") + " · " + dur(v.totalMinutes) + " of agent work in " + v.runs.length + " runs";
    return '<div class="path-block">' + K.phasePath({ phases: p.phases.map((ph) => Object.assign({}, ph, { picked: o.picked === ph.name })), interactive: !!o.interactive, compact: !!o.compact }) +
      (o.noSum ? "" : '<span class="phase-path-sum">' + esc(sum) + "</span>") + "</div>";
  }

  function tokens(v) {
    return K.stageBar(Object.assign({ key: v.key }, v.tokens));
  }

  /* The open Question: the options and the own-words field, then Send. */
  function question(v) {
    const q = v.openQuestion;
    if (!q) return "";
    const opts = q.options.map((o, i) => K.option(Object.assign({}, o, { selected: false, key: "q-" + i, hotkey: i + 1 })).replace(/ data-(set|toggle)="[^"]*"/, "").replace("<button ", '<button data-pick="' + i + '" ')).join("");
    const own = K.option({ label: "Answer in my own words…", effect: "Tell the agent what to do instead.", hotkey: q.options.length + 1, key: "q-own" }).replace(/ data-(set|toggle)="[^"]*"/, "").replace("<button ", '<button data-pick="own" ') +
      '<div class="fold own-fold" data-open="false"><div class="fold-inner"><div class="own-words"><div class="input"><textarea rows="3" aria-label="Answer in my own words" placeholder="For example: use the secondary colour, and make the times one step smaller." data-own></textarea></div>' +
      '<p class="hint" style="margin:0">The agent reads this as your answer. Name tickets by their number; they become links.</p></div></div></div>';
    return '<section class="question-block" id="question" data-question aria-label="Question"><div class="q-main">' +
      '<div class="question-callout"><span class="kicker">' + icon("question", "glyph-sm") + "YOUR DECISION" + '<span class="age">asked ' + esc(dur(mins(q.asked, v.now))) + " ago by " + esc(q.by) + "</span></span><h2>" + esc(q.title) + "</h2></div>" +
      '<div class="question-why">' + q.why.map((p) => "<p>" + esc(p) + "</p>").join("") + '<p class="unanswered">' + icon("cost") + "<span><b>If you don't answer:</b> " + esc(q.unanswered) + "</span></p></div>" +
      '<div class="options" role="radiogroup" aria-label="Answers">' + opts + own + "</div></div>" +
      '<div class="question-send"><span class="pick" data-pick-label hidden><span class="t-secondary">Your answer</span><b></b></span><span data-send-reason>' + K.refusal("Pick an answer first.") + "</span>" +
      K.button({ label: "Send Decision", variant: "primary", size: "large", disabled: true, showReason: false }).replace("<button ", '<button data-send data-reason="Pick an answer first." ') + "</div></section>";
  }

  /* Nothing waits on the person: one quiet line, so the place of the Question never jumps. */
  function nothingNeedsYou(v) {
    const said = v.path.current === "Done" ? "Nothing needs you. The ticket is done." : "Nothing needs you. Symphony moves it on by itself.";
    return '<p class="quiet-line role-done">' + icon("good") + "<span>" + esc(said) + "</span></p>";
  }

  /* ----- Timeline ----- */

  const EVENT_KINDS = { verdict: { glyph: "problem", role: "problem", word: "Check result" } };

  function eventEntry(it, ui) {
    const e = it.e;
    const k = K.TL[e.kind] || EVENT_KINDS[e.kind] || K.TL.rule;
    const role = e.role || k.role;
    const glyph = e.glyph || k.glyph;
    const extra = (e.finding ? '<span class="detail-link">' + K.badge("problem", "Finding", "small") + " " + esc(L.findings[e.finding].title) + "</span>" : "");
    return '<li class="tl-entry role-' + role + (e.fresh ? " is-new" : "") + '" tabindex="0" role="option" aria-selected="' + (ui.selected === it.id) + '" data-sel="' + esc(it.id) + '" data-filter-kind="' + filterOf(it) + '">' +
      '<span class="time">' + esc(hm(e.at)) + '</span><span class="mark" title="' + esc(k.word) + '">' + icon(glyph) + "</span>" +
      '<span class="what"><span class="head">' + (it.unseen ? '<span class="new-dot" title="New since you last looked"></span>' : "") + "<b>" + esc(e.head) + "</b> " + esc(e.rest || "") + "</span>" +
      (e.detail ? '<span class="detail">' + esc(e.detail) + "</span>" : "") + extra + (e.actor ? '<span class="actor">' + esc(e.actor) + "</span>" : "") + "</span></li>";
  }

  function miniSteps(run) {
    const map = { passed: "passed", failed: "failed", current: "current", asked: "paused", pending: "", stopped: "paused", skipped: "skipped" };
    const at = run.steps.find((s) => s.state === "current" || s.state === "failed" || s.state === "asked");
    return '<span class="steps-mini" role="img" aria-label="Steps: ' + esc(run.steps.map((s) => s.name + ", " + (s.stateWord || s.state)).join("; ")) + '">' + run.steps.map((s) => '<i class="' + (map[s.state] || "") + '"></i>').join("") + "</span>" +
      (at ? '<span class="steps-mini-at role-' + (at.state === "current" ? "working" : at.state === "failed" ? "problem" : "you") + '">' + esc(at.name) + "</span>" : "");
  }

  function stepsOf(run, ui) {
    return run.steps.map((st) => {
      const key = run.id + ":" + st.id;
      const minutes = !st.start ? 0 : st.end ? mins(at(run, st.start), at(run, st.end)) : run.live && st.state === "current" ? mins(at(run, st.start), run.now) : 0;
      const durText = !st.start ? "" : st.state === "current" ? dur(minutes) + " so far" : dur(minutes);
      return { id: key, name: st.name, state: st.state, stateWord: st.stateWord, duration: durText, open: ui.open[key] !== undefined ? ui.open[key] : st.state === "current" || st.state === "asked" || st.state === "failed",
        msgs: st.msgs.map((x, i, all) => ({ time: x.at, kind: x.kind, text: x.text, failed: x.failed, typing: run.live && st.state === "current" && i === all.length - 1 && x.kind === "say" })) };
    });
  }

  let current = null;

  function runMeta(run) {
    return '<p class="run-meta">' + [run.kind + " run", run.model, (run.live ? dur(run.minutes) + " so far" : dur(run.minutes)), tok(run.tokens), run.outcome].map(esc).join(" · ") + "</p>";
  }

  function findingCard(f) {
    const a = f.shot ? L.attachments[f.shot] : null;
    return '<section class="card finding-card"><div class="card-head"><h3>' + K.badge(f.resolved ? "done" : "problem", f.resolved ? "Finding, resolved" : "Finding", "small") + " " + esc(f.title) + "</h3>" +
      '<span class="t-secondary">' + esc(f.by + " at " + hm(f.at)) + "</span></div><p class=\"card-body\">" + esc(f.text) + "</p>" +
      (a ? '<div class="finding-shots">' + attachment(Object.assign({ id: f.shot }, a)) + "</div>" : "") + "</section>";
  }

  function attachment(a) {
    return '<button type="button" class="attachment" data-shot="' + esc(a.id) + '" aria-label="Open screenshot: ' + esc(a.name) + '"><span class="thumb image"><img src="' + esc(a.src) + '" alt="" loading="lazy"></span>' +
      '<span class="name">' + esc(a.name) + '</span><span class="meta">' + esc(a.by + " · " + hm(a.at)) + "</span></button>";
  }

  /* One run: its line, and unfolded, what it did step by step (the transcript, in place). */
  function runBody(run, ui) {
    return runMeta(run) + (run.findings || []).map(findingCard).join("") + K.stepList({ steps: stepsOf(run, ui) });
  }

  function runGroup(it, ui, o) {
    o = o || {};
    const run = it.r;
    const vd = VERDICTS[run.verdict] || VERDICTS.passed;
    const open = ui.open[run.id] !== undefined ? ui.open[run.id] : run.live;
    return '<li class="tl-run" data-filter-kind="runs" data-run-item="' + esc(run.id) + '"><div class="run-group' + (ui.selected === run.id ? " is-selected" : "") + '"><button type="button" class="run-head role-' + vd.role + '" aria-expanded="' + open + '" data-run="' + esc(run.id) + '">' +
      '<span class="time">' + esc(hm(run.start)) + '</span><span class="mark">' + (run.live ? '<span class="dot live role-working"></span>' : icon(vd.glyph)) + "</span>" +
      '<span class="name">' + icon("chevron-right", "disclose") + (it.unseen && !run.live ? '<span class="new-dot" title="New since you last looked"></span>' : "") + "<b>" + esc(run.title) + "</b>" + K.badge(vd.role, vd.word, "small") + miniSteps(run) +
      (o.noTokens ? "" : '<span class="t-secondary">' + esc(tok(run.tokens)) + "</span>") + "</span>" +
      '<span class="dur" title="How long the run took">' + esc(run.live ? dur(run.minutes) + " so far" : dur(run.minutes)) + "</span></button>" +
      K.fold("run-" + run.id, open, '<div class="run-body">' + runBody(run, ui) + "</div>") + "</div></li>";
  }

  function filterOf(it) {
    if (it.type === "run") return "runs";
    const k = it.e.kind;
    return k === "phase" || k === "verdict" ? "phases" : k.indexOf("question") === 0 ? "questions" : k.indexOf("pause") === 0 ? "pauses" : "people";
  }

  const FILTERS = [["all", "Everything"], ["runs", "Runs"], ["phases", "Phase moves"], ["questions", "Questions"], ["pauses", "Pauses"], ["people", "People and rules"]];

  function filterCounts(v) {
    const c = { all: v.items.length };
    v.items.forEach((it) => { const f = filterOf(it); c[f] = (c[f] || 0) + 1; });
    return c;
  }

  function filterChips(v, ui) {
    const c = filterCounts(v);
    return '<div class="tl-filters" role="toolbar" aria-label="Show in the timeline">' + FILTERS.map((f) =>
      '<button type="button" class="chip chip-label" aria-pressed="' + ((ui.filter || "all") === f[0]) + '" data-filter="' + f[0] + '">' + esc(f[1]) + ' <span class="n">' + (c[f[0]] || 0) + "</span></button>").join("") + "</div>";
  }

  function filterIndex(v, ui) {
    const c = filterCounts(v);
    return '<nav class="tl-index" aria-label="Show in the timeline"><h4>Show</h4>' + FILTERS.map((f) =>
      '<button type="button" aria-current="' + ((ui.filter || "all") === f[0]) + '" data-filter="' + f[0] + '"><span>' + esc(f[1]) + '</span><span class="n">' + (c[f[0]] || 0) + "</span></button>").join("") + "</nav>";
  }

  /* The timeline, newest first, a line where the person last looked, a heading per day. */
  function timeline(v, ui, o) {
    o = o || {};
    let html = "";
    let lastDay = "";
    let sinceDone = false;
    const items = o.only ? v.items.filter(o.only) : v.items;
    items.forEach((it) => {
      if (day(it.at) !== lastDay) { lastDay = day(it.at); html += '<li class="tl-day">' + esc(dayLabel(it.at)) + "</li>"; }
      if (!sinceDone && !it.unseen && it.at <= v.lastSeen) {
        sinceDone = true;
        if (items[0] !== it) html += '<li class="tl-since" data-since>Since you last looked, at ' + esc(hm(v.lastSeen)) + "</li>";
      }
      html += it.type === "run" ? (o.runRow ? o.runRow(it) : runGroup(it, ui, o)) : eventEntry(it, ui);
    });
    return '<ol class="timeline" role="listbox" aria-label="Timeline, newest first"' + (o.id ? ' id="' + o.id + '"' : "") + ">" + html + "</ol>";
  }

  /* A run as one selectable row of the history (prototype B shows its detail beside it). */
  function runRow(it, ui) {
    const run = it.r;
    const vd = VERDICTS[run.verdict] || VERDICTS.passed;
    return '<li class="tl-entry role-' + vd.role + '" tabindex="0" role="option" aria-selected="' + (ui.selected === run.id) + '" data-sel="' + esc(run.id) + '" data-filter-kind="runs">' +
      '<span class="time">' + esc(hm(run.start)) + '</span><span class="mark">' + (run.live ? '<span class="dot live role-working"></span>' : icon(vd.glyph)) + "</span>" +
      '<span class="what"><span class="head">' + (it.unseen && !run.live ? '<span class="new-dot"></span>' : "") + "<b>" + esc(run.title) + "</b> " + K.badge(vd.role, vd.word, "small") + "</span>" +
      '<span class="detail">' + miniSteps(run) + " " + esc(run.live ? dur(run.minutes) + " so far" : dur(run.minutes)) + " · " + esc(tok(run.tokens)) + "</span></span></li>";
  }

  /* ----- Facts ----- */

  function prPanel(v, o) {
    o = o || {};
    const pr = v.pr;
    const all = v.checks.reduce((a, g) => a + g.items.length, 0);
    const b = pr.state === "merged" ? K.badge("done", "Merged", "small") : K.badge("done", "Checks passing", "small");
    const groups = v.checks.map((g) => '<div class="check-group"><h5>' + esc(g.group) + '</h5><ol class="check-list">' + g.items.map((j) =>
      '<li><button type="button" class="check-row passed role-done" data-flash="Opens the ' + esc(j[0]) + ' check on GitHub (not in a prototype)"><span class="mark">' + icon("done") + '</span><span class="check-name">' + esc(j[0]) + '</span><span class="check-state">Passed</span><span class="num">' + esc(j[1]) + "</span></button></li>").join("") + "</ol></div>").join("");
    const checks = '<div class="panel-sub"><h4>Checks<span class="t-secondary">' + all + " passed · at " + esc(pr.checkedAt) + "</span></h4>" +
      (o.foldChecks ? '<button type="button" class="btn btn-quiet sz-sm fold-toggle" aria-expanded="false" data-fold-toggle="checks-' + v.key + '">' + icon("chevron-right", "disclose") + "Show every check</button>" + K.fold("checks-" + v.key, false, groups) : groups) + "</div>";
    return '<section class="facts-group"><h3 class="zone-title">Pull request</h3><div class="panel pr-panel"><a class="pr-line" href="#" data-flash="Opens PR #' + pr.number + ' on GitHub (not in a prototype)">' + icon("pr", "pr-glyph") +
      '<span class="pr-name">PR #' + pr.number + '</span><span class="t-secondary t-mono">' + esc(pr.head) + "</span>" + b + "</a>" +
      '<p class="empty-line">' + esc(pr.note) + "</p>" + checks + "</div></section>";
  }

  function relRow(t, note) {
    return '<li><button type="button" class="rel-row" data-flash="Opens ' + esc(t.ident) + ' (not in a prototype)"><span class="dot role-' + esc(t.role) + '"></span><span class="rel-ident">' + esc(t.ident) + "</span>" +
      '<span class="rel-title">' + esc(t.title) + (note ? '<span class="rel-note">' + esc(note) + "</span>" : "") + "</span>" + K.badge(t.role, t.state, "small") + icon("chevron-right", "rel-go") + "</button></li>";
  }

  function connected(v) {
    const t = v.ticket;
    const r = v.relations;
    const done = v.path.current === "Done";
    const epicDone = t.epic.done + (done ? 1 : 0);
    const segs = [];
    for (let i = 0; i < t.epic.total; i++) segs.push('<span class="seg ' + (i < epicDone ? "role-done" : i === epicDone && !done ? "role-working" : "role-idle") + '"></span>');
    const blocker = r.blockedBy.map((b) => relRow(b.resolvedAt <= v.now ? b : Object.assign({}, b, { state: "Code Review", role: "working" }), b.resolvedAt <= v.now ? b.note : "Must land first")).join("");
    const holds = r.blocks.map((b) => relRow(done ? Object.assign({}, b, { state: "Todo", role: "idle" }) : b, done ? "Can start now" : b.note)).join("");
    return '<section class="facts-group"><h3 class="zone-title">Connected</h3><div class="panel connected-panel">' +
      '<div class="panel-sub"><h4>Epic</h4><button type="button" class="epic-head" data-flash="Opens the epic (not in a prototype)"><span class="epic-ident">' + esc(t.epic.part) + '</span><span class="epic-title">' + esc(t.epic.title) + "</span>" + icon("chevron-right", "rel-go") + "</button>" +
      '<div class="epic-progress"><div class="epic-track" role="img" aria-label="' + epicDone + " of " + t.epic.total + ' done">' + segs.join("") + '</div><span class="t-secondary">' + epicDone + " of " + t.epic.total + " done</span></div></div>" +
      '<div class="panel-sub"><h4>Waiting on</h4><ol class="rel-list">' + blocker + '</ol><p class="empty-line">' + (r.blockedBy.every((b) => b.resolvedAt <= v.now) ? "Nothing holds it up now." : "") + "</p></div>" +
      '<div class="panel-sub"><h4>Holding up</h4><ol class="rel-list">' + holds + "</ol></div></div></section>";
  }

  function notePanel(v) {
    const n = v.notes[v.notes.length - 1];
    const done = v.path.current === "Done";
    const earlier = n ? '<div class="note-now">' + icon("note") + "<div><p>“" + esc(n.text) + "”</p><span class=\"t-secondary\">" + esc(n.by + " at " + hm(n.at) + (n.read ? " · read by " + L.runs[n.readBy].title + " at " + hm(n.readAt) : " · the next run reads it")) + "</span></div></div>" : "";
    const field = done ? '<p class="empty-line">The ticket is done: no run will read a new note.</p>' :
      '<div class="field"><div class="input"><textarea rows="2" aria-label="Note for the next run" placeholder="What the next run should know. It reads this before it starts." data-note></textarea></div></div>' +
      '<div class="note-foot">' + K.button({ label: "Save Note", size: "small", disabled: true, showReason: false }).replace("<button ", '<button data-note-save data-reason="Write a note first." ') + "</div>";
    return '<section class="facts-group"><h3 class="zone-title">Note for the next run</h3><div class="panel note-panel">' + earlier + field + "</div></section>";
  }

  function decisions(v) {
    const body = v.decisions.length ? '<ol class="decision-list">' + v.decisions.map((q) => '<li class="role-done">' + icon("answered") + "<div><b>" + esc(q.decision) + "</b><span class=\"t-secondary\">" + esc(q.title) + " · " + esc(q.answeredBy || "You") + " at " + esc(hm(q.answered)) + "</span></div></li>").join("") + "</ol>" :
      '<p class="empty-line">None yet. Your answers to its questions are kept here.</p>';
    return '<section class="facts-group"><h3 class="zone-title">Decisions</h3><div class="panel">' + body + "</div></section>";
  }

  function details(v) {
    const t = v.ticket;
    const ws = v.path.current === "Done" ? '<span class="t-secondary">Removed after the merge</span>' : '<span class="t-mono path-text">' + esc(t.workspace) + '</span><button type="button" class="icon-btn sz-sm" aria-label="Copy the path" title="Copy the path" data-flash="Path copied">' + icon("link") + "</button>";
    return '<section class="facts-group"><h3 class="zone-title">Details</h3><div class="panel">' + K.kv([
      ["Priority", K.badge("problem", t.priority, "small", true), true],
      ["Labels", t.labels.map((l) => K.chip({ kind: "label", text: l, role: "accent", interactive: false })).join(""), true],
      ["Repo", K.chip({ kind: "repo", text: t.repo, interactive: false }), true],
      ["Workspace", ws, true],
    ]) + "</div></section>";
  }

  function brief(v) {
    const t = v.ticket;
    return '<section class="facts-group"><h3 class="zone-title">The brief</h3><div class="panel brief-panel"><p>' + esc(t.brief) + "</p><h4>What a person walks through</h4><ol>" + t.walkthrough.map((s) => "<li>" + esc(s) + "</li>").join("") + "</ol></div></section>";
  }

  function attachments(v) {
    const body = v.attachments.length ? '<div class="attachments">' + v.attachments.map(attachment).join("") + "</div>" : '<p class="empty-line">No screenshots yet. QA attaches them here.</p>';
    return '<section class="facts-group"><h3 class="zone-title">Screenshots</h3><div class="panel">' + body + "</div></section>";
  }

  function whereItStands(v, o) {
    o = o || {};
    return '<section class="facts-group"><h3 class="zone-title">Where it has been</h3><div class="panel">' + phasePath(v, o) + tokens(v) + "</div></section>";
  }

  /* What runs now: the run's steps with the current one unfolded and live. */
  function runNowPanel(v, ui, o) {
    o = o || {};
    const r = v.live;
    if (!r) {
      const why = v.openQuestion ? "The next run starts the moment you answer." : v.path.current === "Done" ? "The ticket is done; nothing will run on it again." : "A run starts by itself when a slot frees.";
      return '<div class="empty run-empty">' + icon("run-end", "glyph-xl") + "<h3>Nothing runs now</h3><p>" + esc(why) + "</p></div>";
    }
    return '<div class="run-now"><div class="run-now-head"><span class="dot live role-working"></span><b>' + esc(r.title) + "</b>" + K.badge("working", "Running", "small") + '<span class="t-secondary">' + esc(r.model + " · " + dur(r.minutes) + " so far · " + tok(r.tokens)) + "</span></div>" +
      (o.strip ? '<div class="run-now-strip">' + miniSteps(r) + "</div>" : "") + K.stepList({ steps: stepsOf(r, ui) }) + "</div>";
  }

  function sinceList(v, ui, o) {
    o = o || {};
    const items = v.items.filter((it) => it.unseen && !(it.type === "run" && it.r.live));
    if (!items.length) return '<p class="empty-line">Nothing new since you last looked.</p>';
    return '<ol class="timeline since-list">' + items.slice(0, o.max || 99).map((it) => it.type === "run" ? runRow(it, ui).replace('data-sel="', 'data-open-in-timeline="' + it.id + '" data-sel="') : eventEntry(it, ui).replace('data-sel="', 'data-open-in-timeline="' + it.id + '" data-sel="')).join("") + "</ol>";
  }

  /* ---------- Page controls ---------- */

  const PROTOS = [["a", "A · Story"], ["b", "B · Stage"], ["c", "C · Desk"]];

  function readHash() {
    const o = { moment: "waiting", width: "laptop", theme: "system", fit: "on", motion: "full" };
    location.hash.replace(/^#/, "").split("&").forEach((kv) => { const p = kv.split("="); if (p[0] && p[1] && o[p[0]] !== undefined) o[p[0]] = decodeURIComponent(p[1]); });
    return o;
  }

  function seg(name, label, opts, value) {
    const i = Math.max(0, opts.findIndex((o) => o[0] === value));
    return '<div class="bar-tool"><span class="bar-label">' + esc(label) + '</span><div class="segmented sz-sm" role="radiogroup" aria-label="' + esc(label) + '" style="--n:' + opts.length + ";--i:" + i + '" data-pref="' + name + '"><span class="seg-thumb" aria-hidden="true"></span>' +
      opts.map((o) => '<button type="button" role="radio" class="segment" aria-checked="' + (o[0] === value) + '" data-value="' + o[0] + '"' + (o[2] ? ' title="' + esc(o[2]) + '"' : "") + ">" + esc(o[1]) + "</button>").join("") + "</div></div>";
  }

  function bar(cfg, prefs) {
    return '<header class="proto-bar ds sz-sm" role="toolbar" aria-label="Prototype controls">' +
      '<div class="bar-id"><span class="bar-mark" aria-hidden="true"></span><span><b>' + esc(cfg.name) + "</b><span>" + esc(cfg.idea) + "</span></span></div>" +
      '<nav class="bar-protos" aria-label="Prototypes">' + PROTOS.map((p) => '<a href="' + p[0] + '.html" data-proto="' + p[0] + '"' + (p[0] === cfg.id ? ' aria-current="page"' : "") + ">" + esc(p[1]) + "</a>").join("") + "</nav>" +
      '<span class="bar-sep"></span>' +
      seg("moment", "Moment", [["running", "Running", "16:47, a run on its tests step"], ["waiting", "Waiting on you", "17:52, a question is open"], ["shipped", "Shipped", "21:30, merged"]], prefs.moment) +
      seg("width", "Width", [["laptop", "Laptop", "1440 × 900 window, content 1180 pt"], ["desktop", "Desktop", "1440p display, content 2200 pt"]], prefs.width) +
      seg("theme", "Theme", [["system", "System"], ["light", "Light"], ["dark", "Dark"]], prefs.theme) +
      '<button type="button" class="bar-switch" role="switch" aria-checked="' + (prefs.fit === "on") + '" data-switch="fit" title="Scale the page down to fit this window; off shows it at its real size">' + '<span class="knob" aria-hidden="true"></span>Fit</button>' +
      '<button type="button" class="bar-switch" role="switch" aria-checked="' + (prefs.motion === "reduce") + '" data-switch="motion" title="Show the page as it moves with Reduce Motion on">' + '<span class="knob" aria-hidden="true"></span>Reduce motion</button>' +
      "</header>";
  }

  /* ---------- Running the page ---------- */

  function start(cfg) {
    const prefs = readHash();
    const ui = { open: {}, selected: null, filter: "all", answered: null, pick: null };
    document.body.innerHTML = bar(cfg, prefs) + '<div class="proto-canvas" id="canvas"><div class="proto-viewport" id="viewport"><div class="ds proto-page" id="page"></div></div></div><div id="flash" class="proto-flash" role="status" aria-live="polite"></div>';
    document.title = cfg.name + " · Ticket page prototype";
    current = { cfg: cfg, prefs: prefs, ui: ui, view: null };
    applyPrefs();
    draw();
    bind();
    window.addEventListener("resize", fit);
  }

  function writeHash() {
    const p = current.prefs;
    const h = "moment=" + p.moment + "&width=" + p.width + "&theme=" + p.theme + "&fit=" + p.fit + "&motion=" + p.motion;
    history.replaceState(null, "", "#" + h);
    document.querySelectorAll("[data-proto]").forEach((a) => { a.href = a.dataset.proto + ".html#" + h; });
  }

  function applyPrefs() {
    const p = current.prefs;
    const root = document.documentElement;
    if (p.theme === "system") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", p.theme);
    root.classList.toggle("reduce-motion", p.motion === "reduce");
    const vp = document.getElementById("viewport");
    vp.style.width = (p.width === "desktop" ? 2200 : 1180) + "px";
    vp.dataset.width = p.width;
    document.querySelectorAll("[data-pref]").forEach((g) => {
      const btns = Array.prototype.slice.call(g.querySelectorAll("[data-value]"));
      const i = Math.max(0, btns.findIndex((b) => b.dataset.value === p[g.dataset.pref]));
      g.style.setProperty("--i", i);
      btns.forEach((b, j) => b.setAttribute("aria-checked", String(j === i)));
    });
    document.querySelectorAll("[data-switch]").forEach((s) => s.setAttribute("aria-checked", String(s.dataset.switch === "fit" ? p.fit === "on" : p.motion === "reduce")));
    writeHash();
    fit();
  }

  function fit() {
    const vp = document.getElementById("viewport");
    if (!vp) return;
    const w = current.prefs.width === "desktop" ? 2200 : 1180;
    const avail = document.getElementById("canvas").clientWidth - 32;
    const z = current.prefs.fit === "on" ? Math.min(1, avail / w) : 1;
    vp.style.zoom = String(z);
    vp.dataset.scale = Math.round(z * 100) + " %";
  }

  let timer = null;

  function draw(o) {
    o = o || {};
    const view = derive(current.prefs.moment, current.ui);
    current.view = view;
    const page = document.getElementById("page");
    page.innerHTML = current.cfg.render(view, current.ui);
    applyFilter();
    if (current.cfg.after) current.cfg.after(page, view, current.ui, o);
    clearInterval(timer);
    if (view.live && view.live.queue.length) timer = setInterval(tick, 3200);
  }

  /* The live run: its next line arrives, as it would from the server. */
  function tick() {
    const run = current.view.live;
    const next = run && run.queue.shift();
    if (!next) { clearInterval(timer); return; }
    run.steps.find((s) => s.id === next.step).msgs.push(next);
    document.querySelectorAll('[data-step="' + run.id + ":" + next.step + '"]').forEach((head) => {
      const list = head.parentNode.querySelector(".sl-msgs");
      if (!list) return;
      list.querySelectorAll(".typing").forEach((x) => x.classList.remove("typing"));
      const li = document.createElement("li");
      li.className = "sl-msg " + next.kind + " is-new" + (next.kind === "say" ? " typing" : "");
      li.innerHTML = '<span class="time">' + esc(next.at) + '</span><span class="kind">' + icon({ say: "say", tool: "log", result: "arrow" }[next.kind]) + '</span><span class="text">' + esc(next.text) + "</span>";
      list.appendChild(li);
    });
    if (current.cfg.onTick) current.cfg.onTick(next);
  }

  function flash(text) {
    const f = document.getElementById("flash");
    f.innerHTML = '<div class="toast ds">' + icon("info") + '<span class="msg">' + esc(text) + "</span></div>";
    clearTimeout(flash.t);
    flash.t = setTimeout(() => { f.innerHTML = ""; }, 2600);
  }

  function refuse(el) {
    const reason = el.dataset.reason || el.getAttribute("title");
    if (!reason) return;
    const old = el.parentNode.querySelector(".proto-refusal");
    if (old) old.remove();
    const r = document.createElement("span");
    r.className = "proto-refusal";
    r.innerHTML = K.refusal(reason);
    el.insertAdjacentElement("afterend", r);
    const left = Math.max(0, Math.min(el.offsetLeft, el.parentNode.clientWidth - r.offsetWidth));
    r.style.left = left + "px";
    r.style.top = el.offsetTop + el.offsetHeight + 6 + "px";
    setTimeout(() => r.remove(), 2800);
  }

  function toggleFold(btn, foldEl, key) {
    const open = btn.getAttribute("aria-expanded") !== "true";
    btn.setAttribute("aria-expanded", String(open));
    if (foldEl) foldEl.setAttribute("data-open", String(open));
    if (key) current.ui.open[key] = open;
  }

  function applyFilter() {
    const f = current.ui.filter || "all";
    document.querySelectorAll("#page [data-filter-kind]").forEach((el) => { if (!el.closest(".since-list")) el.hidden = f !== "all" && el.dataset.filterKind !== f; });
    document.querySelectorAll("#page .tl-day, #page .tl-since").forEach((el) => { el.hidden = f !== "all" && el.classList.contains("tl-since"); });
    document.querySelectorAll("#page [data-filter]").forEach((b) => {
      if (b.hasAttribute("aria-pressed")) b.setAttribute("aria-pressed", String(b.dataset.filter === f));
      else b.setAttribute("aria-current", String(b.dataset.filter === f));
    });
  }

  function select(id, o) {
    current.ui.selected = current.ui.selected === id && !(o && o.keep) ? null : id;
    document.querySelectorAll("#page [data-sel]").forEach((el) => el.setAttribute("aria-selected", String(el.dataset.sel === current.ui.selected)));
    if (current.cfg.onSelect) current.cfg.onSelect(current.ui.selected, current.view, current.ui);
  }

  /* Show an item of the timeline: unfold its run, select it and bring it into view. */
  function reveal(id) {
    if (current.cfg.onReveal) current.cfg.onReveal(id);
    const runHead = document.querySelector('#page [data-run="' + id + '"]');
    if (runHead && runHead.getAttribute("aria-expanded") !== "true") toggleFold(runHead, runHead.parentNode.querySelector(".fold"), id);
    const el = runHead || document.querySelector('#page .timeline:not(.since-list) [data-sel="' + id + '"]');
    if (current.ui.filter !== "all") { current.ui.filter = "all"; applyFilter(); }
    select(id, { keep: true });
    if (el) {
      el.scrollIntoView({ block: "center", behavior: current.prefs.motion === "reduce" ? "auto" : "smooth" });
      el.classList.remove("proto-ping");
      void el.offsetWidth;
      el.classList.add("proto-ping");
    }
  }

  function pickOption(btn) {
    const block = btn.closest("[data-question]");
    block.querySelectorAll("[data-pick]").forEach((b) => b.setAttribute("aria-checked", String(b === btn)));
    const own = btn.dataset.pick === "own";
    current.ui.pick = own ? "own" : Number(btn.dataset.pick);
    const fold = block.querySelector(".own-fold");
    fold.setAttribute("data-open", String(own));
    if (own) setTimeout(() => block.querySelector("[data-own]").focus({ preventScroll: true }), 50);
    updateSend(block);
  }

  function updateSend(block) {
    const q = current.view.openQuestion;
    const pick = current.ui.pick;
    const text = (block.querySelector("[data-own]").value || "").trim();
    const ready = pick !== null && (pick !== "own" || text.length > 0);
    const send = block.querySelector("[data-send]");
    const reason = pick === "own" && !text ? "Write your answer first." : "Pick an answer first.";
    send.setAttribute("aria-disabled", String(!ready));
    send.dataset.reason = reason;
    block.querySelector("[data-send-reason]").innerHTML = ready ? "" : K.refusal(reason);
    const label = block.querySelector("[data-pick-label]");
    label.hidden = pick === null;
    label.querySelector("b").textContent = pick === null ? "" : pick === "own" ? (text ? "In your own words" : "In your own words (write it)") : q.options[pick].label;
  }

  function send(block) {
    const text = (block.querySelector("[data-own]").value || "").trim();
    current.ui.answered = current.ui.pick === "own" ? { own: true, text: text } : { pick: current.ui.pick };
    block.classList.add("is-leaving");
    const done = () => { draw({ answered: true }); flash("Answer sent. Implementation run 4 starts with it."); };
    if (current.prefs.motion === "reduce") done(); else setTimeout(done, 420);
  }

  function bind() {
    document.addEventListener("click", (e) => {
      const t = e.target;
      const pref = t.closest("[data-pref] [data-value]");
      if (pref) {
        const name = pref.closest("[data-pref]").dataset.pref;
        if (current.prefs[name] === pref.dataset.value) return;
        current.prefs[name] = pref.dataset.value;
        if (name === "moment") { current.ui.answered = null; current.ui.pick = null; current.ui.selected = null; current.ui.bRun = undefined; }
        if (name === "width") current.ui.drawer = undefined;
        applyPrefs();
        if (name === "moment" || name === "width") draw();
        return;
      }
      const sw = t.closest("[data-switch]");
      if (sw) {
        const name = sw.dataset.switch;
        current.prefs[name] = name === "fit" ? (current.prefs.fit === "on" ? "off" : "on") : (current.prefs.motion === "reduce" ? "full" : "reduce");
        applyPrefs();
        return;
      }
      const menuItem = t.closest(".menu-item");
      const menuBtn = t.closest("[data-menu]");
      document.querySelectorAll("#page .menu").forEach((m) => { if (!menuBtn || m !== menuBtn.parentNode.querySelector(".menu")) { m.hidden = true; const b = m.parentNode.querySelector("[data-menu]"); if (b) b.setAttribute("aria-expanded", "false"); } });
      if (menuBtn) { const m = menuBtn.parentNode.querySelector(".menu"); m.hidden = !m.hidden; menuBtn.setAttribute("aria-expanded", String(!m.hidden)); return; }
      const off = t.closest('[aria-disabled="true"]');
      if (off) { if (menuItem) flash(off.dataset.reason || ""); else if (!off.matches("[data-send]")) refuse(off); return; }
      const shot = t.closest("[data-shot]");
      if (shot) { lightbox(shot.dataset.shot); return; }
      if (t.closest("[data-lightbox-close]")) { closeLightbox(); return; }
      const fl = t.closest("[data-flash]");
      if (fl) { e.preventDefault(); flash(fl.dataset.flash); return; }
      const runHead = t.closest("[data-run]");
      if (runHead) { toggleFold(runHead, runHead.parentNode.querySelector(".fold"), runHead.dataset.run); return; }
      const stepHead = t.closest(".sl-head[data-step]");
      if (stepHead) { toggleFold(stepHead, stepHead.parentNode.querySelector(".fold"), stepHead.dataset.step); return; }
      const ft = t.closest("[data-fold-toggle]");
      if (ft) { toggleFold(ft, document.querySelector('[data-anim="fold-' + ft.dataset.foldToggle + '"]')); ft.lastChild.textContent = ft.getAttribute("aria-expanded") === "true" ? "Hide the checks" : "Show every check"; return; }
      const filter = t.closest("[data-filter]");
      if (filter) { current.ui.filter = filter.dataset.filter; applyFilter(); return; }
      const pick = t.closest("[data-pick]");
      if (pick) { pickOption(pick); return; }
      const sendBtn = t.closest("[data-send]");
      if (sendBtn) { send(sendBtn.closest("[data-question]")); return; }
      const jump = t.closest("[data-jump]");
      if (jump) { const el = document.getElementById(jump.dataset.jump); if (el) { el.scrollIntoView({ block: "start", behavior: current.prefs.motion === "reduce" ? "auto" : "smooth" }); el.classList.remove("proto-ping"); void el.offsetWidth; el.classList.add("proto-ping"); } return; }
      const openIn = t.closest("[data-open-in-timeline]");
      if (openIn) { reveal(openIn.dataset.openInTimeline); return; }
      const sel = t.closest("[data-sel]");
      if (sel) { select(sel.dataset.sel); return; }
      if (current.cfg.onClick) current.cfg.onClick(e, current.view, current.ui);
    });
    document.addEventListener("input", (e) => {
      if (e.target.matches("[data-own]")) updateSend(e.target.closest("[data-question]"));
      if (e.target.matches("[data-note]")) {
        const b = document.querySelector("[data-note-save]");
        const empty = !e.target.value.trim();
        b.setAttribute("aria-disabled", String(empty));
        b.dataset.flash = "Saved. The next run reads it before it starts.";
        if (empty) delete b.dataset.flash;
      }
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { closeLightbox(); document.querySelectorAll("#page .menu").forEach((m) => { m.hidden = true; }); if (current.cfg.onEscape) current.cfg.onEscape(); return; }
      const typing = e.target.matches("textarea, input");
      if (typing) return;
      const block = document.querySelector("#page [data-question]");
      if (block && /^[1-9]$/.test(e.key)) {
        const btn = block.querySelectorAll("[data-pick]")[Number(e.key) - 1];
        if (btn) { pickOption(btn); btn.focus({ preventScroll: true }); }
        return;
      }
      if ((e.key === "Enter" || e.key === " ") && e.target.matches("[data-sel]")) { e.preventDefault(); select(e.target.dataset.sel); return; }
      if ((e.key === "ArrowDown" || e.key === "ArrowUp") && e.target.matches("[data-sel]")) {
        e.preventDefault();
        const all = Array.prototype.slice.call(e.target.closest("ol, ul, div").querySelectorAll("[data-sel]")).filter((x) => !x.hidden && x.offsetParent);
        const i = all.indexOf(e.target) + (e.key === "ArrowDown" ? 1 : -1);
        if (all[i]) { all[i].focus(); select(all[i].dataset.sel, { keep: true }); }
      }
    });
  }

  function lightbox(id) {
    const a = L.attachments[id];
    const box = document.createElement("div");
    box.className = "proto-lightbox ds";
    box.innerHTML = '<div class="sheet-scrim" data-lightbox-close><figure class="sheet shot-sheet" role="dialog" aria-label="' + esc(a.name) + '"><div class="sheet-head"><h2>' + esc(a.name) + '</h2><p class="sub">' + esc(a.by + " at " + hm(a.at)) + '</p><button type="button" class="icon-btn" aria-label="Close" title="Close (Esc)" data-lightbox-close>' + icon("close") + "</button></div>" +
      '<div class="sheet-body"><img src="' + esc(a.src) + '" alt="' + esc(a.name) + '"></div></figure></div>';
    box.querySelector("figure").addEventListener("click", (e) => { if (!e.target.closest("[data-lightbox-close]")) e.stopPropagation(); });
    document.body.appendChild(box);
  }

  function closeLightbox() {
    document.querySelectorAll(".proto-lightbox").forEach((b) => b.remove());
  }

  return {
    start: start, draw: draw, derive: derive, state: () => current, reveal: reveal, select: select, flash: flash, K: K, L: L, esc: esc, icon: icon, hm: hm, dur: dur, mins: mins, tok: tok,
    parts: { header: header, identLine: identLine, actionRail: actionRail, situation: situation, phasePath: phasePath, tokens: tokens, question: question, nothingNeedsYou: nothingNeedsYou,
      timeline: timeline, runGroup: runGroup, runRow: runRow, runBody: runBody, runMeta: runMeta, miniSteps: miniSteps, stepsOf: stepsOf, eventEntry: eventEntry, filterChips: filterChips, filterIndex: filterIndex,
      prPanel: prPanel, connected: connected, notePanel: notePanel, decisions: decisions, details: details, brief: brief, attachments: attachments, attachment: attachment, findingCard: findingCard,
      whereItStands: whereItStands, runNowPanel: runNowPanel, sinceList: sinceList, VERDICTS: VERDICTS },
  };
})();
