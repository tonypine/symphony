/*
 * The ticket page prototype: the catalog's approved Page layout (TP-1382, Sections › Page layout)
 * drawn with the life of one real ticket (fixtures.js) at a moment of its life.
 *
 * The page keeps the catalog's structure and markup, zone by zone: the header across the page; on a
 * laptop the decisions line, then the lifecycle on top of the timeline, with the facts rail beside
 * them and the decisions in a side sheet; on a desktop the decisions as a column on the far right.
 * Every class is the catalog's (components.css); page.css adds only the frame around the page and the
 * few pieces the catalog's story leaves out (a run's transcript, a finding, the note field).
 *
 * The page is redrawn when the moment or the width changes and when the person answers the
 * Question; everything else (folds, selection, the menu, the sheet, the live run's new lines)
 * changes the page in place, so it animates.
 */
(function () {
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
  const mins = (a, b) => Math.max(0, Math.round((parse(b) - parse(a)) / 60000));
  const dur = (m) => (m < 1 ? "under a minute" : m < 60 ? m + " min" : Math.floor(m / 60) + " h" + (m % 60 ? " " + (m % 60) + " min" : ""));
  const at = (run, clock) => run.start.slice(0, 11) + clock;
  const tok = (n) => (Math.round(n * 10) / 10).toFixed(1) + "M tokens";
  const ordinal = (n) => n + (n % 10 === 1 && n !== 11 ? "st" : n % 10 === 2 && n !== 12 ? "nd" : n % 10 === 3 && n !== 13 ? "rd" : "th");
  const dayLabel = (s, now) => {
    const diff = Math.round((parse(day(now) + "T00:00") - parse(day(s) + "T00:00")) / 86400000);
    if (diff === 0) return "Today";
    if (diff === 1) return "Yesterday";
    const d = parse(s);
    return DAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()];
  };

  /* ---------- The ticket at a moment ---------- */

  const VERDICTS = {
    running: { role: "working", word: "Running", glyph: "run-start" },
    passed: { role: "done", word: "Passed", glyph: "done" },
    approved: { role: "done", word: "Approved", glyph: "done" },
    failed: { role: "problem", word: "Failed", glyph: "problem" },
    "sent-back": { role: "you", word: "Sent back", glyph: "undo" },
    asked: { role: "you", word: "Asked you", glyph: "question" },
  };

  /* A run as it stood at the moment: the live run is cut at its current step. */
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
    r.outcome = "On the " + (run.steps.find((s) => s.id === m.live.step) || {}).name.toLowerCase() + " step";
    return r;
  }

  /* The ticket's stages (the catalog's lifecycle), from its phase moves. */
  const STAGE_OF = { "In Progress": "coding", Rework: "coding", "CI Fix": "coding", "Code Review": "review", QA: "qa", Merging: "merging", Done: "done" };
  const STAGE_NAME = { coding: "Coding", review: "Code Review", qa: "QA", merging: "Merging", done: "Done" };
  const STAGE_ORDER = ["coding", "review", "qa", "merging", "done"];

  function lifecycleOf(events, now, situation) {
    const moves = events.filter((e) => e.kind === "phase");
    const stages = {};
    STAGE_ORDER.forEach((k) => { stages[k] = { visits: 0, minutes: 0, lastExit: null }; });
    let prev = null;
    moves.forEach((e, i) => {
      const k = STAGE_OF[e.to];
      if (prev && prev !== k && stages[prev]) stages[prev].lastExit = k || "todo";
      if (k && k !== prev) stages[k].visits += 1;
      if (k) stages[k].minutes += mins(e.at, moves[i + 1] ? moves[i + 1].at : k === "done" ? e.at : now);
      prev = k;
    });
    const current = prev || "todo";
    const last = moves[moves.length - 1];
    const state = {};
    STAGE_ORDER.forEach((k) => {
      const s = stages[k];
      const visits = s.visits > 1 ? s.visits + " times · " : "";
      if (k === current) {
        state[k] = k === "done" ? "passed" : situation.role === "you" ? "paused" : "current";
        state[k + "Note"] = k === "done" ? "at " + hm(last.at) : visits + dur(s.minutes) + " so far";
      } else if (s.visits) {
        const back = STAGE_ORDER.indexOf(s.lastExit) >= 0 && STAGE_ORDER.indexOf(s.lastExit) < STAGE_ORDER.indexOf(k);
        state[k] = back ? "returned" : "passed";
        state[k + "Note"] = visits + dur(s.minutes);
      } else {
        state[k] = "pending";
      }
    });
    const sentBack = moves.filter((e) => e.to === "Rework").length;
    let where;
    if (current === "done") where = "Done: " + situation.cause.charAt(0).toLowerCase() + situation.cause.slice(1).replace(/\.$/, "");
    else {
      const v = stages[current] ? stages[current].visits : 0;
      where = "In " + (STAGE_NAME[current] || "Todo") + (v > 1 ? ", the " + ordinal(v) + " time" : "");
      if (last && current === "coding" && (last.from === "Code Review" || last.from === "QA")) where += ": " + last.from + " sent it back";
      if (situation.role === "you") where += ", and it waits on your answer";
    }
    return { state: state, current: current, where: where, sentBack: sentBack, moves: moves.length };
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
      decisions.push(Object.assign({}, q, { answered: now, answeredBy: "You, on this page", decision: "D1: " + said.replace(/[“”]/g, "") + "." }));
      situation = L.afterAnswer.situation;
      openQuestion = null;
    }
    const live = runs.find((r) => r.live) || null;
    const since = situation.since === "now" ? now : situation.since;
    const findings = Object.keys(L.findings).map((id) => Object.assign({ id: id }, L.findings[id])).filter((f) => f.at <= now)
      .map((f) => Object.assign(f, { resolved: !!(f.resolvedBy && runs.some((r) => r.id === f.resolvedBy && !r.live)) }));
    const notes = Object.keys(L.notes).map((id) => Object.assign({ id: id }, L.notes[id])).filter((n) => n.at <= now).map((n) => Object.assign(n, { read: n.readAt <= now }));
    runs.forEach((r) => { r.findings = findings.filter((f) => f.run === r.id); });
    const stage = { code: 0, review: 0, qa: 0 };
    runs.forEach((r) => { stage[r.kind === "Code Review" ? "review" : r.kind === "QA" ? "qa" : "code"] += r.tokens; });
    const round = (n) => Math.round(n * 10) / 10;
    const items = events.map((e, i) => ({ type: "event", at: e.at, order: i * 2, e: e })).concat(runs.map((r, i) => ({ type: "run", at: r.start, order: i * 2 + 1, r: r })));
    items.sort((a, b) => (a.at === b.at ? b.order - a.order : a.at < b.at ? 1 : -1));
    items.forEach((it) => { it.unseen = it.at > m.lastSeen || (it.type === "run" && it.r.live); it.id = it.type === "run" ? it.r.id : it.e.id; });
    const s = Object.assign({}, situation, { age: dur(mins(since, now)) });
    return {
      key: key, moment: m, now: now, lastSeen: m.lastSeen, ticket: L.ticket, relations: L.relations, checks: L.checks, pr: m.pr,
      situation: s, openQuestion: openQuestion, decisions: decisions, live: live, runs: runs, events: events, items: items, notes: notes,
      life: lifecycleOf(events, now, s),
      tokens: { label: "Tokens", code: round(stage.code), review: round(stage.review), qa: round(stage.qa), merge: 0, cap: L.tokenCap, unit: "M tokens" },
      totalMinutes: runs.reduce((a, r) => a + r.minutes, 0),
      unseenCount: items.filter((it) => it.unseen && !(it.type === "run" && it.r.live)).length,
    };
  }

  /* ---------- The page, zone by zone (the catalog's Page layout) ---------- */

  const btn = (p, attrs) => K.button(p).replace("<button ", "<button " + (attrs || "") + " ");
  const later = (what) => 'data-flash="' + esc(what) + ' (not in a prototype)"';

  /* The moves, in the catalog's order: the expected one first and primary, then the others, More for
     the rest. A disabled move stays in its place and says why under it. */
  function actionRail(v) {
    const moves = [];
    const done = v.life.current === "done";
    if (v.situation.role === "working" && !done) moves.push(K.button({ label: "Approve and Merge…", variant: "primary", disabled: true, reason: v.live ? "A run is still working on it." : "Code Review has not approved it yet." }));
    moves.push(btn({ label: "Open Pull Request", variant: "secondary", glyph: "pr" }, later("Opens PR #" + v.pr.number + " on GitHub")));
    moves.push(done ? K.button({ label: "Force", variant: "secondary", glyph: "forced", disabled: true, reason: "It is done." }) : btn({ label: "Force", variant: "secondary", glyph: "forced" }, later("Pushes it ahead of the queue")));
    moves.push('<span class="only-wide rail-sep" aria-hidden="true"></span>');
    moves.push('<span class="only-wide">' + (v.live ? btn({ label: "Stop Run…", variant: "destructive" }, later("Asks before it stops the run")) : K.button({ label: "Stop Run…", variant: "destructive", disabled: true, reason: "No run is working." })) + "</span>");
    const items = [["Move to…", ""], ["Restart…", ""], ["Copy Link", "⌘ L"], ["sep"], ["Stop Run…", "", "destructive only-narrow"]];
    const menu = '<ul class="menu" role="menu" hidden>' + items.map((it) => it[0] === "sep" ? '<li class="menu-sep only-narrow" role="separator"></li>' :
      '<li class="menu-item' + (it[2] ? " " + it[2] : "") + '" role="menuitem" tabindex="-1"' + ((it[0] === "Stop Run…" && !v.live) || (done && it[0] !== "Copy Link") ? ' aria-disabled="true" title="' + (done ? "It is done." : "No run is working.") + '"' : " " + later(it[0])) + ">" + esc(it[0]) + (it[1] ? K.kbd(it[1], true) : "") + "</li>").join("") + "</ul>";
    moves.push('<span class="menu-wrap"><button type="button" class="menu-btn" aria-haspopup="menu" aria-expanded="false" data-menu>More' + icon("chevron-down", "chev") + "</button>" + menu + "</span>");
    return '<div class="action-rail" role="toolbar" aria-label="Moves">' + moves.join("") + "</div>";
  }

  function pageHeader(v) {
    const t = v.ticket;
    const s = v.situation;
    return '<header class="page-header"><div class="head-main"><div class="ident-line"><span class="ident">' + esc(t.ident) + "</span>" +
      K.chip({ kind: "repo", text: t.repo, interactive: false }) + K.chip({ kind: "epic", text: t.epic.title, interactive: false }) + "</div>" +
      "<h1>" + esc(t.title) + '</h1><div class="head-status">' + K.situation({ role: s.role, glyph: s.glyph, word: s.word, cause: s.cause, waits: s.waits, age: s.age, size: "large" }) + "</div></div>" +
      actionRail(v) + "</header>";
  }

  /* On a laptop: the one line the page keeps about the open Question, and the move that opens it. */
  function decisionCta(v, ui) {
    const q = v.openQuestion;
    return '<section class="decision-cta" aria-label="Decisions"><span class="cta-mark">' + icon("question") + "</span>" +
      '<span class="cta-text"><b>A question waits on you</b><span class="t-secondary">' + esc(q.title) + " · asked " + esc(dur(mins(q.asked, v.now))) + " ago</span></span>" +
      btn({ label: "Answer…", variant: "primary" }, 'aria-expanded="' + !!ui.sheetOpen + '" aria-haspopup="dialog" data-sheet="open"') + "</section>";
  }

  function lifecyclePanel(v) {
    const live = !!v.live;
    const sum = v.runs.length ? dur(v.totalMinutes) + " of work in " + v.runs.length + " runs" : "No run yet";
    return '<section class="panel lifecycle-panel" aria-label="Lifecycle"><div class="life-head"><span class="dot role-' + esc(v.situation.role) + (live ? " live" : "") + '"></span><span class="life-where">' + esc(v.life.where) + "</span>" +
      '<span class="life-sum">' + esc(sum) + "</span></div>" + K.steps(Object.assign({ kind: "ticket" }, v.life.state)) + K.stageBar(Object.assign({ key: "life" }, v.tokens)) + "</section>";
  }

  /* ----- Timeline ----- */

  const EXTRA_KINDS = { verdict: { glyph: "problem", role: "problem", word: "Check result" } };

  function eventEntry(it, ui) {
    const e = it.e;
    const k = K.TL[e.kind] || EXTRA_KINDS[e.kind] || K.TL.rule;
    const finding = e.finding ? '<span class="detail-link">' + K.badge("problem", "Finding", "small") + "<span>" + esc(L.findings[e.finding].title) + "</span></span>" : "";
    return '<li class="tl-entry role-' + esc(e.role || k.role) + (e.fresh ? " is-new" : "") + '" tabindex="0" role="option" aria-selected="' + (ui.selected === it.id) + '" data-sel="' + esc(it.id) + '">' +
      '<span class="time">' + esc(hm(e.at)) + '</span><span class="mark" title="' + esc(k.word) + '">' + icon(e.glyph || k.glyph) + "</span>" +
      '<span class="what"><span class="head">' + (it.unseen ? '<span class="new-dot" title="New since you last looked"></span>' : "") + "<b>" + esc(e.head) + "</b> " + esc(e.rest || "") + "</span>" +
      (e.detail ? '<span class="detail">' + esc(e.detail) + "</span>" : "") + finding + (e.actor ? '<span class="actor">' + esc(e.actor) + "</span>" : "") + "</span></li>";
  }

  /* A run's steps folded into its line: a short bar per step and the step it is on (or stopped at). */
  function miniSteps(run) {
    const map = { passed: "passed", failed: "failed", current: "current", asked: "paused", pending: "", stopped: "paused", skipped: "skipped" };
    const stop = run.steps.find((s) => s.state === "current" || s.state === "failed" || s.state === "asked");
    return '<span class="steps-mini" role="img" aria-label="Steps: ' + esc(run.steps.map((s) => s.name + ", " + (s.stateWord || s.state)).join("; ")) + '">' + run.steps.map((s) => '<i class="' + (map[s.state] || "") + '"></i>').join("") + "</span>" +
      (stop ? '<span class="steps-mini-at role-' + (stop.state === "current" ? "working" : stop.state === "failed" ? "problem" : "you") + '">' + esc(stop.name) + "</span>" : "");
  }

  function stepsOf(run, ui) {
    return run.steps.map((st) => {
      const key = run.id + ":" + st.id;
      const minutes = !st.start ? 0 : st.end ? mins(at(run, st.start), at(run, st.end)) : run.live && st.state === "current" ? mins(at(run, st.start), run.now) : 0;
      const open = ui.open[key] !== undefined ? ui.open[key] : st.state === "current" || st.state === "asked" || st.state === "failed";
      return { id: key, name: st.name, state: st.state, stateWord: st.stateWord, duration: !st.start ? "" : dur(minutes) + (st.state === "current" ? " so far" : ""), open: open,
        msgs: st.msgs.map((x, i, all) => ({ time: x.at, kind: x.kind, text: x.text, failed: x.failed, typing: run.live && st.state === "current" && i === all.length - 1 && x.kind === "say" })) };
    });
  }

  function attachment(id) {
    const a = L.attachments[id];
    return '<button type="button" class="attachment" data-shot="' + esc(id) + '" aria-label="Open the screenshot: ' + esc(a.name) + '"><span class="thumb image"><img src="' + esc(a.src) + '" alt=""></span>' +
      '<span class="name">' + esc(a.name) + '</span><span class="meta">' + esc(a.by + " · " + hm(a.at)) + "</span></button>";
  }

  function findingCard(f) {
    return '<section class="card finding-card' + (f.resolved ? " resolved" : "") + '"><div class="card-head"><h3>' + K.badge(f.resolved ? "done" : "problem", f.resolved ? "Resolved" : "Finding", "small") + "<span>" + esc(f.title) + "</span></h3>" +
      '<span class="t-secondary">' + esc(f.by + " · " + hm(f.at)) + '</span></div><p class="card-body">' + esc(f.text) + "</p>" +
      (f.shot ? '<div class="finding-shots">' + attachment(f.shot) + "</div>" : "") + "</section>";
  }

  /* One run: its line, and unfolded, what it did step by step (its transcript, in place). */
  function runGroup(it, ui) {
    const run = it.r;
    const vd = VERDICTS[run.verdict] || VERDICTS.passed;
    const open = ui.open[run.id] !== undefined ? ui.open[run.id] : run.live;
    const meta = [run.model, run.live ? dur(run.minutes) + " so far" : dur(run.minutes), tok(run.tokens), run.outcome].map(esc).join(" · ");
    const body = '<div class="run-body"><p class="run-meta">' + meta + "</p>" + run.findings.map(findingCard).join("") + K.stepList({ steps: stepsOf(run, ui) }) + "</div>";
    return '<div class="run-group" data-run-group="' + esc(run.id) + '"><button type="button" class="run-head role-' + vd.role + '" aria-expanded="' + open + '" data-run="' + esc(run.id) + '">' +
      '<span class="time">' + esc(hm(run.start)) + '</span><span class="mark">' + (run.live ? '<span class="dot live role-working"></span>' : icon(vd.glyph)) + "</span>" +
      '<span class="name">' + icon("chevron-right", "disclose") + (it.unseen && !run.live ? '<span class="new-dot" title="New since you last looked"></span>' : "") + "<b>" + esc(run.title) + "</b>" + K.badge(vd.role, vd.word, "small") + miniSteps(run) + "</span>" +
      '<span class="dur" title="How long the run took">' + esc(run.live ? dur(run.minutes) + " so far" : dur(run.minutes)) + "</span></button>" +
      K.fold("run-" + run.id, open, body) + "</div>";
  }

  /* The catalog's timeline: a heading per day, newest first; runs fold into their line, the events
     between them are one list each; a line where the person last looked. */
  function timelineSection(v, ui) {
    let html = "";
    let lastDay = "";
    let list = [];
    let sinceDone = false;
    const flush = () => { if (list.length) html += '<ol class="timeline" role="listbox" aria-label="Events">' + list.join("") + "</ol>"; list = []; };
    v.items.forEach((it, i) => {
      if (day(it.at) !== lastDay) {
        flush();
        html += '<div class="tl-day">' + esc(dayLabel(it.at, v.now)) + (lastDay ? "" : '<span class="t-secondary">newest first</span>') + "</div>";
        lastDay = day(it.at);
      }
      if (!sinceDone && !it.unseen && it.at <= v.lastSeen) {
        sinceDone = true;
        if (i > 0) { flush(); html += '<div class="tl-since">Since you last looked, at ' + esc(hm(v.lastSeen)) + "</div>"; }
      }
      if (it.type === "run") { flush(); html += runGroup(it, ui); } else list.push(eventEntry(it, ui));
    });
    flush();
    return '<div class="timeline-layout"><section class="timeline-section" aria-label="Timeline, newest first">' + html + "</section></div>";
  }

  /* ----- Facts rail ----- */

  function prPanel(v) {
    const pr = v.pr;
    const all = v.checks.reduce((a, g) => a.concat(g.items), []);
    const b = pr.state === "merged" ? K.badge("done", "Merged", "small") : K.badge("done", "Checks passing", "small");
    const groups = v.checks.map((g) => '<div class="check-group"><h5>' + esc(g.group) + '</h5><ol class="check-list">' + g.items.map((j) =>
      '<li><button type="button" class="check-row passed role-done" aria-label="' + esc(j[0] + ", passed, " + j[1]) + '" ' + later("Opens the " + j[0] + " check's log") + '><span class="mark">' + icon("done") + '</span><span class="check-name">' + esc(j[0]) + '</span><span class="check-state">Passed</span><span class="num">' + esc(j[1]) + "</span></button></li>").join("") + "</ol></div>").join("");
    return '<section class="facts-group"><h3 class="zone-title">Pull request</h3><div class="panel pr-panel">' +
      '<a class="pr-line" href="#" ' + later("Opens PR #" + pr.number + " on GitHub") + ">" + icon("pr", "pr-glyph") + '<span class="pr-name">PR #' + pr.number + '</span><span class="t-secondary">' + esc(pr.size) + "</span>" + b + "</a>" +
      '<div class="panel-sub"><h4>Checks<span class="t-secondary">' + all.length + " passed · " + esc(pr.checksOn) + "</span></h4>" + groups + "</div></div></section>";
  }

  function relRow(t, note, self) {
    const tag = self ? "div" : "button";
    return "<li><" + tag + (self ? "" : ' type="button" ' + later("Opens " + t.ident)) + ' class="rel-row' + (self ? " is-self" : "") + '"' + (self ? ' aria-current="true"' : "") + '><span class="dot role-' + esc(t.role) + '"></span><span class="rel-ident">' + esc(t.ident) + "</span>" +
      '<span class="rel-title">' + esc(t.title) + "</span>" + K.badge(t.role, t.state, "small") + (self ? "" : icon("chevron-right", "rel-go")) + "</" + tag + "></li>";
  }

  function connectedPanel(v) {
    const t = v.ticket;
    const r = v.relations;
    const done = v.life.current === "done";
    const epicDone = t.epic.done + (done ? 1 : 0);
    const segs = [];
    for (let i = 0; i < t.epic.total; i++) segs.push('<span class="seg ' + (i < epicDone ? "role-done" : i === epicDone && !done ? "role-" + v.situation.role : "role-idle") + '"></span>');
    const self = { ident: t.ident, title: t.title, role: v.situation.role, state: done ? "Done" : v.situation.role === "you" ? "Waiting on you" : STAGE_NAME[v.life.current] || "Todo" };
    const blocker = r.blockedBy[0];
    const next = done ? Object.assign({}, r.blocks[0], { note: "Can start now" }) : r.blocks[0];
    return '<section class="facts-group"><h3 class="zone-title">Connected</h3><div class="panel connected-panel">' +
      '<div class="panel-sub"><h4>Epic</h4><button type="button" class="epic-head" ' + later("Opens the epic") + '><span class="epic-ident">Epic</span><span class="epic-title">' + esc(t.epic.title) + "</span>" + icon("chevron-right", "rel-go") + "</button>" +
      '<div class="epic-progress"><div class="epic-track" role="img" aria-label="' + epicDone + " of " + t.epic.total + ' done">' + segs.join("") + '</div><span class="t-secondary">' + epicDone + " of " + t.epic.total + " done · this is the " + ordinal(t.epic.done + 1) + "</span></div>" +
      '<ol class="rel-list">' + relRow(blocker, "") + relRow(self, "", true) + relRow(next, "") + "</ol></div>" +
      /* Nothing holds this ticket up at any of the three moments, so there is no "Waiting on" block: a block is drawn only when it has something to say. */
      '<div class="panel-sub"><h4>Holding up</h4><ol class="rel-list">' + relRow(next, "") + "</ol></div></div></section>";
  }

  /* The note the next run reads before it starts, and the last one, with who read it. */
  function notePanel(v, ui) {
    const n = v.notes[v.notes.length - 1];
    const done = v.life.current === "done";
    const earlier = n ? '<div class="note-now">' + icon("note") + "<div><p>“" + esc(n.text) + '”</p><span class="t-secondary">' + esc(n.by + " · " + hm(n.at) + (n.read ? " · read by " + L.runs[n.readBy].title + " at " + hm(n.readAt) : " · the next run reads it")) + "</span></div></div>" : "";
    const empty = !String(ui.note || "").trim();
    const field = done ? '<p class="empty-line">The ticket is done: no run will read a new note.</p>' :
      '<div class="input"><textarea rows="2" aria-label="Note for the next run" placeholder="What the next run should know. It reads this before it starts." data-note>' + esc(ui.note || "") + "</textarea></div>" +
      '<div class="note-foot">' + btn({ label: "Save Note", size: "small", disabled: empty, reason: "Write a note first.", showReason: false }, "data-note-save") + "</div>";
    return '<section class="facts-group"><h3 class="zone-title">Note for the next run</h3><div class="panel note-panel">' + earlier + field + "</div></section>";
  }

  function decisionsPanel(v) {
    const body = v.decisions.length ? '<ol class="decision-list">' + v.decisions.map((q) => "<li>" + icon("answered") + "<div><b>" + esc(q.decision) + '</b><span class="t-secondary">' + esc(q.answeredBy || "You") + " · " + esc(hm(q.answered)) + "</span></div></li>").join("") + "</ol>" :
      '<p class="empty-line">None yet. Your answers to its questions are kept here.</p>';
    return '<section class="facts-group"><h3 class="zone-title">Decisions</h3><div class="panel">' + body + "</div></section>";
  }

  function detailsPanel(v) {
    const t = v.ticket;
    const ws = v.life.current === "done" ? '<span class="t-secondary">Removed after the merge</span>' :
      '<span class="ws"><span class="t-mono path-text">' + esc(t.workspace) + "</span>" + '<button type="button" class="icon-btn sz-sm" aria-label="Copy the path" title="Copy the path" data-flash="Path copied">' + icon("link") + "</button></span>";
    return '<section class="facts-group"><h3 class="zone-title">Details</h3><div class="panel">' + K.kv([
      ["Priority", K.badge("problem", t.priority, "small", true), true],
      ["Labels", '<span class="label-chips">' + t.labels.map((l) => K.chip({ kind: "label", text: l, role: "accent", interactive: false })).join("") + "</span>", true],
      ["Workspace", ws, true],
    ]) + "</div></section>";
  }

  function factsRail(v, ui) {
    return '<aside class="facts-rail" aria-label="Facts">' + prPanel(v) + connectedPanel(v) + notePanel(v, ui) + decisionsPanel(v) + detailsPanel(v) + "</aside>";
  }

  /* ----- The Question ----- */

  function questionBody(v, ui) {
    const q = v.openQuestion;
    const opts = q.options.map((o, i) => K.option(Object.assign({}, o, { selected: ui.pick === i, key: "q-" + i, hotkey: i + 1 })).replace(/ data-(set|toggle)="[^"]*"/, "").replace("<button ", '<button data-pick="' + i + '" ')).join("");
    const own = K.option({ label: "Answer in my own words…", effect: "Tell the agent what to do instead.", selected: ui.pick === "own", hotkey: q.options.length + 1, key: "q-own" }).replace(/ data-(set|toggle)="[^"]*"/, "").replace("<button ", '<button data-pick="own" ') +
      '<div class="fold own-fold" data-open="' + (ui.pick === "own") + '"><div class="fold-inner"><div class="own-words"><div class="input"><textarea rows="3" aria-label="Answer in my own words" placeholder="For example: use the secondary colour, and make the times one step smaller." data-own>' + esc(ui.own || "") + "</textarea></div>" +
      '<p class="hint">The agent reads this as your answer. Name tickets by their number; they become links.</p></div></div></div>';
    return '<section class="question-block in-sheet" aria-label="Question" data-question><div class="question-callout"><span class="kicker">' + icon("question", "glyph-sm") + "YOUR DECISION" + '<span class="age">asked ' + esc(dur(mins(q.asked, v.now))) + " ago</span></span><h2>" + esc(q.title) + "</h2></div>" +
      '<div class="question-why">' + q.why.map((p) => "<p>" + esc(p) + "</p>").join("") + '<p class="unanswered">' + icon("cost") + "<span><b>If you don't answer:</b> " + esc(q.unanswered) + "</span></p></div>" +
      '<div class="options" role="radiogroup" aria-label="Answers">' + opts + own + "</div></section>";
  }

  function answerLabel(v, ui) {
    if (ui.pick === null || ui.pick === undefined) return "";
    if (ui.pick === "own") return String(ui.own || "").trim() ? "In your own words" : "";
    return v.openQuestion.options[ui.pick].label;
  }

  function sendArea(v, ui) {
    const label = answerLabel(v, ui);
    const reason = ui.pick === "own" && !label ? "Write your answer first." : "Pick an answer first.";
    return '<span class="pick"' + (label ? "" : " hidden") + '><span class="t-secondary">Your answer</span><b>' + esc(label) + "</b></span>" +
      (label ? "" : K.refusal(reason)) + btn({ label: "Send Decision…", variant: "primary", size: "large", disabled: !label, showReason: false, reason: reason }, "data-send");
  }

  /* The catalog's decision sheet: every open Question, scrolling on its own, one Send at its foot. */
  function decisionSheet(v, ui, desktop) {
    return '<div class="dsheet-layer"><div class="dsheet-scrim" data-sheet="close" aria-hidden="true"></div>' +
      '<aside class="dsheet" role="dialog" aria-label="Your decision"' + (desktop ? "" : ' aria-modal="true"') + '><header class="dsheet-head"><span class="cta-mark">' + icon("question") + '</span><div><h2>Your decision</h2><p class="sub">' + esc(v.ticket.ident + " · " + v.ticket.title) + "</p></div>" +
      (desktop ? "<span></span>" : '<button type="button" class="icon-btn" aria-label="Close" title="Close (Esc)" data-sheet="close">' + icon("close") + "</button>") + "</header>" +
      '<div class="dsheet-body">' + questionBody(v, ui) + "</div>" +
      '<footer class="dsheet-foot" data-send-area>' + sendArea(v, ui) + "</footer></aside></div>";
  }

  function ticketPage(v, ui, desktop) {
    const asks = !!v.openQuestion;
    return '<div class="ticket-page' + (asks ? " has-decision" : "") + '"><div class="zone-head">' + pageHeader(v) + "</div>" +
      (asks && !desktop ? '<div class="zone-decide"><h3 class="zone-title">Waiting on you</h3>' + decisionCta(v, ui) + "</div>" : "") +
      '<div class="zone-run"><h3 class="zone-title">Lifecycle</h3>' + lifecyclePanel(v) + "</div>" +
      '<div class="zone-timeline"><h3 class="zone-title">Timeline<span class="zone-sub">' + esc(v.unseenCount ? v.unseenCount + " new since you looked at " + hm(v.lastSeen) : "nothing new since you looked") + "</span></h3>" + timelineSection(v, ui) + "</div>" +
      '<div class="zone-facts">' + factsRail(v, ui) + "</div>" +
      (asks && desktop ? '<div class="zone-sheet is-open"><h3 class="zone-title">Waiting on you</h3>' + decisionSheet(v, ui, true) + "</div>" : "") + "</div>";
  }

  /* ---------- The frame: the bar on top and the window at its width ---------- */

  const WIDTHS = { laptop: { w: 1180, h: 820, said: "Laptop · 1440 × 900 window · content 1180 × 820 pt" }, desktop: { w: 2200, h: 1360, said: "Desktop · 1440p display · content 2200 × 1360 pt" } };
  const MOMENTS = [["running", "Running", "16:47: Implementation run 2 is on its tests step"], ["waiting", "Waiting on you", "17:52: a question is open"], ["shipped", "Shipped", "21:30: merged at 21:05"]];

  function readHash() {
    const o = { moment: "waiting", width: "laptop", theme: "system", fit: "on", motion: "full" };
    location.hash.replace(/^#/, "").split("&").forEach((kv) => { const p = kv.split("="); if (p[0] && p[1] && o[p[0]] !== undefined) o[p[0]] = decodeURIComponent(p[1]); });
    if (!L.moments[o.moment]) o.moment = "waiting";
    if (!WIDTHS[o.width]) o.width = "laptop";
    return o;
  }

  function seg(name, label, opts, value) {
    const i = Math.max(0, opts.findIndex((o) => o[0] === value));
    return '<div class="bar-tool"><span class="bar-label">' + esc(label) + '</span><div class="segmented sz-sm" role="radiogroup" aria-label="' + esc(label) + '" style="--n:' + opts.length + ";--i:" + i + '" data-pref="' + name + '"><span class="seg-thumb" aria-hidden="true"></span>' +
      opts.map((o) => '<button type="button" role="radio" class="segment" aria-checked="' + (o[0] === value) + '" data-value="' + o[0] + '"' + (o[2] ? ' title="' + esc(o[2]) + '"' : "") + ">" + esc(o[1]) + "</button>").join("") + "</div></div>";
  }

  const sw = (name, label, on, title) => '<button type="button" class="bar-switch" role="switch" aria-checked="' + on + '" data-switch="' + name + '" title="' + esc(title) + '"><span class="knob" aria-hidden="true"></span>' + esc(label) + "</button>";

  function bar(prefs) {
    return '<header class="proto-bar ds sz-sm" role="toolbar" aria-label="Prototype controls">' +
      '<div class="bar-id"><span class="bar-mark" aria-hidden="true"></span><span><b>Ticket page</b><span>Prototype of the catalog’s Page layout · TP-1244</span></span></div>' +
      '<span class="bar-sep"></span>' + seg("moment", "Moment", MOMENTS, prefs.moment) +
      seg("width", "Width", [["laptop", "Laptop", WIDTHS.laptop.said], ["desktop", "Desktop", WIDTHS.desktop.said]], prefs.width) +
      seg("theme", "Theme", [["system", "System"], ["light", "Light"], ["dark", "Dark"]], prefs.theme) +
      '<span class="bar-grow"></span>' +
      sw("motion", "Reduce motion", prefs.motion === "reduce", "Show the page as it moves with Reduce Motion on") +
      sw("fit", "Fit", prefs.fit === "on", "Scale the window down to fit this browser window; off shows it at its real size") + "</header>";
  }

  /* ---------- Running the page ---------- */

  let S = null;
  let timer = null;
  const reduced = () => S.prefs.motion === "reduce" || window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const desktop = () => S.prefs.width === "desktop";
  const $ = (sel) => document.querySelector(sel);
  const $$ = (sel) => Array.prototype.slice.call(document.querySelectorAll(sel));

  function start() {
    const prefs = readHash();
    S = { prefs: prefs, ui: freshUi(), view: null };
    document.body.innerHTML = bar(prefs) +
      '<main class="proto-canvas" id="canvas"><p class="proto-caption" id="caption"></p><div class="proto-zoom" id="zoom"><div class="proto-window ds" id="window"><div class="proto-scroll" id="scroll"><div class="section-frame" id="page"></div></div></div></div></main>' +
      '<div id="flash" class="proto-flash" role="status" aria-live="polite"></div>';
    applyPrefs();
    draw();
    bind();
    window.addEventListener("resize", () => { fit(); stickRail(); });
    $("#window").addEventListener("transitionend", (e) => { if (e.target.id === "window") stickRail(); });
  }

  const freshUi = () => ({ open: {}, selected: null, answered: null, pick: null, own: "", note: "", sheetOpen: false });

  function writeHash() {
    const p = S.prefs;
    history.replaceState(null, "", "#moment=" + p.moment + "&width=" + p.width + "&theme=" + p.theme + "&fit=" + p.fit + "&motion=" + p.motion);
  }

  function applyPrefs() {
    const p = S.prefs;
    const root = document.documentElement;
    if (p.theme === "system") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", p.theme);
    root.classList.toggle("reduce-motion", p.motion === "reduce");
    const win = $("#window");
    win.style.width = WIDTHS[p.width].w + "px";
    win.style.height = WIDTHS[p.width].h + "px";
    win.style.setProperty("--win-h", WIDTHS[p.width].h + "px");
    $$("[data-pref]").forEach((g) => {
      const btns = Array.prototype.slice.call(g.querySelectorAll("[data-value]"));
      const i = Math.max(0, btns.findIndex((b) => b.dataset.value === p[g.dataset.pref]));
      g.style.setProperty("--i", i);
      btns.forEach((b, j) => b.setAttribute("aria-checked", String(j === i)));
    });
    $$("[data-switch]").forEach((s) => s.setAttribute("aria-checked", String(s.dataset.switch === "fit" ? p.fit === "on" : p.motion === "reduce")));
    writeHash();
    fit();
  }

  /* Fit: the window keeps its real size in points and is scaled down as one, so what is seen is the
     layout at that width, never a reflow at the browser's width. */
  function fit() {
    const W = WIDTHS[S.prefs.width];
    const canvas = $("#canvas");
    const availW = canvas.clientWidth - 48;
    const availH = window.innerHeight - canvas.getBoundingClientRect().top - 64;
    const z = S.prefs.fit === "on" ? Math.max(0.3, Math.min(1, availW / W.w, availH / W.h)) : 1;
    $("#zoom").style.zoom = String(z);
    $("#caption").textContent = W.said + " · shown at " + Math.round(z * 100) + " %";
  }

  function draw() {
    const view = derive(S.prefs.moment, S.ui);
    S.view = view;
    $("#page").innerHTML = ticketPage(view, S.ui, desktop());
    $$(".proto-window > .dsheet-layer").forEach((x) => x.remove());
    if (S.ui.sheetOpen && view.openQuestion && !desktop()) openSheet({ instant: true });
    stickRail();
    clearInterval(timer);
    if (view.live && view.live.queue.length) timer = setInterval(tick, 3200);
  }

  /* The facts rail is sticky, as in the catalog. When it is taller than the window, it scrolls with
     the page until its foot is in view and sticks there, so no fact is ever out of reach. */
  function stickRail() {
    const rail = $("#page .zone-facts");
    if (!rail) return;
    const room = $("#scroll").clientHeight;
    rail.style.top = Math.min(16, room - rail.offsetHeight - 16) + "px";
  }

  /* Redraw with the browser's view transition where it has one, so what moves glides into place. */
  function redraw(after) {
    const run = () => { draw(); if (after) after(); };
    if (!reduced() && document.startViewTransition) document.startViewTransition(run); else run();
  }

  /* The live run: its next line arrives, as it would from the server. */
  function tick() {
    const run = S.view.live;
    const next = run && run.queue.shift();
    if (!next) { clearInterval(timer); return; }
    run.steps.find((s) => s.id === next.step).msgs.push(next);
    const head = document.querySelector('[data-step="' + run.id + ":" + next.step + '"]');
    const list = head && head.parentNode.querySelector(".sl-msgs");
    if (!list) return;
    list.querySelectorAll(".typing").forEach((x) => x.classList.remove("typing"));
    const li = document.createElement("li");
    li.className = "sl-msg " + next.kind + " is-new" + (next.kind === "say" ? " typing" : "");
    li.innerHTML = '<span class="time">' + esc(next.at) + '</span><span class="kind">' + icon({ say: "say", tool: "log", result: "arrow" }[next.kind]) + '</span><span class="text">' + esc(next.text) + "</span>";
    list.appendChild(li);
  }

  function flash(text) {
    const f = $("#flash");
    f.innerHTML = '<div class="toast ds">' + icon("info") + '<span class="msg">' + esc(text) + "</span></div>";
    clearTimeout(flash.t);
    flash.t = setTimeout(() => { f.innerHTML = ""; }, 2600);
  }

  /* A disabled move that is pressed: its reason, already under it, shakes once so it is read. */
  function refuse(el) {
    const group = el.closest(".btn-group");
    const reason = group && group.querySelector(".refusal");
    if (reason) { reason.classList.remove("nudge"); void reason.offsetWidth; reason.classList.add("nudge"); return; }
    const said = el.getAttribute("title") || el.dataset.reason;
    if (said) flash(said);
  }

  function toggleFold(head, key) {
    const open = head.getAttribute("aria-expanded") !== "true";
    head.setAttribute("aria-expanded", String(open));
    const f = head.parentNode.querySelector(":scope > .fold");
    if (f) f.setAttribute("data-open", String(open));
    S.ui.open[key] = open;
  }

  function select(id) {
    S.ui.selected = S.ui.selected === id ? null : id;
    $$("#page [data-sel]").forEach((el) => el.setAttribute("aria-selected", String(el.dataset.sel === S.ui.selected)));
  }

  /* ----- The sheet (laptop) ----- */

  function openSheet(o) {
    o = o || {};
    S.ui.sheetOpen = true;
    const win = $("#window");
    win.insertAdjacentHTML("beforeend", decisionSheet(S.view, S.ui, false));
    const layer = win.lastElementChild;
    if (o.instant) layer.classList.add("no-enter");
    $$('[data-sheet="open"]').forEach((b) => b.setAttribute("aria-expanded", "true"));
    $("#scroll").setAttribute("inert", "");
    const first = layer.querySelector('[data-pick][aria-checked="true"]') || layer.querySelector("[data-pick]");
    if (first && !o.instant) setTimeout(() => first.focus({ preventScroll: true }), 30);
  }

  function closeSheet(o) {
    o = o || {};
    const layer = $(".proto-window > .dsheet-layer");
    if (!layer) return;
    S.ui.sheetOpen = false;
    $("#scroll").removeAttribute("inert");
    const opener = $('[data-sheet="open"]');
    if (opener) { opener.setAttribute("aria-expanded", "false"); if (!o.quiet) opener.focus({ preventScroll: true }); }
    if (reduced()) { layer.remove(); if (o.then) o.then(); return; }
    layer.classList.add("is-closing");
    setTimeout(() => { layer.remove(); if (o.then) o.then(); }, 300);
  }

  /* ----- Answering ----- */

  function block() { return document.querySelector("[data-question]"); }

  function pickOption(b) {
    const q = block();
    q.querySelectorAll("[data-pick]").forEach((x) => x.setAttribute("aria-checked", String(x === b)));
    const own = b.dataset.pick === "own";
    S.ui.pick = own ? "own" : Number(b.dataset.pick);
    q.querySelector(".own-fold").setAttribute("data-open", String(own));
    if (own) setTimeout(() => q.querySelector("[data-own]").focus({ preventScroll: true }), 60);
    updateSend();
  }

  function updateSend() {
    const area = document.querySelector("[data-send-area]");
    area.innerHTML = sendArea(S.view, S.ui);
  }

  /* The Question leaves the page: the answered block settles and fades, the sheet (or the column)
     goes, and the timeline takes the answer as two new entries that enter at its top. */
  function send() {
    const text = String(S.ui.own || "").trim();
    S.ui.answered = S.ui.pick === "own" ? { own: true, text: text } : { pick: S.ui.pick };
    const done = () => { S.ui.sheetOpen = false; redraw(() => {
      flash("Answer sent. Implementation run 4 starts with it.");
      /* The new entries keep their tint a moment, then settle into the timeline. */
      setTimeout(() => $$("#page .tl-entry.is-new").forEach((x) => x.classList.remove("is-new")), 2400);
    }); };
    if (reduced()) { closeSheet({ quiet: true }); done(); return; }
    block().classList.add("is-leaving");
    const decide = $(".zone-decide");
    if (decide) decide.classList.add("is-leaving");
    if (desktop()) { $(".zone-sheet").classList.add("is-leaving"); setTimeout(done, 520); }
    else setTimeout(() => closeSheet({ quiet: true, then: done }), 360);
  }

  /* ----- Screenshots ----- */

  function lightbox(id) {
    const a = L.attachments[id];
    const box = document.createElement("div");
    box.className = "proto-lightbox ds";
    box.innerHTML = '<div class="sheet-scrim" data-lightbox-close><figure class="sheet shot-sheet" role="dialog" aria-label="' + esc(a.name) + '"><div class="sheet-head"><h2>' + esc(a.name) + '</h2><p class="sub">' + esc(a.by + " · " + hm(a.at)) + '</p><button type="button" class="icon-btn" aria-label="Close" title="Close (Esc)" data-lightbox-close>' + icon("close") + "</button></div>" +
      '<div class="sheet-body"><img src="' + esc(a.src) + '" alt="' + esc(a.name) + '"></div></figure></div>';
    box.querySelector("figure").addEventListener("click", (e) => { if (!e.target.closest("[data-lightbox-close]")) e.stopPropagation(); });
    document.body.appendChild(box);
    box.querySelector(".icon-btn").focus({ preventScroll: true });
  }

  function closeMenus(except) {
    $$("#page .menu").forEach((m) => {
      if (m === except) return;
      m.hidden = true;
      const b = m.parentNode.querySelector("[data-menu]");
      if (b) b.setAttribute("aria-expanded", "false");
    });
  }

  function bind() {
    document.addEventListener("click", (e) => {
      const t = e.target;
      const pref = t.closest("[data-pref] [data-value]");
      if (pref) {
        const name = pref.closest("[data-pref]").dataset.pref;
        if (S.prefs[name] === pref.dataset.value) return;
        S.prefs[name] = pref.dataset.value;
        if (name === "moment") S.ui = freshUi();
        applyPrefs();
        if (name === "moment" || name === "width") redraw();
        return;
      }
      const swt = t.closest("[data-switch]");
      if (swt) {
        const name = swt.dataset.switch;
        S.prefs[name] = name === "fit" ? (S.prefs.fit === "on" ? "off" : "on") : (S.prefs.motion === "reduce" ? "full" : "reduce");
        applyPrefs();
        return;
      }
      if (t.closest("[data-lightbox-close]")) { $$(".proto-lightbox").forEach((b) => b.remove()); return; }
      const menuBtn = t.closest("[data-menu]");
      const menu = menuBtn && menuBtn.parentNode.querySelector(".menu");
      closeMenus(menu);
      if (menuBtn) { menu.hidden = !menu.hidden; menuBtn.setAttribute("aria-expanded", String(!menu.hidden)); if (!menu.hidden) { const f = menu.querySelector('.menu-item:not([aria-disabled="true"])'); if (f) f.focus({ preventScroll: true }); } return; }
      const off = t.closest('[aria-disabled="true"]');
      if (off) { if (off.matches("[data-send]")) { const r = $("[data-send-area] .refusal"); if (r) { r.classList.remove("nudge"); void r.offsetWidth; r.classList.add("nudge"); } } else refuse(off); return; }
      const sheet = t.closest("[data-sheet]");
      if (sheet) { if (sheet.dataset.sheet === "open") openSheet(); else closeSheet(); return; }
      const shot = t.closest("[data-shot]");
      if (shot) { lightbox(shot.dataset.shot); return; }
      const fl = t.closest("[data-flash]");
      if (fl) { e.preventDefault(); flash(fl.dataset.flash); return; }
      const runHead = t.closest("[data-run]");
      if (runHead) { toggleFold(runHead, runHead.dataset.run); return; }
      const stepHead = t.closest(".sl-head[data-step]");
      if (stepHead) { toggleFold(stepHead, stepHead.dataset.step); return; }
      const pick = t.closest("[data-pick]");
      if (pick) { pickOption(pick); return; }
      if (t.closest("[data-send]")) { send(); return; }
      const sel = t.closest("[data-sel]");
      if (sel) { select(sel.dataset.sel); return; }
    });
    document.addEventListener("input", (e) => {
      if (e.target.matches("[data-own]")) { S.ui.own = e.target.value; updateSend(); }
      if (e.target.matches("[data-note]")) {
        S.ui.note = e.target.value;
        const b = $("[data-note-save]");
        const empty = !e.target.value.trim();
        b.setAttribute("aria-disabled", String(empty));
        if (empty) { b.removeAttribute("data-flash"); b.setAttribute("title", "Write a note first."); } else { b.dataset.flash = "Saved. The next run reads it before it starts."; b.removeAttribute("title"); }
      }
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        if ($(".proto-lightbox")) { $$(".proto-lightbox").forEach((b) => b.remove()); return; }
        const open = $$("#page .menu").find((m) => !m.hidden);
        if (open) { closeMenus(); open.parentNode.querySelector("[data-menu]").focus(); return; }
        closeSheet();
        return;
      }
      const menuItem = e.target.closest(".menu-item");
      if (menuItem && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
        e.preventDefault();
        const items = Array.prototype.slice.call(menuItem.parentNode.querySelectorAll('.menu-item:not([aria-disabled="true"])')).filter((x) => x.offsetParent);
        const i = items.indexOf(menuItem) + (e.key === "ArrowDown" ? 1 : -1);
        if (items[i]) items[i].focus();
        return;
      }
      if (menuItem && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); menuItem.click(); return; }
      if (e.target.matches("textarea, input")) return;
      const q = block();
      if (q && q.offsetParent && /^[1-9]$/.test(e.key)) {
        const b = q.querySelectorAll("[data-pick]")[Number(e.key) - 1];
        if (b) { pickOption(b); if (b.dataset.pick !== "own") b.focus({ preventScroll: true }); }
        return;
      }
      if ((e.key === "Enter" || e.key === " ") && e.target.matches("[data-sel]")) { e.preventDefault(); select(e.target.dataset.sel); return; }
      if ((e.key === "ArrowDown" || e.key === "ArrowUp") && e.target.matches("[data-sel]")) {
        e.preventDefault();
        const all = $$("#page [data-sel]").filter((x) => x.offsetParent);
        const i = all.indexOf(e.target) + (e.key === "ArrowDown" ? 1 : -1);
        if (all[i]) { all[i].focus(); all[i].scrollIntoView({ block: "nearest", behavior: reduced() ? "auto" : "smooth" }); }
      }
    });
  }

  window.TICKET_PAGE = { derive: derive, render: (key, ui, wide) => ticketPage(derive(key, Object.assign(freshUi(), ui || {})), Object.assign(freshUi(), ui || {}), !!wide), sheet: (key, ui) => { const u = Object.assign(freshUi(), ui || {}); return decisionSheet(derive(key, u), u, false); } };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
})();
