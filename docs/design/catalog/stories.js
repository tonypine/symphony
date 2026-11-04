/*
 * Every story of the Director design catalog, as data.
 *
 * A component is { title, docs, args, controls, render, stories }. Each story is
 * { name, args } and is drawn by render(props), where props are the component's args
 * with the story's args on top. render returns HTML that uses the classes of
 * components.css. The catalog shell (catalog.js) turns this into the sidebar, the
 * canvas, the controls and the docs tab.
 */
window.CATALOG = (function () {
  "use strict";

  /* ---------- Helpers ---------- */

  const esc = (value) => String(value === undefined || value === null ? "" : value)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");

  const INNER = 'style="stroke:var(--glyph-inner,#fff)"';
  const INNER_FILL = 'style="fill:var(--glyph-inner,#fff)"';

  const ICONS = {
    you: '<circle cx="6.5" cy="5" r="2.5"/><path d="M2 13.5c0-2.5 2-4 4.5-4s4.5 1.5 4.5 4"/><path d="M13.5 2.8v4"/><circle cx="13.5" cy="9.6" r=".7" fill="currentColor" stroke="none"/>',
    working: '<circle cx="8" cy="8" r="6" stroke-dasharray="2 2.2"/><circle cx="8" cy="8" r="2.4" fill="currentColor" stroke="none"/>',
    problem: '<path d="M8 1.6 15.2 14.2H.8z" fill="currentColor" stroke="none"/><path d="M8 6v3.6" ' + INNER + '/><circle cx="8" cy="11.8" r=".8" stroke="none" ' + INNER_FILL + "/>",
    done: '<circle cx="8" cy="8" r="7" fill="currentColor" stroke="none"/><path d="m5 8.2 2 2 4-4.4" ' + INNER + "/>",
    idle: '<circle cx="8" cy="8" r="6.3"/><path d="M6.5 5.8v4.4M9.5 5.8v4.4"/>',
    forced: '<path d="M9.2 1 3 9.2h4.2L6.6 15 13 6.6H8.6z" fill="currentColor" stroke="none"/>',
    clock: '<circle cx="8" cy="8" r="6.3"/><path d="M8 4.5V8l2.5 1.5"/>',
    "chevron-down": '<path d="m4 6 4 4 4-4"/>',
    "chevron-right": '<path d="m6 4 4 4-4 4"/>',
    "chevron-left": '<path d="m10 4-4 4 4 4"/>',
    updown: '<path d="m5 6 3-3 3 3M5 10l3 3 3-3"/>',
    close: '<path d="m4 4 8 8M12 4l-8 8"/>',
    search: '<circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3.5 3.5"/>',
    more: '<circle cx="3.5" cy="8" r="1.2" fill="currentColor" stroke="none"/><circle cx="8" cy="8" r="1.2" fill="currentColor" stroke="none"/><circle cx="12.5" cy="8" r="1.2" fill="currentColor" stroke="none"/>',
    repo: '<path d="M2.5 5 8 2l5.5 3L8 8z"/><path d="m2.5 8 5.5 3 5.5-3M2.5 11l5.5 3 5.5-3"/>',
    epic: '<path d="M3.5 14.5V2.5M3.5 3h8.5l-1.8 3 1.8 3H3.5"/>',
    label: '<path d="M2 2.5h5.5L14 9l-5 5-6.5-6.5z"/><circle cx="5.2" cy="5.2" r=".9" fill="currentColor" stroke="none"/>',
    arrow: '<path d="M2.5 8h10M9 4.5 12.5 8 9 11.5"/>',
    pause: '<path d="M5.5 3.5v9M10.5 3.5v9"/>',
    play: '<path d="M5 3.2v9.6L12.5 8z" fill="currentColor" stroke="none"/>',
    question: '<path d="M2.5 3h11v8H7.5L4.5 13.5V11h-2z"/><path d="M6.6 5.6a1.5 1.5 0 1 1 2.1 1.4c-.4.2-.7.5-.7.9"/><circle cx="8" cy="9.4" r=".6" fill="currentColor" stroke="none"/>',
    answered: '<path d="M2.5 3h11v8H7.5L4.5 13.5V11h-2z"/><path d="m5.6 7 1.6 1.6L10.4 5.4"/>',
    "run-start": '<circle cx="8" cy="8" r="6.3"/><path d="M6.6 5.3v5.4L10.8 8z" fill="currentColor" stroke="none"/>',
    "run-end": '<circle cx="8" cy="8" r="6.3"/><rect x="5.6" y="5.6" width="4.8" height="4.8" rx=".6" fill="currentColor" stroke="none"/>',
    hand: '<path d="M5 8.5V4a1 1 0 0 1 2 0v3.5M7 7V3a1 1 0 0 1 2 0v4M9 7.2V4a1 1 0 0 1 2 0v5c0 3-1.6 5-4 5-1.9 0-3-1-3.9-2.7L1.8 9a1 1 0 0 1 1.7-1.1L5 9.6"/>',
    gear: '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4"/>',
    check: '<path d="m3.5 8.5 3 3 6-7"/>',
    good: '<circle cx="8" cy="8" r="6.3"/><path d="m5.3 8.2 1.9 1.9 3.6-3.9"/>',
    cost: '<path d="M8 2.2 14.5 13.5h-13z"/><path d="M8 6.5v3"/><circle cx="8" cy="11.4" r=".6" fill="currentColor" stroke="none"/>',
    risk: '<circle cx="8" cy="8" r="6.3"/><path d="m5.8 5.8 4.4 4.4M10.2 5.8l-4.4 4.4"/>',
    lock: '<rect x="3.5" y="7" width="9" height="7" rx="1.5"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"/>',
    info: '<circle cx="8" cy="8" r="6.3"/><path d="M8 7.2v4"/><circle cx="8" cy="5" r=".7" fill="currentColor" stroke="none"/>',
    doc: '<path d="M4 1.8h5l3 3V14.2H4z"/><path d="M9 1.8V5h3M6 8h4M6 10.5h4"/>',
    image: '<rect x="2" y="3" width="12" height="10" rx="1.5"/><circle cx="6" cy="6.5" r="1.2"/><path d="m2.5 12 3.5-3.5 2.5 2.5 2-2 3 3"/>',
    log: '<rect x="2" y="2.5" width="12" height="11" rx="1.5"/><path d="m4.5 6 2 2-2 2M8 10.5h3.5"/>',
    pr: '<circle cx="4.5" cy="3.5" r="1.6"/><circle cx="4.5" cy="12.5" r="1.6"/><circle cx="11.5" cy="12.5" r="1.6"/><path d="M4.5 5.1v5.8M11.5 10.9V6.5a2 2 0 0 0-2-2H7M8.5 3 7 4.5 8.5 6"/>',
    tray: '<path d="M2 9.5 3.8 3h8.4L14 9.5V13H2z"/><path d="M2 9.5h3.5l1 1.5h3l1-1.5H14"/>',
    columns: '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M6 3v10M10 3v10"/>',
    filter: '<path d="M2 3.5h12M4.5 8h7M7 12.5h2"/>',
    refresh: '<path d="M13 2v2.8h-2.8"/><path d="M12.9 4.6A5.5 5.5 0 1 0 13.5 8"/>',
    "sort-down": '<path d="m3 5 5 6 5-6z" fill="currentColor" stroke="none"/>',
    "sort-up": '<path d="m3 11 5-6 5 6z" fill="currentColor" stroke="none"/>',
    link: '<path d="M7 9a3 3 0 0 0 4.2 0l2-2A3 3 0 0 0 9 2.8l-.8.8M9 7a3 3 0 0 0-4.2 0l-2 2A3 3 0 0 0 7 13.2l.8-.8"/>',
    inspector: '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M10 3v10"/>',
    plus: '<path d="M8 3v10M3 8h10"/>',
    calendar: '<rect x="2" y="3" width="12" height="11" rx="1.5"/><path d="M2 6.5h12M5 1.8v2.6M11 1.8v2.6"/>',
    stop: '<rect x="3.5" y="3.5" width="9" height="9" rx="1.5"/>',
    undo: '<path d="M5.5 3 2.5 6l3 3"/><path d="M2.5 6H10a3.5 3.5 0 0 1 0 7H7"/>',
    sparkle: '<path d="M8 1.5 9.4 6.6 14.5 8 9.4 9.4 8 14.5 6.6 9.4 1.5 8l5.1-1.4z"/>',
  };

  const icon = (name, cls) => '<svg class="glyph' + (cls ? " " + cls : "") + '" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICONS[name] || ICONS.info) + "</svg>";

  const ROLES = {
    you: { word: "Waiting on you", glyph: "you", hue: "orange" },
    working: { word: "Working", glyph: "working", hue: "blue" },
    problem: { word: "Needs attention", glyph: "problem", hue: "red" },
    done: { word: "Done", glyph: "done", hue: "green" },
    idle: { word: "Paused", glyph: "idle", hue: "gray" },
    forced: { word: "Forced", glyph: "forced", hue: "purple" },
  };

  const ROLE_OPTIONS = Object.keys(ROLES).map((k) => ({ value: k, label: ROLES[k].word + " (" + ROLES[k].hue + ")" }));

  const stateClass = (s) => ({ hover: " is-hover", pressed: " is-pressed", focused: " is-focused" }[s] || "");
  const attr = (name, value) => (value === undefined || value === null || value === false ? "" : " " + name + '="' + esc(value) + '"');

  /* Shared controls */
  const STATE = { name: "state", label: "Shown state", type: "select", options: [
    { value: "default", label: "Live (use the pointer)" },
    { value: "hover", label: "Hover" },
    { value: "pressed", label: "Pressed" },
    { value: "focused", label: "Focused" },
  ] };
  const STATE_NO_PRESS = { name: "state", label: "Shown state", type: "select", options: [
    { value: "default", label: "Live (use the pointer)" },
    { value: "hover", label: "Hover" },
    { value: "focused", label: "Focused" },
  ] };
  const DISABLED = { name: "disabled", label: "Disabled", type: "toggle" };
  const REASON = { name: "reason", label: "Disabled reason", type: "text", when: (p) => p.disabled };

  /* ---------- Building blocks, shared by components and sections ---------- */

  const refusal = (reason, fix) => '<span class="refusal">' + icon("lock") + "<span>" + esc(reason) +
    (fix ? ' <a class="fix" href="#" onclick="return false">' + esc(fix) + "</a>" : "") + "</span></span>";

  function button(p) {
    const variant = { primary: " btn-primary", destructive: " btn-destructive", "destructive-filled": " btn-destructive-filled", quiet: " btn-quiet" }[p.variant] || "";
    const size = { large: " btn-lg", small: " btn-sm" }[p.size] || "";
    const glyph = p.glyph && p.glyph !== "none" ? icon(p.glyph) : "";
    const b = '<button type="button" class="btn' + variant + size + (p.disabled ? "" : stateClass(p.state)) + '"' +
      (p.disabled ? ' aria-disabled="true"' + attr("title", p.reason) : "") + attr("data-key", p.key) + ">" + glyph + esc(p.label) + "</button>";
    if (p.disabled && p.reason && p.showReason !== false) return '<span class="btn-group">' + b + refusal(p.reason) + "</span>";
    return b;
  }

  const badge = (role, word, size, noGlyph) => '<span class="badge role-' + esc(role) + (size === "small" ? " badge-sm" : size === "large" ? " badge-lg" : "") + '">' +
    (noGlyph ? "" : icon((ROLES[role] || {}).glyph || "sparkle")) + esc(word || (ROLES[role] || {}).word || "") + "</span>";

  const kbd = (keys, plain) => '<span class="kbd-hint' + (plain ? " plain" : "") + '" aria-label="' + esc(keys.replace(/\s+/g, " ")) + '">' +
    String(keys).trim().split(/\s+/).map((k) => '<kbd class="kbd">' + esc(k) + "</kbd>").join("") + "</span>";

  function situation(p) {
    const role = p.role || "working";
    const word = p.word || ROLES[role].word;
    return '<p class="situation role-' + esc(role) + (p.size === "large" ? " situation-lg" : "") + (p.compact ? " situation-compact" : "") + '" style="margin:0">' +
      icon(ROLES[role].glyph) + '<span class="word">' + esc(word) + "</span>" +
      (p.cause ? '<span class="cause">' + esc(p.cause) + "</span>" : "") +
      (p.waits ? '<span class="waits">' + esc(p.waits) + "</span>" : "") +
      (p.age ? '<span class="age" title="Since this situation began">' + esc(p.age) + "</span>" : "") + "</p>";
  }

  function chip(p) {
    const kind = p.kind || "status";
    const interactive = p.interactive !== false;
    const tag = interactive ? "button" : "span";
    let lead = "";
    if (kind === "status") lead = icon(ROLES[p.role || "working"].glyph);
    else if (kind === "repo") lead = icon("repo");
    else if (kind === "epic") lead = icon("epic");
    else if (kind === "label") lead = '<span class="swatch role-' + esc(p.role || "idle") + '"></span>';
    return "<" + tag + (interactive ? ' type="button"' : "") + ' class="chip chip-' + esc(kind) + (kind === "status" ? " role-" + esc(p.role || "working") : "") +
      (p.disabled ? "" : stateClass(p.state)) + '"' + (interactive && p.pressed !== undefined ? attr("aria-pressed", String(!!p.pressed)) : "") +
      (p.disabled ? ' aria-disabled="true"' + attr("title", p.reason) : "") + (p.toggle ? ' data-toggle="' + esc(p.toggle) + '"' : "") + attr("data-key", p.key) + ">" +
      lead + esc(p.text) + (p.removable ? icon("close", "remove") : "") + "</" + tag + ">";
  }

  function row(p) {
    const role = p.role || "working";
    const fix = p.fix ? button({ label: p.fix, variant: p.fixPrimary ? "primary" : "secondary", size: "small", disabled: p.fixDisabled, reason: p.fixReason, showReason: false }) : "";
    const reason = p.fix && p.fixDisabled && p.fixReason ? '<span class="age">' + esc(p.fixReason) + "</span>" : "";
    return '<div role="option" tabindex="0" class="row role-' + esc(role) + (p.twoLine ? " two-line" : "") + (p.unfocused ? " unfocused-selection" : "") + stateClass(p.state) + '"' +
      attr("aria-selected", p.selected ? "true" : null) + (p.toggle ? ' data-toggle="' + esc(p.toggle) + '"' : "") + (p.set ? ' data-set="' + esc(p.set) + '"' : "") + attr("data-key", p.key) + ">" +
      '<span class="lead">' + (p.live && role === "working" ? '<span class="dot live role-working"></span>' : icon(ROLES[role].glyph)) + "</span>" +
      '<span class="main"><span class="line1"><span class="ident">' + esc(p.ident) + '</span><span class="title">' + esc(p.title) + "</span></span>" +
      (p.twoLine && p.line2 ? '<span class="line2">' + esc(p.line2) + "</span>" : "") + "</span>" +
      '<span class="trail">' + (p.badge ? badge(role, p.badge, "small") : "") + reason + fix + (p.age ? '<span class="age">' + esc(p.age) + "</span>" : "") + "</span></div>";
  }

  function card(p) {
    const tag = p.clickable ? "button" : "section";
    return "<" + tag + (p.clickable ? ' type="button"' : "") + ' class="card' + (p.clickable ? " clickable" : "") + (p.selected ? " selected" : "") + stateClass(p.state) + '"' +
      (p.clickable ? ' style="text-align:left;border:0;font:inherit;color:inherit"' : "") + (p.width ? ' style="max-width:' + esc(p.width) + 'px"' : "") + ">" +
      '<div class="card-head"><h3>' + esc(p.title) + "</h3>" + (p.link ? '<a class="link" href="#" onclick="return false">' + esc(p.link) + "</a>" : "") + "</div>" +
      (p.html !== undefined ? p.html : p.empty ? '<p class="empty-line">' + esc(p.emptyText || "Nothing here yet.") + "</p>" : '<p class="card-body">' + esc(p.body) + "</p>") + "</" + tag + ">";
  }

  function kv(pairs, stacked) {
    const shown = pairs.filter((x) => x[1] !== "" && x[1] !== null && x[1] !== undefined);
    return '<dl class="kv' + (stacked ? " stacked" : "") + '">' + shown.map((x) => "<dt>" + esc(x[0]) + "</dt><dd>" + (x[2] ? x[1] : esc(x[1])) + "</dd>").join("") + "</dl>";
  }

  const TL = {
    phase: { glyph: "arrow", role: "accent", word: "Phase move" },
    "pause-set": { glyph: "pause", role: "idle", word: "Pause set" },
    "pause-cleared": { glyph: "play", role: "working", word: "Pause cleared" },
    "question-asked": { glyph: "question", role: "you", word: "Question asked" },
    "question-answered": { glyph: "answered", role: "done", word: "Question answered" },
    "run-started": { glyph: "run-start", role: "working", word: "Run started" },
    "run-passed": { glyph: "done", role: "done", word: "Run ended: passed" },
    "run-failed": { glyph: "problem", role: "problem", word: "Run ended: failed" },
    "run-stopped": { glyph: "run-end", role: "idle", word: "Run ended: stopped" },
    person: { glyph: "hand", role: "accent", word: "Person action" },
    rule: { glyph: "gear", role: "idle", word: "Rule action" },
  };

  const TL_OPTIONS = Object.keys(TL).map((k) => ({ value: k, label: TL[k].word }));

  function tlEntry(p) {
    const k = TL[p.kind] || TL.phase;
    return '<li class="tl-entry role-' + k.role + stateClass(p.state) + '"><span class="time">' + esc(p.time) + "</span>" +
      '<span class="mark" title="' + esc(k.word) + '">' + icon(k.glyph) + "</span>" +
      '<span class="what"><span class="head">' + p.headHtml + "</span>" +
      (p.detail ? '<span class="detail">' + esc(p.detail) + "</span>" : "") +
      (p.actor ? '<span class="actor">' + esc(p.actor) + "</span>" : "") + "</span></li>";
  }

  const head = (strong, rest) => "<b>" + esc(strong) + "</b>" + (rest ? " " + esc(rest) : "");

  function runGroup(p) {
    const verdict = { passed: "done", failed: "problem", running: "working", stopped: "idle" }[p.verdict] || "working";
    const glyph = { passed: "done", failed: "problem", running: "run-start", stopped: "run-end" }[p.verdict] || "run-start";
    const word = { passed: "Passed", failed: "Failed", running: "Running", stopped: "Stopped" }[p.verdict] || "";
    const body = p.expanded ? '<div class="run-body"><ol class="timeline">' + (p.entries || []).map(tlEntry).join("") + "</ol></div>" : "";
    return '<div class="run-group"><button type="button" class="run-head role-' + verdict + stateClass(p.state) + '" aria-expanded="' + !!p.expanded + '" data-toggle="expanded" data-key="run">' +
      '<span class="time">' + esc(p.time) + '</span><span class="mark">' + (p.verdict === "running" ? '<span class="dot live role-working"></span>' : icon(glyph)) + "</span>" +
      '<span class="name">' + icon("chevron-right", "disclose") + "<b>" + esc(p.title) + "</b>" + badge(verdict, word, "small") + (p.tokens ? '<span class="t-secondary">' + esc(p.tokens) + "</span>" : "") + "</span>" +
      '<span class="dur" title="How long the run took">' + esc(p.duration) + "</span></button>" + body + "</div>";
  }

  const STEP_NAMES = [["code", "Writing the code"], ["build", "Build"], ["checks", "Checks"], ["tests", "Tests"], ["handoff", "Handoff"]];
  const STEP_STATES = {
    passed: { word: "Passed", glyph: "done", role: "done" },
    failed: { word: "Failed", glyph: "problem", role: "problem" },
    paused: { word: "Paused", glyph: "idle", role: "idle" },
    skipped: { word: "Skipped", glyph: "chevron-right", role: "idle" },
    current: { word: "Now", glyph: "working", role: "working" },
    pending: { word: "Not started", glyph: "clock", role: "idle" },
  };
  const STEP_OPTIONS = Object.keys(STEP_STATES).map((k) => ({ value: k, label: STEP_STATES[k].word }));

  function steps(p) {
    return '<ol class="steps" aria-label="Steps of the run">' + STEP_NAMES.map((s) => {
      const st = STEP_STATES[p[s[0]]] || STEP_STATES.pending;
      const detail = p[s[0] + "Note"] || "";
      return '<li class="step ' + esc(p[s[0]]) + " role-" + st.role + '"><span class="bar"></span><span class="name">' + icon(st.glyph) + esc(s[1]) + "</span>" +
        '<span class="state">' + esc(st.word) + (detail ? " · " + esc(detail) : "") + "</span></li>";
    }).join("") + "</ol>";
  }

  function tags(p) {
    const items = [["good", p.good, "done", "Good"], ["cost", p.cost, "you", "Cost"], ["risk", p.risk, "problem", "Risk"]].filter((t) => t[1]);
    if (!items.length) return "";
    return '<ul class="tags">' + items.map((t) => '<li class="tag role-' + t[2] + '" aria-label="' + t[3] + ": " + esc(t[1]) + '">' + icon(t[0]) + "<span>" + esc(t[1]) + "</span></li>").join("") + "</ul>";
  }

  function option(p) {
    const disabled = !!p.disabled;
    return '<button type="button" role="radio" class="option' + (disabled ? "" : stateClass(p.state)) + '" aria-checked="' + (!disabled && !!p.selected) + '"' +
      (disabled ? ' aria-disabled="true"' + attr("title", p.reason) : "") + (p.set ? ' data-set="' + esc(p.set) + '"' : ' data-toggle="selected"') + attr("data-key", p.key || "opt") + ">" +
      '<span class="radio" aria-hidden="true"></span><span class="label-line"><span class="label">' + esc(p.label) + "</span>" +
      (p.recommended ? badge("accent", "Recommended", "small", true) : "") + "</span>" +
      (p.hotkey && !disabled ? '<span class="kbd-wrap">' + kbd(String(p.hotkey)) + "</span>" : "") +
      (p.effect ? '<span class="effect">' + esc(p.effect) + "</span>" : "") + tags(p) +
      (p.recommended && p.why ? '<span class="why"><b>Why we recommend it:</b> ' + esc(p.why) + "</span>" : "") +
      (disabled && p.reason ? '<span class="effect">' + refusal(p.reason) + "</span>" : "") + "</button>";
  }

  function ownWords(p) {
    const cardHtml = option({ label: "Answer in my own words…", effect: "Tell the agent what to do instead.", selected: p.picked, state: p.picked ? "" : p.state, hotkey: p.hotkey, set: "picked=" + !p.picked, key: "own" });
    if (!p.picked) return cardHtml;
    const empty = !String(p.text || "").trim();
    return cardHtml + '<div class="own-words"><div class="input' + (p.state === "focused" ? " is-focused" : "") + '"><textarea rows="3" aria-label="Answer in my own words…" data-bind="text" placeholder="For example: keep TP-1383 waiting until the new colours land.">' + esc(p.text) + "</textarea></div>" +
      '<p class="hint" style="margin:0">The agent reads this as your answer. Name tickets by their number; they become links.</p>' +
      (p.send ? '<div class="foot">' + button({ label: "Send Decision…", variant: "primary", disabled: empty, reason: "Write your answer first.", showReason: true }) + "</div>" : "") + "</div>";
  }

  function meter(p) {
    const cap = Math.max(1, Number(p.cap) || 1);
    const used = Math.max(0, Number(p.used) || 0);
    const pct = Math.min(100, Math.round((used / cap) * 100));
    const role = pct >= 95 ? "problem" : pct >= 75 ? "you" : "accent";
    const fmt = (n) => (p.unit === "tokens" ? (n >= 1e6 ? (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M" : n >= 1e3 ? Math.round(n / 1e3) + "K" : String(n)) : String(n));
    const note = pct >= 100 ? "At the cap: no new run starts until " + p.resets + "." : pct >= 95 ? "Almost at the cap: runs still finish, new ones wait from 100 %." : pct >= 75 ? "Getting close: " + (100 - pct) + " % left until " + p.resets + "." : "Plenty left. Resets " + p.resets + ".";
    return '<div class="meter role-' + role + '" role="meter" aria-valuenow="' + pct + '" aria-valuemin="0" aria-valuemax="100" aria-label="' + esc(p.label) + ", " + pct + ' percent">' +
      '<div class="meter-head"><span>' + esc(p.label) + '</span><span class="value">' + esc(fmt(used)) + " of " + esc(fmt(cap)) + " " + esc(p.unit) + " · " + pct + " %</span></div>" +
      '<div class="meter-track"><div class="meter-fill" style="width:' + pct + '%"></div></div>' +
      '<div class="meter-note' + (role === "accent" ? " calm" : "") + '">' + esc(note) + "</div></div>";
  }

  /* Fixtures */
  const TICKETS = [
    { ident: "TP-1382", title: "Design system catalog as HTML", repo: "symphony", role: "you", badge: "Waiting on you", age: "3 h 12 min", line2: "Question: review the design catalog" },
    { ident: "TP-1376", title: "A CI-wait pause lifts itself when the commit's CI finishes", repo: "symphony", role: "working", badge: "Working", age: "14 min", line2: "Implementation run 2 · on the tests step" },
    { ident: "TP-1375", title: "A new ticket's first dispatch waits for its relations", repo: "symphony", role: "problem", badge: "Checks failed", age: "22 min", line2: "Two tests failed in the orchestrator", fix: "Open Checks" },
    { ident: "SHOP-305", title: "Checkout total rounding", repo: "web-shop", role: "working", badge: "Code Review", age: "6 min", line2: "Waiting for CI on PR #812" },
    { ident: "TP-1374", title: "Ask “changes nothing against main” only when the diff is empty", repo: "symphony", role: "done", badge: "Shipped", age: "1 day", line2: "Merged as PR #794" },
    { ident: "TP-1371", title: "Workspace lifecycle docs", repo: "symphony", role: "idle", badge: "Queued", age: "2 h", line2: "Waiting for a free slot" },
    { ident: "TP-1380", title: "Usage page shows cost per epic", repo: "symphony", role: "forced", badge: "Forced", age: "2 min", line2: "You pushed it ahead of the queue" },
  ];

  const DAY = [
    { kind: "phase", time: "09:02", headHtml: head("Moved to In Progress", "from Todo"), actor: "Symphony" },
    { kind: "run-started", time: "09:02", headHtml: head("Implementation run 1 started"), detail: "Claude · laptop workspace" },
    { kind: "run-failed", time: "09:24", headHtml: head("Implementation run 1 ended:", "checks failed"), detail: "22 min · 1.4M tokens" },
    { kind: "pause-set", time: "09:30", headHtml: head("Paused:", "Deploy freeze"), detail: "Dispatch paused for every ticket", actor: "Tony" },
    { kind: "pause-cleared", time: "10:05", headHtml: head("Pause cleared"), detail: "Dispatch resumed", actor: "Tony" },
    { kind: "question-asked", time: "10:40", headHtml: head("Question asked:", "Review the design catalog"), detail: "Two options, one recommended" },
    { kind: "question-answered", time: "11:15", headHtml: head("Answered:", "“Approve the catalog”"), actor: "Tony, in the Inbox" },
    { kind: "person", time: "11:16", headHtml: head("Forced ahead of the queue"), actor: "Tony" },
    { kind: "rule", time: "11:17", headHtml: head("Branch updated", "with the newest main"), detail: "Rule: keep the branch current while in Merging" },
    { kind: "run-passed", time: "11:40", headHtml: head("Code Review passed"), detail: "8 min · no findings" },
  ];

  /* ---------- Tokens ---------- */

  const swatch = (name, cssVar, use) => '<div class="swatch-card"><div class="chip-color" style="background:var(' + cssVar + ')"></div><b>' + esc(name) + "</b><code>" + esc(cssVar) + "</code><span>" + esc(use) + "</span></div>";

  const tokens = [
    {
      title: "Colour",
      wide: false,
      docs: {
        what: "Named colour roles. Every colour in the Director is one of these roles, never a raw value. In the app each role maps to a system colour, so light, dark and Increase Contrast follow by themselves.",
        when: ["Text uses the three text roles: primary for content, secondary for metadata, tertiary for placeholders and disabled text only.", "Surfaces stack window → content → raised; hover and pressed are translucent overlays on whatever surface is under them.", "The six status colours are reserved for status. A chart or a decoration never borrows one."],
        tokens: ["--surface-window", "--surface-content", "--surface-raised", "--surface-sunken", "--surface-hover", "--surface-pressed", "--stroke-separator", "--stroke-strong", "--text-primary", "--text-secondary", "--text-tertiary", "--accent", "--status-you … --status-forced", "--tint-you … --tint-forced", "--status-you-text … --status-forced-text"],
        access: "Status is never colour alone: each status ships with its glyph and its word. A word drawn in a status colour uses the matching text role, which keeps 4.5:1 on content in light and dark.",
      },
      render: (p, ctx) => {
        const id = ctx.story.id;
        if (id === "surfaces-and-text") {
          return '<div class="swatches">' + [
            swatch("Window", "--surface-window", "Behind content"),
            swatch("Content", "--surface-content", "Cards, lists, tables"),
            swatch("Raised", "--surface-raised", "Inset groups, hover on cards"),
            swatch("Sunken", "--surface-sunken", "Tracks, search fields, segmented controls"),
            swatch("Hover", "--surface-hover", "Overlay under the pointer"),
            swatch("Pressed", "--surface-pressed", "Overlay while pressed"),
            swatch("Separator", "--stroke-separator", "Hairlines between rows and around cards"),
            swatch("Strong line", "--stroke-strong", "Control borders"),
            swatch("Text", "--text-primary", "Titles, values, body"),
            swatch("Secondary text", "--text-secondary", "Metadata, captions"),
            swatch("Tertiary text", "--text-tertiary", "Placeholders and disabled only"),
          ].join("") + "</div>";
        }
        if (id === "accent") {
          return '<div class="swatches">' + [
            swatch("Accent", "--accent", "Selection, links, the default button"),
            swatch("Accent hover", "--accent-hover", "Default button under the pointer"),
            swatch("Accent pressed", "--accent-pressed", "Default button pressed"),
            swatch("Accent tint", "--accent-tint", "Recommended, selected option"),
            swatch("Focus ring", "--focus-ring-color", "Keyboard focus only"),
          ].join("") + "</div>";
        }
        const keys = Object.keys(ROLES);
        if (id === "status-tints") {
          return '<div class="swatches">' + keys.map((k) => '<div class="swatch-card"><div class="chip-color" style="background:var(--tint-' + k + ')"></div><b>' + esc(ROLES[k].word) + " tint</b><code>--tint-" + k + "</code><span>" + badge(k) + "</span></div>").join("") + "</div>";
        }
        return '<div class="swatches">' + keys.map((k) => '<div class="swatch-card role-' + k + '"><div class="chip-color" style="background:var(--status-' + k + ')"></div><b>' + esc(ROLES[k].word) + "</b><code>--status-" + k + '</code><span style="color:var(--status-' + k + '-text)">' + icon(ROLES[k].glyph) + " Text in --status-" + k + "-text</span></div>").join("") + "</div>";
      },
      stories: [{ name: "Surfaces and text" }, { name: "Accent" }, { name: "Status" }, { name: "Status tints" }],
    },
    {
      title: "Type scale",
      args: { sample: "Design system catalog as HTML" },
      controls: [{ name: "sample", label: "Sample text", type: "text" }],
      docs: {
        what: "The system font at nine sizes. Each style is a role, so a heading is always a heading wherever it appears.",
        when: ["Title opens a page (the ticket's title). Sentence opens a view with its status. Heading names a section or a card.", "Body is for reading text and table cells; secondary for metadata under it.", "Mono is for commit hashes, paths and commands only, never for prose or numbers."],
        tokens: ["--type-title", "--type-sentence", "--type-heading", "--type-row-title", "--type-body", "--type-secondary", "--type-label", "--type-caption", "--type-mono", "--measure"],
        access: "Text sizes follow the system's text size setting in the app. Reading text never runs past the measure (68 characters).",
      },
      render: (p, ctx) => {
        if (ctx.story.id === "mono-for-hashes-and-paths") {
          return '<div class="specimen">' + [["Commit", "289143e8"], ["Path", "docs/design/catalog/index.html"], ["Command", "symphony force TP-1382"]].map((x) =>
            '<div class="specimen-row"><code>' + esc(x[0]) + '</code><span class="t-mono">' + esc(x[1]) + "</span></div>").join("") +
            '<div class="specimen-row"><code>Not for</code><span class="t-secondary">Prose, numbers, ticket identifiers (TP-1382 stays in the text font)</span></div></div>';
        }
        const styles = [["Title", "t-title", "22 / 28 semibold"], ["Sentence", "t-sentence", "17 / 22 semibold"], ["Heading", "t-heading", "15 / 20 semibold"], ["Row title", "t-row-title", "13 / 18 semibold"], ["Body", "t-body", "13 / 18 regular"], ["Secondary", "t-secondary", "12 / 16 regular"], ["Label", "t-label", "11 / 14 medium"], ["Caption", "t-caption", "10 / 13 regular"], ["Mono", "t-mono", "12 / 16 monospaced"]];
        return '<div class="specimen">' + styles.map((s) => '<div class="specimen-row"><code>' + esc(s[0]) + " · " + esc(s[2]) + '</code><span class="' + s[1] + '">' + esc(s[1] === "t-mono" ? "289143e8 docs/design/catalog" : p.sample) + "</span></div>").join("") + "</div>";
      },
      stories: [{ name: "All styles" }, { name: "Mono for hashes and paths" }],
    },
    {
      title: "Spacing",
      docs: {
        what: "A 4 pt grid. Every gap and padding is one of seven steps.",
        when: ["4 between a glyph and its word; 8 between related lines; 12 row and tile padding; 16 between cards; 20 window inset; 24 between sections; 32 above an empty state."],
        tokens: ["--space-1", "--space-2", "--space-3", "--space-4", "--space-5", "--space-6", "--space-8"],
      },
      render: () => '<div class="specimen">' + [[1, 4, "Glyph to word"], [2, 8, "Related lines, badges"], [3, 12, "Row and tile padding"], [4, 16, "Between cards"], [5, 20, "Window inset"], [6, 24, "Between sections"], [8, 32, "Above an empty state"]].map((s) =>
        '<div class="specimen-row"><code>--space-' + s[0] + " · " + s[1] + ' pt</code><span style="display:flex;align-items:center;gap:12px"><span class="space-bar" style="width:' + s[1] + 'px"></span><span class="t-secondary">' + esc(s[2]) + "</span></span></div>").join("") + "</div>",
      stories: [{ name: "All steps" }],
    },
    {
      title: "Radii",
      docs: {
        what: "Four radii, used concentrically: an inner radius is the outer radius minus the inset between them.",
        when: ["Card 14 for cards and section containers; row 10 for rows, option cards and tiles inside a card (14 − 4); control 6 for buttons and fields; mark 4 for chart ends and meters; capsule for badges, chips and count badges."],
        tokens: ["--radius-card", "--radius-row", "--radius-control", "--radius-mark", "--radius-capsule"],
      },
      render: (p, ctx) => {
        if (ctx.story.id === "concentric") {
          return '<div class="card" style="width:360px;padding:4px"><div class="row is-hover role-working">' + '<span class="lead">' + icon("working") + '</span><span class="main"><span class="line1"><span class="ident">Row 10</span><span class="title">inside a card of 14, 4 inset</span></span></span></div></div>';
        }
        return '<div style="display:flex;flex-wrap:wrap;gap:24px">' + [["Card", 14], ["Row", 10], ["Control", 6], ["Mark", 4], ["Capsule", 999]].map((r) =>
          '<div style="display:grid;gap:8px;justify-items:center"><div class="radius-box" style="border-radius:' + r[1] + "px;" + (r[1] > 100 ? "height:36px" : "") + '"></div><span class="t-secondary">' + esc(r[0]) + " · " + (r[1] > 100 ? "height / 2" : r[1] + " pt") + "</span></div>").join("") + "</div>";
      },
      stories: [{ name: "All radii" }, { name: "Concentric" }],
    },
    {
      title: "Elevation",
      docs: {
        what: "Content is flat. Only layers that float over content cast a shadow, and in the app those come from the system.",
        when: ["Level 0: anything inside a card. Level 1: a card, a hairline only. Level 2: menus, tooltips, toasts. Level 3: sheets."],
        avoid: "Never a shadow on a row, a tile or a chart, and never a home-made blur.",
        tokens: ["--elevation-0", "--elevation-1", "--elevation-2", "--elevation-3"],
      },
      render: () => '<div style="display:flex;flex-wrap:wrap;gap:32px;padding:16px">' + [0, 1, 2, 3].map((n) =>
        '<div class="elev-box" style="box-shadow:var(--elevation-' + n + ')">Level ' + n + "<br>" + ["Inside a card", "Card", "Menu, tooltip, toast", "Sheet"][n] + "</div>").join("") + "</div>",
      stories: [{ name: "Levels" }],
    },
    {
      title: "Motion",
      args: { duration: "--motion-standard", easing: "--ease-standard", play: false },
      controls: [
        { name: "duration", label: "Duration", type: "select", options: [{ value: "--motion-fast", label: "Fast · 0.12 s" }, { value: "--motion-standard", label: "Standard · 0.25 s" }, { value: "--motion-slow", label: "Slow · 0.4 s" }] },
        { name: "easing", label: "Easing", type: "select", options: [{ value: "--ease-standard", label: "Standard" }, { value: "--ease-enter", label: "Enter" }, { value: "--ease-exit", label: "Exit" }] },
      ],
      docs: {
        what: "Three durations and three easings. Hover and pressed use fast; sections appearing, folding and selection use standard; nothing in the Director is slow except the sheet.",
        when: ["A tooltip and a chip's popover wait 0.5 s of hover before they open (--motion-hover-delay).", "Values that change on a poll update in place; nothing moves under the pointer."],
        tokens: ["--motion-fast", "--motion-standard", "--motion-slow", "--motion-hover-delay", "--ease-standard", "--ease-enter", "--ease-exit"],
        access: "With Reduce Motion on every duration is zero and nothing loops.",
      },
      render: (p) => '<div style="display:grid;gap:12px;width:520px"><div class="motion-track" data-motion><span class="motion-ball" style="transition:left var(' + esc(p.duration) + ") var(" + esc(p.easing) + ')"></span></div>' +
        '<div style="display:flex;gap:12px;align-items:center">' + button({ label: "Play again", glyph: "play", key: "play" }).replace("<button ", '<button data-toggle="play" ') + '<span class="t-secondary">' + esc(p.duration) + " with " + esc(p.easing) + "</span></div></div>",
      mounted: (stage) => {
        stage.querySelectorAll("[data-motion]").forEach((track) => {
          window.setTimeout(() => track.classList.add("go"), 60);
        });
      },
      stories: [{ name: "Durations and easings" }, { name: "Fast", args: { duration: "--motion-fast" } }, { name: "Slow", args: { duration: "--motion-slow" } }],
    },
    {
      title: "Focus ring",
      docs: {
        what: "A 3 pt ring in the accent at half strength, drawn only when focus came from the keyboard.",
        when: ["Every control, row, card and option that takes focus draws it. A pointer click never does."],
        tokens: ["--focus-ring", "--focus-ring-color"],
        access: "Tab moves through controls in reading order; the ring is the only sign of where the keyboard is, so nothing may hide it.",
      },
      render: (p, ctx) => {
        if (ctx.story.id === "on-a-row") return '<div style="width:520px">' + row(Object.assign({}, TICKETS[1], { state: "focused" })) + "</div>";
        if (ctx.story.id === "on-a-field") return '<div class="field"><label>Reason</label><div class="input is-focused"><input value="Deploy freeze"></div></div>';
        return button({ label: "Approve the catalog", variant: "primary", state: "focused" });
      },
      stories: [{ name: "On a button" }, { name: "On a row" }, { name: "On a field" }],
    },
  ];

  /* ---------- Components ---------- */

  const components = [
    {
      title: "Button",
      args: { label: "Approve Plan", variant: "primary", size: "regular", glyph: "none", state: "default", disabled: false, reason: "Checks are still running on PR #812." },
      controls: [
        { name: "label", label: "Label", type: "text" },
        { name: "variant", label: "Kind", type: "select", options: [{ value: "primary", label: "Primary" }, { value: "secondary", label: "Secondary" }, { value: "destructive", label: "Destructive" }, { value: "destructive-filled", label: "Destructive, in a sheet" }, { value: "quiet", label: "Quiet" }] },
        { name: "size", label: "Size", type: "select", options: ["small", "regular", "large"] },
        { name: "glyph", label: "Glyph", type: "select", options: ["none", "play", "stop", "refresh", "pr", "plus", "undo"] },
        STATE, DISABLED, REASON,
      ],
      render: (p) => button(p),
      docs: {
        what: "A labelled action. One primary button per place (the move we expect), secondary for the others, destructive for what stops or throws work away, quiet for low-stakes actions inside text and cards.",
        when: ["Name it with its verb in title case: Approve Plan, Stop Run…, Send Decision….", "End the label with “…” when it opens a sheet that asks for more.", "Disabled always says why, in an inline refusal under it and as its help text."],
        avoid: "Two primary buttons side by side, or a disabled button without a reason.",
        states: [["Default", "resting"], ["Hover", "one step darker"], ["Pressed", "two steps darker, 98 % scale"], ["Focused", "the focus ring"], ["Disabled with reason", "tertiary text on raised, the reason underneath"]],
        tokens: ["--accent", "--accent-hover", "--accent-pressed", "--status-problem", "--radius-control", "--motion-fast", "--focus-ring"],
        access: "VoiceOver reads the label and “button”; a disabled button reads “dimmed” and then the reason.",
      },
      stories: [
        { name: "Primary" },
        { name: "Primary hover", args: { state: "hover" } },
        { name: "Primary pressed", args: { state: "pressed" } },
        { name: "Primary focused", args: { state: "focused" } },
        { name: "Primary disabled with reason", args: { disabled: true, label: "Approve and Merge…" } },
        { name: "Secondary", args: { variant: "secondary", label: "Open Checks" } },
        { name: "Secondary hover", args: { variant: "secondary", label: "Open Checks", state: "hover" } },
        { name: "Secondary pressed", args: { variant: "secondary", label: "Open Checks", state: "pressed" } },
        { name: "Secondary disabled with reason", args: { variant: "secondary", label: "Restart…", disabled: true, reason: "A run is still finishing. Wait for it, or stop it first." } },
        { name: "Destructive", args: { variant: "destructive", label: "Stop Run…" } },
        { name: "Destructive hover", args: { variant: "destructive", label: "Stop Run…", state: "hover" } },
        { name: "Destructive in a sheet", args: { variant: "destructive-filled", label: "Stop Run" } },
        { name: "Quiet", args: { variant: "quiet", label: "Show All" } },
        { name: "Quiet hover", args: { variant: "quiet", label: "Show All", state: "hover" } },
        { name: "With a glyph", args: { variant: "secondary", label: "Run Again", glyph: "refresh" } },
        { name: "Small", args: { size: "small", variant: "secondary", label: "Open" } },
        { name: "Large", args: { size: "large", label: "Send Decision…" } },
      ],
    },
    {
      title: "Icon button",
      args: { glyph: "inspector", label: "Show the details pane", state: "default", toggled: false, disabled: false, reason: "No ticket is selected." },
      controls: [
        { name: "glyph", label: "Glyph", type: "select", options: ["inspector", "refresh", "more", "close", "link", "filter", "columns", "search"] },
        { name: "label", label: "Help text", type: "text" },
        STATE, { name: "toggled", label: "On", type: "toggle" }, DISABLED, REASON,
      ],
      render: (p) => {
        const b = '<button type="button" class="icon-btn' + (p.disabled ? "" : stateClass(p.state)) + '" aria-label="' + esc(p.label) + '" title="' + esc(p.disabled ? p.reason : p.label) + '"' +
          (p.disabled ? ' aria-disabled="true"' : ' aria-pressed="' + !!p.toggled + '" data-toggle="toggled" data-key="ib"') + ">" + icon(p.glyph) + "</button>";
        return p.disabled ? '<span class="btn-group" style="align-items:center">' + b + refusal(p.reason) + "</span>" : b;
      },
      docs: {
        what: "A glyph-only action for toolbars and card corners, where the glyph is well known (close, more, refresh, the details pane).",
        when: ["Always has help text that names the action; that text is what VoiceOver reads.", "A toggle (show or hide a pane) shows its on state with the accent tint."],
        avoid: "An icon button for a move that changes Linear or a run: those get a labelled button.",
        states: [["Default", "secondary glyph, no background"], ["Hover", "hover overlay"], ["Pressed", "pressed overlay"], ["Focused", "focus ring"], ["On", "accent glyph on accent tint"], ["Disabled with reason", "tertiary glyph, reason as help and underneath"]],
        tokens: ["--surface-hover", "--surface-pressed", "--accent-tint", "--radius-control"],
      },
      stories: [
        { name: "Default" }, { name: "Hover", args: { state: "hover" } }, { name: "Pressed", args: { state: "pressed" } }, { name: "Focused", args: { state: "focused" } },
        { name: "On", args: { toggled: true } }, { name: "Disabled with reason", args: { disabled: true } },
      ],
    },
    {
      title: "Menu button",
      args: { label: "Move to…", open: false, state: "default", disabled: false, reason: "Moves wait while a run is working." },
      controls: [{ name: "label", label: "Label", type: "text" }, { name: "open", label: "Menu open", type: "toggle" }, STATE, DISABLED, REASON],
      render: (p) => {
        const items = [["Todo", ""], ["In Progress", ""], ["Rework", ""], ["sep"], ["Backlog", "⌘ ⌫"], ["Canceled", ""]];
        const menu = p.open && !p.disabled ? '<ul class="menu" role="menu">' + items.map((it, i) => it[0] === "sep" ? '<li class="menu-sep" role="separator"></li>' :
          '<li class="menu-item' + (i === 1 ? " is-hover" : "") + '" role="menuitem">' + icon("check", "check") + esc(it[0]) + (it[1] ? kbd(it[1], true) : "") + "</li>").join("") + "</ul>" : "";
        const b = '<button type="button" class="menu-btn' + (p.disabled ? "" : stateClass(p.state)) + '" aria-haspopup="menu" aria-expanded="' + (!!p.open && !p.disabled) + '"' +
          (p.disabled ? ' aria-disabled="true"' + attr("title", p.reason) : ' data-toggle="open" data-key="mb"') + ">" + esc(p.label) + icon("chevron-down", "chev") + "</button>";
        return '<div style="min-height:' + (p.open ? 200 : 40) + 'px"><span class="menu-wrap">' + b + menu + "</span>" + (p.disabled ? '<div style="margin-top:4px">' + refusal(p.reason) + "</div>" : "") + "</div>";
      },
      docs: {
        what: "A button that opens a short menu of related moves, for a set that does not fit the action rail.",
        when: ["The label names the set and ends with “…” or a chevron; each item is a verb or a destination.", "Destructive items sit last, under a separator."],
        states: [["Closed", "like a secondary button with a chevron"], ["Hover", "one step darker"], ["Pressed / open", "two steps darker while the menu shows"], ["Focused", "focus ring"], ["Disabled with reason", "reason underneath"]],
        tokens: ["--elevation-2", "--radius-row", "--accent (menu highlight)"],
        access: "Space or Return opens the menu, arrows move, Escape closes.",
      },
      stories: [
        { name: "Closed" }, { name: "Hover", args: { state: "hover" } }, { name: "Pressed", args: { state: "pressed" } }, { name: "Open", args: { open: true } },
        { name: "Focused", args: { state: "focused" } }, { name: "Disabled with reason", args: { disabled: true } },
      ],
    },
    {
      title: "Segmented control",
      args: { options: "Day, Week, Month", selected: 1, hoverAt: -1, state: "default", disabled: false, reason: "The period is fixed while comparing two epics." },
      controls: [
        { name: "options", label: "Segments", type: "text" },
        { name: "selected", label: "Selected segment", type: "number", min: 0, max: 6 },
        { name: "hoverAt", label: "Shown hover on", type: "number", min: -1, max: 6 },
        { name: "state", label: "Shown state", type: "select", options: [{ value: "default", label: "Live (use the pointer)" }, { value: "focused", label: "Focused" }] },
        DISABLED, REASON,
      ],
      render: (p) => {
        const opts = String(p.options).split(",").map((s) => s.trim()).filter(Boolean);
        const seg = '<div class="segmented" role="radiogroup"' + (p.disabled ? ' aria-disabled="true"' + attr("title", p.reason) : "") + ">" + opts.map((o, i) =>
          '<button type="button" role="radio" class="segment' + (i === Number(p.hoverAt) && i !== Number(p.selected) ? " is-hover" : "") + (i === Number(p.selected) && p.state === "focused" ? " is-focused" : "") + '" aria-checked="' + (i === Number(p.selected)) + '"' +
          (p.disabled ? ' aria-disabled="true"' : ' data-set="selected=' + i + '" data-key="seg' + i + '"') + ">" + esc(o) + "</button>").join("") + "</div>";
        return p.disabled ? '<span class="btn-group">' + seg + refusal(p.reason) + "</span>" : seg;
      },
      docs: {
        what: "Two to five mutually exclusive views of the same thing: a period, a unit, a layout.",
        when: ["Segments are short nouns. The choice applies at once, with no confirmation."],
        avoid: "More than five segments (use a pop-up), or segments that trigger moves.",
        states: [["Selected", "raised segment on a sunken track"], ["Hover", "hover overlay on an unselected segment"], ["Pressed", "pressed overlay"], ["Focused", "ring on the selected segment"], ["Disabled with reason", "tertiary text, reason underneath"]],
        tokens: ["--surface-sunken", "--surface-content", "--radius-control", "--motion-fast"],
        access: "A radio group: arrows move the selection, VoiceOver reads “Week, selected, 2 of 3”.",
      },
      stories: [
        { name: "Default" }, { name: "Segment hover", args: { hoverAt: 2 } }, { name: "Focused", args: { state: "focused" } },
        { name: "Two segments", args: { options: "Tokens, Runs", selected: 0 } }, { name: "Disabled with reason", args: { disabled: true } },
      ],
    },
    {
      title: "Chip",
      args: { kind: "status", text: "Waiting on you", role: "you", interactive: true, pressed: false, removable: false, state: "default", disabled: false, reason: "No ticket in this repo matches the other filters." },
      controls: [
        { name: "kind", label: "Kind", type: "select", options: [{ value: "status", label: "Status" }, { value: "repo", label: "Repo" }, { value: "epic", label: "Epic" }, { value: "label", label: "Label" }] },
        { name: "text", label: "Text", type: "text" },
        { name: "role", label: "Colour role", type: "role", when: (p) => p.kind === "status" || p.kind === "label" },
        { name: "interactive", label: "Is a filter", type: "toggle" },
        { name: "pressed", label: "Selected", type: "toggle", when: (p) => p.interactive },
        { name: "removable", label: "Removable", type: "toggle" },
        STATE, DISABLED, REASON,
      ],
      render: (p) => {
        const c = chip(Object.assign({}, p, { pressed: p.interactive ? p.pressed : undefined, toggle: p.interactive ? "pressed" : null, key: "chip" }));
        return p.disabled ? '<span class="btn-group">' + c + refusal(p.reason) + "</span>" : c;
      },
      docs: {
        what: "A compact tag for what a ticket is or where it belongs: its status, its repo, its epic, a label. As a filter it toggles on and off.",
        when: ["Status chips carry the status glyph and word on the status tint.", "Repo and epic chips carry their glyph; label chips a small colour swatch.", "In a filter bar every chip is a toggle; selected chips show the accent outline."],
        avoid: "Chips as buttons for moves, or a status chip without its word.",
        states: [["Default", "raised or tinted capsule"], ["Hover", "tint up to 26 %"], ["Pressed", "one step darker"], ["Selected", "accent tint and outline"], ["Focused", "focus ring"], ["Disabled with reason", "tertiary, reason underneath"]],
        tokens: ["--tint-*", "--surface-raised", "--accent-tint", "--radius-capsule", "--type-label"],
        access: "A filter chip is a toggle button: VoiceOver reads “symphony, repo filter, selected”.",
      },
      stories: [
        { name: "Status" },
        { name: "Status working", args: { text: "Working", role: "working" } },
        { name: "Repo", args: { kind: "repo", text: "symphony" } },
        { name: "Epic", args: { kind: "epic", text: "Phase 3b · The Director redesigned" } },
        { name: "Label", args: { kind: "label", text: "qa:skip", role: "idle", interactive: false } },
        { name: "Hover", args: { state: "hover" } },
        { name: "Pressed", args: { state: "pressed", kind: "repo", text: "symphony" } },
        { name: "Selected", args: { pressed: true, kind: "repo", text: "symphony" } },
        { name: "Focused", args: { state: "focused", kind: "repo", text: "symphony" } },
        { name: "Removable", args: { kind: "epic", text: "Phase 3b", removable: true, pressed: true } },
        { name: "Disabled with reason", args: { kind: "repo", text: "web-shop", disabled: true } },
      ],
    },
    {
      title: "Badge",
      args: { role: "you", word: "", size: "regular" },
      controls: [
        { name: "role", label: "Colour role", type: "select", options: ROLE_OPTIONS.concat([{ value: "accent", label: "Recommended (accent)" }]) },
        { name: "word", label: "Word (blank: the role's)", type: "text" },
        { name: "size", label: "Size", type: "select", options: ["small", "regular", "large"] },
      ],
      render: (p) => badge(p.role, p.word || (p.role === "accent" ? "Recommended" : ""), p.size, p.role === "accent"),
      docs: {
        what: "A status glyph and word on the status tint: the one way the Director says what state something is in.",
        when: ["In rows, headers and popovers, next to what it describes.", "Recommended on a Question option is not a status: it uses the accent tint and no glyph."],
        avoid: "A badge as a button, or colour without the word.",
        states: [["One per status", "Waiting on you, Working, Needs attention, Done, Paused, Forced"], ["Small, regular, large", "11, 11 and 13 pt words"]],
        tokens: ["--tint-*", "--status-*", "--text-primary", "--radius-capsule"],
        access: "VoiceOver reads the word only.",
      },
      stories: Object.keys(ROLES).map((k) => ({ name: ROLES[k].word, args: { role: k } })).concat([
        { name: "Small", args: { role: "working", size: "small" } },
        { name: "Large", args: { role: "problem", size: "large", word: "Checks failed" } },
        { name: "Recommended", args: { role: "accent" } },
      ]),
    },
    {
      title: "Count badge",
      args: { count: 4, role: "you", quiet: false },
      controls: [{ name: "count", label: "Count", type: "number", min: 0 }, { name: "role", label: "Colour role", type: "role" }, { name: "quiet", label: "Quiet (no colour)", type: "toggle" }],
      render: (p) => {
        const n = Number(p.count) || 0;
        if (n <= 0) return '<span class="t-secondary">Zero: the count badge is not drawn.</span>';
        return '<span class="dot-label">' + icon("tray") + ' <span>Inbox</span><span class="count' + (p.quiet ? " count-quiet" : " role-" + esc(p.role)) + '" aria-label="' + n + ' waiting">' + (n > 99 ? "99+" : n) + "</span></span>";
      },
      docs: {
        what: "How many things wait in a place: the Inbox, a board group, a filter.",
        when: ["Coloured only for what needs the Director (orange) or a problem (red); every other count is quiet."],
        states: [["Count", "1 to 99"], ["Over 99", "99+"], ["Quiet", "secondary text on sunken"], ["Zero", "not drawn at all"]],
        tokens: ["--status-you", "--status-problem", "--surface-sunken", "--radius-capsule"],
        access: "Read as part of its place: “Inbox, 4 waiting”.",
      },
      stories: [{ name: "Waiting on you" }, { name: "Problems", args: { role: "problem", count: 2 } }, { name: "Over 99", args: { count: 128 } }, { name: "Quiet", args: { quiet: true, count: 12 } }, { name: "Zero", args: { count: 0 } }],
    },
    {
      title: "Status dot",
      args: { role: "working", live: false, label: "Dispatch on" },
      controls: [{ name: "role", label: "Colour role", type: "role" }, { name: "live", label: "Live (pulses)", type: "toggle" }, { name: "label", label: "Word beside it", type: "text" }],
      render: (p) => '<span class="dot-label"><span class="dot dot-lg role-' + esc(p.role) + (p.live ? " live" : "") + '"></span>' + (p.label ? "<span>" + esc(p.label) + "</span>" : "") + "</span>",
      docs: {
        what: "The smallest status mark, for a dense place where a glyph would be too heavy: the dispatch control, a connection state, a legend.",
        when: ["Always beside a word. It pulses only for something live and visible, and never with Reduce Motion."],
        states: [["One per status", "the six status colours"], ["Live", "a slow pulse while working"]],
        tokens: ["--status-*", "--motion-standard"],
      },
      stories: Object.keys(ROLES).map((k) => ({ name: ROLES[k].word, args: { role: k, label: ROLES[k].word } })).concat([{ name: "Working, live", args: { role: "working", live: true, label: "3 working" } }]),
    },
    {
      title: "Situation line",
      args: { role: "working", word: "Waiting for CI", cause: "Checks are running on PR #812.", waits: "Code Review starts when they pass.", age: "6 min", size: "regular", compact: false },
      controls: [
        { name: "role", label: "Colour role", type: "role" },
        { name: "word", label: "Where it stands", type: "text" },
        { name: "cause", label: "Cause", type: "text" },
        { name: "waits", label: "What it waits on", type: "text" },
        { name: "age", label: "Age", type: "text" },
        { name: "size", label: "Size", type: "select", options: ["regular", "large"] },
        { name: "compact", label: "Compact (no wait)", type: "toggle" },
      ],
      render: (p) => '<div style="width:640px">' + situation(p) + "</div>",
      docs: {
        what: "One line that says where a ticket stands: a glyph and a word in its status colour, the cause, what it waits on, and for how long. It opens the ticket page and sits under every row that needs a reason.",
        when: ["The word is the situation in the Director's words (Waiting for CI, Waiting on you, Writing the code, Needs attention).", "The cause is one short sentence of fact; the wait names who or what moves it next.", "The age counts from when this situation began, not from when the ticket was filed."],
        avoid: "Internal state names, two situations in one line, or a line that runs past the measure.",
        states: [["Waiting for CI", "working, waits on checks"], ["Waiting on you", "you, waits on an answer"], ["Writing the code", "working"], ["Needs attention", "problem, names its fix"], ["Paused", "idle, names what lifts it"], ["Forced", "forced"], ["Shipped", "done"], ["Large", "page header size"], ["Compact", "the wait left out, for rows"]],
        tokens: ["--status-*", "--status-*-text", "--type-body", "--measure"],
        access: "Read as one sentence: “Waiting for CI. Checks are running on PR 812. Code Review starts when they pass. 6 minutes.”",
      },
      stories: [
        { name: "Waiting for CI" },
        { name: "Waiting on you", args: { role: "you", word: "Waiting on you", cause: "A question: should the catalog ship as it is?", waits: "Answer it in the Inbox.", age: "3 h 12 min" } },
        { name: "Writing the code", args: { role: "working", word: "Writing the code", cause: "Implementation run 2 is on the tests step.", waits: "Hands off to Code Review when it pushes.", age: "14 min" } },
        { name: "Needs attention", args: { role: "problem", word: "Needs attention", cause: "Checks failed: two tests in the orchestrator.", waits: "A fix run starts on its own.", age: "22 min" } },
        { name: "Paused", args: { role: "idle", word: "Paused", cause: "Dispatch is paused: Deploy freeze.", waits: "Starts when you resume dispatch.", age: "1 h 4 min" } },
        { name: "Forced", args: { role: "forced", word: "Forced", cause: "You pushed it ahead of the queue.", waits: "Runs as soon as a slot frees.", age: "2 min" } },
        { name: "Shipped", args: { role: "done", word: "Shipped", cause: "Merged as PR #797.", waits: "", age: "yesterday" } },
        { name: "Large", args: { size: "large" } },
        { name: "Compact", args: { compact: true } },
      ],
    },
    {
      title: "Progress meter",
      args: { label: "Tokens today", used: 2100000, cap: 5000000, unit: "tokens", resets: "at midnight" },
      controls: [
        { name: "label", label: "Label", type: "text" },
        { name: "used", label: "Used", type: "number", min: 0, step: 100000 },
        { name: "cap", label: "Cap", type: "number", min: 1, step: 100000 },
        { name: "unit", label: "Unit", type: "select", options: ["tokens", "runs"] },
        { name: "resets", label: "Resets", type: "text" },
      ],
      render: (p) => meter(p),
      docs: {
        what: "How much of a cap is used: tokens against the daily budget, a ticket against its token cap, runs against a limit.",
        when: ["The fill carries severity: accent below 75 %, orange from 75 %, red from 95 %. The note under it says what happens at the cap, in words."],
        states: [["Calm", "below 75 %"], ["Near the cap", "75 to 95 %"], ["At the cap", "95 % and over"], ["Empty", "nothing used yet"]],
        tokens: ["--accent", "--status-you", "--status-problem", "--radius-mark", "--motion-standard"],
        access: "A meter: “Tokens today, 42 percent”.",
      },
      stories: [
        { name: "Calm" }, { name: "Near the cap", args: { used: 4100000 } }, { name: "At the cap", args: { used: 4900000 } },
        { name: "Ticket cap", args: { label: "TP-1382 against its cap", used: 7600000, cap: 8000000, resets: "never: the cap is per ticket" } },
        { name: "Empty", args: { used: 0 } },
      ],
    },
    {
      title: "Stacked stage bar",
      args: { label: "Time by stage", code: 42, review: 18, qa: 25, merge: 6, waiting: 70, unit: "min" },
      controls: [
        { name: "label", label: "Label", type: "text" },
        { name: "code", label: "Writing the code", type: "number", min: 0 },
        { name: "review", label: "Code Review", type: "number", min: 0 },
        { name: "qa", label: "QA", type: "number", min: 0 },
        { name: "merge", label: "Merging", type: "number", min: 0 },
        { name: "waiting", label: "Waiting on you", type: "number", min: 0 },
        { name: "unit", label: "Unit", type: "select", options: ["min", "M tokens"] },
      ],
      render: (p) => {
        const parts = [["Writing the code", p.code, "s1"], ["Code Review", p.review, "s2"], ["QA", p.qa, "s3"], ["Merging", p.merge, "s4"], ["Waiting on you", p.waiting, "s5"]];
        const total = parts.reduce((a, x) => a + (Number(x[1]) || 0), 0);
        const track = total ? '<div class="stage-track" role="img" aria-label="' + esc(p.label) + '">' + parts.filter((x) => Number(x[1]) > 0).map((x) => '<span class="stage-seg ' + x[2] + '" style="flex:' + Number(x[1]) + '" title="' + esc(x[0]) + ": " + esc(x[1]) + " " + esc(p.unit) + '"></span>').join("") + "</div>" : '<div class="stage-track empty"></div>';
        return '<div class="stage-bar"><div class="meter-head"><span>' + esc(p.label) + '</span><span class="value">' + (total ? esc(total) + " " + esc(p.unit) + " in all" : "Nothing yet") + "</span></div>" + track +
          '<ul class="stage-legend">' + parts.map((x) => '<li><span class="key stage-seg ' + x[2] + '"></span>' + esc(x[0]) + ' <span class="v">' + esc(x[1] || 0) + "</span></li>").join("") + "</ul></div>";
      },
      docs: {
        what: "Where a ticket's time or tokens went, stage by stage, as one bar split into segments with a legend that carries the numbers.",
        when: ["Segments keep their landing order left to right. The legend is always there, so colour is never the only way to read it."],
        avoid: "Status colours in the segments (they are stages, not states) other than the gray for waiting.",
        states: [["Typical", "every stage present"], ["One stage dominant", "a stuck review"], ["Empty", "a track with “Nothing yet”"]],
        tokens: ["chart series 1 to 4", "--status-idle", "--radius-mark"],
      },
      stories: [{ name: "Typical ticket" }, { name: "Stuck in review", args: { review: 180, qa: 0, merge: 0, waiting: 5 } }, { name: "Tokens by stage", args: { label: "Tokens by stage", code: 4.2, review: 0.8, qa: 1.1, merge: 0.1, waiting: 0, unit: "M tokens" } }, { name: "Empty", args: { code: 0, review: 0, qa: 0, merge: 0, waiting: 0 } }],
    },
    {
      title: "Text field",
      args: { label: "Reason", value: "", placeholder: "Deploy freeze", help: "Shown to everyone who sees the pause.", error: "", state: "default", disabled: false, reason: "The reason is set by the rule that paused it." },
      controls: [
        { name: "label", label: "Label", type: "text" }, { name: "value", label: "Value", type: "text" }, { name: "placeholder", label: "Placeholder", type: "text" },
        { name: "help", label: "Help", type: "text" }, { name: "error", label: "Error", type: "text" }, STATE_NO_PRESS, DISABLED, REASON,
      ],
      render: (p) => '<div class="field"><label for="tf">' + esc(p.label) + '</label><div class="input' + (p.error ? " invalid" : "") + (p.disabled ? " disabled" : stateClass(p.state)) + '">' +
        '<input id="tf" value="' + esc(p.value) + '" placeholder="' + esc(p.placeholder) + '"' + (p.disabled ? " disabled" : "") + "></div>" +
        (p.disabled ? refusal(p.reason) : p.error ? '<span class="error">' + esc(p.error) + "</span>" : p.help ? '<span class="help">' + esc(p.help) + "</span>" : "") + "</div>",
      docs: {
        what: "One line of text the Director types: a reason, a name, a number.",
        when: ["The label sits above; help or the error sits under it, never both. The error says what to change."],
        states: [["Empty", "placeholder in tertiary"], ["Filled", "value in primary"], ["Hover", "stronger edge"], ["Focused", "accent edge and focus ring"], ["Error", "red edge and the message"], ["Disabled with reason", "raised, reason underneath"]],
        tokens: ["--surface-content", "--stroke-strong", "--accent", "--status-problem", "--radius-control", "--focus-ring"],
      },
      stories: [
        { name: "Empty" }, { name: "Filled", args: { value: "Deploy freeze" } }, { name: "Hover", args: { state: "hover" } }, { name: "Focused", args: { state: "focused", value: "Deploy fr" } },
        { name: "Error", args: { value: "", error: "Give a reason so the pause explains itself.", state: "focused" } }, { name: "Disabled with reason", args: { disabled: true, value: "Claude usage limit" } },
      ],
    },
    {
      title: "Search field",
      args: { query: "", placeholder: "Search tickets", state: "default", results: 12 },
      controls: [{ name: "query", label: "Query", type: "text" }, { name: "placeholder", label: "Placeholder", type: "text" }, { name: "results", label: "Results", type: "number", min: 0 }, STATE_NO_PRESS],
      render: (p) => '<div class="field" style="width:280px"><div class="input search' + stateClass(p.state) + '">' + icon("search") +
        '<input type="search" aria-label="' + esc(p.placeholder) + '" value="' + esc(p.query) + '" placeholder="' + esc(p.placeholder) + '">' +
        (p.query ? '<span class="result-count">' + (Number(p.results) ? esc(p.results) + " found" : "None") + '</span><button type="button" class="clear" aria-label="Clear the search" data-set="query=" data-key="clr">' + icon("close") + "</button>" : kbd("⌘ F")) + "</div>" +
        (p.query && !Number(p.results) ? '<span class="help">Nothing matches “' + esc(p.query) + "”. Search looks at identifiers and titles.</span>" : "") + "</div>",
      docs: {
        what: "Filters the current list as the Director types. Its shortcut is ⌘F.",
        when: ["The count of matches shows inside the field; the clear button appears once there is a query."],
        states: [["Empty", "glyph, placeholder, shortcut"], ["Focused", "focus ring"], ["With a query", "count and clear"], ["No results", "a line that says what it searched"]],
        tokens: ["--surface-sunken", "--focus-ring", "--text-tertiary"],
      },
      stories: [{ name: "Empty" }, { name: "Hover", args: { state: "hover" } }, { name: "Focused", args: { state: "focused" } }, { name: "With a query", args: { query: "catalog", results: 3 } }, { name: "No results", args: { query: "storybook", results: 0 } }],
    },
    {
      title: "Pop-up",
      args: { label: "Repo", value: "All repos", options: "All repos, symphony, web-shop", open: false, state: "default", disabled: false, reason: "Only one repo is set up." },
      controls: [{ name: "label", label: "Label", type: "text" }, { name: "value", label: "Value", type: "text" }, { name: "options", label: "Choices", type: "text" }, { name: "open", label: "Open", type: "toggle" }, STATE, DISABLED, REASON],
      render: (p) => {
        const opts = String(p.options).split(",").map((s) => s.trim()).filter(Boolean);
        const menu = p.open && !p.disabled ? '<ul class="menu" role="listbox">' + opts.map((o) => '<li class="menu-item" role="option" aria-checked="' + (o === p.value) + '" data-set="value=' + esc(o) + '">' + icon("check", "check") + esc(o) + "</li>").join("") + "</ul>" : "";
        const b = '<button type="button" class="popup' + (p.disabled ? "" : stateClass(p.state)) + '" aria-haspopup="listbox" aria-expanded="' + (!!p.open && !p.disabled) + '"' + (p.disabled ? ' aria-disabled="true"' + attr("title", p.reason) : ' data-toggle="open" data-key="pu"') + ">" +
          '<span class="popup-label"><span>' + esc(p.label) + "</span><span>" + esc(p.value) + "</span></span>" + icon("updown", "chev") + "</button>";
        return '<div style="min-height:' + (p.open ? 40 + opts.length * 26 : 40) + 'px"><span class="menu-wrap">' + b + menu + "</span>" + (p.disabled ? '<div style="margin-top:4px">' + refusal(p.reason) + "</div>" : "") + "</div>";
      },
      docs: {
        what: "One choice out of a list too long for a segmented control: a repo, an epic, a unit.",
        when: ["The label names what is chosen and the value shows the choice; the open list ticks the current one."],
        states: [["Default", "label and value"], ["Hover", "one step darker"], ["Pressed", "two steps darker"], ["Open", "the list with a tick"], ["Focused", "focus ring"], ["Disabled with reason", "reason underneath"]],
        tokens: ["--elevation-2", "--radius-control", "--accent"],
      },
      stories: [{ name: "Default" }, { name: "Hover", args: { state: "hover" } }, { name: "Pressed", args: { state: "pressed" } }, { name: "Open", args: { open: true } }, { name: "Focused", args: { state: "focused" } }, { name: "Disabled with reason", args: { disabled: true, value: "symphony" } }],
    },
    {
      title: "Toggle",
      args: { label: "Notify me about new questions", effect: "A notification for each new question in the Inbox.", on: true, state: "default", disabled: false, reason: "Notifications are off for Symphony in System Settings." },
      controls: [{ name: "label", label: "Label", type: "text" }, { name: "effect", label: "One-line effect", type: "text" }, { name: "on", label: "On", type: "toggle" }, STATE, DISABLED, REASON],
      render: (p) => '<div class="toggle-row"><span class="label" id="tg-l">' + esc(p.label) + '</span><span class="effect">' + (p.disabled ? refusal(p.reason) : esc(p.effect)) + "</span>" +
        '<button type="button" role="switch" class="switch' + (p.disabled ? "" : stateClass(p.state)) + '" aria-labelledby="tg-l" aria-checked="' + !!p.on + '"' + (p.disabled ? ' aria-disabled="true"' : ' data-toggle="on" data-key="sw"') + "></button></div>",
      docs: {
        what: "A setting that is on or off, with one line under its label that says what being on does.",
        when: ["The effect line is a consequence, not a restatement of the label. The change applies at once."],
        states: [["Off", "sunken track"], ["On", "accent track"], ["Hover", "slightly brighter"], ["Pressed", "knob stretches"], ["Focused", "focus ring"], ["Disabled with reason", "the reason replaces the effect line"]],
        tokens: ["--accent", "--surface-sunken", "--motion-standard", "--radius-capsule"],
        access: "A switch: “Notify me about new questions, on”, with the effect as its help.",
      },
      stories: [{ name: "On" }, { name: "Off", args: { on: false } }, { name: "Hover", args: { state: "hover" } }, { name: "Pressed", args: { state: "pressed" } }, { name: "Focused", args: { state: "focused" } }, { name: "Disabled with reason", args: { disabled: true, on: false } }],
    },
    {
      title: "Tooltip",
      args: { text: "Approve and Merge is off: checks are still running on PR #812.", placement: "above", always: true },
      controls: [{ name: "text", label: "Text", type: "textarea" }, { name: "placement", label: "Placement", type: "select", options: ["above", "below"] }, { name: "always", label: "Always shown", type: "toggle" }],
      render: (p) => '<div style="padding:70px 0"><span class="tooltip-demo">' + button({ label: "Approve and Merge…", variant: "primary", disabled: true, showReason: false }) +
        '<span class="tooltip ' + esc(p.placement) + (p.always ? "" : " on-hover") + '" role="tooltip">' + esc(p.text) + "</span></span></div>",
      docs: {
        what: "Help that appears after 0.5 s of hover: the full text of something cut short, the reason a control is off, an absolute time.",
        when: ["Short, plain sentences, at most 260 pt wide."],
        avoid: "Anything the Director needs to act: that goes on the page, not in a tooltip.",
        states: [["Above / below", "placement"], ["On hover", "fades in after the hover delay"], ["Long text", "wraps at 260 pt"]],
        tokens: ["--elevation-2", "--motion-hover-delay", "--radius-control", "--type-secondary"],
      },
      stories: [{ name: "Above" }, { name: "Below", args: { placement: "below" } }, { name: "Long text wraps", args: { text: "This ticket waits on TP-1383 (Three ticket page prototypes). It starts on its own once TP-1383 is done, or when you remove the link." } }, { name: "On hover (live)", args: { always: false, text: "Hover the button: I appear after half a second." } }],
    },
    {
      title: "Row",
      args: Object.assign({}, TICKETS[1], { twoLine: false, selected: false, unfocused: false, live: false, state: "default", fix: "", fixDisabled: false, fixReason: "" }),
      controls: [
        { name: "ident", label: "Identifier", type: "text" }, { name: "title", label: "Title", type: "text" }, { name: "role", label: "Colour role", type: "role" },
        { name: "badge", label: "Badge word", type: "text" }, { name: "age", label: "Age", type: "text" }, { name: "twoLine", label: "Two lines", type: "toggle" },
        { name: "line2", label: "Second line", type: "text", when: (p) => p.twoLine }, { name: "selected", label: "Selected", type: "toggle" },
        { name: "unfocused", label: "Window not focused", type: "toggle", when: (p) => p.selected }, { name: "live", label: "Live (working)", type: "toggle" },
        { name: "fix", label: "Fix button", type: "text" }, { name: "fixDisabled", label: "Fix disabled", type: "toggle", when: (p) => p.fix }, { name: "fixReason", label: "Fix disabled reason", type: "text", when: (p) => p.fix && p.fixDisabled },
        STATE,
      ],
      render: (p) => '<div style="width:640px" role="listbox" aria-label="Tickets">' + row(Object.assign({}, p, { toggle: "selected", key: "row" })) + "</div>",
      docs: {
        what: "One ticket in a list: its status glyph, identifier and title, a badge, its age, and when it has a problem, the button that fixes it.",
        when: ["One line (28 pt) in dense lists, two lines (44 pt) when the second line carries the situation.", "Clicking selects; Return or a double click opens the ticket page.", "A problem row ends with its fix button; a disabled fix says why in place of the button's action."],
        states: [["Default", "no background"], ["Hover", "hover overlay at radius 10"], ["Pressed", "pressed overlay"], ["Selected", "accent fill, white text"], ["Selected, window not focused", "gray fill"], ["Focused", "focus ring"], ["Working", "a live dot in place of the glyph"]],
        tokens: ["--surface-hover", "--surface-pressed", "--accent", "--radius-row", "--type-row-title", "--motion-fast"],
        access: "One element: “TP-1376, A CI-wait pause lifts itself…, symphony, working, 14 minutes”; its buttons are custom actions.",
      },
      stories: [
        { name: "Default" }, { name: "Hover", args: { state: "hover" } }, { name: "Pressed", args: { state: "pressed" } }, { name: "Selected", args: { selected: true } },
        { name: "Selected, window not focused", args: { selected: true, unfocused: true } }, { name: "Focused", args: { state: "focused" } },
        { name: "Two lines", args: { twoLine: true } }, { name: "Working, live", args: { live: true, twoLine: true } },
        { name: "With a fix", args: Object.assign({}, TICKETS[2], { twoLine: true, fix: "Open Checks", fixPrimary: true }) },
        { name: "Fix disabled with reason", args: Object.assign({}, TICKETS[2], { twoLine: true, fix: "Run Again", fixDisabled: true, fixReason: "A fix run is already working" }) },
        { name: "Waiting on you", args: Object.assign({}, TICKETS[0], { twoLine: true }) },
      ],
    },
    {
      title: "Table header and row",
      args: { sort: "age-desc", hoverHeader: "", hoverRow: -1, selectedRow: -1, focusedRow: -1, empty: false },
      controls: [
        { name: "sort", label: "Sorted by", type: "select", options: [{ value: "ident-asc", label: "Ticket, A to Z" }, { value: "ident-desc", label: "Ticket, Z to A" }, { value: "age-desc", label: "Age, oldest first" }, { value: "age-asc", label: "Age, newest first" }, { value: "tokens-desc", label: "Tokens, most first" }, { value: "tokens-asc", label: "Tokens, least first" }] },
        { name: "hoverHeader", label: "Shown header hover", type: "select", options: [{ value: "", label: "None (live)" }, { value: "ident", label: "Ticket" }, { value: "age", label: "Age" }, { value: "tokens", label: "Tokens" }] },
        { name: "hoverRow", label: "Shown row hover", type: "number", min: -1, max: 4 },
        { name: "selectedRow", label: "Selected row", type: "number", min: -1, max: 4 },
        { name: "focusedRow", label: "Focused row", type: "number", min: -1, max: 4 },
        { name: "empty", label: "Empty", type: "toggle" },
      ],
      render: (p) => table(p),
      docs: {
        what: "A sortable table for comparing many tickets on the same columns: Tickets, Usage, Shipped.",
        when: ["Header labels are short nouns; clicking one sorts by it, clicking again reverses. The sorted column shows its arrow.", "Numbers align right with tabular figures."],
        states: [["Header default", "secondary label"], ["Header hover", "hover overlay"], ["Header sorted", "primary label with an arrow"], ["Row hover", "hover overlay"], ["Row selected", "accent fill"], ["Row focused", "focus ring"], ["Empty", "one line that says why and how to widen the filter"]],
        tokens: ["--stroke-separator", "--surface-hover", "--accent", "--type-label", "--radius-row"],
        access: "Column headers are sort buttons that read their order: “Age, sorted, oldest first”.",
      },
      stories: [
        { name: "Default" }, { name: "Header hover", args: { hoverHeader: "tokens" } }, { name: "Sorted by tokens", args: { sort: "tokens-desc" } },
        { name: "Row hover", args: { hoverRow: 1 } }, { name: "Row selected", args: { selectedRow: 2 } }, { name: "Row focused", args: { focusedRow: 0 } }, { name: "Empty", args: { empty: true } },
      ],
    },
    {
      title: "Card",
      args: { title: "What happened", body: "Code Review sent PR #812 back once: the timeline missed the run that was stopped. Run 2 added it, and the checks pass.", link: "", clickable: false, selected: false, state: "default", empty: false },
      controls: [
        { name: "title", label: "Title", type: "text" }, { name: "body", label: "Body", type: "textarea" }, { name: "link", label: "Trailing link", type: "text" },
        { name: "clickable", label: "Opens something", type: "toggle" }, { name: "selected", label: "Selected", type: "toggle" }, { name: "empty", label: "Empty", type: "toggle" }, STATE,
      ],
      render: (p) => '<div style="width:460px">' + card(Object.assign({}, p, { state: p.clickable || p.state === "focused" ? p.state : "" })) + "</div>",
      docs: {
        what: "A titled block of content on the content surface. Most of a page is cards.",
        when: ["Title in sentence case; an optional trailing link (Show All) opens more of the same.", "A card that opens something as a whole is clickable and gets hover and pressed; others have no hover."],
        avoid: "A card with nothing to say: hide it (Quiet when healthy). Use the empty state only where its absence would confuse.",
        states: [["Default", "content surface, hairline"], ["With a link", "trailing link"], ["Clickable: hover, pressed", "raised surface"], ["Focused", "focus ring"], ["Selected", "accent outline"], ["Empty", "one quiet line"]],
        tokens: ["--surface-content", "--elevation-1", "--radius-card", "--space-4", "--type-heading"],
      },
      stories: [
        { name: "Default" }, { name: "With a link", args: { title: "Runs", link: "Show All", body: "3 runs, 1 h 12 min in all." } },
        { name: "Clickable", args: { clickable: true, title: "Waiting on you", body: "4 questions, the oldest for 3 h 12 min." } },
        { name: "Clickable hover", args: { clickable: true, state: "hover", title: "Waiting on you", body: "4 questions, the oldest for 3 h 12 min." } },
        { name: "Clickable pressed", args: { clickable: true, state: "pressed", title: "Waiting on you", body: "4 questions, the oldest for 3 h 12 min." } },
        { name: "Focused", args: { clickable: true, state: "focused", title: "Waiting on you", body: "4 questions, the oldest for 3 h 12 min." } },
        { name: "Selected", args: { selected: true } }, { name: "Empty", args: { empty: true, title: "Attachments" } },
      ],
    },
    {
      title: "Collapsible card",
      args: { title: "Earlier runs", summary: "3 runs · 1 h 12 min", expanded: true, state: "default", empty: false },
      controls: [{ name: "title", label: "Title", type: "text" }, { name: "summary", label: "Summary when folded", type: "text" }, { name: "expanded", label: "Open", type: "toggle" }, { name: "empty", label: "Empty", type: "toggle" }, STATE_NO_PRESS],
      render: (p) => '<div style="width:520px"><section class="card collapsible"><button type="button" class="fold-head' + stateClass(p.state) + '" aria-expanded="' + (!!p.expanded && !p.empty) + '"' + (p.empty ? ' aria-disabled="true"' : ' data-toggle="expanded" data-key="fold"') + ">" +
        (p.empty ? "" : icon("chevron-right", "disclose")) + esc(p.title) + '<span class="summary">' + esc(p.empty ? "None yet" : p.summary) + "</span></button>" +
        (p.expanded && !p.empty ? '<div class="fold-body"><div class="list">' + TICKETS.slice(3, 6).map((t) => row(t)).join("") + "</div></div>" : "") + "</section></div>",
      docs: {
        what: "A card whose body folds away, for history and detail the Director opens on demand.",
        when: ["Folded, the header still says what is inside (a count, a duration). The fold is remembered per card."],
        states: [["Open", "chevron down"], ["Folded", "chevron right and the summary"], ["Header hover", "hover overlay"], ["Header focused", "focus ring"], ["Empty", "no chevron, “None yet”"]],
        tokens: ["--radius-card", "--surface-hover", "--motion-standard"],
        access: "The header is a disclosure button: “Earlier runs, collapsed, 3 runs”.",
      },
      stories: [{ name: "Open" }, { name: "Folded", args: { expanded: false } }, { name: "Header hover", args: { expanded: false, state: "hover" } }, { name: "Header focused", args: { expanded: false, state: "focused" } }, { name: "Empty", args: { empty: true } }],
    },
    {
      title: "Key-value list",
      args: { layout: "columns", grouped: false, missing: false },
      controls: [{ name: "layout", label: "Layout", type: "select", options: [{ value: "columns", label: "Two columns" }, { value: "stacked", label: "Stacked (narrow)" }] }, { name: "grouped", label: "Grouped", type: "toggle" }, { name: "missing", label: "Some values unknown", type: "toggle" }],
      render: (p) => {
        const a = [["Stage", badge("you", "Waiting on you", "small"), true], ["Repo", chip({ kind: "repo", text: "symphony", interactive: false }), true], ["Pull request", "PR #812 · checks passing"], ["Part of", p.missing ? "" : "TP-1381 · Phase 3b"]];
        const b = [["Runs", "3 · 1 h 12 min"], ["Tokens", p.missing ? "" : "6.2M of 8M"], ["Waiting since", "Today 11:15"]];
        if (!p.grouped) return '<div style="width:360px">' + kv(a.concat(b), p.layout === "stacked") + "</div>";
        return '<div style="width:360px"><div class="kv-group"><h4>Now</h4>' + kv(a, p.layout === "stacked") + '</div><div class="kv-group"><h4>Work</h4>' + kv(b, p.layout === "stacked") + "</div></div>";
      },
      docs: {
        what: "Facts about one thing as label and value pairs: the facts rail, popovers, the review's context card.",
        when: ["Labels in secondary, values in primary; a value can be a chip or a badge.", "A fact that is unknown is left out, never shown as a dash or “unknown”."],
        states: [["Two columns", "labels left"], ["Stacked", "labels above values, under 300 pt"], ["Grouped", "small caps headings"], ["Values unknown", "those rows left out"]],
        tokens: ["--text-secondary", "--space-4", "--type-label"],
      },
      stories: [{ name: "Default" }, { name: "Grouped", args: { grouped: true } }, { name: "Stacked", args: { layout: "stacked" } }, { name: "Values left out", args: { missing: true } }],
    },
    {
      title: "Timeline entry",
      args: { kind: "phase", time: "09:02", strong: "Moved to Code Review", rest: "from In Progress", detail: "The push opened PR #812", actor: "Symphony", state: "default" },
      controls: [
        { name: "kind", label: "Class", type: "select", options: TL_OPTIONS },
        { name: "time", label: "Time", type: "text" }, { name: "strong", label: "What", type: "text" }, { name: "rest", label: "More", type: "text" },
        { name: "detail", label: "Detail", type: "text" }, { name: "actor", label: "Who", type: "text" }, STATE_NO_PRESS,
      ],
      render: (p) => '<ol class="timeline" style="width:560px">' + tlEntry(Object.assign({}, p, { headHtml: head(p.strong, p.rest) })) + "</ol>",
      docs: {
        what: "One thing that happened to a ticket, at a time, with a glyph and colour per class so a day reads at a glance.",
        when: ["Phase move: arrow, accent. Pause set: pause, gray. Pause cleared: play, blue. Question asked: speech bubble, orange. Question answered: bubble with a tick, green. Run started: play circle, blue. Run ended: its verdict (passed green, failed red, stopped gray). Person action: hand, accent. Rule action: gear, gray.", "The first words in bold say what happened; detail and who did it follow in secondary."],
        states: [["Each class", "glyph and colour above"], ["Hover", "hover overlay"]],
        tokens: ["--tint-*", "--status-*", "--accent", "--type-secondary", "--measure"],
        access: "Each entry reads “09:02, phase move, moved to Code Review from In Progress, Symphony”.",
      },
      stories: [
        { name: "Phase move" },
        { name: "Pause set", args: { kind: "pause-set", strong: "Paused:", rest: "Deploy freeze", detail: "Dispatch paused for every ticket", actor: "Tony" } },
        { name: "Pause cleared", args: { kind: "pause-cleared", strong: "Pause cleared", rest: "", detail: "Dispatch resumed", actor: "Tony" } },
        { name: "Question asked", args: { kind: "question-asked", strong: "Question asked:", rest: "Review the design catalog", detail: "Two options, one recommended", actor: "" } },
        { name: "Question answered", args: { kind: "question-answered", strong: "Answered:", rest: "“Approve the catalog”", detail: "", actor: "Tony, in the Inbox" } },
        { name: "Run started", args: { kind: "run-started", strong: "Implementation run 2 started", rest: "", detail: "Claude", actor: "" } },
        { name: "Run ended, passed", args: { kind: "run-passed", strong: "Code Review passed", rest: "", detail: "8 min · no findings", actor: "" } },
        { name: "Run ended, failed", args: { kind: "run-failed", strong: "Implementation run 1 ended:", rest: "checks failed", detail: "22 min · 1.4M tokens", actor: "" } },
        { name: "Run ended, stopped", args: { kind: "run-stopped", strong: "Run stopped", rest: "", detail: "After 4 min", actor: "Tony" } },
        { name: "Person action", args: { kind: "person", strong: "Forced ahead of the queue", rest: "", detail: "", actor: "Tony" } },
        { name: "Rule action", args: { kind: "rule", strong: "Branch updated", rest: "with the newest main", detail: "Rule: keep the branch current while in Merging", actor: "" } },
        { name: "Hover", args: { state: "hover" } },
      ],
    },
    {
      title: "Run group",
      args: { title: "Implementation run 2", verdict: "passed", time: "10:05", duration: "22 min", tokens: "1.8M tokens", expanded: false, state: "default" },
      controls: [
        { name: "title", label: "Title", type: "text" }, { name: "verdict", label: "Verdict", type: "select", options: ["passed", "failed", "running", "stopped"] },
        { name: "time", label: "Started", type: "text" }, { name: "duration", label: "Duration", type: "text" }, { name: "tokens", label: "Tokens", type: "text" },
        { name: "expanded", label: "Unfolded", type: "toggle" }, STATE,
      ],
      render: (p) => '<div style="width:600px">' + runGroup(Object.assign({}, p, { entries: [
        { kind: "run-started", time: p.time, headHtml: head("Started"), detail: "Claude" },
        { kind: "phase", time: "10:12", headHtml: head("Build passed") },
        { kind: p.verdict === "failed" ? "run-failed" : "run-passed", time: "10:20", headHtml: head(p.verdict === "failed" ? "Tests failed" : "Tests passed"), detail: p.verdict === "failed" ? "2 failures in the orchestrator" : "" },
        { kind: "rule", time: "10:27", headHtml: head("Pushed", "and handed off to Code Review") },
      ] })) + "</div>",
      docs: {
        what: "One run of an agent on the timeline, folded to a single line with its verdict and duration, unfolding into its steps.",
        when: ["Folded by default once it ended; the running one is unfolded and live."],
        states: [["Folded", "one line"], ["Unfolded", "its entries indented under a rule"], ["Running", "a live dot, no end time"], ["Failed", "red verdict"], ["Header hover, pressed, focused", "as a row"]],
        tokens: ["--status-*", "--tint-*", "--radius-row", "--motion-standard"],
        access: "A disclosure: “Implementation run 2, passed, 22 minutes, collapsed”.",
      },
      stories: [
        { name: "Folded" }, { name: "Unfolded", args: { expanded: true } }, { name: "Running", args: { verdict: "running", duration: "6 min so far", expanded: true } },
        { name: "Failed", args: { verdict: "failed", title: "Implementation run 1" } }, { name: "Header hover", args: { state: "hover" } }, { name: "Header pressed", args: { state: "pressed" } }, { name: "Header focused", args: { state: "focused" } },
      ],
    },
    {
      title: "Step strip",
      args: { code: "passed", build: "passed", checks: "passed", tests: "current", handoff: "pending", testsNote: "" },
      controls: STEP_NAMES.map((s) => ({ name: s[0], label: s[1], type: "select", options: STEP_OPTIONS })),
      render: (p) => steps(p),
      docs: {
        what: "The five steps of an implementation run, left to right, so where a run stands or where it stopped reads at once.",
        when: ["Writing the code, Build, Checks, Tests, Handoff, always in that order. Each step says its state in words under its name."],
        states: [["Passed", "green bar"], ["Failed", "red tint and word"], ["Paused", "gray bar"], ["Skipped", "dashed bar"], ["Current", "blue tint, partial bar"], ["Not started", "empty bar"]],
        tokens: ["--status-done", "--status-problem", "--status-working", "--status-idle", "--radius-row"],
        access: "A list: “Steps of the run. Writing the code, passed. Build, passed…”.",
      },
      stories: [
        { name: "Current: tests" }, { name: "All passed", args: { tests: "passed", handoff: "passed" } }, { name: "Failed at checks", args: { checks: "failed", tests: "pending", handoff: "pending" } },
        { name: "Paused at build", args: { build: "paused", checks: "pending", tests: "pending", handoff: "pending" } }, { name: "Tests skipped", args: { tests: "skipped", handoff: "passed" } },
        { name: "Not started", args: { code: "current", build: "pending", checks: "pending", tests: "pending" } },
      ],
    },
    {
      title: "Option card",
      args: { label: "Approve the catalog", effect: "TP-1382 goes to Code Review and lands; TP-1383 starts from the approved catalog.", good: "The prototypes start today.", cost: "", risk: "", recommended: true, why: "Every component and section is in the catalog in light and dark.", selected: false, hotkey: 1, state: "default", disabled: false, reason: "This question was answered in Linear." },
      controls: [
        { name: "label", label: "Label", type: "text" }, { name: "effect", label: "Effect", type: "textarea" },
        { name: "good", label: "Good", type: "text" }, { name: "cost", label: "Cost", type: "text" }, { name: "risk", label: "Risk", type: "text" },
        { name: "recommended", label: "Recommended", type: "toggle" }, { name: "why", label: "Why recommended", type: "text", when: (p) => p.recommended },
        { name: "selected", label: "Selected", type: "toggle" }, { name: "hotkey", label: "Key", type: "number", min: 1, max: 9 }, STATE, DISABLED, REASON,
      ],
      render: (p) => '<div class="options" role="radiogroup" style="width:600px">' + option(p) + "</div>",
      docs: {
        what: "One answer to a Question: its label, what it does, its trade-offs, and whether we recommend it. The cards of a Question form a radio group.",
        when: ["Label first, the effect under it, never on one line together.", "Trade-offs are tagged good, cost or risk, one line each.", "The recommended card carries the Recommended badge and a line saying why."],
        states: [["Default", "hairline"], ["Hover", "raised"], ["Pressed", "darker"], ["Focused", "focus ring"], ["Selected", "accent ring and tint, filled radio"], ["Recommended", "badge and the why line"], ["Not answerable", "no radio, the reason"]],
        tokens: ["--accent", "--accent-tint", "--radius-row", "--status-done / you / problem (tags)", "--focus-ring"],
        access: "“Option 1 of 2, Approve the catalog, recommended, selected”, then its effect and its tags. Number keys pick an option.",
      },
      stories: [
        { name: "Default", args: { recommended: false } }, { name: "Hover", args: { recommended: false, state: "hover" } }, { name: "Pressed", args: { recommended: false, state: "pressed" } },
        { name: "Focused", args: { recommended: false, state: "focused" } }, { name: "Selected", args: { recommended: false, selected: true } }, { name: "Recommended" },
        { name: "Recommended and selected", args: { selected: true } },
        { name: "With trade-offs", args: { recommended: false, label: "Ask for changes (write them below)", effect: "The next run applies your words and asks again.", good: "You get exactly what you asked for.", cost: "One more review round.", risk: "TP-1383 waits until you approve.", hotkey: 2 } },
        { name: "Not answerable", args: { disabled: true } },
      ],
    },
    {
      title: "Answer in my own words",
      args: { picked: true, text: "", state: "default", send: true, hotkey: 3 },
      controls: [{ name: "picked", label: "Picked", type: "toggle" }, { name: "text", label: "Words", type: "textarea", when: (p) => p.picked }, { name: "state", label: "Shown state", type: "select", options: [{ value: "default", label: "Live" }, { value: "hover", label: "Hover (card)" }, { value: "focused", label: "Focused (field)" }] }, { name: "send", label: "Send button", type: "toggle" }],
      render: (p) => '<div class="options" style="width:600px">' + ownWords(p) + "</div>",
      docs: {
        what: "The last card of every Question: the Director's own answer instead of the options. Picking it opens a field under the cards.",
        when: ["The field starts three lines tall and grows to eight. Send stays off until there are words, and says so."],
        states: [["Not picked", "a card like the others"], ["Picked, empty", "field shown, Send off with its reason"], ["Picked, with words", "Send on"], ["Focused", "accent edge and ring"]],
        tokens: ["--accent", "--radius-row", "--type-body", "--focus-ring"],
        access: "The card reads as an option; the field is labelled “Answer in my own words…” with the hint as its help.",
      },
      stories: [
        { name: "Not picked", args: { picked: false } }, { name: "Not picked, hover", args: { picked: false, state: "hover" } }, { name: "Picked, empty" },
        { name: "Picked, focused", args: { state: "focused" } }, { name: "Picked, with words", args: { text: "Approve, but make the dark status tints a step stronger first." } },
      ],
    },
    {
      title: "Attachment thumbnail",
      args: { name: "ticket-page-dark.png", kind: "image", meta: "PNG · 412 KB", status: "ready", state: "default" },
      controls: [
        { name: "name", label: "File name", type: "text" }, { name: "kind", label: "Kind", type: "select", options: ["image", "pdf", "log"] }, { name: "meta", label: "Kind and size", type: "text" },
        { name: "status", label: "Status", type: "select", options: [{ value: "ready", label: "Ready" }, { value: "loading", label: "Loading" }, { value: "failed", label: "Failed to load" }] }, STATE,
      ],
      render: (p) => {
        const inner = p.status === "loading" ? "" : p.status === "failed" ? icon("problem") : p.kind === "image" ? '<span class="mock-ui"></span>' : icon(p.kind === "pdf" ? "doc" : "log");
        return '<button type="button" class="attachment' + (p.status !== "ready" ? " " + esc(p.status) : "") + stateClass(p.state) + '"' + (p.status === "loading" ? ' aria-busy="true"' : "") + '><span class="thumb' + (p.kind === "image" && p.status === "ready" ? " image" : "") + '">' + inner + "</span>" +
          '<span class="name">' + esc(p.name) + '</span><span class="meta">' + esc(p.status === "failed" ? "Couldn't load · Try Again" : p.status === "loading" ? "Loading…" : p.meta) + "</span></button>";
      },
      docs: {
        what: "A file attached to a ticket (a screenshot, a PDF, a log), as a thumbnail with its name. Clicking opens it in Quick Look.",
        states: [["Image, PDF, log", "a preview or the kind's glyph"], ["Hover, pressed, focused", "as a row"], ["Loading", "a shimmer"], ["Failed to load", "red glyph, Try Again"]],
        tokens: ["--surface-raised", "--radius-row", "--radius-control", "--surface-hover"],
      },
      stories: [
        { name: "Image" }, { name: "PDF", args: { kind: "pdf", name: "qa-report.pdf", meta: "PDF · 3 pages" } }, { name: "Log", args: { kind: "log", name: "ci-tests.log", meta: "Text · 18 KB" } },
        { name: "Hover", args: { state: "hover" } }, { name: "Pressed", args: { state: "pressed" } }, { name: "Focused", args: { state: "focused" } },
        { name: "Loading", args: { status: "loading" } }, { name: "Failed to load", args: { status: "failed" } },
      ],
    },
    {
      title: "Empty state",
      args: { glyph: "tray", good: true, title: "Nothing waits on you", message: "New questions, plans and pull requests to approve land here.", action: "" },
      controls: [
        { name: "glyph", label: "Glyph", type: "select", options: ["tray", "search", "stop", "doc", "done"] }, { name: "good", label: "Good news", type: "toggle" },
        { name: "title", label: "Title", type: "text" }, { name: "message", label: "Message", type: "textarea" }, { name: "action", label: "Action", type: "text" },
      ],
      render: (p) => '<div class="empty' + (p.good ? " good" : "") + '">' + icon(p.good && p.glyph === "tray" ? "done" : p.glyph) + "<h3>" + esc(p.title) + "</h3><p>" + esc(p.message) + "</p>" + (p.action ? button({ label: p.action, variant: "secondary" }) : "") + "</div>",
      docs: {
        what: "What a view shows when it has nothing: a glyph, a sentence that says what that means, at most one action.",
        when: ["An empty Inbox is good news and says so.", "No results says what was searched and how to widen it.", "Symphony stopped is one placeholder per view, with Start Symphony."],
        avoid: "An empty state for a section with nothing to say on a busy page: hide the section instead.",
        states: [["Good news", "green tick"], ["No results", "with Clear Filters"], ["Stopped", "with Start Symphony"]],
        tokens: ["--text-tertiary", "--status-done", "--space-8", "--measure-narrow"],
      },
      stories: [
        { name: "Inbox empty" },
        { name: "No results", args: { glyph: "search", good: false, title: "No tickets match", message: "Nothing in symphony matches “storybook” with these filters.", action: "Clear Filters" } },
        { name: "Symphony stopped", args: { glyph: "stop", good: false, title: "Symphony is stopped", message: "Nothing runs and nothing updates until it starts again.", action: "Start Symphony" } },
      ],
    },
    {
      title: "Toast",
      args: { role: "accent", text: "Sending your decision", sub: "", action: "Undo", countdown: 7 },
      controls: [
        { name: "role", label: "Kind", type: "select", options: [{ value: "accent", label: "Info" }, { value: "done", label: "Success" }, { value: "you", label: "Warning" }, { value: "problem", label: "Error" }] },
        { name: "text", label: "Text", type: "text" }, { name: "sub", label: "Second line", type: "text" }, { name: "action", label: "Action", type: "text" }, { name: "countdown", label: "Seconds left (0: none)", type: "number", min: 0, max: 10 },
      ],
      render: (p) => {
        const g = { accent: "info", done: "done", you: "cost", problem: "problem" }[p.role] || "info";
        const n = Number(p.countdown) || 0;
        return '<div class="toast role-' + esc(p.role) + '" role="status">' + icon(g) + '<span class="msg">' + esc(p.text) + (p.sub ? '<span class="sub">' + esc(p.sub) + "</span>" : "") +
          (n ? '<span class="timer"><i style="width:' + n * 10 + '%"></i></span>' : "") + "</span>" + (n ? '<span class="countdown">' + n + " s</span>" : "") +
          (p.action ? button({ label: p.action, variant: "quiet", size: "small" }) : "") + '<button type="button" class="icon-btn" aria-label="Close" title="Close">' + icon("close") + "</button></div>";
      },
      docs: {
        what: "A short note at the foot of the window about something that just happened, with Undo when it can be taken back.",
        when: ["A move made from the app shows one for 10 seconds with Undo. A decision is held for those 10 seconds and sent when they end."],
        avoid: "Toasts for routine progress, or more than one at a time.",
        states: [["Info", "accent"], ["Success", "green"], ["Warning", "orange"], ["Error", "red, with Try Again"], ["Countdown", "a draining line and the seconds left"]],
        tokens: ["--elevation-2", "--radius-row", "--status-*"],
        access: "Announced once when it appears.",
      },
      stories: [
        { name: "Sending a decision" },
        { name: "Moved, with Undo", args: { role: "done", text: "TP-1382 moved to Rework", sub: "Its run starts in a moment.", countdown: 0 } },
        { name: "Warning", args: { role: "you", text: "Linear is slow to answer", sub: "Changes may take a minute to show.", action: "", countdown: 0 } },
        { name: "Error", args: { role: "problem", text: "The move didn't go through", sub: "Linear rejected it: the ticket changed meanwhile.", action: "Try Again", countdown: 0 } },
      ],
    },
    {
      title: "Sheet header",
      args: { title: "Stop the run on TP-1382?", sub: "The agent stops at once. Its work so far stays on the branch.", close: true, body: true, destructive: true },
      controls: [{ name: "title", label: "Title (a question)", type: "text" }, { name: "sub", label: "Explanation", type: "textarea" }, { name: "close", label: "Close button", type: "toggle" }, { name: "body", label: "Show the rest of the sheet", type: "toggle" }, { name: "destructive", label: "Destructive action", type: "toggle" }],
      render: (p) => '<div class="sheet" role="dialog" aria-label="' + esc(p.title) + '"><header class="sheet-head"><h2>' + esc(p.title) + "</h2>" + (p.sub ? '<p class="sub">' + esc(p.sub) + "</p>" : "") +
        (p.close ? '<button type="button" class="icon-btn" aria-label="Close" title="Close (Esc)">' + icon("close") + "</button>" : "") + "</header>" +
        (p.body ? '<div class="sheet-body"><p><b>What happens:</b> the run ends now and TP-1382 stays in In Progress, paused.</p><p class="muted"><b>What stays the same:</b> the pull request, the branch and every comment.</p></div><footer class="sheet-foot">' +
          button({ label: "Cancel", variant: "secondary" }) + button({ label: p.destructive ? "Stop Run" : "Continue", variant: p.destructive ? "destructive-filled" : "primary" }) + "</footer>" : "") + "</div>",
      docs: {
        what: "The top of every consequence sheet: the move asked as a question, then one line on what it does.",
        when: ["The title is the question (“Stop the run on TP-1382?”), the explanation says what happens and what doesn't. The footer names the action with its verb."],
        states: [["Question only", "title"], ["With explanation", "title and line"], ["Destructive", "the action in the destructive style"], ["Without close", "when Cancel is the only way out"]],
        tokens: ["--elevation-3", "--radius-card", "--type-sentence", "--space-5"],
        access: "A dialog named by its title; Esc cancels, Return takes the default.",
      },
      stories: [
        { name: "Destructive" }, { name: "Question only", args: { sub: "", body: false } }, { name: "With explanation", args: { title: "Force TP-1383 ahead of the queue?", sub: "It starts at the next free slot, ahead of everything queued.", destructive: false } },
        { name: "Without close", args: { close: false, title: "Send your answer?", sub: "“Approve, but make the dark tints a step stronger first.”", destructive: false } },
      ],
    },
    {
      title: "Inline refusal",
      args: { reason: "Checks are still running on PR #812.", fix: "", withButton: true, label: "Approve and Merge…" },
      controls: [{ name: "reason", label: "Reason", type: "text" }, { name: "fix", label: "Way to fix it", type: "text" }, { name: "withButton", label: "Under a button", type: "toggle" }, { name: "label", label: "Button", type: "text", when: (p) => p.withButton }],
      render: (p) => p.withButton ? '<span class="btn-group">' + button({ label: p.label, variant: "primary", disabled: true, reason: p.reason, showReason: false }) + refusal(p.reason, p.fix) + "</span>" : refusal(p.reason, p.fix),
      docs: {
        what: "Why an action is off, in one line under it. Every disabled action in the Director has one.",
        when: ["Say the cause, then what lifts it if the Director can do something: “A run is still finishing. Stop it first.”"],
        avoid: "“Not available”, or a reason only in a tooltip.",
        states: [["Under a button", "beside its disabled action"], ["Standalone", "in a row or a card"], ["With a way to fix it", "a link that does it"]],
        tokens: ["--text-secondary", "--text-tertiary", "--accent", "--type-secondary", "--measure-narrow"],
        access: "Read as the disabled control's help.",
      },
      stories: [{ name: "Under a button" }, { name: "Standalone", args: { withButton: false, reason: "Moves wait while a run is working." } }, { name: "With a way to fix it", args: { reason: "A run is still finishing.", fix: "Stop it", label: "Restart…" } }],
    },
    {
      title: "Keyboard hint",
      args: { keys: "⌘ ⇧ F", plain: false, context: "alone" },
      controls: [{ name: "keys", label: "Keys (space between)", type: "text" }, { name: "plain", label: "Plain (no key caps)", type: "toggle" }, { name: "context", label: "Where", type: "select", options: ["alone", "menu", "option"] }],
      render: (p) => {
        if (p.context === "menu") return '<ul class="menu" style="position:static"><li class="menu-item">' + icon("check", "check") + "Force a Ticket…" + kbd(p.keys, true) + '</li><li class="menu-item is-hover">' + icon("check", "check") + "Open in Linear" + kbd("⌘ L", true) + "</li></ul>";
        if (p.context === "option") return '<div class="options" style="width:520px">' + option({ label: "Approve the catalog", effect: "TP-1382 lands.", hotkey: (p.keys.split(/\s+/)[0] || "1") }) + "</div>";
        return kbd(p.keys, p.plain);
      },
      docs: {
        what: "The keys for an action, drawn as key caps: on option cards, in menus (plain), in the search field.",
        when: ["Modifier symbols in the macOS order: ⌃ ⌥ ⇧ ⌘, then the key."],
        states: [["Single key", "one cap"], ["Combination", "caps in a row"], ["In a menu", "plain, right aligned, white on highlight"], ["On an option", "the number that picks it"]],
        tokens: ["--surface-raised", "--stroke-strong", "--type-label"],
        access: "Read as words: “Command Shift F”.",
      },
      stories: [{ name: "Combination" }, { name: "Single key", args: { keys: "1" } }, { name: "Plain", args: { plain: true } }, { name: "In a menu", args: { context: "menu" } }, { name: "On an option", args: { context: "option", keys: "1" } }],
    },
  ];

  function table(p) {
    const rows = [
      { ident: "TP-1382", title: "Design system catalog as HTML", role: "you", word: "Waiting on you", repo: "symphony", age: 192, tokens: 6.2 },
      { ident: "TP-1376", title: "A CI-wait pause lifts itself", role: "working", word: "Working", repo: "symphony", age: 14, tokens: 1.8 },
      { ident: "TP-1375", title: "First dispatch waits for its relations", role: "problem", word: "Checks failed", repo: "symphony", age: 22, tokens: 3.4 },
      { ident: "SHOP-305", title: "Checkout total rounding", role: "working", word: "Code Review", repo: "web-shop", age: 6, tokens: 0.9 },
      { ident: "TP-1371", title: "Workspace lifecycle docs", role: "idle", word: "Queued", repo: "symphony", age: 120, tokens: 0 },
    ];
    const parts = String(p.sort || "age-desc").split("-");
    const col = parts[0];
    const dir = parts[1] === "asc" ? 1 : -1;
    rows.sort((a, b) => (a[col] > b[col] ? 1 : a[col] < b[col] ? -1 : 0) * dir);
    const fmtAge = (m) => (m >= 60 ? Math.floor(m / 60) + " h " + (m % 60 ? (m % 60) + " min" : "") : m + " min").trim();
    const th = (key, label, cls, wide) => {
      const sorted = col === key;
      const next = key + "-" + (sorted && dir === -1 ? "asc" : "desc");
      return "<th" + (cls ? ' class="' + cls + (wide ? " col-wide" : "") + '"' : wide ? ' class="col-wide"' : "") + (sorted ? ' aria-sort="' + (dir === 1 ? "ascending" : "descending") + '"' : "") + ">" +
        '<button type="button" class="' + (p.hoverHeader === key ? "is-hover" : "") + '" data-set="sort=' + next + '" data-key="th-' + key + '">' + esc(label) + (sorted ? icon(dir === 1 ? "sort-up" : "sort-down", "sort") : "") + "</button></th>";
    };
    const body = p.empty ? '<tr><td colspan="6" class="empty-cell">No tickets match these filters. <a href="#" onclick="return false" style="color:var(--accent)">Clear Filters</a></td></tr>' :
      rows.map((r, i) => '<tr class="role-' + r.role + (i === Number(p.hoverRow) ? " is-hover" : "") + (i === Number(p.focusedRow) ? " is-focused" : "") + '"' + (i === Number(p.selectedRow) ? ' aria-selected="true"' : "") + ' data-set="selectedRow=' + (i === Number(p.selectedRow) ? -1 : i) + '">' +
        "<td><b>" + esc(r.ident) + '</b></td><td class="wrap">' + esc(r.title) + "</td><td>" + badge(r.role, r.word, "small") + '</td><td class="col-wide muted">' + esc(r.repo) + '</td><td class="num">' + esc(fmtAge(r.age)) + '</td><td class="num">' + (r.tokens ? esc(r.tokens) + "M" : '<span class="muted">none</span>') + "</td></tr>").join("");
    return '<div style="width:' + (p.fill ? "100%" : "760px") + '"><table class="table"><thead><tr>' + th("ident", "Ticket") + "<th>Title</th><th>Stage</th>" + th("repo", "Repo", "", true) + th("age", "Age", "num") + th("tokens", "Tokens", "num") + "</tr></thead><tbody>" + body + "</tbody></table></div>";
  }

  /* ---------- Sections ---------- */

  const VIEWPORT_STORIES = (extra) => [{ name: "Laptop", viewport: "laptop" }, { name: "Desktop", viewport: "desktop" }].concat(extra || []);

  function actionRail(p) {
    const moves = [];
    if (p.role === "you") moves.push(button({ label: "Answer in the Inbox", variant: "primary", glyph: "tray" }));
    else moves.push(button({ label: "Approve and Merge…", variant: "primary", disabled: !!p.blocked, reason: "Checks are still running on PR #812." }));
    moves.push(button({ label: "Open Pull Request", variant: "secondary", glyph: "pr" }));
    moves.push(button({ label: "Force", variant: "secondary", glyph: "forced" }));
    moves.push(button({ label: "Stop Run…", variant: "destructive", disabled: !!p.noRun, reason: "No run is working." }));
    moves.push('<span class="menu-wrap rail-more"><button type="button" class="menu-btn">More' + icon("chevron-down", "chev") + "</button></span>");
    return '<div class="action-rail" role="toolbar" aria-label="Moves">' + moves.join("") + "</div>";
  }

  function pageHeader(p) {
    const s = p.role === "you" ? { role: "you", word: "Waiting on you", cause: "A question: review the design catalog.", waits: "Answer it in the Inbox.", age: "3 h 12 min" } :
      { role: "working", word: "Waiting for CI", cause: "Checks are running on PR #812.", waits: "Code Review starts when they pass.", age: "6 min" };
    return '<header class="page-header"><div class="head-main"><div class="ident-line"><span class="ident">' + esc(p.ident) + "</span>" + chip({ kind: "repo", text: "symphony", interactive: false }) + chip({ kind: "epic", text: "Phase 3b", interactive: false }) + "</div>" +
      "<h1>" + esc(p.title) + "</h1>" + situation(Object.assign({ size: "large" }, s)) + "</div>" + actionRail(p) + "</header>";
  }

  function factsRail(p) {
    const groups = [
      ["Now", [["Stage", badge(p.role || "working", p.role === "you" ? "Waiting on you" : "Code Review", "small"), true], ["Waiting on", p.role === "you" ? "You" : "CI on PR #812"], ["Since", "Today 11:15"]]],
      ["Work", [["Pull request", '<a href="#" onclick="return false" style="color:var(--accent)">PR #812</a> · 14 files', true], ["Runs", "3 · 1 h 12 min"], ["Tokens", meter({ label: "", used: 6200000, cap: 8000000, unit: "tokens", resets: "never" }).replace('class="meter ', 'style="width:180px" class="meter '), true]]],
      ["Connected", [["Part of", "TP-1381 · Phase 3b"], ["Blocks", "TP-1383 · Three prototypes"], ["Repo", chip({ kind: "repo", text: "symphony", interactive: false }), true]]],
    ];
    return '<aside class="facts-rail' + (p.spread ? " can-spread" : "") + '" aria-label="Facts">' + groups.map((g) => '<section class="card"><div class="kv-group"><h4>' + esc(g[0]) + "</h4>" + kv(g[1], p.stacked) + "</div></section>").join("") + "</aside>";
  }

  function questionBlock(p) {
    const opts = [
      { label: "Approve the catalog", effect: "TP-1382 goes to Code Review and lands; TP-1383 starts from the approved catalog.", good: "The prototypes start today.", recommended: true, why: "Every component and section is in the catalog in light and dark.", hotkey: 1 },
      { label: "Ask for changes (write them below)", effect: "The next run applies your words and asks again.", cost: "One more review round.", hotkey: 2 },
    ];
    const sel = Number(p.selected);
    const optionsHtml = opts.map((o, i) => option(Object.assign({}, o, { selected: sel === i + 1, set: "selected=" + (i + 1), key: "q" + i }))).join("");
    const own = ownWords({ picked: sel === 3, text: p.text, hotkey: 3, send: false }).replace('data-set="picked=true"', 'data-set="selected=3"').replace('data-set="picked=false"', 'data-set="selected=0"');
    const chosen = sel > 0 && (sel < 3 || String(p.text || "").trim());
    const block = '<section class="question-block" aria-label="Question"><div class="question-callout"><span class="kicker">YOUR DECISION</span><h2>Review the design catalog</h2></div>' +
      '<div class="question-why"><p>TP-1382 (Design system catalog) built every Director component and section as stories you can open in a browser. Open the catalog from the path below, try the controls, switch theme and viewport, then pick an answer.</p>' +
      '<p class="t-mono" style="font-size:11px;color:var(--text-secondary)">/Users/tonypine/symphony-workspaces/symphony/TP-1382/docs/design/catalog/index.html</p>' +
      '<p class="unanswered">' + icon("cost") + "<span><b>If you don't answer:</b> TP-1382 stays where it is and TP-1383 (Three prototypes) waits.</span></p></div>" +
      '<div class="options" role="radiogroup" aria-label="Answers">' + optionsHtml + own + "</div>" +
      '<div class="question-send">' + (chosen ? "" : refusal("Pick an answer first.")) + button({ label: "Send Decision…", variant: "primary", disabled: !chosen, showReason: false }) + "</div></section>";
    const side = card({ title: "Where this ticket sits", html: kv([["Part of", "TP-1381 · Phase 3b"], ["Its work", "PR #812 · checks passing"], ["Unblocks", "TP-1383 · Three prototypes"]]) });
    return '<div class="question-split">' + block + '<div class="side">' + side + "</div></div>";
  }

  function boardGroup(title, role, items, expanded, hint, key) {
    const empty = !items.length;
    return '<section class="board-group' + (empty ? " empty" : "") + '"><button type="button" class="group-head" aria-expanded="' + (!empty && expanded) + '"' + (empty ? ' aria-disabled="true"' : ' data-toggle="' + key + '" data-key="bg-' + key + '"') + ">" +
      (empty ? "" : icon("chevron-right", "disclose")) + '<span class="role-' + role + '">' + icon(ROLES[role].glyph) + "</span>" + esc(title) + (empty ? "" : '<span class="count' + (role === "you" || role === "problem" ? " role-" + role : " count-quiet") + '">' + items.length + "</span>") +
      '<span class="hint">' + esc(empty ? "None right now" : hint) + "</span></button>" +
      (!empty && expanded ? '<div class="rows list" role="listbox">' + items.map((t) => row(Object.assign({}, t, { twoLine: true }))).join("") + "</div>" : "") + "</section>";
  }

  function board(p) {
    const you = p.emptyYou ? [] : [TICKETS[0]];
    return '<div class="board' + (p.columns ? " columns" : "") + '">' +
      boardGroup("Waiting on you", "you", you, p.g1, "oldest 3 h 12 min", "g1") +
      boardGroup("Needs attention", "problem", [Object.assign({}, TICKETS[2], { fix: "Open Checks", fixPrimary: true })], p.g2, "a fix run starts on its own", "g2") +
      boardGroup("Working", "working", [TICKETS[1], TICKETS[3], TICKETS[6]], p.g3, "3 runs", "g3") +
      boardGroup("Forced", "forced", [], false, "", "g4") + "</div>";
  }

  function tableSection(p) {
    const chips = [["status", "Waiting on you", "you"], ["status", "Needs attention", "problem"], ["status", "Working", "working"], ["repo", "symphony"], ["epic", "Phase 3b"]];
    const chooser = p.chooser ? '<ul class="menu column-chooser" role="menu" style="left:auto;right:0">' + ["Ticket", "Title", "Stage", "Repo", "Age", "Tokens", "Epic", "Last run"].map((c, i) =>
      '<li class="menu-item" role="menuitemcheckbox" aria-checked="' + (i < 6) + '">' + icon("check", "check") + esc(c) + "</li>").join("") + "</ul>" : "";
    return '<section class="table-section"><div class="filter-bar"><div class="input search">' + icon("search") + '<input type="search" aria-label="Search tickets" placeholder="Search tickets"></div>' +
      chips.map((c, i) => chip({ kind: c[0], text: c[1], role: c[2], pressed: i === 3 || (i === 0 && !!p.filtered), toggle: i === 0 ? "filtered" : null, key: "fc" + i })).join("") +
      '<span class="spacer"></span><span class="menu-wrap"><button type="button" class="menu-btn" aria-expanded="' + !!p.chooser + '" data-toggle="chooser" data-key="cc">' + icon("columns") + "Columns" + icon("chevron-down", "chev") + "</button>" + chooser + "</span></div>" +
      table({ sort: p.sort || "age-desc", fill: true, selectedRow: p.selectedRow === undefined ? -1 : p.selectedRow, hoverRow: -1, focusedRow: -1 }) + "</section>";
  }

  function controlBar(p) {
    const seg = '<div class="segmented" role="radiogroup" aria-label="Period">' + ["Day", "Week", "Month"].map((o, i) => '<button type="button" role="radio" class="segment" aria-checked="' + (i === Number(p.period)) + '" data-set="period=' + i + '">' + o + "</button>").join("") + "</div>";
    const pop = (label, value) => '<button type="button" class="popup"><span class="popup-label"><span>' + esc(label) + "</span><span>" + esc(value) + "</span></span>" + icon("updown", "chev") + "</button>";
    return '<div class="control-bar" role="toolbar" aria-label="What the page shows">' +
      '<span class="group"><span class="lbl">Period</span>' + seg + "</span>" +
      '<span class="group"><span class="lbl">Unit</span>' + pop("", p.unit) + "</span>" +
      '<span class="group">' + pop("Repo", p.repo) + "</span>" +
      '<span class="group">' + pop("Epic", p.epic) + "</span>" +
      '<span class="spacer"></span><span class="summary">' + esc(p.summary) + "</span>" +
      (p.repo !== "All repos" || p.epic !== "All epics" ? button({ label: "Clear", variant: "quiet", size: "small" }) : "") + "</div>";
  }

  const frame = (inner) => '<div class="section-frame">' + inner + "</div>";

  const sections = [
    {
      title: "Page header",
      wide: true,
      args: { ident: "TP-1382", title: "Design system catalog as HTML, Storybook-shaped: every Director component and section as stories per state", role: "working", blocked: true, noRun: false },
      controls: [{ name: "ident", label: "Identifier", type: "text" }, { name: "title", label: "Title", type: "textarea" }, { name: "role", label: "Situation", type: "select", options: [{ value: "working", label: "Waiting for CI" }, { value: "you", label: "Waiting on you" }] }, { name: "blocked", label: "Approve disabled", type: "toggle" }, { name: "noRun", label: "No run working", type: "toggle" }],
      render: (p) => frame(pageHeader(p)),
      docs: {
        what: "The top of a ticket page: the identifier with its repo and epic, the title, the situation line, and the action rail.",
        responsive: ["Laptop (1180 pt): the action rail sits on its own row under the situation line, left aligned, so the title keeps the full width.", "Desktop (2200 pt): the action rail moves to the right of the title, top aligned with it.", "The title wraps (balanced) and stops at 30 em; the situation line stops at the measure (68 characters)."],
        tokens: ["--type-title", "--space-6", "--measure"],
      },
      stories: VIEWPORT_STORIES([{ name: "Waiting on you", viewport: "laptop", args: { role: "you", blocked: false } }, { name: "Short title", viewport: "desktop", args: { title: "Checkout total rounding", ident: "SHOP-305" } }]),
    },
    {
      title: "Action rail",
      wide: true,
      args: { role: "working", blocked: true, noRun: false },
      controls: [{ name: "role", label: "Situation", type: "select", options: [{ value: "working", label: "Waiting for CI" }, { value: "you", label: "Waiting on you" }] }, { name: "blocked", label: "Approve disabled", type: "toggle" }, { name: "noRun", label: "No run working", type: "toggle" }],
      render: (p) => frame(actionRail(p)),
      docs: {
        what: "The moves a ticket allows, in one row: the expected move first and primary, then the others, the destructive one last, and More for the rest.",
        when: ["A disabled move stays in its place and says why under it, so the rail never jumps."],
        responsive: ["Laptop: the rail wraps onto a second line before any button shrinks; More always stays last.", "Desktop: one row, beside the title in the page header."],
        tokens: ["--space-2", "button tokens"],
      },
      stories: VIEWPORT_STORIES([{ name: "Waiting on you", viewport: "laptop", args: { role: "you", blocked: false } }, { name: "Nothing running", viewport: "laptop", args: { blocked: false, noRun: true } }]),
    },
    {
      title: "Facts rail",
      wide: true,
      args: { role: "working", stacked: false, spread: true },
      controls: [{ name: "role", label: "Situation", type: "select", options: [{ value: "working", label: "Waiting for CI" }, { value: "you", label: "Waiting on you" }] }, { name: "stacked", label: "Labels above values", type: "toggle" }, { name: "spread", label: "Spread on wide screens", type: "toggle" }],
      render: (p) => frame(factsRail(p)),
      docs: {
        what: "The ticket's facts in small grouped cards: Now, Work, Connected. Unknown facts are left out.",
        responsive: ["Laptop: one column, 300 pt, beside the page's main column.", "Desktop: the groups spread into three columns of up to 300 pt each, under the header, so the timeline below gets the full width.", "Values wrap inside their column; labels never wrap."],
        tokens: ["--radius-card", "--space-4", "key-value list tokens"],
      },
      stories: VIEWPORT_STORIES([{ name: "Stacked labels", viewport: "laptop", args: { stacked: true } }]),
    },
    {
      title: "Timeline",
      wide: true,
      args: { runOpen: false },
      controls: [{ name: "runOpen", label: "Run group unfolded", type: "toggle" }],
      render: (p) => frame('<section class="timeline-section"><div class="tl-day">Today</div><ol class="timeline">' + DAY.slice(0, 1).map(tlEntry).join("") + "</ol>" +
        runGroup({ title: "Implementation run 1", verdict: "failed", time: "09:02", duration: "22 min", tokens: "1.4M tokens", expanded: p.runOpen, entries: DAY.slice(1, 3) }).replace('data-toggle="expanded"', 'data-toggle="runOpen"') +
        '<ol class="timeline">' + DAY.slice(3).map(tlEntry).join("") + "</ol></section>"),
      docs: {
        what: "A day of a ticket's history, newest last: phase moves, pauses, questions, runs folded into groups, the Director's own actions and the rules Symphony applied.",
        responsive: ["Laptop and desktop: the timeline keeps one column of at most 760 pt so every line stays under the measure; the extra width on desktop goes to the facts and the margins, never to longer lines."],
        tokens: ["timeline entry tokens", "--measure"],
      },
      stories: VIEWPORT_STORIES([{ name: "Run unfolded", viewport: "laptop", args: { runOpen: true } }]),
    },
    {
      title: "Question block",
      wide: true,
      args: { selected: 0, text: "" },
      controls: [{ name: "selected", label: "Picked answer", type: "select", options: [{ value: 0, label: "None yet" }, { value: 1, label: "Approve the catalog" }, { value: 2, label: "Ask for changes" }, { value: 3, label: "My own words" }] }, { name: "text", label: "Own words", type: "textarea", when: (p) => Number(p.selected) === 3 }],
      render: (p) => frame(questionBlock(p)),
      docs: {
        what: "A Question as the Director answers it: the callout with the question, why it is asked and what happens if it waits, the option cards, the own-words card, and Send.",
        when: ["Send stays off until an answer is picked (and, for own words, written), and says so."],
        responsive: ["Laptop: one column of at most 720 pt.", "Desktop: the same column, with “Where this ticket sits” as a 300 pt card beside it instead of under it.", "Every paragraph stops at the measure."],
        tokens: ["--tint-you", "--status-you", "option card tokens", "--measure"],
      },
      stories: VIEWPORT_STORIES([{ name: "Option picked", viewport: "laptop", args: { selected: 1 } }, { name: "Own words", viewport: "laptop", args: { selected: 3, text: "Approve, but make the dark status tints a step stronger first." } }]),
    },
    {
      title: "Board group",
      wide: true,
      args: { g1: true, g2: true, g3: true, g4: false, columns: false, emptyYou: false },
      controls: [{ name: "g1", label: "Waiting on you open", type: "toggle" }, { name: "g2", label: "Needs attention open", type: "toggle" }, { name: "g3", label: "Working open", type: "toggle" }, { name: "emptyYou", label: "Nothing waits on you", type: "toggle" }, { name: "columns", label: "Columns on wide screens", type: "toggle" }],
      render: (p) => frame(board(p)),
      docs: {
        what: "Tickets grouped by their situation, each group a heading with its glyph, count and a hint, then its rows. A group with nothing in it stays as a collapsed heading that says so.",
        responsive: ["Laptop: groups stack in one column, rows full width.", "Desktop: groups sit side by side in three columns, each its own list.", "Rows cut their title at the end before the age or the fix button would wrap."],
        tokens: ["row tokens", "--status-*", "--radius-row"],
      },
      stories: [
        { name: "Laptop", viewport: "laptop" }, { name: "Desktop", viewport: "desktop", args: { columns: true } },
        { name: "Empty group collapsed", viewport: "laptop", args: { emptyYou: true } }, { name: "Groups folded", viewport: "laptop", args: { g1: false, g2: false, g3: false } },
      ],
    },
    {
      title: "Table with filters",
      wide: true,
      args: { chooser: false, filtered: false, sort: "age-desc" },
      controls: [{ name: "chooser", label: "Column chooser open", type: "toggle" }, { name: "filtered", label: "Status filter on", type: "toggle" }, { name: "sort", label: "Sorted by", type: "select", options: [{ value: "age-desc", label: "Age" }, { value: "tokens-desc", label: "Tokens" }, { value: "ident-asc", label: "Ticket" }] }],
      render: (p) => frame(tableSection(p)),
      docs: {
        what: "A table of tickets with a search field and filter chips above it, and a Columns menu that picks which columns show.",
        responsive: ["Laptop: the Repo column hides (the repo filter chip says it); the filter bar wraps onto two lines if it must; the Title column wraps at 42 characters.", "Desktop: every chosen column shows; the table fills the width, but the Title column still wraps at its measure."],
        tokens: ["table tokens", "chip tokens", "--elevation-2"],
      },
      stories: VIEWPORT_STORIES([{ name: "Column chooser open", viewport: "laptop", args: { chooser: true } }, { name: "Filtered", viewport: "laptop", args: { filtered: true } }]),
    },
    {
      title: "Control bar",
      wide: true,
      args: { period: 1, unit: "Tokens", repo: "All repos", epic: "All epics", summary: "Mar 3 to Mar 9 · 18.4M tokens" },
      controls: [{ name: "period", label: "Period", type: "select", options: [{ value: 0, label: "Day" }, { value: 1, label: "Week" }, { value: 2, label: "Month" }] }, { name: "unit", label: "Unit", type: "select", options: ["Tokens", "Runs", "Hours"] }, { name: "repo", label: "Repo", type: "select", options: ["All repos", "symphony", "web-shop"] }, { name: "epic", label: "Epic", type: "select", options: ["All epics", "Phase 3b", "Phase 3a"] }, { name: "summary", label: "Summary", type: "text" }],
      render: (p) => frame(controlBar(p)),
      docs: {
        what: "The bar above Usage and Shipped that sets what the page shows: the period, the unit, the repo and the epic, with a one-line summary of the result.",
        responsive: ["Laptop: the controls keep one line and the summary drops to the next line when they do not fit together.", "Desktop: one line, the summary right aligned.", "Clear appears only when a repo or an epic is picked."],
        tokens: ["--surface-raised", "--radius-row", "segmented control and pop-up tokens"],
      },
      stories: VIEWPORT_STORIES([{ name: "Filtered", viewport: "laptop", args: { repo: "symphony", epic: "Phase 3b", summary: "Mar 3 to Mar 9 · 6.2M tokens in Phase 3b" } }]),
    },
  ];

  return {
    esc: esc,
    ROLE_OPTIONS: ROLE_OPTIONS,
    groups: [
      { id: "tokens", title: "Tokens", items: tokens },
      { id: "components", title: "Components", items: components },
      { id: "sections", title: "Sections", items: sections },
    ],
  };
})();
