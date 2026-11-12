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
    note: '<path d="M3 2.5h10v8l-3 3H3z"/><path d="M10 13.5v-3h3M5.5 6h5M5.5 8.5h3"/>',
    home: '<path d="M2.5 7.5 8 2.8l5.5 4.7v6H9.9V9.8H6.1v3.7H2.5z"/>',
    journal: '<rect x="3" y="2" width="10" height="12" rx="1.5"/><path d="M5.8 5.5h4.4M5.8 8h4.4M5.8 10.5h2.6"/>',
    grid: '<rect x="2.5" y="2.5" width="4.5" height="4.5" rx="1"/><rect x="9" y="2.5" width="4.5" height="4.5" rx="1"/><rect x="2.5" y="9" width="4.5" height="4.5" rx="1"/><rect x="9" y="9" width="4.5" height="4.5" rx="1"/>',
    chart: '<path d="M2.5 13.5h11"/><path d="m3 10.5 3.2-3.6 2.6 2.2L13 4"/>',
    factory: '<path d="M2.5 13.5V7l3.5 2V7l3.5 2V3.5h3v10z"/><path d="M5 11.2h1.2M8.2 11.2h1.2"/>',
    wrench: '<path d="M10.8 2.2a3.3 3.3 0 0 0-3 4.6L2.6 12a1 1 0 0 0 1.4 1.4l5.2-5.2a3.3 3.3 0 0 0 4.6-3l-2 1.9-1.9-.5-.5-1.9z"/>',
    pulse: '<path d="M1.8 8.5h2.7l1.6-4 2.6 8 1.7-4h3.8"/>',
    sidebar: '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M6 3v10"/>',
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
    say: '<path d="M2.5 3h11v8H7.5L4.5 13.5V11h-2z"/>',
    build: '<path d="M2.5 5 8 2l5.5 3v6L8 14l-5.5-3z"/><path d="M2.5 5 8 8l5.5-3M8 8v6"/>',
    cancelled: '<circle cx="8" cy="8" r="6.3"/><path d="m3.6 12.4 8.8-8.8"/>',
    note: '<path d="M3 2.5h10v8l-3 3H3z"/><path d="M10 13.5v-3h3M5.5 6h5M5.5 8.5h3"/>',
    folder: '<path d="M1.8 4.2a1 1 0 0 1 1-1h3.4l1.5 1.6h5.5a1 1 0 0 1 1 1v6.9a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z"/>',
    eye: '<path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/>',
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

  /* Three control sizes: small 24 pt, medium 30 pt, large 36 pt. "regular" reads as medium. */
  const SIZES = { small: "sm", medium: "md", regular: "md", large: "lg" };
  const sizeClass = (size) => " sz-" + (SIZES[size] || "md");
  const SIZE = { name: "size", label: "Size", type: "select", options: [{ value: "small", label: "Small · 24 pt" }, { value: "medium", label: "Medium · 30 pt" }, { value: "large", label: "Large · 36 pt" }] };

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
    const size = sizeClass(p.size);
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

  /* A segmented control: equal segments and one thumb that slides to the selection */
  function segmented(opts, selected, o) {
    o = o || {};
    const n = Math.max(1, opts.length);
    const sel = Math.max(0, Math.min(n - 1, Number(selected) || 0));
    return '<div class="segmented' + (o.size ? sizeClass(o.size) : "") + '" role="radiogroup"' + attr("aria-label", o.label) + ' data-anim="' + esc(o.anim || "seg") + '" style="--n:' + n + ";--i:" + sel + '"' +
      (o.disabled ? ' aria-disabled="true"' + attr("title", o.reason) : "") + '><span class="seg-thumb" aria-hidden="true"></span>' + opts.map((label, i) =>
      '<button type="button" role="radio" class="segment' + (i === Number(o.hoverAt) && i !== sel ? " is-hover" : "") + (i === sel && o.focused ? " is-focused" : "") + '" aria-checked="' + (i === sel) + '"' +
      (o.disabled ? ' aria-disabled="true"' : ' data-set="' + esc(o.prop || "selected") + "=" + i + '" data-key="' + esc((o.anim || "seg") + i) + '"') + ">" + esc(label) + "</button>").join("") + "</div>";
  }

  function situation(p) {
    const role = p.role || "working";
    const word = p.word || ROLES[role].word;
    const large = p.size === "large";
    /* Large (the page header): the age is anchored to the word, in one status pill, so it never floats at the end of the line. */
    const glyph = p.glyph || ROLES[role].glyph;
    const lead = large ? '<span class="state-pill">' + icon(glyph) + '<span class="word">' + esc(word) + "</span>" +
      (p.age ? '<span class="since" title="Since this situation began">' + icon("clock") + "<span>for " + esc(p.age) + "</span></span>" : "") + "</span>" :
      icon(glyph) + '<span class="word">' + esc(word) + "</span>";
    return '<p class="situation role-' + esc(role) + (large ? " situation-lg" : "") + (p.compact ? " situation-compact" : "") + '" style="margin:0">' + lead +
      (p.cause ? '<span class="cause">' + esc(p.cause) + "</span>" : "") +
      (p.waits ? '<span class="waits">' + esc(p.waits) + "</span>" : "") +
      (p.age && !large ? '<span class="age" title="Since this situation began">' + esc(p.age) + "</span>" : "") + "</p>";
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
      (p.wide ? '<span class="xcol xcol-waits"><span>' + esc(p.line2 || "") + "</span></span>" + '<span class="xcol xcol-repo">' + chip({ kind: "repo", text: p.repo || "symphony", interactive: false }) + "</span>" +
        '<span class="xcol xcol-steps mini-steps" aria-label="Steps">' + (p.steps || "passed passed current pending pending").split(" ").map((k) => '<i class="' + esc(k) + '"></i>').join("") + "</span>" : "") +
      '<span class="trail">' + (p.badge ? badge(role, p.badge, "small") : "") + reason + fix + (p.age ? '<span class="age">' + esc(p.age) + "</span>" : "") + "</span></div>";
  }

  /* An animated fold: the body is always drawn, data-open opens it (see components.css) */
  const fold = (key, open, inner) => '<div class="fold" data-anim="fold-' + esc(key) + '" data-open="' + !!open + '"><div class="fold-inner">' + inner + "</div></div>";

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
    message: { glyph: "note", role: "accent", word: "You wrote to the ticket" },
  };

  const TL_OPTIONS = Object.keys(TL).map((k) => ({ value: k, label: TL[k].word }));

  function tlEntry(p) {
    const k = TL[p.kind] || TL.phase;
    return '<li class="tl-entry role-' + k.role + stateClass(p.state) + (p.fresh ? " is-new" : "") + '"' + (p.selectable ? ' tabindex="0" role="option" aria-selected="' + !!p.selected + '"' + (p.toggle ? ' data-toggle="' + esc(p.toggle) + '"' : "") : "") + '><span class="time">' + esc(p.time) + "</span>" +
      '<span class="mark" title="' + esc(k.word) + '">' + icon(k.glyph) + "</span>" +
      '<span class="what"><span class="head">' + (p.unseen ? '<span class="new-dot" title="New since you last looked"></span>' : "") + p.headHtml + "</span>" +
      (p.detail ? '<span class="detail">' + esc(p.detail) + "</span>" : "") +
      (p.actor ? '<span class="actor">' + esc(p.actor) + "</span>" : "") + "</span></li>";
  }

  const head = (strong, rest) => "<b>" + esc(strong) + "</b>" + (rest ? " " + esc(rest) : "");

  function runGroup(p) {
    const verdict = { passed: "done", failed: "problem", running: "working", stopped: "idle" }[p.verdict] || "working";
    const glyph = { passed: "done", failed: "problem", running: "run-start", stopped: "run-end" }[p.verdict] || "run-start";
    const word = { passed: "Passed", failed: "Failed", running: "Running", stopped: "Stopped" }[p.verdict] || "";
    const strip = p.steps ? '<div class="run-steps">' + steps(p.steps) + "</div>" : "";
    const body = fold("run-" + (p.foldKey || "run"), p.expanded, '<div class="run-body">' + strip + '<ol class="timeline">' + (p.entries || []).slice().reverse().map(tlEntry).join("") + "</ol></div>");
    return '<div class="run-group"><button type="button" class="run-head role-' + verdict + stateClass(p.state) + '" aria-expanded="' + !!p.expanded + '" data-toggle="expanded" data-key="run">' +
      '<span class="time">' + esc(p.time) + '</span><span class="mark">' + (p.verdict === "running" ? '<span class="dot live role-working"></span>' : icon(glyph)) + "</span>" +
      '<span class="name">' + icon("chevron-right", "disclose") + "<b>" + esc(p.title) + "</b>" + badge(verdict, word, "small") + (p.steps ? miniSteps(p.steps) : "") + (p.tokens ? '<span class="t-secondary">' + esc(p.tokens) + "</span>" : "") + "</span>" +
      '<span class="dur" title="How long the run took">' + esc(p.duration) + "</span></button>" + body + "</div>";
  }

  const STEP_NAMES = [["code", "Writing the code"], ["build", "Build"], ["checks", "Checks"], ["tests", "Tests"], ["handoff", "Handoff"]];
  /* The ticket's whole path, not one run's: the stages a ticket moves through to land. */
  const STAGE_NAMES = [["coding", "Coding"], ["review", "Code Review"], ["qa", "QA"], ["merging", "Merging"], ["done", "Done"]];
  const STEP_STATES = {
    passed: { word: "Passed", glyph: "done", role: "done" },
    failed: { word: "Failed", glyph: "problem", role: "problem" },
    paused: { word: "Paused", glyph: "idle", role: "idle" },
    skipped: { word: "Skipped", glyph: "chevron-right", role: "idle" },
    current: { word: "Now", glyph: "working", role: "working" },
    returned: { word: "Sent back", glyph: "undo", role: "you" },
    pending: { word: "Not started", glyph: "clock", role: "idle" },
  };
  const STEP_OPTIONS = Object.keys(STEP_STATES).map((k) => ({ value: k, label: STEP_STATES[k].word }));

  function steps(p) {
    const stages = p.kind === "ticket";
    return '<ol class="steps' + (stages ? " stages" : "") + '" aria-label="' + (stages ? "Stages of the ticket" : "Steps of the run") + '">' + (stages ? STAGE_NAMES : STEP_NAMES).map((s) => {
      const st = STEP_STATES[p[s[0]]] || STEP_STATES.pending;
      const detail = p[s[0] + "Note"] || "";
      return '<li class="step ' + esc(p[s[0]]) + " role-" + st.role + '"><span class="bar"></span><span class="name">' + icon(st.glyph) + esc(s[1]) + "</span>" +
        '<span class="state">' + esc(st.word) + (detail ? " · " + esc(detail) : "") + "</span></li>";
    }).join("") + "</ol>";
  }

  /* The same steps folded into one line of the timeline: a short bar per step, the current step's
     name beside them. The run's line unfolds into the full strip. */
  function miniSteps(p) {
    const at = STEP_NAMES.find((s) => p[s[0]] === "current" || p[s[0]] === "failed" || p[s[0]] === "paused");
    const said = STEP_NAMES.map((s) => s[1] + ", " + (STEP_STATES[p[s[0]]] || STEP_STATES.pending).word.toLowerCase()).join("; ");
    return '<span class="steps-mini" role="img" aria-label="Steps: ' + esc(said) + '">' + STEP_NAMES.map((s) => '<i class="' + esc(p[s[0]] || "pending") + '"></i>').join("") + "</span>" +
      (at ? '<span class="steps-mini-at role-' + (STEP_STATES[p[at[0]]] || STEP_STATES.pending).role + '">' + esc(at[1]) + "</span>" : "");
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

  /* With a cap, the bar is the whole allowance: the stages fill it from the left and the rest stays
     empty, so one bar says both where the tokens went and how much is left. A stage passed as
     undefined is left out of the legend (agents spend no tokens waiting on you). */
  function stageBar(p) {
    const parts = [["Coding", p.code, "s1"], ["Code Review", p.review, "s2"], ["QA", p.qa, "s3"], ["Merging", p.merge, "s4"], ["Waiting on you", p.waiting, "s5"]].filter((x) => x[1] !== undefined && x[1] !== "");
    const round = (n) => Math.round(n * 10) / 10;
    const total = round(parts.reduce((a, x) => a + (Number(x[1]) || 0), 0));
    const cap = Number(p.cap) || 0;
    const pct = cap ? Math.min(100, Math.round((total / cap) * 100)) : 0;
    const role = pct >= 95 ? "problem" : pct >= 75 ? "you" : "accent";
    const k = p.key ? p.key + "-" : "";
    const segs = parts.filter((x) => Number(x[1]) > 0).map((x) => '<span class="stage-seg ' + x[2] + '" data-anim="seg-' + k + x[2] + '" style="flex:' + Number(x[1]) + '" title="' + esc(x[0]) + ": " + esc(x[1]) + " " + esc(p.unit) + '"></span>').join("");
    const rest = cap && cap > total ? '<span class="stage-seg rest" data-anim="seg-' + k + 'rest" style="flex:' + round(cap - total) + '" title="Left: ' + round(cap - total) + " " + esc(p.unit) + '"></span>' : "";
    const label = esc(p.label) + (cap ? ", " + pct + " percent of the cap" : "");
    const track = total || cap ? '<div class="stage-track' + (total ? "" : " empty") + '" role="img" aria-label="' + label + '">' + segs + (total ? rest : "") + "</div>" : '<div class="stage-track empty"></div>';
    const value = cap ? esc(total) + " of " + esc(cap) + " " + esc(p.unit) + " · " + pct + " %" : total ? esc(total) + " " + esc(p.unit) + " in all" : "Nothing yet";
    const note = cap ? '<div class="meter-note role-' + role + (role === "accent" ? " calm" : "") + '">' + esc(pct >= 100 ? "At the cap: no new run starts." : pct >= 95 ? "Almost at the cap: the run finishes, the next one waits." : pct >= 75 ? "Getting close: " + (100 - pct) + " % left of the ticket's cap." : (100 - pct) + " % of the ticket's cap left.") + "</div>" : "";
    return '<div class="stage-bar' + (cap ? " has-cap" : "") + '"><div class="meter-head"><span>' + esc(p.label) + '</span><span class="value">' + value + "</span></div>" + track +
      '<ul class="stage-legend">' + parts.map((x) => '<li><span class="key stage-seg ' + x[2] + '"></span>' + esc(x[0]) + ' <span class="v">' + esc(x[1] || 0) + "</span></li>").join("") + "</ul>" + note + "</div>";
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
      '<div class="meter-track"><div class="meter-fill" data-anim="meter-fill" style="width:' + pct + '%"></div></div>' +
      '<div class="meter-note' + (role === "accent" ? " calm" : "") + '">' + esc(note) + "</div></div>";
  }

  /* The phases a ticket went through, in the order it first entered each. Each phase is
     { name, visits, time, state: "passed" | "current" | "later", role }; a phase entered more than
     once shows its count, so a ticket sent back twice reads "Code Review ×3". */
  function phasePath(p) {
    const items = (p.phases || []).map((ph, i) => {
      const cls = "phase " + esc(ph.state || "passed") + (ph.state === "current" ? " role-" + esc(ph.role || "working") : "") + (i === Number(p.hoverAt) ? stateClass("hover") : "");
      const said = ph.name + (ph.visits > 1 ? ", entered " + ph.visits + " times" : "") + (ph.time ? ", " + ph.time + " in all" : "") + (ph.state === "current" ? ", now" : ph.state === "later" ? ", not yet" : "");
      const inner = '<span class="phase-name">' + esc(ph.name) + (ph.visits > 1 ? '<span class="visits">×' + esc(ph.visits) + "</span>" : "") + "</span>" +
        (ph.time ? '<span class="phase-meta">' + esc(ph.time) + "</span>" : "");
      return p.interactive ? '<li style="display:contents"><button type="button" class="' + cls + '" aria-label="' + esc(said) + '"' + attr("aria-pressed", ph.picked ? "true" : null) + attr("data-phase", ph.name) + ">" + inner + "</button></li>"
        : '<li class="' + cls + '" aria-label="' + esc(said) + '">' + inner + "</li>";
    }).join("");
    return '<ol class="phase-path' + (p.compact ? " compact" : "") + '" aria-label="Phases, in the order the ticket entered them">' + items + "</ol>";
  }

  const MSG_GLYPH = { say: "say", tool: "log", result: "arrow" };
  const SL_STATES = {
    passed: { word: "Passed", glyph: "done", role: "done" },
    failed: { word: "Failed", glyph: "problem", role: "problem" },
    current: { word: "Now", glyph: "working", role: "working" },
    stopped: { word: "Stopped", glyph: "run-end", role: "idle" },
    asked: { word: "Asked you", glyph: "question", role: "you" },
    skipped: { word: "Skipped", glyph: "chevron-right", role: "idle" },
    pending: { word: "Not started", glyph: "clock", role: "idle" },
  };

  /* A run's steps, top to bottom, each folding into its lines: { name, state, duration, open, msgs:
     [{ time, kind: "say" | "tool" | "result", text, failed, fresh, typing }] }. */
  function stepList(p) {
    return '<ol class="step-list" aria-label="Steps of the run">' + (p.steps || []).map((st, i) => {
      const s = SL_STATES[st.state] || SL_STATES.pending;
      const msgs = st.msgs || [];
      const has = msgs.length > 0;
      const head = '<button type="button" class="sl-head' + (i === Number(p.hoverAt) ? " is-hover" : "") + '" aria-expanded="' + (has && !!st.open) + '"' + (has ? attr("data-step", st.id || String(i)) + (p.setProp ? attr("data-set", p.setProp + "=" + (st.open ? -1 : i)) : "") : ' aria-disabled="true" title="Nothing happened in this step yet"') + ">" +
        icon("chevron-right", "disclose") + '<span class="sl-mark">' + (st.state === "current" ? '<span class="dot live role-working"></span>' : icon(s.glyph)) + "</span>" +
        '<span class="sl-name">' + esc(st.name) + '</span><span class="sl-state">' + esc(st.stateWord || s.word) + '</span><span class="sl-dur">' + esc(st.duration || "") + "</span></button>";
      const lines = '<ol class="sl-msgs">' + msgs.map((m) => '<li class="sl-msg ' + esc(m.kind || "say") + (m.failed ? " failed" : "") + (m.fresh ? " is-new" : "") + (m.typing ? " typing" : "") + '"><span class="time">' + esc(m.time || "") + '</span><span class="kind" title="' + esc({ say: "The agent said", tool: "A tool call", result: "What it returned" }[m.kind] || "") + '">' + icon(MSG_GLYPH[m.kind] || "say") + '</span><span class="text">' + esc(m.text) + "</span></li>").join("") + "</ol>";
      return '<li class="sl-step ' + esc(st.state || "pending") + " role-" + s.role + '">' + head + (has ? fold("step-" + (st.id || i), st.open, lines) : "") + "</li>";
    }).join("") + "</ol>";
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
    { kind: "run-failed", time: "09:24", headHtml: head("Implementation run 1 ended:", "checks failed"), detail: "Two tests failed in the orchestrator" },
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
        what: "A 4 pt grid. Every gap and padding is one of eight steps.",
        when: ["4 between a glyph and its word; 8 between related lines and controls; 12 row padding and the gap between cards in a stack; 16 card padding and between cards side by side; 20 card padding sideways; 24 between sections and the page inset; 32 above an empty state; 40 between the zones of a page on a desktop."],
        tokens: ["--space-1", "--space-2", "--space-3", "--space-4", "--space-5", "--space-6", "--space-8", "--space-10"],
      },
      render: () => '<div class="specimen">' + [[1, 4, "Glyph to word"], [2, 8, "Related lines, controls in a row"], [3, 12, "Row padding, cards in a stack"], [4, 16, "Card padding, cards side by side"], [5, 20, "Card padding sideways"], [6, 24, "Between sections, page inset"], [8, 32, "Above an empty state, page zones"], [10, 40, "Desktop zones"]].map((s) =>
        '<div class="specimen-row"><code>--space-' + s[0] + " · " + s[1] + ' pt</code><span style="display:flex;align-items:center;gap:12px"><span class="space-bar" style="width:' + s[1] + 'px"></span><span class="t-secondary">' + esc(s[2]) + "</span></span></div>").join("") + "</div>",
      stories: [{ name: "All steps" }],
    },
    {
      title: "Control sizes",
      args: { size: "medium" },
      controls: [SIZE],
      docs: {
        what: "Three heights that every control shares: buttons, icon buttons, menu buttons, pop-ups, segmented controls, fields. A control is small, medium or large, and never any other height.",
        when: ["Small · 24 pt, radius 7: inside rows, toasts, table headers, dense filter bars. Chips and switches are always this height.", "Medium · 30 pt, radius 9: the default for rails, cards, sheets and toolbars.", "Large · 36 pt, radius 11: one main action where it is the whole point of the place (a Question's Send, an empty state's action)."],
        avoid: "Mixing sizes in one row, or setting a height on a control by hand. A container may set the size once for all of its controls.",
        tokens: ["--control-sm", "--control-md", "--control-lg", "--radius-control-sm", "--radius-control-md", "--radius-control-lg"],
      },
      render: (p, ctx) => {
        if (ctx.story.id === "one-row-one-size") {
          return '<div class="btn-row' + sizeClass(p.size) + '">' + button({ label: "Approve Plan", variant: "primary", size: p.size }) + button({ label: "Open Checks", variant: "secondary", size: p.size }) +
            '<button type="button" class="menu-btn' + sizeClass(p.size) + '">Move to…' + icon("chevron-down", "chev") + "</button>" + segmented(["Day", "Week", "Month"], 1, { size: p.size, anim: "seg-sz" }) +
            '<div class="input search' + sizeClass(p.size) + '" style="width:200px">' + icon("search") + '<input type="search" aria-label="Search" placeholder="Search"></div><button type="button" class="icon-btn' + sizeClass(p.size) + '" aria-label="More" title="More">' + icon("more") + "</button></div>";
        }
        return '<div class="size-guide">' + [["small", "Small", 24, 7], ["medium", "Medium", 30, 9], ["large", "Large", 36, 11]].map((z) =>
          "<div>" + button({ label: z[1], variant: "secondary", size: z[0] }) + '<span class="t-secondary">' + z[2] + " pt · radius " + z[3] + "</span></div>").join("") + "</div>";
      },
      stories: [{ name: "Three heights" }, { name: "One row, one size" }, { name: "One row, small", args: { size: "small" } }, { name: "One row, large", args: { size: "large" } }],
    },
    {
      title: "Radii",
      docs: {
        what: "Continuous rounded corners, used concentrically: an inner radius is the outer radius minus the inset between them.",
        when: ["Sheet 22; card 16 for cards and section containers; row 10 for rows, option cards and tiles inside a card; controls 7, 9 and 11 by size; mark 4 for small marks; capsule for chips, badges, segmented controls, switches, search fields and meters."],
        tokens: ["--radius-sheet", "--radius-card", "--radius-row", "--radius-control-sm", "--radius-control-md", "--radius-control-lg", "--radius-mark", "--radius-capsule"],
      },
      render: (p, ctx) => {
        if (ctx.story.id === "concentric") {
          return '<div class="card" style="width:380px;padding:6px"><div class="row is-hover role-working">' + '<span class="lead">' + icon("working") + '</span><span class="main"><span class="line1"><span class="ident">Row 10</span><span class="title">inside a card of 16, 6 inset</span></span></span></div></div>';
        }
        return '<div style="display:flex;flex-wrap:wrap;gap:24px">' + [["Sheet", 22], ["Card", 16], ["Row", 10], ["Control, large", 11], ["Control", 9], ["Control, small", 7], ["Mark", 4], ["Capsule", 999]].map((r) =>
          '<div style="display:grid;gap:8px;justify-items:center"><div class="radius-box" style="border-radius:' + r[1] + "px;" + (r[1] > 100 ? "height:36px" : "") + '"></div><span class="t-secondary">' + esc(r[0]) + " · " + (r[1] > 100 ? "height / 2" : r[1] + " pt") + "</span></div>").join("") + "</div>";
      },
      stories: [{ name: "All radii" }, { name: "Concentric" }],
    },
    {
      title: "Elevation",
      docs: {
        what: "Layered soft shadows: a hairline ring, a near shadow and a far one. Content sits flat on its card; only what rises casts more.",
        when: ["Level 0: anything inside a card. Level 1: a card, a group, a toggle row. Level 2: a card under the pointer, a tooltip, a preview pane. Level 3: menus, pop-up lists, toasts. Level 4: sheets."],
        avoid: "A shadow on a row, a chip or a chart, or a shadow without the hairline ring (it blurs the edge in dark).",
        tokens: ["--elevation-0", "--elevation-1", "--elevation-2", "--elevation-3", "--elevation-4", "--edge-highlight"],
      },
      render: () => '<div style="display:flex;flex-wrap:wrap;gap:32px;padding:16px">' + [0, 1, 2, 3, 4].map((n) =>
        '<div class="elev-box" style="box-shadow:var(--elevation-' + n + ')">Level ' + n + "<br>" + ["Inside a card", "Card", "Hovered card, tooltip", "Menu, toast", "Sheet"][n] + "</div>").join("") + "</div>",
      stories: [{ name: "Levels" }],
    },
    {
      title: "Materials",
      docs: {
        what: "Glass for what floats over content: a translucent fill, a strong blur that saturates what is behind, and a bright inner edge. Menus, pop-up lists, tooltips, toasts, sheets and bars use it; content never does.",
        when: ["Thick glass (88 % in light) for anything with text to read: menus, toasts, sheets. Regular glass (72 %) for bars over scrolling content.", "The window behind carries a faint iris and blue glow, so the glass has something to refract."],
        avoid: "Glass on cards or rows, or text on regular glass over a busy picture.",
        tokens: ["--material-glass", "--material-glass-thick", "--material-blur", "--material-edge", "--backdrop-glow"],
        access: "With Reduce Transparency on, the app draws the same layers opaque.",
      },
      render: () => '<div class="glass-demo"><div class="glass-under">' + TICKETS.slice(0, 4).map((t) => row(Object.assign({}, t, { twoLine: true }))).join("") + "</div>" +
        '<div class="glass-over" style="background:var(--material-glass)"><b>Regular glass</b><span class="t-secondary">Bars over scrolling content</span></div>' +
        '<div class="glass-over thick" style="background:var(--material-glass-thick)"><b>Thick glass</b><span class="t-secondary">Menus, toasts, sheets</span></div></div>',
      stories: [{ name: "Glass over content" }],
    },
    {
      title: "Motion",
      args: { duration: "--motion-spring", easing: "--ease-spring", play: false, open: false, picked: 0, on: false },
      controls: [
        { name: "duration", label: "Duration", type: "select", when: (p) => p.demo === "ball", options: [{ value: "--motion-instant", label: "Instant · 0.1 s" }, { value: "--motion-fast", label: "Fast · 0.16 s" }, { value: "--motion-standard", label: "Standard · 0.28 s" }, { value: "--motion-slow", label: "Slow · 0.45 s" }, { value: "--motion-spring", label: "Spring · 0.5 s" }] },
        { name: "easing", label: "Easing", type: "select", when: (p) => p.demo === "ball", options: [{ value: "--ease-standard", label: "Standard" }, { value: "--ease-enter", label: "Enter" }, { value: "--ease-exit", label: "Exit" }, { value: "--ease-spring", label: "Spring" }, { value: "--ease-bounce", label: "Bounce" }] },
        { name: "open", label: "Open", type: "toggle", when: (p) => p.demo === "fold" },
        { name: "picked", label: "Picked", type: "number", min: 0, max: 2, when: (p) => p.demo === "select" },
        { name: "on", label: "On", type: "toggle", when: (p) => p.demo === "select" },
      ],
      docs: {
        what: "Motion is part of each component, not a speed on a list. Five patterns cover the Director: press, lift, fold, slide and enter. Each uses one duration and one easing from here, and each component's docs say which.",
        when: [
          "Press: a control shrinks to 97 % in 0.1 s while held and springs back.",
          "Lift: a clickable card or option rises 1 pt with a deeper shadow on hover, on a spring.",
          "Fold: a group, card or run opens to its height in 0.28 s; its rows fade down into place one after another, 35 ms apart; the chevron turns on a spring. Board groups, collapsible cards and run groups fold this way.",
          "Slide: a selection moves rather than jumps: the segmented thumb, the switch knob, a meter's fill.",
          "Enter: what floats (menus, tooltips, toasts, sheets) rises a few points and fades in on a spring; it leaves faster than it came.",
          "Values that change on a poll update in place; nothing moves under the pointer.",
        ],
        tokens: ["--motion-instant", "--motion-fast", "--motion-standard", "--motion-slow", "--motion-spring", "--motion-hover-delay", "--motion-stagger", "--ease-standard", "--ease-enter", "--ease-exit", "--ease-spring", "--ease-bounce", "--press-scale", "--lift", "--enter-offset"],
        access: "With Reduce Motion on, every duration is near zero, nothing scales, lifts or loops, and folds and selections simply change.",
      },
      render: (p, ctx) => {
        const id = ctx.story.id;
        const replay = (label) => button({ label: label || "Play again", glyph: "play", variant: "secondary", size: "small" }).replace("<button ", '<button data-toggle="play" data-key="play" ');
        if (id === "fold") {
          const items = [TICKETS[1], TICKETS[3], TICKETS[6]];
          return '<div style="width:640px">' + boardGroup("Working", "working", items, p.open, "3 runs", "open") + '<p class="t-secondary" style="margin:12px 4px 0">Click the heading: the group grows to its height while its rows fade down in turn.</p></div>';
        }
        if (id === "slide") {
          return '<div style="display:grid;gap:20px;justify-items:start">' + segmented(["Day", "Week", "Month"], p.picked, { prop: "picked", anim: "seg-motion" }) +
            '<div class="toggle-row"><span class="label" id="mo-l">Notify me about new questions</span><span class="effect">Click the switch, then the segments.</span><button type="button" role="switch" class="switch" aria-labelledby="mo-l" aria-checked="' + !!p.on + '" data-toggle="on" data-key="mo-sw"></button></div>' +
            meter({ label: "Tokens today", used: p.on ? 4200000 : 1600000, cap: 5000000, unit: "tokens", resets: "at midnight" }) + "</div>";
        }
        if (id === "press-and-lift") {
          return '<div style="display:grid;gap:20px;justify-items:start;width:520px"><div class="btn-row">' + button({ label: "Press and hold me", variant: "primary" }) + button({ label: "Or me", variant: "secondary" }) + "</div>" +
            card({ clickable: true, title: "Waiting on you", body: "Hover me: I rise a point on a spring. Press me: I settle." }) + "</div>";
        }
        if (id === "enter") {
          return '<div style="display:grid;gap:16px;justify-items:start" data-replay="' + !!p.play + '">' + replay("Play the entrances again") +
            '<div class="toast role-done" role="status">' + icon("done") + '<span class="msg">TP-1382 moved to Rework<span class="sub">A toast rises from the bottom edge.</span></span>' + button({ label: "Undo", variant: "quiet", size: "small" }) + "</div>" +
            '<div style="position:relative;height:170px;width:260px"><ul class="menu" role="menu" style="position:relative;top:0">' + ["Todo", "In Progress", "Rework"].map((x, i) => '<li class="menu-item' + (i === 1 ? " is-hover" : "") + '" role="menuitem" tabindex="-1">' + icon("check", "check") + esc(x) + "</li>").join("") + "</ul></div></div>";
        }
        return '<div style="display:grid;gap:12px;width:520px"><div class="motion-track" data-motion><span class="motion-ball" style="transition:left var(' + esc(p.duration) + ") var(" + esc(p.easing) + ')"></span></div>' +
          '<div style="display:flex;gap:12px;align-items:center">' + replay() + '<span class="t-secondary">' + esc(p.duration) + " with " + esc(p.easing) + "</span></div></div>";
      },
      mounted: (stage) => {
        stage.querySelectorAll("[data-motion]").forEach((track) => {
          window.setTimeout(() => track.classList.add("go"), 60);
        });
      },
      stories: [
        { name: "Durations and easings", args: { demo: "ball" } },
        { name: "Spring", args: { demo: "ball", duration: "--motion-spring", easing: "--ease-spring" } },
        { name: "Bounce", args: { demo: "ball", duration: "--motion-spring", easing: "--ease-bounce" } },
        { name: "Fold", args: { demo: "fold" } },
        { name: "Slide", args: { demo: "select" } },
        { name: "Press and lift", args: { demo: "press" } },
        { name: "Enter", args: { demo: "enter" } },
      ],
    },
    {
      title: "Focus ring",
      docs: {
        what: "A 2 pt ring in the iris at half strength, 2 pt outside the shape and following its corners, drawn only when focus came from the keyboard.",
        when: ["Every control, row, card and option that takes focus draws it. A pointer click never does. Fields draw an accent edge with a soft halo instead."],
        tokens: ["--focus-ring-color", "--focus-ring-width", "--focus-ring-offset"],
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
      args: { label: "Approve Plan", variant: "primary", size: "medium", glyph: "none", state: "default", disabled: false, reason: "Checks are still running on PR #812." },
      controls: [
        { name: "label", label: "Label", type: "text" },
        { name: "variant", label: "Kind", type: "select", options: [{ value: "primary", label: "Primary" }, { value: "secondary", label: "Secondary" }, { value: "destructive", label: "Destructive" }, { value: "destructive-filled", label: "Destructive, in a sheet" }, { value: "quiet", label: "Quiet" }] },
        SIZE,
        { name: "glyph", label: "Glyph", type: "select", options: ["none", "play", "stop", "refresh", "pr", "plus", "undo"] },
        STATE, DISABLED, REASON,
      ],
      render: (p, ctx) => {
        if (ctx.story.id !== "sizes-side-by-side") return button(p);
        const kinds = [["primary", "Primary"], ["secondary", "Secondary"], ["destructive", "Destructive"], ["quiet", "Quiet"]];
        return '<div class="btn-sizes"><span></span><span class="t-label">Small · 24 pt</span><span class="t-label">Medium · 30 pt</span><span class="t-label">Large · 36 pt</span>' +
          kinds.map((k) => '<span class="t-label">' + k[1] + "</span>" + ["small", "medium", "large"].map((z) => button({ label: p.label, variant: k[0], size: z, glyph: p.glyph })).join("")).join("") +
          '<span class="t-label">Icon button</span>' + ["small", "medium", "large"].map((z) => '<button type="button" class="icon-btn' + sizeClass(z) + '" aria-label="More" title="More">' + icon("more") + "</button>").join("") +
          '<span class="t-label">Menu button</span>' + ["small", "medium", "large"].map((z) => '<button type="button" class="menu-btn' + sizeClass(z) + '">Move to…' + icon("chevron-down", "chev") + "</button>").join("") +
          '<span class="t-label">Field</span>' + ["small", "medium", "large"].map((z) => '<div class="input search' + sizeClass(z) + '" style="width:180px">' + icon("search") + '<input type="search" aria-label="Search" placeholder="Search"></div>').join("") + "</div>";
      },
      docs: {
        what: "A labelled action. One primary button per place (the move we expect), secondary for the others, destructive for what stops or throws work away, quiet for low-stakes actions inside text and cards.",
        when: ["Name it with its verb in title case: Approve Plan, Stop Run…, Send Decision….", "End the label with “…” when it opens a sheet that asks for more.", "Disabled always says why, in an inline refusal under it and as its help text."],
        avoid: "Two primary buttons side by side, or a disabled button without a reason.",
        sizes: "Three sizes, and every control shares them: small 24 pt (inside rows, toasts, dense bars), medium 30 pt (the default: rails, sheets, cards), large 36 pt (one main action on an empty page or a Question's Send). A button never takes another height, whatever it sits in.",
        states: [["Default", "resting, with a hairline edge and a top highlight; primary in the iris fill with a soft coloured glow"], ["Hover", "lighter fill, the shadow grows"], ["Pressed", "darker, scales to 97 %"], ["Focused", "the focus ring outside the shape"], ["Disabled with reason", "tertiary text on raised, the not-allowed pointer, the reason underneath"]],
        motion: "Hover and pressed ease in 0.16 s; the press scales to 97 % in 0.1 s and springs back when released.",
        tokens: ["--control-sm", "--control-md", "--control-lg", "--radius-control-sm … lg", "--accent-fill", "--accent-glow", "--status-problem", "--motion-fast", "--press-scale", "--focus-ring-color"],
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
        { name: "Medium", args: { size: "medium", variant: "secondary", label: "Open Checks" } },
        { name: "Large", args: { size: "large", label: "Send Decision…" } },
        { name: "Sizes side by side", args: { label: "Approve" } },
      ],
    },
    {
      title: "Icon button",
      args: { glyph: "inspector", label: "Show the details pane", size: "medium", state: "default", toggled: false, disabled: false, reason: "No ticket is selected." },
      controls: [
        { name: "glyph", label: "Glyph", type: "select", options: ["inspector", "refresh", "more", "close", "link", "filter", "columns", "search"] },
        { name: "label", label: "Help text", type: "text" }, SIZE,
        STATE, { name: "toggled", label: "On", type: "toggle" }, DISABLED, REASON,
      ],
      render: (p) => {
        const b = '<button type="button" class="icon-btn' + sizeClass(p.size) + (p.disabled ? "" : stateClass(p.state)) + '" aria-label="' + esc(p.label) + '" title="' + esc(p.disabled ? p.reason : p.label) + '"' +
          (p.disabled ? ' aria-disabled="true"' : ' aria-pressed="' + !!p.toggled + '" data-toggle="toggled" data-key="ib"') + ">" + icon(p.glyph) + "</button>";
        return p.disabled ? '<span class="btn-group" style="align-items:center">' + b + refusal(p.reason) + "</span>" : b;
      },
      docs: {
        what: "A glyph-only action for toolbars and card corners, where the glyph is well known (close, more, refresh, the details pane).",
        when: ["Always has help text that names the action; that text is what VoiceOver reads.", "A toggle (show or hide a pane) shows its on state with the accent tint."],
        avoid: "An icon button for a move that changes Linear or a run: those get a labelled button.",
        states: [["Default", "secondary glyph, no background"], ["Hover", "hover overlay"], ["Pressed", "pressed overlay"], ["Focused", "focus ring"], ["On", "accent glyph on accent tint"], ["Disabled with reason", "tertiary glyph, reason as help and underneath"]],
        sizes: "Square, at the three control heights: 24, 30 and 36 pt, so it lines up with the buttons beside it.",
        motion: "Pressed shrinks it to 92 %; switching on pops the glyph with a small bounce.",
        tokens: ["--surface-hover", "--surface-pressed", "--accent-tint", "--control-sm … lg", "--radius-control-sm … lg"],
      },
      stories: [
        { name: "Default" }, { name: "Hover", args: { state: "hover" } }, { name: "Pressed", args: { state: "pressed" } }, { name: "Focused", args: { state: "focused" } },
        { name: "On", args: { toggled: true } }, { name: "Small", args: { size: "small" } }, { name: "Large", args: { size: "large" } }, { name: "Disabled with reason", args: { disabled: true } },
      ],
    },
    {
      title: "Menu button",
      args: { label: "Move to…", size: "medium", open: false, state: "default", disabled: false, reason: "Moves wait while a run is working." },
      controls: [{ name: "label", label: "Label", type: "text" }, SIZE, { name: "open", label: "Menu open", type: "toggle" }, STATE, DISABLED, REASON],
      render: (p) => {
        const items = [["Todo", ""], ["In Progress", ""], ["Rework", ""], ["sep"], ["Backlog", "⌘ ⌫"], ["Canceled", "", "destructive"]];
        const menu = p.open && !p.disabled ? '<ul class="menu" role="menu">' + items.map((it, i) => it[0] === "sep" ? '<li class="menu-sep" role="separator"></li>' :
          '<li class="menu-item' + (i === 1 ? " is-hover" : "") + (it[2] ? " " + it[2] : "") + '" role="menuitem" tabindex="-1">' + icon("check", "check") + esc(it[0]) + (it[1] ? kbd(it[1], true) : "") + "</li>").join("") + "</ul>" : "";
        const b = '<button type="button" class="menu-btn' + sizeClass(p.size) + (p.disabled ? "" : stateClass(p.state)) + '" aria-haspopup="menu" aria-expanded="' + (!!p.open && !p.disabled) + '"' +
          (p.disabled ? ' aria-disabled="true"' + attr("title", p.reason) : ' data-toggle="open" data-key="mb"') + ">" + esc(p.label) + icon("chevron-down", "chev") + "</button>";
        return '<div style="min-height:' + (p.open ? 200 : 40) + 'px"><span class="menu-wrap">' + b + menu + "</span>" + (p.disabled ? '<div style="margin-top:4px">' + refusal(p.reason) + "</div>" : "") + "</div>";
      },
      docs: {
        what: "A button that opens a short menu of related moves, for a set that does not fit the action rail.",
        when: ["The label names the set and ends with “…” or a chevron; each item is a verb or a destination.", "Destructive items sit last, under a separator."],
        states: [["Closed", "like a secondary button with a chevron"], ["Hover", "lighter, the shadow grows"], ["Pressed", "scales to 97 %"], ["Open", "accent edge while the menu shows, the chevron turned"], ["Focused", "focus ring"], ["Disabled with reason", "reason underneath"]],
        sizes: "Small, medium (default) and large, the same heights as buttons.",
        motion: "The menu rises 6 pt and fades in on a spring (0.28 s) from the button's corner; the chevron turns over with it.",
        tokens: ["--material-glass-thick", "--material-blur", "--elevation-3", "--accent (menu highlight)", "--ease-spring"],
        access: "Space or Return opens the menu, arrows move, Escape closes.",
      },
      stories: [
        { name: "Closed" }, { name: "Hover", args: { state: "hover" } }, { name: "Pressed", args: { state: "pressed" } }, { name: "Open", args: { open: true } },
        { name: "Focused", args: { state: "focused" } }, { name: "Disabled with reason", args: { disabled: true } },
      ],
    },
    {
      title: "Segmented control",
      args: { options: "Day, Week, Month", selected: 1, size: "medium", hoverAt: -1, state: "default", disabled: false, reason: "The period is fixed while comparing two epics." },
      controls: [
        { name: "options", label: "Segments", type: "text" }, SIZE,
        { name: "selected", label: "Selected segment", type: "number", min: 0, max: 6 },
        { name: "hoverAt", label: "Shown hover on", type: "number", min: -1, max: 6 },
        { name: "state", label: "Shown state", type: "select", options: [{ value: "default", label: "Live (use the pointer)" }, { value: "focused", label: "Focused" }] },
        DISABLED, REASON,
      ],
      render: (p) => {
        const opts = String(p.options).split(",").map((s) => s.trim()).filter(Boolean);
        const seg = segmented(opts, p.selected, { size: p.size, hoverAt: p.hoverAt, focused: p.state === "focused", disabled: p.disabled, reason: p.reason, label: "Period" });
        return p.disabled ? '<span class="btn-group">' + seg + refusal(p.reason) + "</span>" : seg;
      },
      docs: {
        what: "Two to five mutually exclusive views of the same thing: a period, a unit, a layout.",
        when: ["Segments are short nouns. The choice applies at once, with no confirmation."],
        avoid: "More than five segments (use a pop-up), or segments that trigger moves.",
        states: [["Selected", "a raised capsule thumb on a sunken capsule track"], ["Hover", "hover overlay on an unselected segment"], ["Pressed", "pressed overlay"], ["Focused", "ring on the selected segment"], ["Disabled with reason", "tertiary text, reason underneath"]],
        sizes: "Small, medium (default) and large; segments share the width equally so the thumb can slide.",
        motion: "Picking a segment slides the thumb to it on a spring (0.5 s, about 2 % overshoot); the words cross-fade their colour. Click one on the canvas to see it.",
        tokens: ["--surface-sunken", "--surface-content", "--radius-capsule", "--motion-spring", "--ease-spring"],
        access: "A radio group: arrows move the selection, VoiceOver reads “Week, selected, 2 of 3”.",
      },
      stories: [
        { name: "Default" }, { name: "Segment hover", args: { hoverAt: 2 } }, { name: "Focused", args: { state: "focused" } },
        { name: "Two segments", args: { options: "Tokens, Runs", selected: 0 } }, { name: "Small", args: { size: "small" } }, { name: "Large", args: { size: "large" } }, { name: "Disabled with reason", args: { disabled: true } },
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
        sizes: "One height: 24 pt, the small control size, so a filter bar of chips lines up with small buttons and fields.",
        motion: "Hover and selection ease their tint in 0.16 s; pressed shrinks the chip to 95 %.",
        tokens: ["--tint-*", "--surface-content", "--accent-tint", "--control-sm", "--radius-capsule", "--type-label"],
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
        motion: "A new count pops in with a small bounce.",
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
        motion: "Live sends a soft ring out from the dot every 1.8 s; nothing else moves.",
        tokens: ["--status-*", "--motion-standard"],
      },
      stories: Object.keys(ROLES).map((k) => ({ name: ROLES[k].word, args: { role: k, label: ROLES[k].word } })).concat([{ name: "Working, live", args: { role: "working", live: true, label: "3 working" } }]),
    },
    {
      title: "Situation line",
      args: { role: "working", glyph: "", word: "Waiting for CI", cause: "Checks are running on PR #812.", waits: "Code Review starts when they pass.", age: "6 min", size: "regular", compact: false },
      controls: [
        { name: "role", label: "Colour role", type: "role" },
        { name: "glyph", label: "Glyph", type: "select", options: [{ value: "", label: "The role's own" }, "clock", "build", "lock", "pause", "refresh", "cancelled"] },
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
        states: [["Waiting for CI", "working, waits on checks"], ["Waiting on you", "you, waits on an answer"], ["Writing the code", "working"], ["Needs attention", "problem, names its fix"], ["Paused", "idle, names what lifts it"], ["Forced", "forced"], ["Shipped", "done"], ["Waiting for a slot", "idle, clock"], ["Waiting for a build", "working, box"], ["Blocked by a ticket", "idle, lock, names the ticket"], ["Retrying", "problem, names the try and when"], ["Cancelled", "idle, slashed circle"], ["Large", "page header size: the word and its age in one status pill"], ["Compact", "the wait left out, for rows"]],
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
        { name: "Waiting for a slot", args: { role: "idle", glyph: "clock", word: "Waiting for a slot", cause: "Three runs are ahead of it; Symphony runs four at a time.", waits: "Starts when a slot frees.", age: "12 min" } },
        { name: "Waiting for a build", args: { role: "working", glyph: "build", word: "Waiting for a build", cause: "The app for this commit is being built for QA.", waits: "QA starts when the build is ready.", age: "4 min" } },
        { name: "Blocked by a ticket", args: { role: "idle", glyph: "lock", word: "Blocked by TP-1251", cause: "It is in Code Review.", waits: "Starts when TP-1251 lands.", age: "17 h" } },
        { name: "Retrying", args: { role: "problem", glyph: "refresh", word: "Retrying", cause: "The run stopped: the agent hit its usage limit.", waits: "Try 2 of 3 starts at 16:20.", age: "3 min" } },
        { name: "Cancelled", args: { role: "idle", glyph: "cancelled", word: "Cancelled", cause: "You cancelled it; PR #812 was closed.", waits: "", age: "2 days" } },
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
        motion: "The fill grows to a new value on a spring (0.45 s) and glows faintly in its colour. Change Used in the controls to see it.",
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
      args: { label: "Time by stage", code: 42, review: 18, qa: 25, merge: 6, waiting: 70, unit: "min", cap: 0 },
      controls: [
        { name: "label", label: "Label", type: "text" },
        { name: "code", label: "Coding", type: "number", min: 0 },
        { name: "review", label: "Code Review", type: "number", min: 0 },
        { name: "qa", label: "QA", type: "number", min: 0 },
        { name: "merge", label: "Merging", type: "number", min: 0 },
        { name: "waiting", label: "Waiting on you", type: "number", min: 0, when: (p) => p.waiting !== undefined },
        { name: "unit", label: "Unit", type: "select", options: ["min", "M tokens"] },
        { name: "cap", label: "Cap (0 for none)", type: "number", min: 0, step: 0.5 },
      ],
      render: (p) => stageBar(p),
      docs: {
        what: "Where a ticket's time or tokens went, stage by stage, as one bar split into segments with a legend that carries the numbers.",
        when: ["Segments keep their landing order left to right. The legend is always there, so colour is never the only way to read it.", "With a cap, the bar is the whole allowance: the stages fill it from the left, the rest stays empty, and a note says how much is left. Use it for a ticket's tokens, so one bar replaces a meter and a stage split."],
        avoid: "Status colours in the segments (they are stages, not states) other than the gray for waiting.",
        states: [["Typical", "every stage present"], ["One stage dominant", "a stuck review"], ["Empty", "a track with “Nothing yet”"]],
        motion: "Segments resize on a spring when the numbers change; the order never moves.",
        tokens: ["chart series 1 to 4", "--status-idle", "--radius-mark"],
      },
      stories: [{ name: "Typical ticket" }, { name: "Stuck in review", args: { review: 180, qa: 0, merge: 0, waiting: 5 } }, { name: "Tokens by stage", args: { label: "Tokens by stage", code: 4.2, review: 0.8, qa: 1.1, merge: 0.1, waiting: 0, unit: "M tokens" } }, { name: "Tokens against the ticket's cap", args: { label: "Tokens", code: 5.8, review: 0.4, qa: 0, merge: 0, waiting: undefined, unit: "M tokens", cap: 8 } }, { name: "Near the cap", args: { label: "Tokens", code: 5.8, review: 0.8, qa: 0.4, merge: 0, waiting: undefined, unit: "M tokens", cap: 8 } }, { name: "Empty", args: { code: 0, review: 0, qa: 0, merge: 0, waiting: 0 } }],
    },
    {
      title: "Text field",
      args: { label: "Reason", value: "", placeholder: "Deploy freeze", help: "Shown to everyone who sees the pause.", error: "", size: "medium", state: "default", disabled: false, reason: "The reason is set by the rule that paused it." },
      controls: [
        { name: "label", label: "Label", type: "text" }, { name: "value", label: "Value", type: "text" }, { name: "placeholder", label: "Placeholder", type: "text" }, SIZE,
        { name: "help", label: "Help", type: "text" }, { name: "error", label: "Error", type: "text" }, STATE_NO_PRESS, DISABLED, REASON,
      ],
      render: (p) => '<div class="field' + sizeClass(p.size) + '"><label for="tf">' + esc(p.label) + '</label><div class="input' + (p.error ? " invalid" : "") + (p.disabled ? " disabled" : stateClass(p.state)) + '">' +
        '<input id="tf" value="' + esc(p.value) + '" placeholder="' + esc(p.placeholder) + '"' + (p.disabled ? " disabled" : "") + "></div>" +
        (p.disabled ? refusal(p.reason) : p.error ? '<span class="error">' + esc(p.error) + "</span>" : p.help ? '<span class="help">' + esc(p.help) + "</span>" : "") + "</div>",
      docs: {
        what: "One line of text the Director types: a reason, a name, a number.",
        when: ["The label sits above; help or the error sits under it, never both. The error says what to change."],
        states: [["Empty", "placeholder in tertiary"], ["Filled", "value in primary"], ["Hover", "stronger edge"], ["Focused", "accent edge and a soft accent halo"], ["Error", "red edge and the message"], ["Disabled with reason", "raised, reason underneath"]],
        sizes: "Small, medium (default) and large, the same heights as buttons, so a field and its button line up.",
        motion: "The halo eases in on focus (0.16 s). An error shakes the field once and the message rises in; with Reduce Motion it only appears.",
        tokens: ["--surface-content", "--stroke-strong", "--accent", "--accent-tint-strong", "--status-problem", "--radius-control-md"],
      },
      stories: [
        { name: "Empty" }, { name: "Filled", args: { value: "Deploy freeze" } }, { name: "Hover", args: { state: "hover" } }, { name: "Focused", args: { state: "focused", value: "Deploy fr" } },
        { name: "Error", args: { value: "", error: "Give a reason so the pause explains itself.", state: "focused" } }, { name: "Disabled with reason", args: { disabled: true, value: "Claude usage limit" } },
      ],
    },
    {
      title: "Search field",
      args: { query: "", placeholder: "Search tickets", size: "medium", state: "default", results: 12 },
      controls: [{ name: "query", label: "Query", type: "text" }, { name: "placeholder", label: "Placeholder", type: "text" }, { name: "results", label: "Results", type: "number", min: 0 }, SIZE, STATE_NO_PRESS],
      render: (p) => '<div class="field' + sizeClass(p.size) + '" style="width:280px"><div class="input search' + stateClass(p.state) + '">' + icon("search") +
        '<input type="search" aria-label="' + esc(p.placeholder) + '" value="' + esc(p.query) + '" placeholder="' + esc(p.placeholder) + '">' +
        (p.query ? '<span class="result-count">' + (Number(p.results) ? esc(p.results) + " found" : "None") + '</span><button type="button" class="clear" aria-label="Clear the search" data-set="query=" data-key="clr">' + icon("close") + "</button>" : kbd("⌘ F")) + "</div>" +
        (p.query && !Number(p.results) ? '<span class="help">Nothing matches “' + esc(p.query) + "”. Search looks at identifiers and titles.</span>" : "") + "</div>",
      docs: {
        what: "Filters the current list as the Director types. Its shortcut is ⌘F.",
        when: ["The count of matches shows inside the field; the clear button appears once there is a query."],
        states: [["Empty", "a sunken capsule: glyph, placeholder, shortcut"], ["Hover", "stronger edge"], ["Focused", "lifts to the content colour with the accent halo"], ["With a query", "count and clear"], ["No results", "a line that says what it searched"]],
        sizes: "Small, medium (default) and large.",
        motion: "The clear button pops in with a small bounce once there is a query.",
        tokens: ["--surface-sunken", "--accent-tint-strong", "--text-tertiary", "--radius-capsule"],
      },
      stories: [{ name: "Empty" }, { name: "Hover", args: { state: "hover" } }, { name: "Focused", args: { state: "focused" } }, { name: "With a query", args: { query: "catalog", results: 3 } }, { name: "No results", args: { query: "storybook", results: 0 } }],
    },
    {
      title: "Pop-up",
      args: { label: "Repo", value: "All repos", options: "All repos, symphony, web-shop", size: "medium", open: false, state: "default", disabled: false, reason: "Only one repo is set up." },
      controls: [{ name: "label", label: "Label", type: "text" }, { name: "value", label: "Value", type: "text" }, { name: "options", label: "Choices", type: "text" }, SIZE, { name: "open", label: "Open", type: "toggle" }, STATE, DISABLED, REASON],
      render: (p) => {
        const opts = String(p.options).split(",").map((s) => s.trim()).filter(Boolean);
        const menu = p.open && !p.disabled ? '<ul class="menu" role="listbox">' + opts.map((o) => '<li class="menu-item" role="option" aria-checked="' + (o === p.value) + '" data-set="value=' + esc(o) + '">' + icon("check", "check") + esc(o) + "</li>").join("") + "</ul>" : "";
        const b = '<button type="button" class="popup' + sizeClass(p.size) + (p.disabled ? "" : stateClass(p.state)) + '" aria-haspopup="listbox" aria-expanded="' + (!!p.open && !p.disabled) + '"' + (p.disabled ? ' aria-disabled="true"' + attr("title", p.reason) : ' data-toggle="open" data-key="pu"') + ">" +
          '<span class="popup-label"><span>' + esc(p.label) + "</span><span>" + esc(p.value) + "</span></span>" + icon("updown", "chev") + "</button>";
        return '<div style="min-height:' + (p.open ? 40 + opts.length * 26 : 40) + 'px"><span class="menu-wrap">' + b + menu + "</span>" + (p.disabled ? '<div style="margin-top:4px">' + refusal(p.reason) + "</div>" : "") + "</div>";
      },
      docs: {
        what: "One choice out of a list too long for a segmented control: a repo, an epic, a unit.",
        when: ["The label names what is chosen and the value shows the choice; the open list ticks the current one."],
        states: [["Default", "label and value"], ["Hover", "lighter, the shadow grows"], ["Pressed", "scales to 97 %"], ["Open", "accent edge and the list with a tick"], ["Focused", "focus ring"], ["Disabled with reason", "reason underneath"]],
        sizes: "Small, medium (default) and large, the same heights as buttons.",
        motion: "The list rises and fades in on a spring; picking a value closes it and the new value is there at once.",
        tokens: ["--material-glass-thick", "--elevation-3", "--radius-control-md", "--accent"],
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
        motion: "The knob travels on a lively spring (0.5 s, about 8 % overshoot) and the track's colour eases with it; while pressed the knob stretches toward where it will go.",
        tokens: ["--accent-fill", "--surface-sunken", "--motion-spring", "--ease-bounce", "--radius-capsule"],
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
        motion: "After 0.5 s of hover it fades in and slides 4 pt toward its anchor; it leaves at once.",
        tokens: ["--material-glass-thick", "--elevation-2", "--motion-hover-delay", "--type-secondary"],
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
        motion: "Hover eases in 0.16 s; selection fills with the iris in the same time; pressed sinks the row a hair. Click the row on the canvas to select it.",
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
        motion: "Rows and header cells ease their background in 0.16 s; a new sort arrow pops in.",
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
        motion: "A clickable card lifts 1 pt on hover with a deeper shadow, on a spring, and settles back when pressed.",
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
        (p.empty ? "" : fold("card", p.expanded, '<div class="fold-body"><div class="list">' + TICKETS.slice(3, 6).map((t, i) => '<div style="--i:' + i + '">' + row(t) + "</div>").join("") + "</div></div>")) + "</section></div>",
      docs: {
        what: "A card whose body folds away, for history and detail the Director opens on demand.",
        when: ["Folded, the header still says what is inside (a count, a duration). The fold is remembered per card."],
        states: [["Open", "chevron down"], ["Folded", "chevron right and the summary"], ["Header hover", "hover overlay"], ["Header focused", "focus ring"], ["Empty", "no chevron, “None yet”"]],
        motion: "Opening grows the body to its height (0.28 s, standard easing) while its rows fade down into place one after another, 35 ms apart; the chevron turns on a spring. Folding plays it backwards, all at once. Click the header on the canvas.",
        tokens: ["--radius-card", "--surface-hover", "--motion-standard", "--motion-stagger", "--ease-spring"],
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
        return '<div style="width:360px"><div class="kv-group"><h4>Ticket</h4>' + kv(a, p.layout === "stacked") + '</div><div class="kv-group"><h4>Work</h4>' + kv(b, p.layout === "stacked") + "</div></div>";
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
      args: { kind: "phase", time: "09:02", strong: "Moved to Code Review", rest: "from In Progress", detail: "The push opened PR #812", actor: "Symphony", state: "default", selected: false, unseen: false, since: false },
      controls: [
        { name: "kind", label: "Class", type: "select", options: TL_OPTIONS },
        { name: "time", label: "Time", type: "text" }, { name: "strong", label: "What", type: "text" }, { name: "rest", label: "More", type: "text" },
        { name: "detail", label: "Detail", type: "text" }, { name: "actor", label: "Who", type: "text" }, STATE_NO_PRESS,
        { name: "selected", label: "Selected", type: "toggle" }, { name: "unseen", label: "New since you looked", type: "toggle" }, { name: "since", label: "Where you last looked", type: "toggle" },
      ],
      render: (p) => '<ol class="timeline" style="width:560px">' + (p.since ? '<li class="tl-since">Since you last looked, at 16:20</li>' : "") + tlEntry(Object.assign({}, p, { headHtml: head(p.strong, p.rest), selectable: true, toggle: "selected" })) + "</ol>",
      docs: {
        what: "One thing that happened to a ticket, at a time, with a glyph and colour per class so a day reads at a glance.",
        when: ["Phase move: arrow, accent. Pause set: pause, gray. Pause cleared: play, blue. Question asked: speech bubble, orange. Question answered: bubble with a tick, green. Run started: play circle, blue. Run ended: its verdict (passed green, failed red, stopped gray). Person action: hand, accent. Rule action: gear, gray.", "The first words in bold say what happened; detail and who did it follow in secondary."],
        states: [["Each class", "glyph and colour above"], ["Hover", "hover overlay"], ["Selected", "accent tint and ring; the page shows its detail"], ["New since you looked", "an accent dot before its words, under the line that marks where you last looked"], ["Entering", "a new entry drops in at the top on a spring and its tint fades"]],
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
        { name: "Selected", args: { selected: true } },
        { name: "New since you looked", args: { unseen: true, since: true } },
      ],
    },
    {
      title: "Run group",
      args: { title: "Implementation run 2", verdict: "passed", time: "10:05", duration: "22 min", tokens: "1.8M tokens", withSteps: true, expanded: false, state: "default" },
      controls: [
        { name: "title", label: "Title", type: "text" }, { name: "verdict", label: "Verdict", type: "select", options: ["passed", "failed", "running", "stopped"] },
        { name: "time", label: "Started", type: "text" }, { name: "duration", label: "Duration", type: "text" }, { name: "tokens", label: "Tokens", type: "text" },
        { name: "withSteps", label: "Shows its steps", type: "toggle" }, { name: "expanded", label: "Unfolded", type: "toggle" }, STATE,
      ],
      render: (p) => '<div style="width:720px">' + runGroup(Object.assign({}, p, { steps: p.withSteps ? { code: "passed", build: "passed", checks: p.verdict === "failed" ? "failed" : "passed", tests: p.verdict === "failed" ? "pending" : p.verdict === "running" ? "current" : "passed", handoff: p.verdict === "passed" ? "passed" : p.verdict === "stopped" ? "paused" : "pending" } : null, entries: [
        { kind: "run-started", time: p.time, headHtml: head("Started"), detail: "Claude" },
        { kind: "phase", time: "10:12", headHtml: head("Build passed") },
        { kind: p.verdict === "failed" ? "run-failed" : "run-passed", time: "10:20", headHtml: head(p.verdict === "failed" ? "Tests failed" : "Tests passed"), detail: p.verdict === "failed" ? "2 failures in the orchestrator" : "" },
        { kind: "rule", time: "10:27", headHtml: head("Pushed", "and handed off to Code Review") },
      ] })) + "</div>",
      docs: {
        what: "One run of an agent on the timeline, folded to a single line with its verdict, its steps as short bars and the step it is on or stopped at, and its duration. Unfolded, the full step strip sits above the run's entries, newest first.",
        when: ["Folded by default once it ended; the running one is unfolded and live."],
        states: [["Folded", "one line, the steps as five short bars"], ["Unfolded", "the step strip, then its entries indented under a rule"], ["Running", "a live dot, no end time"], ["Failed", "red verdict"], ["Header hover, pressed, focused", "as a row"]],
        motion: "Hover eases in; the connecting line runs from each mark to the next.",
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
      args: { kind: "run", code: "passed", build: "passed", checks: "passed", tests: "current", handoff: "pending", testsNote: "", coding: "current", review: "returned", qa: "skipped", merging: "pending", done: "pending" },
      controls: [{ name: "kind", label: "Strip", type: "select", options: [{ value: "run", label: "A run's steps" }, { value: "ticket", label: "The ticket's stages" }] }]
        .concat(STEP_NAMES.map((s) => ({ name: s[0], label: s[1], type: "select", options: STEP_OPTIONS, when: (p) => p.kind !== "ticket" })))
        .concat(STAGE_NAMES.map((s) => ({ name: s[0], label: s[1], type: "select", options: STEP_OPTIONS, when: (p) => p.kind === "ticket" }))),
      render: (p) => steps(p),
      docs: {
        what: "Steps left to right, so where something stands or where it stopped reads at once. Two strips use it: a run's five steps, and the ticket's five stages in its lifecycle.",
        when: ["A run: Writing the code, Build, Checks, Tests, Handoff, always in that order; on the timeline it folds into the run's line as five short bars.", "The ticket: Coding, Code Review, QA, Merging, Done, always in that order; each stage's note carries its time.", "Each step says its state in words under its name."],
        states: [["Passed", "green bar"], ["Failed", "red tint and word"], ["Sent back", "orange bar: a review returned the ticket"], ["Paused", "gray bar"], ["Skipped", "dashed bar"], ["Current", "blue tint, partial bar"], ["Not started", "empty bar"]],
        motion: "The current step\u2019s bar flows while it works; a step that passes fills its bar on a spring.",
        tokens: ["--status-done", "--status-problem", "--status-working", "--status-idle", "--radius-row"],
        access: "A list: “Steps of the run. Writing the code, passed. Build, passed…”.",
      },
      stories: [
        { name: "Current: tests" }, { name: "All passed", args: { tests: "passed", handoff: "passed" } }, { name: "Failed at checks", args: { checks: "failed", tests: "pending", handoff: "pending" } },
        { name: "Paused at build", args: { build: "paused", checks: "pending", tests: "pending", handoff: "pending" } }, { name: "Tests skipped", args: { tests: "skipped", handoff: "passed" } },
        { name: "Not started", args: { code: "current", build: "pending", checks: "pending", tests: "pending" } },
        { name: "Ticket stages: in Coding, sent back once", args: { kind: "ticket", codingNote: "1 h 4 min", reviewNote: "8 min" } },
        { name: "Ticket stages: merging", args: { kind: "ticket", coding: "passed", review: "passed", qa: "passed", merging: "current", done: "pending" } },
      ],
    },
    {
      title: "Phase path",
      args: { at: "rework", compact: false, interactive: true, state: "default" },
      controls: [
        { name: "at", label: "Where the ticket is", type: "select", options: [{ value: "progress", label: "In Progress, first time" }, { value: "rework", label: "Rework, sent back twice" }, { value: "done", label: "Done" }] },
        { name: "compact", label: "Compact (no times)", type: "toggle" }, { name: "interactive", label: "Filters the timeline", type: "toggle" },
        { name: "state", label: "Shown state", type: "select", options: [{ value: "default", label: "Live (use the pointer)" }, { value: "hover", label: "Hover on the second" }] },
      ],
      render: (p) => {
        const all = [["Todo", 1, "17 h 43 min"], ["In Progress", 1, "38 min"], ["CI Fix", 1, "10 min"], ["Code Review", 3, "29 min"], ["Rework", 2, "1 h 2 min"], ["QA", 2, "36 min"], ["Merging", 1, "2 h"], ["Done", 1, ""]];
        const upto = { progress: 1, rework: 4, done: 7 }[p.at];
        const phases = all.map((x, i) => ({ name: x[0], visits: i <= upto ? (p.at === "progress" ? 1 : x[1]) : 0, time: i < upto ? x[2] : i === upto ? (p.at === "done" ? "" : "12 min so far") : "", state: i < upto ? "passed" : i === upto ? "current" : "later", role: p.at === "done" ? "done" : p.at === "rework" ? "you" : "working" }))
          .filter((x, i) => p.at !== "progress" || i <= 1 || i >= 3);
        return '<div style="display:grid;gap:8px;max-width:980px">' + phasePath({ phases: phases, compact: p.compact, interactive: p.interactive, hoverAt: p.state === "hover" ? 1 : -1 }) +
          '<span class="phase-path-sum">' + (p.at === "done" ? "14 moves in 23 h 22 min" : p.at === "rework" ? "9 moves so far · sent back twice" : "1 move so far") + "</span></div>";
      },
      docs: {
        what: "Where a ticket has been: its phases in the order it first entered each, with how many times it entered and how long it spent there in all. The phase it is in now carries its status colour; phases still ahead are outlined and faint.",
        when: ["Under the situation line on the ticket page, so “sent back twice” reads without counting timeline entries.", "Each phase that filters the timeline is a button: pressing it shows only that phase's moves and runs."],
        avoid: "Listing every move here (that is the timeline), or a phase the ticket's workflow never enters.",
        states: [["Passed", "raised surface"], ["Current", "status tint and ring"], ["Later", "outline, faint name"], ["Entered more than once", "×n in the waiting colour"], ["Hover, pressed, picked", "as a chip"], ["Compact", "names and counts only"]],
        motion: "Hover eases in; a press settles to 97 %; a new phase enters at the end with the enter pattern.",
        tokens: ["--surface-raised", "--role-tint", "--status-you-text", "--radius-row", "--type-caption"],
        access: "An ordered list: “Code Review, entered 3 times, 29 minutes in all”.",
      },
      stories: [{ name: "Sent back twice" }, { name: "First time in progress", args: { at: "progress" } }, { name: "Done", args: { at: "done" } }, { name: "Compact", args: { compact: true } }, { name: "Hover", args: { state: "hover" } }],
    },
    {
      title: "Step list",
      args: { live: true, openStep: 3, failed: false, state: "default" },
      controls: [
        { name: "live", label: "Running now", type: "toggle" }, { name: "failed", label: "Tests failed", type: "toggle", when: (p) => !p.live },
        { name: "openStep", label: "Unfolded step", type: "select", options: [{ value: -1, label: "None" }, { value: 0, label: "Writing the code" }, { value: 1, label: "Build" }, { value: 2, label: "Checks" }, { value: 3, label: "Tests" }] },
        { name: "state", label: "Shown state", type: "select", options: [{ value: "default", label: "Live (use the pointer)" }, { value: "hover", label: "Hover on the first" }] },
      ],
      render: (p) => {
        const o = Number(p.openStep);
        const tests = p.live ? "current" : p.failed ? "failed" : "passed";
        const testMsgs = [{ time: "16:44", kind: "tool", text: "swift test --filter TicketPageTests" }, { time: "16:46", kind: "result", text: p.failed && !p.live ? "2 failures: pausedLineFallsBackToPaused, pausedLineOrdersReasons" : "131 tests passed", failed: p.failed && !p.live }]
          .concat(p.live ? [{ time: "16:47", kind: "say", text: "The fallback works. Now recording the two snapshots it changes.", fresh: true, typing: true }] : []);
        const steps = [
          { name: "Writing the code", state: "passed", duration: "4 min", msgs: [{ time: "16:39", kind: "say", text: "Code Review found a reason without words shows its raw code. I'll fall back to “Paused”." }, { time: "16:40", kind: "tool", text: "edit TicketPage.swift" }] },
          { name: "Build", state: "passed", duration: "2 min", msgs: [{ time: "16:43", kind: "tool", text: "swift build" }, { time: "16:44", kind: "result", text: "Build complete" }] },
          { name: "Checks", state: "passed", duration: "1 min", msgs: [{ time: "16:44", kind: "result", text: "format and lint clean" }] },
          { name: "Tests", state: tests, duration: p.live ? "3 min so far" : "3 min", msgs: testMsgs },
          { name: "Handoff", state: p.live || p.failed ? "pending" : "passed", duration: "", msgs: p.live || p.failed ? [] : [{ time: "16:58", kind: "tool", text: "git push" }] },
        ].map((st, i) => Object.assign(st, { open: i === o }));
        return '<div style="width:640px">' + stepList({ steps: steps, setProp: "openStep", hoverAt: p.state === "hover" ? 0 : -1 }) + "</div>";
      },
      docs: {
        what: "A run's steps, top to bottom, each unfolding into what the agent did in it: what it said, each tool it called and what came back. It is the run's transcript, in place on the page, so “what is it doing now” never needs another window.",
        when: ["Inside an unfolded run on the timeline, or as the body of the run-now panel.", "The step it is on now is unfolded and live: new lines enter at the bottom; the newest line of the agent's own words shows a caret while it writes.", "A step with nothing in it yet cannot unfold, and says so on hover."],
        avoid: "Raw logs: a tool's long output is cut to its last line here, the whole of it opens from the line.",
        states: [["Passed, failed, now, stopped, asked you, skipped, not started", "glyph, colour and word"], ["Unfolded", "its lines under a rule"], ["Live line", "enters with the enter pattern and a brief tint"], ["Hover, pressed", "as a row"]],
        motion: "The fold opens on the shared fold; lines stagger in by 35 ms; with Reduce Motion they appear at once and nothing flashes.",
        tokens: ["--status-*", "--tint-*", "--type-mono", "--radius-row", "--motion-stagger"],
        access: "A disclosure per step: “Tests, now, 3 minutes so far, expanded”; each line reads its time, its kind and its text.",
      },
      stories: [{ name: "Live, on the tests step" }, { name: "Ended, all passed", args: { live: false, openStep: -1 } }, { name: "Ended, tests failed", args: { live: false, failed: true, openStep: 3 } }, { name: "All folded", args: { openStep: -1 } }, { name: "Hover", args: { state: "hover", openStep: -1 } }],
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
        motion: "Hover lifts the card 1 pt and rings the radio in the accent; picking it snaps the radio\u2019s dot in with a bounce and draws the accent edge.",
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
        motion: "Picking it unfolds the field below on a spring.",
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
        motion: "Hover deepens the frame and zooms the picture 6 % on a spring; pressed shrinks it to 97 %. Loading shimmers.",
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
      render: (p) => '<div class="empty' + (p.good ? " good" : "") + '"><span class="glyph-wrap">' + icon(p.good && p.glyph === "tray" ? "done" : p.glyph) + "</span><h3>" + esc(p.title) + "</h3><p>" + esc(p.message) + "</p>" + (p.action ? button({ label: p.action, variant: "secondary", size: "large" }) : "") + "</div>",
      docs: {
        what: "What a view shows when it has nothing: a glyph, a sentence that says what that means, at most one action.",
        when: ["An empty Inbox is good news and says so.", "No results says what was searched and how to widen it.", "Symphony stopped is one placeholder per view, with Start Symphony."],
        avoid: "An empty state for a section with nothing to say on a busy page: hide the section instead.",
        states: [["Good news", "green tick"], ["No results", "with Clear Filters"], ["Stopped", "with Start Symphony"]],
        motion: "It rises and fades in once when it appears (0.45 s spring).",
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
        motion: "It rises 16 pt from the bottom edge on a spring and fades in; the countdown line drains in real time.",
        tokens: ["--material-glass-thick", "--material-blur", "--elevation-3", "--status-*", "--ease-spring"],
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
      render: (p) => '<div class="sheet-scrim"><div class="sheet" role="dialog" aria-label="' + esc(p.title) + '"><header class="sheet-head"><h2>' + esc(p.title) + "</h2>" + (p.sub ? '<p class="sub">' + esc(p.sub) + "</p>" : "") +
        (p.close ? '<button type="button" class="icon-btn" aria-label="Close" title="Close (Esc)">' + icon("close") + "</button>" : "") + "</header>" +
        (p.body ? '<div class="sheet-body"><p><b>What happens:</b> the run ends now and TP-1382 stays in In Progress, paused.</p><p class="muted"><b>What stays the same:</b> the pull request, the branch and every comment.</p></div><footer class="sheet-foot">' +
          button({ label: "Cancel", variant: "secondary" }) + button({ label: p.destructive ? "Stop Run" : "Continue", variant: p.destructive ? "destructive-filled" : "primary" }) + "</footer>" : "") + "</div></div>",
      docs: {
        what: "The top of every consequence sheet: the move asked as a question, then one line on what it does.",
        when: ["The title is the question (“Stop the run on TP-1382?”), the explanation says what happens and what doesn't. The footer names the action with its verb."],
        states: [["Question only", "title"], ["With explanation", "title and line"], ["Destructive", "the action in the destructive style"], ["Without close", "when Cancel is the only way out"]],
        motion: "The sheet drops 10 pt and grows from 96 % on a spring as it opens over a dimmed window.",
        tokens: ["--material-glass-thick", "--elevation-4", "--radius-sheet", "--type-sentence", "--space-6", "--ease-spring"],
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
        motion: "It rises in with the control it explains, never after it.",
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
    if (p.role === "you") { if (!p.cta) moves.push(button({ label: "Answer in the Inbox", variant: "primary", glyph: "tray" })); }
    else moves.push(button({ label: "Approve and Merge…", variant: "primary", disabled: !!p.blocked, reason: "Checks are still running on PR #812." }));
    moves.push(button({ label: "Open Pull Request", variant: "secondary", glyph: "pr" }));
    moves.push(button({ label: "Force", variant: "secondary", glyph: "forced" }));
    /* Desktop shows the destructive move in the rail; laptop keeps it in More, last */
    moves.push('<span class="only-wide rail-sep" aria-hidden="true"></span>');
    moves.push('<span class="only-wide">' + button({ label: "Stop Run…", variant: "destructive", disabled: !!p.noRun, reason: "No run is working." }) + "</span>");
    const items = [["Move to…", ""], ["Restart…", ""], ["sep"], ["Copy Link", "⌘ L"], ["Copy Workspace Path", ""], ["Open in Linear", ""], ["sep"], ["Stop Run…", "", "destructive only-narrow"]];
    const menu = p.more ? '<ul class="menu" role="menu">' + items.map((it) => it[0] === "sep" ? '<li class="menu-sep" role="separator"></li>' :
      '<li class="menu-item' + (it[2] ? " " + it[2] : "") + '" role="menuitem" tabindex="-1"' + (it[0] === "Stop Run…" && p.noRun ? ' aria-disabled="true"' : "") + ">" + esc(it[0]) + (it[1] ? kbd(it[1], true) : "") + "</li>").join("") + "</ul>" : "";
    moves.push('<span class="menu-wrap"><button type="button" class="menu-btn" aria-haspopup="menu" aria-expanded="' + !!p.more + '" data-toggle="more" data-key="rail-more">More' + icon("chevron-down", "chev") + "</button>" + menu + "</span>");
    return '<div class="action-rail" role="toolbar" aria-label="Moves">' + moves.join("") + "</div>";
  }

  function pageHeader(p) {
    const s = p.role === "you" ? { role: "you", word: "Waiting on you", cause: "A question: review the design catalog.", waits: "Answer it in the Inbox.", age: "3 h 12 min" } :
      { role: "working", word: "Waiting for CI", cause: "Checks are running on PR #812.", waits: "Code Review starts when they pass.", age: "6 min" };
    return '<header class="page-header"><div class="head-main"><div class="ident-line"><span class="ident">' + esc(p.ident) + "</span>" + chip({ kind: "repo", text: "symphony", interactive: false }) + chip({ kind: "epic", text: "Phase 3b", interactive: false }) +
      ('<span class="ident-sep" aria-hidden="true"></span><span class="prio" title="Priority">' + icon("forced") + "Urgent</span>" + chip({ kind: "label", text: "design", role: "working", interactive: false }) + chip({ kind: "label", text: "mac", role: "idle", interactive: false })) + "</div>" +
      "<h1>" + esc(p.title) + "</h1>" + '<div class="head-status">' + situation(Object.assign({ size: "large" }, s)) +
      "</div></div>" + actionRail(p) + "</header>";
  }

  /* The ticket's lifecycle, its pull request and its connections, each a titled panel: the title sits
     outside the card, so every column of the page starts on the same line. Each fact appears once:
     time and tokens in the lifecycle, checks in the pull request, a run's steps on its timeline line. */
  const RUNS = [
    { name: "Implementation run 1", verdict: "failed", word: "Checks failed", min: 22, tokens: 1.4 },
    { name: "Code Review", verdict: "passed", word: "Passed", min: 8, tokens: 0.4 },
    { name: "Implementation run 2", verdict: "current", word: "Running", min: 42, tokens: 4.4 },
  ];
  const fmtMin = (m) => (m >= 60 ? Math.floor(m / 60) + " h " + (m % 60 ? (m % 60) + " min" : "") : m + " min").trim();

  function lifecyclePanel(p) {
    const runs = p.noRun ? [] : RUNS;
    const min = runs.reduce((a, r) => a + r.min, 0);
    const stage = p.noRun ? { coding: "current", review: "pending", qa: "skipped", merging: "pending", done: "pending", codingNote: "no run yet", qaNote: "not needed here" } :
      { coding: "current", review: "returned", qa: "skipped", merging: "pending", done: "pending", codingNote: "1 h 4 min", reviewNote: "8 min", qaNote: "not needed here" };
    const tokens = p.noRun ? { label: "Tokens", code: 0, review: 0, qa: 0, merge: 0, cap: 8, unit: "M tokens" } : { label: "Tokens", code: 5.8, review: 0.4, qa: 0, merge: 0, cap: 8, unit: "M tokens" };
    const where = p.noRun ? "In Coding: waiting for a free slot" : "In Coding, the second time: Code Review sent it back once";
    return '<section class="panel lifecycle-panel" aria-label="Lifecycle"><div class="life-head"><span class="dot role-working' + (p.noRun ? "" : " live") + '"></span><span class="life-where">' + esc(where) + "</span>" +
      '<span class="life-sum">' + esc(runs.length ? fmtMin(min) + " of work in " + runs.length + " runs" : "No run yet") + "</span></div>" +
      steps(Object.assign({ kind: "ticket" }, stage)) + stageBar(Object.assign({ key: "life" }, tokens)) + "</section>";
  }

  /* A pull request's checks, by workflow, every job with its state: passed, failed, running, waiting, skipped. */
  const CHECK_STATES = {
    passed: { word: "Passed", role: "done", glyph: "done" },
    failed: { word: "Failed", role: "problem", glyph: "problem" },
    running: { word: "Running", role: "working", glyph: "" },
    waiting: { word: "Waiting", role: "idle", glyph: "clock" },
    skipped: { word: "Skipped", role: "idle", glyph: "chevron-right" },
  };
  function checkRuns(ci) {
    const pick = (passed, running, failed) => (ci === "failed" ? failed : ci === "running" ? running : passed);
    return [
      { name: "Elixir checks", jobs: [
        ["Format", "passed", "42 s"], ["Lint", "passed", "1 min 4 s"], ["Build", "passed", "1 min 12 s"], ["Dialyzer", "passed", "1 min 40 s"],
        ["Tests, part 1 of 4", pick("passed", "running", "failed"), pick("2 min 12 s", "1 min 50 s", "2 min 12 s")],
        ["Tests, part 2 of 4", pick("passed", "running", "passed"), pick("2 min 4 s", "1 min 50 s", "2 min 4 s")],
        ["Tests, parts 3 and 4", pick("passed", "passed", "passed"), "1 min 58 s"],
        ["Coverage report", pick("passed", "waiting", "skipped"), pick("18 s", "", "")],
      ] },
      { name: "Mac app", jobs: [["What changed", "passed", "8 s"], ["App build", "skipped", ""]] },
    ];
  }

  function checksBlock(ci) {
    const groups = checkRuns(ci);
    const all = groups.reduce((a, g) => a.concat(g.jobs), []);
    const n = (st) => all.filter((j) => j[1] === st).length;
    const sum = [n("failed") ? n("failed") + " failed" : "", n("running") ? n("running") + " running" : "", n("passed") + " passed", n("waiting") ? n("waiting") + " waiting" : "", n("skipped") ? n("skipped") + " skipped" : ""].filter(Boolean).join(" · ");
    return '<div class="panel-sub"><h4>Checks<span class="t-secondary">' + esc(sum) + "</span></h4>" + groups.map((g) =>
      '<div class="check-group"><h5>' + esc(g.name) + "</h5><ol class=\"check-list\">" + g.jobs.map((j) => {
        const st = CHECK_STATES[j[1]];
        const mark = j[1] === "running" ? '<span class="dot live role-working"></span>' : icon(st.glyph);
        return '<li><button type="button" class="check-row ' + esc(j[1]) + " role-" + st.role + '" aria-label="' + esc(j[0] + ", " + st.word.toLowerCase() + (j[2] ? ", " + j[2] : "")) + '"><span class="mark">' + mark + '</span><span class="check-name">' + esc(j[0]) + "</span>" +
          '<span class="check-state">' + esc(st.word) + '</span><span class="num">' + esc(j[2] || "") + "</span></button></li>";
      }).join("") + "</ol></div>").join("") + "</div>";
  }

  function prPanel(p) {
    const ci = p.ci || "running";
    const badgeFor = { passed: ["done", "Checks passing"], running: ["working", "Checks running"], failed: ["problem", "1 check failed"] }[ci];
    const body = p.noPr ? '<p class="empty-line">No pull request yet: the first run opens one, and its checks appear here.</p>' :
      '<a class="pr-line" href="#" onclick="return false">' + icon("pr", "pr-glyph") + '<span class="pr-name">PR #812</span><span class="t-secondary">14 files · +412 −88</span>' + badge(badgeFor[0], badgeFor[1], "small") + "</a>" + checksBlock(ci);
    return '<section class="facts-group"><h3 class="zone-title">Pull request</h3><div class="panel pr-panel">' + body + "</div></section>";
  }

  /* One line per ticket: the highlight says which one this page is, the badge says where each stands. No second line. */
  function relRow(t, self) {
    const tag = self ? "div" : "button";
    return "<li><" + tag + (self ? "" : ' type="button"') + ' class="rel-row' + (self ? " is-self" : "") + '"' + (self ? ' aria-current="true"' : "") + '><span class="dot role-' + esc(t.role) + '"></span><span class="rel-ident">' + esc(t.ident) + "</span>" +
      '<span class="rel-title">' + esc(t.title) + "</span>" + badge(t.role, t.word, "small") + (self ? "" : icon("chevron-right", "rel-go")) + "</" + tag + "></li>";
  }

  function connectedPanel(p) {
    const self = { ident: "TP-1382", title: "Design system catalog", role: p.role === "you" ? "you" : "working", word: p.role === "you" ? "Waiting on you" : "Code Review" };
    const next = { ident: "TP-1383", title: "Three ticket page prototypes", role: "idle", word: "Todo" };
    const later = { ident: "TP-1384", title: "Ticket page built in the app", role: "idle", word: "Backlog" };
    const blocker = { ident: "TP-1375", title: "First dispatch waits for its relations", role: "problem", word: "Checks failed" };
    /* A block is drawn only when it has something to say: no epic, nothing holding it up, nothing held up means no block, never an empty one. */
    const epic = p.noEpic ? "" :
      '<div class="panel-sub"><h4>Epic</h4><button type="button" class="epic-head"><span class="epic-ident">TP-1381</span><span class="epic-title">Phase 3b: the Director redesigned around a ticket’s situation</span>' + icon("chevron-right", "rel-go") + "</button>" +
      '<div class="epic-progress"><div class="epic-track" role="img" aria-label="0 of 3 done, 1 in progress, 2 waiting"><span class="seg role-working"></span><span class="seg role-idle"></span><span class="seg role-idle"></span></div><span class="t-secondary">0 of 3 done · this is the 1st</span></div>' +
      '<ol class="rel-list">' + relRow(self, true) + relRow(next) + relRow(later) + "</ol></div>";
    const held = p.blockedBy ? '<div class="panel-sub"><h4>Waiting on</h4><ol class="rel-list">' + relRow(blocker) + "</ol></div>" : "";
    const holds = p.holdsNothing ? "" : '<div class="panel-sub"><h4>Holding up</h4><ol class="rel-list">' + relRow(next) + "</ol></div>";
    if (!epic && !held && !holds) return "";
    return '<section class="facts-group"><h3 class="zone-title">Connected</h3><div class="panel connected-panel">' + epic + held + holds + "</div></section>";
  }


  /* The brief: what the ticket did and how to see it, in the words of the run that wrote it. It sits at
     the top of the main column at the reading measure, a few lines until the Director asks for all of it. */
  function briefBlock(p, open) {
    const asked = !!p.noBrief;
    const text = asked ?
      "<p>Every Director component and section, drawn once as HTML in every state, so a design can be reviewed in a browser before any Swift is written. The catalog has controls for theme, width and motion.</p>" :
      "<p>Every component and section of the Director now exists once, as a story per state, in an HTML catalog that opens from disk. The catalog has its own controls for theme, width and motion, so a design can be reviewed in a browser before any Swift is written.</p>" +
      "<p>The tokens moved into one file that the catalog and the prototypes share. Sixteen components gained the states they lacked (hover, pressed, focused, disabled with its reason), and the Page layout section shows the ticket page at laptop and desktop widths.</p>";
    const more = asked ? "" : '<div class="brief-part"><h4>Walkthrough</h4><p>Open <span class="t-mono">docs/design/catalog/index.html</span>. Pick Sections, Page layout: the ticket page draws at 1180 pt. Switch the theme to Dark and the width to Desktop: the page redraws in three columns. Turn on Reduce motion: nothing slides.</p></div>' +
      '<div class="brief-part"><h4>What was asked</h4><p class="soft-text">A Storybook-shaped design catalog as plain HTML: every Director component and section as stories per state, with live controls, reviewed from the workspace and approved in the Inbox.</p></div>';
    return '<section class="panel brief' + (open ? " is-open" : "") + '"><div class="brief-text">' + text + "</div>" + (open ? more : "") +
      (asked ? "" : '<button type="button" class="story-more brief-more" data-toggle="briefOpen" data-key="brief-more">' + icon(open ? "chevron-down" : "chevron-right") + (open ? "Show less" : "Read all of it, with the walkthrough") + "</button>") + "</section>";
  }
  const briefTitle = (p) => '<h3 class="zone-title">' + (p.noBrief ? 'Asked for <span class="zone-note">no run has written a brief yet</span>' : 'Brief <span class="zone-note">written by Implementation run 2 at 11:20</span>') + "</h3>";

  /* Writing to the ticket: one box above the timeline. What is sent becomes an entry of the ticket's history,
     and the next run reads it first. There is no separate note panel. */
  function composer(p) {
    const draft = !!p.noteDraft;
    return '<div class="tl-compose' + (draft ? " has-draft" : "") + '"><div class="input"><textarea rows="' + (draft ? 2 : 1) + '" aria-label="Write to the ticket" placeholder="Write to the ticket. The next run reads it first.">' + (draft ? "Use the catalog’s chip in the header, not a new one." : "") + "</textarea></div>" +
      (draft ? '<div class="tl-compose-foot">' + kbd("⌘ ↩") + button({ label: "Send", variant: "primary", size: "small" }) + "</div>" : "") + "</div>";
  }

  /* Decisions: drawn only when the Director has answered something on this ticket */
  function decisionsPanel(p) {
    if (!p.decisions) return "";
    const rows = [["Ship the catalog without the motion page", "You · 10:42"], ["Dark is the default theme of the stories", "You · yesterday, 18:05"]];
    return '<section class="facts-group"><h3 class="zone-title">Decisions</h3><div class="panel"><ol class="decision-list">' + rows.map((r) => "<li>" + icon("answered") + "<div><b>" + esc(r[0]) + '</b><span class="t-secondary">' + esc(r[1]) + "</span></div></li>").join("") + "</ol></div></section>";
  }

  function factsRail(p) {
    return '<aside class="facts-rail" aria-label="Facts">' + prPanel(p) + connectedPanel(p) + decisionsPanel(p) + "</aside>";
  }

  const QUESTIONS = [
    {
      title: "Review the design catalog", age: "3 h 12 min", prop: "selected", textProp: "text",
      why: "TP-1382 (Design system catalog) built every Director component and section as stories you can open in a browser. Open the catalog from the path below, try the controls, switch theme and viewport, then pick an answer.",
      path: "/Users/tonypine/symphony-workspaces/symphony/TP-1382/docs/design/catalog/index.html",
      unanswered: "TP-1382 stays where it is and TP-1383 (Three prototypes) waits.",
      opts: [
        { label: "Approve the catalog", effect: "TP-1382 goes to Code Review and lands; TP-1383 starts from the approved catalog.", good: "The prototypes start today.", recommended: true, why: "Every component and section is in the catalog in light and dark." },
        { label: "Ask for changes (write them below)", effect: "The next run applies your words and asks again.", cost: "One more review round." },
      ],
    },
    {
      title: "Let TP-1382 change the file that sets how agents work?", age: "40 min", prop: "selected2", textProp: "text2",
      why: "The catalog needs one line in the file that sets how agents work, so later tickets can find it. Agents may change that file only when you say so.",
      unanswered: "TP-1382 leaves the line out; the catalog still opens.",
      opts: [
        { label: "Allow this change", effect: "The next run adds the line, and PR #812 carries it.", good: "Later tickets find the catalog on their own.", recommended: true, why: "The line only names the catalog's folder." },
        { label: "Keep the file as it is", effect: "TP-1382 leaves the line out.", risk: "Each later ticket is told about the catalog by hand." },
      ],
    },
  ];

  const answerOf = (p, q) => {
    const sel = Number(p[q.prop]);
    if (sel === 3) return String(p[q.textProp] || "").trim() ? "In your own words" : "";
    return sel > 0 && q.opts[sel - 1] ? q.opts[sel - 1].label : "";
  };

  /* One Question's text and answers; the options take the full width of whatever holds them. */
  function questionBody(p, q, n) {
    const sel = Number(p[q.prop]);
    const optionsHtml = q.opts.map((o, i) => option(Object.assign({}, o, { selected: sel === i + 1, set: q.prop + "=" + (i + 1), key: q.prop + i, hotkey: n ? null : i + 1 }))).join("");
    const own = ownWords({ picked: sel === 3, text: p[q.textProp], hotkey: n ? null : 3, send: false }).replace('data-set="picked=true"', 'data-set="' + q.prop + '=3"').replace('data-set="picked=false"', 'data-set="' + q.prop + '=0"').replace('data-bind="text"', 'data-bind="' + q.textProp + '"').replace('data-key="own"', 'data-key="own-' + q.prop + '"');
    return '<div class="question-callout"><span class="kicker">' + icon("question", "glyph-sm") + (n ? "QUESTION " + n[0] + " OF " + n[1] : "YOUR DECISION") + '<span class="age">' + esc(q.age) + "</span></span><h2>" + esc(q.title) + "</h2></div>" +
      '<div class="question-why"><p>' + esc(q.why) + "</p>" +
      (q.path ? '<p class="t-mono path">' + esc(q.path) + "</p>" : "") +
      '<p class="unanswered">' + icon("cost") + "<span><b>If you don't answer:</b> " + esc(q.unanswered) + "</span></p></div>" +
      '<div class="options" role="radiogroup" aria-label="Answers">' + optionsHtml + own + "</div>";
  }

  function sendArea(answers, total) {
    const done = answers.filter(Boolean).length;
    const label = done > 1 ? "Send " + done + " Decisions…" : "Send Decision…";
    const pick = total === 1 ? (answers[0] ? '<span class="pick"><span class="t-secondary">Your answer</span><b>' + esc(answers[0]) + "</b></span>" : "") :
      '<span class="pick"><span class="t-secondary">Answered</span><b>' + done + " of " + total + "</b></span>";
    return pick + (done ? "" : refusal(total === 1 ? "Pick an answer first." : "Answer at least one question first.")) + button({ label: label, variant: "primary", size: "large", disabled: !done, showReason: false, key: "send" });
  }

  function questionBlock(p) {
    const q = QUESTIONS[0];
    return '<section class="question-block" aria-label="Question"><div class="q-main">' + questionBody(p, q) + "</div>" +
      '<div class="question-send">' + sendArea([answerOf(p, q)], 1) + "</div></section>";
  }

  /* The CTA at the top of a ticket page: what waits on the Director, and one move that opens the sheet. */
  function decisionCta(p) {
    const n = Math.max(1, Math.min(QUESTIONS.length, Number(p.questions) || 1));
    const qs = QUESTIONS.slice(0, n);
    return '<section class="decision-cta" aria-label="Decisions"><span class="cta-mark">' + icon("question") + "</span>" +
      '<span class="cta-text"><b>' + (n === 1 ? "A question waits on you" : n + " questions wait on you") + "</b>" +
      '<span class="t-secondary">' + esc(qs.map((q) => q.title).join(" · ")) + " · oldest " + esc(qs[0].age) + "</span></span>" +
      button({ label: n === 1 ? "Answer…" : "Answer " + n + "…", variant: "primary", key: "cta" }).replace("<button ", '<button aria-expanded="' + !!p.sheetOpen + '" data-set="sheetOpen=' + !p.sheetOpen + '" ') + "</section>";
  }

  /* The side sheet that holds every open Question, scrolling on its own; one Send at its foot. */
  function decisionSheet(p) {
    const n = Math.max(1, Math.min(QUESTIONS.length, Number(p.questions) || 1));
    const qs = QUESTIONS.slice(0, n);
    const body = qs.map((q, i) => '<section class="question-block in-sheet" aria-label="Question ' + (i + 1) + '">' + questionBody(p, q, n > 1 ? [i + 1, n] : null) + "</section>").join('<hr class="q-sep">');
    return '<div class="dsheet-layer"><div class="dsheet-scrim" data-set="sheetOpen=false" aria-hidden="true"></div>' +
      '<aside class="dsheet" role="dialog" aria-label="Your decisions"><header class="dsheet-head"><span class="cta-mark">' + icon("question") + "</span><div><h2>" + (n === 1 ? "Your decision" : n + " decisions wait on you") + "</h2>" +
      '<p class="sub">TP-1382 · Design system catalog</p></div><span class="only-narrow"><button type="button" class="icon-btn" aria-label="Close" title="Close (Esc)" data-set="sheetOpen=false" data-key="sheet-close">' + icon("close") + "</button></span></header>" +
      '<div class="dsheet-body">' + body + "</div>" +
      '<footer class="dsheet-foot">' + sendArea(qs.map((q) => answerOf(p, q)), n) + "</footer></aside></div>";
  }

  function boardGroup(title, role, items, expanded, hint, key, o) {
    o = o || {};
    const empty = !items.length;
    const rows = items.map((t, i) => '<div style="--i:' + i + '">' + row(Object.assign({}, t, { twoLine: true, wide: !!o.wide, selected: o.selected === t.ident, set: o.selectable ? "selected=" + (o.selected === t.ident ? "" : t.ident) : null, key: o.selectable ? "r-" + t.ident : null })) + "</div>").join("");
    return '<section class="board-group' + (empty ? " empty" : "") + '"><button type="button" class="group-head" aria-expanded="' + (!empty && !!expanded) + '"' + (empty ? ' aria-disabled="true"' : ' data-toggle="' + key + '" data-key="bg-' + key + '"') + ">" +
      (empty ? "" : icon("chevron-right", "disclose")) + '<span class="role-' + role + '">' + icon(ROLES[role].glyph) + "</span>" + esc(title) + (empty ? "" : '<span class="count' + (role === "you" || role === "problem" ? " role-" + role : " count-quiet") + '">' + items.length + "</span>") +
      '<span class="hint">' + esc(empty ? "None right now" : hint) + "</span></button>" +
      (empty ? "" : fold("bg-" + key, expanded, '<div class="rows list" role="listbox">' + rows + "</div>")) + "</section>";
  }

  const BOARD_STEPS = { "TP-1382": "passed passed passed passed paused", "TP-1375": "passed passed failed pending pending", "TP-1376": "passed passed passed current pending", "SHOP-305": "passed passed passed passed current", "TP-1380": "current pending pending pending pending" };

  function boardPreview(t) {
    if (!t) return '<div class="preview-card"><div class="empty" style="padding:24px 8px;max-width:none"><span class="glyph-wrap">' + icon("inspector") + "</span><h3>Pick a ticket</h3><p>Its situation, steps and moves show here without leaving the board.</p></div></div>";
    const st = (BOARD_STEPS[t.ident] || "passed passed current pending pending").split(" ");
    const stepsHtml = steps({ code: st[0], build: st[1], checks: st[2], tests: st[3], handoff: st[4] });
    return '<div class="preview-card" aria-label="Preview"><div class="ident-line t-secondary" style="display:flex;gap:8px;align-items:center"><b>' + esc(t.ident) + "</b>" + chip({ kind: "repo", text: t.repo || "symphony", interactive: false }) + "</div>" +
      "<h2>" + esc(t.title) + "</h2>" + situation({ role: t.role, word: t.badge, cause: t.line2 + ".", age: t.age }) + stepsHtml +
      kv([["Pull request", "PR #812 · 14 files"], ["Runs", "3 · 1 h 12 min"], ["Part of", "TP-1381 · Phase 3b"]]) +
      '<div class="btn-row">' + button({ label: t.role === "you" ? "Answer in the Inbox" : t.fix || "Open Ticket", variant: "primary" }) + button({ label: "Open Pull Request", variant: "secondary", glyph: "pr" }) + "</div></div>";
  }

  function board(p) {
    const you = p.emptyYou ? [] : [TICKETS[0]];
    const problem = [Object.assign({}, TICKETS[2], { fix: "Open Checks", fixPrimary: true })];
    const working = [TICKETS[1], TICKETS[3], TICKETS[6]];
    const all = you.concat(problem, working);
    const o = { wide: true, selectable: true, selected: p.selected };
    const groups = '<div class="board">' +
      boardGroup("Waiting on you", "you", you, p.g1, "oldest 3 h 12 min", "g1", o) +
      boardGroup("Needs attention", "problem", problem, p.g2, "a fix run starts on its own", "g2", o) +
      boardGroup("Working", "working", working, p.g3, "3 runs", "g3", o) +
      boardGroup("Forced", "forced", [], false, "", "g4", o) + "</div>";
    const picked = all.filter((t) => t.ident === p.selected)[0];
    return '<div class="board-page with-preview">' + groups + '<aside class="board-preview">' + boardPreview(picked) + "</aside></div>";
  }

  function tableSection(p) {
    const facets = [
      ["Status", [["status", "Waiting on you", "you", 1], ["status", "Needs attention", "problem", 1], ["status", "Working", "working", 2]]],
      ["Repo", [["repo", "symphony", null, 4], ["repo", "web-shop", null, 1]]],
      ["Epic", [["epic", "Phase 3b", null, 2]]],
    ];
    let n = 0;
    const chooser = p.chooser ? '<ul class="menu column-chooser" role="menu" style="left:0">' + ["Ticket", "Title", "Stage", "Repo", "Age", "Tokens", "Epic", "Last run"].map((c, i) =>
      '<li class="menu-item" role="menuitemcheckbox" tabindex="-1" aria-checked="' + (i < 6) + '">' + icon("check", "check") + esc(c) + "</li>").join("") + "</ul>" : "";
    const bar = '<div class="filter-bar sz-sm"><div class="input search">' + icon("search") + '<input type="search" aria-label="Search tickets" placeholder="Search tickets"></div>' +
      facets.map((f) => '<div class="facet"><span class="facet-label">' + esc(f[0]) + "</span>" + f[1].map((c) => {
        const i = n++;
        const on = i === 3 || (i === 0 && !!p.filtered);
        return chip({ kind: c[0], text: c[1], role: c[2], pressed: on, toggle: i === 0 ? "filtered" : null, key: "fc" + i }).replace("</button>", ' <span class="n only-wide">' + c[3] + "</span></button>");
      }).join("") + "</div>").join("") +
      '<span class="spacer"></span><span class="menu-wrap"><button type="button" class="menu-btn" aria-haspopup="menu" aria-expanded="' + !!p.chooser + '" data-toggle="chooser" data-key="cc">' + icon("columns") + "Columns" + icon("chevron-down", "chev") + "</button>" + chooser + "</span></div>";
    return '<section class="table-section">' + bar + '<div class="table-wrap">' + table({ sort: p.sort || "age-desc", fill: true, selectedRow: p.selectedRow === undefined ? -1 : p.selectedRow, hoverRow: -1, focusedRow: -1 }) + "</div></section>";
  }

  function controlBar(p) {
    const pop = (label, value) => '<button type="button" class="popup"><span class="popup-label"><span>' + esc(label) + "</span><span>" + esc(value) + "</span></span>" + icon("updown", "chev") + "</button>";
    return '<div class="control-bar sz-sm" role="toolbar" aria-label="What the page shows">' +
      '<span class="group"><span class="lbl">Period</span>' + segmented(["Day", "Week", "Month"], p.period, { prop: "period", anim: "cb-seg", label: "Period" }) + "</span>" +
      '<span class="group"><span class="lbl">Unit</span>' + pop("", p.unit) + "</span>" +
      '<span class="group">' + pop("Repo", p.repo) + "</span>" +
      '<span class="group">' + pop("Epic", p.epic) + "</span>" +
      (p.repo !== "All repos" || p.epic !== "All epics" ? button({ label: "Clear", variant: "quiet", size: "small" }) : "") +
      '<span class="spacer"></span><span class="summary">' + esc(p.summary) + "</span></div>";
  }

  const RUN_NOW = [
    { kind: "phase", time: "11:44", headHtml: head("Moved to In Progress", "from Code Review"), detail: "Code Review sent it back: the timeline missed a stopped run", actor: "Symphony" },
    { kind: "run-started", time: "11:45", headHtml: head("Implementation run 2 started"), detail: "Claude · laptop workspace" },
  ];
  const RUN_NOW_STEPS = { code: "passed", build: "passed", checks: "passed", tests: "current", handoff: "pending", testsNote: "212 of 340" };
  const RUN_ONE_STEPS = { code: "passed", build: "passed", checks: "failed", tests: "pending", handoff: "pending", checksNote: "2 tests" };

  function timelineSection(p) {
    const index = '<nav class="tl-index only-wide" aria-label="Days"><h4>Days</h4>' + [["Today", 12, true], ["Yesterday", 7], ["Mon 2 Nov", 4], ["Fri 30 Oct", 9]].map((d) =>
      '<button type="button"' + (d[2] ? ' aria-current="true"' : "") + "><span>" + esc(d[0]) + '</span><span class="n">' + d[1] + "</span></button>").join("") + "</nav>";
    const now = p.noRun ? "" : runGroup({ title: "Implementation run 2", verdict: "running", time: "11:45", duration: "42 min so far", expanded: p.runNowOpen, entries: RUN_NOW, steps: RUN_NOW_STEPS, foldKey: "tl-now" }).replace('data-toggle="expanded"', 'data-toggle="runNowOpen"');
    return '<div class="timeline-layout">' + index + '<section class="timeline-section"><div class="tl-day">Today<span class="t-secondary">newest first</span></div>' +
      (p.note && p.note !== "none" ? '<ol class="timeline">' + tlEntry({ kind: "message", time: "11:50", headHtml: head("You wrote:", "“Keep the button word Release, not Unblock.”"), detail: p.note === "read" ? "Read by Implementation run 2 at 11:51" : "The next run reads it first", actor: "Tony" }) + "</ol>" : "") + now + '<ol class="timeline">' + DAY.slice(3).reverse().map(tlEntry).join("") + "</ol>" +
      runGroup({ title: "Implementation run 1", verdict: "failed", time: "09:02", duration: "22 min", tokens: "", expanded: p.runOpen, entries: DAY.slice(1, 3), steps: RUN_ONE_STEPS, foldKey: "tl" }).replace('data-toggle="expanded"', 'data-toggle="runOpen"') +
      '<ol class="timeline">' + DAY.slice(0, 1).map(tlEntry).join("") + "</ol></section></div>";
  }

  function ticketPage(p) {
    const asks = p.role === "you";
    const open = asks && !!p.sheetOpen;
    return '<div class="ticket-page' + (asks ? " has-decision" : "") + (open ? " sheet-open" : "") + '"><div class="zone-head">' + pageHeader(Object.assign({}, p, { cta: asks })) + "</div>" +
      (asks ? '<div class="zone-decide only-narrow"><h3 class="zone-title">Waiting on you</h3>' + decisionCta(p) + "</div>" : "") +
      '<div class="zone-run"><div class="zone-brief">' + briefTitle(p) + briefBlock(p, !!p.briefOpen) + '</div><h3 class="zone-title">Lifecycle</h3>' + lifecyclePanel(p) + "</div>" +
      '<div class="zone-timeline"><h3 class="zone-title">Timeline</h3>' + composer(p) + timelineSection(p) + "</div>" +
      '<div class="zone-facts">' + factsRail(p) + "</div>" +
      /* Laptop: the decisions open in a sheet over the page. Desktop: they are always there, a column under the header. */
      (asks ? '<div class="zone-sheet' + (open ? " is-open" : "") + '"><h3 class="zone-title only-wide">Waiting on you</h3>' + decisionSheet(p) + "</div>" : "") + "</div>";
  }

  const frame = (inner) => '<div class="section-frame">' + inner + "</div>";

  const HEADER_CONTROLS = [{ name: "role", label: "Situation", type: "select", options: [{ value: "working", label: "Waiting for CI" }, { value: "you", label: "Waiting on you" }] }, { name: "blocked", label: "Approve disabled", type: "toggle" }, { name: "noRun", label: "No run working", type: "toggle" }, { name: "more", label: "More menu open", type: "toggle" }];

  const sections = [
    {
      title: "Page layout",
      wide: true,
      args: { chainOpen: "", briefOpen: false, noBrief: false, note: "read", noteDraft: false, decisions: true, page: "ticket", boardPick: "", ident: "TP-1382", title: "Design system catalog as HTML: every Director component and section as stories", role: "you", blocked: false, noRun: false, more: false, questions: 2, sheetOpen: false, selected: 0, text: "", selected2: 0, text2: "", runOpen: false, runNowOpen: false, ci: "running", blockedBy: false, noEpic: false, noPr: false, g1: true, g2: true, g3: true, emptyYou: false },
      controls: [
        { name: "page", label: "Page", type: "select", options: [{ value: "ticket", label: "Ticket page" }, { value: "board", label: "Board" }] },
        HEADER_CONTROLS[0],
        { name: "questions", label: "Open questions", type: "select", options: [{ value: 1, label: "One" }, { value: 2, label: "Two" }], when: (p) => p.page === "ticket" && p.role === "you" },
        { name: "sheetOpen", label: "Decisions sheet open (laptop)", type: "toggle", when: (p) => p.page === "ticket" && p.role === "you" },
        { name: "runNowOpen", label: "The run now unfolded", type: "toggle", when: (p) => p.page === "ticket" },
        { name: "ci", label: "Checks", type: "select", options: [{ value: "running", label: "Running" }, { value: "failed", label: "One failed" }, { value: "passed", label: "All passed" }], when: (p) => p.page === "ticket" },
        { name: "briefOpen", label: "Brief read in full", type: "toggle" },
        { name: "noBrief", label: "No run has written a brief yet", type: "toggle" },
        { name: "note", label: "A message sent to the ticket", type: "select", options: [{ value: "none", label: "None" }, { value: "written", label: "Sent, not read yet" }, { value: "read", label: "Read by a run" }] },
        { name: "noteDraft", label: "A message is being typed", type: "toggle" },
        { name: "decisions", label: "Decisions recorded", type: "toggle" },
        { name: "more", label: "More menu open", type: "toggle" },
      ],
      render: (p) => frame(p.page === "board" ? homePage(p) : ticketPage(p)),
      docs: {
        what: "Where every section goes on a whole page, at both widths. The ticket page reads top to bottom in the order the Director needs it: who and where it stands (the header, one row across the page), what waits on them (the decisions), where the ticket is on its way to landing (the lifecycle: its stages with the time each took, and one token bar split by stage), then what happened (the timeline, newest first, the run now at the top with its steps folded into its line). The facts rail is the reference beside them: the pull request with every check, and the ticket's connections. A wider window gives the same structure more room; it never moves sections around.",
        when: ["The header is always one row across the whole page; every column starts under it.", "On a laptop the decisions never sit in the page itself: the page shows one line saying what waits, and Answer opens them in a side sheet on the right, where several Questions scroll on their own. On a desktop there is room for them, so they are always there as a column and the page needs no such line.", "The lifecycle always sits directly on top of the timeline: the stages say where the ticket is, the timeline says how it got there.", "Each fact appears once: time and tokens in the lifecycle, the checks in the pull request panel, a run's steps on the run's own line of the timeline."],
        responsive: [
          "Ticket page, laptop (1180 pt): the header across the top; the main column holds the decisions line, the lifecycle and the timeline, in that order; the facts rail (340 pt) on the right with the pull request and Connected. The decisions sheet (520 pt) slides over the right of the page, over a dimmed page, and closes on a click outside it.",
          "Ticket page, desktop (2200 pt): the header is one row across the page, the moves on the identifier's line so the title has the whole width, the situation and the key facts on the line under it. Under the header, three columns: the main column with the lifecycle on top of the timeline; the facts rail (440 pt) with the pull request and Connected; and, when something waits on the Director, the decisions (600 pt) on the far right, always open and scrolling on their own. No decisions line, no Answer button: the answers are already on the page. With nothing waiting, the page keeps two columns, the main one up to 1040 pt.",
          "Every column opens with its title outside its card (Lifecycle, Pull request, Waiting on you), so the columns start on one line.",
          "Board, laptop: the situation groups stacked top to bottom in the order the Director acts on them; each row says where the ticket stands in two lines. Picking a row opens its page.",
          "Board, desktop: the groups still stack; each row turns into one line of aligned columns (what it waits on, repo, steps, age), and a preview of the picked ticket sits beside the list, so the Director can act without leaving the board.",
        ],
        motion: "On a laptop the sheet slides in from the right on a spring (0.5 s) while the page dims. On a desktop nothing moves: the decisions column is there from the start.",
        tokens: ["--space-6", "--space-8", "--measure", "--radius-sheet", "--material-glass-thick", "section tokens"],
      },
      stories: [
        { name: "Ticket page, laptop", viewport: "laptop", args: { page: "ticket" } },
        { name: "Ticket page, laptop, the run now unfolded", viewport: "laptop", args: { page: "ticket", role: "working", runNowOpen: true } },
        { name: "Ticket page, laptop, decisions open", viewport: "laptop", args: { page: "ticket", sheetOpen: true, selected: 1 } },
        { name: "Ticket page, desktop", viewport: "desktop", args: { page: "ticket" } },
        { name: "Ticket page, desktop, one answer picked", viewport: "desktop", args: { page: "ticket", selected: 1 } },
        { name: "Ticket page, desktop, nothing waits on you", viewport: "desktop", args: { page: "ticket", role: "working" } },
        { name: "Ticket page, nothing waits on you", viewport: "laptop", args: { page: "ticket", role: "working" } },
        { name: "Board, laptop", viewport: "laptop", args: { page: "board" } },
        { name: "Board, desktop", viewport: "desktop", args: { page: "board", boardPick: "TP-1375" } },
      ],
    },
    {
      title: "Page header",
      wide: true,
      args: { ident: "TP-1382", title: "Design system catalog as HTML, Storybook-shaped: every Director component and section as stories per state", role: "working", blocked: true, noRun: false, more: false },
      controls: [{ name: "ident", label: "Identifier", type: "text" }, { name: "title", label: "Title", type: "textarea" }].concat(HEADER_CONTROLS),
      render: (p) => frame(pageHeader(p)),
      docs: {
        what: "The top of a ticket page: the identifier with its repo and epic, the title, the situation line, and the action rail.",
        responsive: ["Laptop (1180 pt): the action rail sits on its own row under the situation line, so the title keeps the full width. The title wraps (balanced) and stops at 30 em.", "Desktop (2200 pt): one row across the whole page. The action rail shares the top line with the identifier, so the title runs the full width under them (up to 56 em, about 120 characters, before it wraps). The situation sits on the line under the title. The header carries no facts: time and tokens are in the lifecycle, the pull request and its checks in the facts rail.", "The age sits inside the status pill, next to the word it counts (Waiting on you, for 3 h 12 min), so it always has the same place to be read."],
        tokens: ["--type-title", "--tracking-display", "--space-8", "--measure"],
      },
      stories: VIEWPORT_STORIES([{ name: "Waiting on you", viewport: "laptop", args: { role: "you", blocked: false } }, { name: "Short title", viewport: "desktop", args: { title: "Checkout total rounding", ident: "SHOP-305" } }]),
    },
    {
      title: "Action rail",
      wide: true,
      args: { role: "working", blocked: true, noRun: false, more: false },
      controls: HEADER_CONTROLS,
      render: (p) => frame(actionRail(p)),
      docs: {
        what: "The moves a ticket allows, in one row of medium buttons: the expected move first and primary, then the others, and More for the rest.",
        when: ["A disabled move stays in its place and says why under it, so the rail never jumps."],
        responsive: ["Laptop: the expected move and two others; Stop Run… lives in More, last and in red, so a destructive move is never the easiest one to hit.", "Desktop: Stop Run… joins the rail after a separator; More keeps the rare moves.", "The rail wraps onto a second line before any button shrinks."],
        tokens: ["--control-md", "--space-2", "button tokens"],
      },
      stories: VIEWPORT_STORIES([{ name: "More open, laptop", viewport: "laptop", args: { more: true } }, { name: "Waiting on you", viewport: "laptop", args: { role: "you", blocked: false } }, { name: "Nothing running", viewport: "desktop", args: { blocked: false, noRun: true } }]),
    },
    {
      title: "Lifecycle",
      wide: true,
      args: { noRun: false },
      controls: [{ name: "noRun", label: "No run yet", type: "toggle" }],
      render: (p) => frame('<div style="max-width:780px"><h3 class="zone-title">Lifecycle</h3>' + lifecyclePanel(p) + "</div>"),
      docs: {
        what: "Where the ticket is on its whole way to landing: the stages it moves through (Coding, Code Review, QA, Merging, Done), each with its state and the time it took, then one token bar against the ticket's cap, split by the same stages. It sits on top of the timeline on the ticket page.",
        when: ["The stages are the ticket's, not one run's: a run's own steps (writing the code, build, checks, tests, handoff) sit on that run's line in the timeline.", "A stage that sent the ticket back says so (Sent back) and keeps its time; a stage the ticket skips says why.", "One bar for tokens: the stages fill the ticket's cap from the left and what is left stays empty, so where the tokens went and how much is left read together. Its colour turns orange from 75 % and red from 95 %, as the progress meter does."],
        responsive: ["Laptop: the main column's width, up to 780 pt; the stages share it equally.", "Desktop: the same, up to 1040 pt; stage names and their notes never wrap mid-word."],
        states: [["In Coding, sent back once", "Coding now, Code Review sent back, QA skipped"], ["No run yet", "Coding now with no time, an empty bar"]],
        motion: "The current stage's bar flows while it works; the token bar's segments grow on a spring when a run spends.",
        tokens: ["step strip tokens", "stacked stage bar tokens", "--radius-card", "--elevation-1"],
      },
      stories: [{ name: "Laptop", viewport: "laptop" }, { name: "Desktop", viewport: "desktop" }, { name: "No run yet", viewport: "laptop", args: { noRun: true } }],
    },
    {
      title: "Facts rail",
      wide: true,
      args: { role: "working", noPr: false, ci: "running", noEpic: false, blockedBy: false, holdsNothing: false },
      controls: [
        { name: "role", label: "Situation", type: "select", options: [{ value: "working", label: "Waiting for CI" }, { value: "you", label: "Waiting on you" }] },
        { name: "noPr", label: "No pull request yet", type: "toggle" },
        { name: "ci", label: "Checks", type: "select", options: [{ value: "running", label: "Running" }, { value: "failed", label: "One failed" }, { value: "passed", label: "All passed" }], when: (p) => !p.noPr },
        { name: "noEpic", label: "Not part of an epic", type: "toggle" },
        { name: "blockedBy", label: "Another ticket holds it up", type: "toggle" },
        { name: "holdsNothing", label: "It holds no ticket up", type: "toggle" },
      ],
      render: (p) => frame(factsRail(p)),
      docs: {
        what: "The column beside the lifecycle and the timeline, in two panels. Pull request: the pull request with its size and the state of its checks, then every check, by workflow, with its state (passed, failed, running, waiting, skipped) and how long it took. Connected shows where the ticket sits: its epic with the epic's progress and its tickets in order, what this ticket waits on, and what waits on it.",
        when: ["The checks are listed in full, never summed up alone: a failed or running one is read in place, and each row opens its log.", "Time and tokens are not here: they belong to the lifecycle, beside the stages they were spent in.", "Each panel's title sits outside the card, like Lifecycle and Timeline, so the columns start on one line. The panels never fold: what is there is short enough to read in full.", "A fact that is unknown says so in a plain line (No pull request yet, Not part of an epic, Nothing holds this one up), never a dash."],
        responsive: ["Laptop: one column, 340 pt, beside the page's main column.", "Desktop: one column, 440 pt, the wider room going to the check names and the ticket titles. The rail stays a column: facts are read top to bottom, never spread across the page.", "Check names and ticket titles wrap inside their row; the state, the identifier and the numbers never wrap."],
        states: [["Checks running", "a live dot on each running check, the rest passed or waiting"], ["One check failed", "the failed row in red, the report after it skipped"], ["All passed", "every row green"], ["No pull request yet", "a plain line in its place"], ["Not part of an epic", "a plain line"], ["Held up", "the ticket it waits on, with its stage"]],
        motion: "A check or ticket row lifts its background on hover and its arrow nudges right; a running check's dot pulses; states update in place.",
        tokens: ["--radius-card", "--elevation-1", "--space-4", "--space-5", "--surface-sunken", "--surface-hover", "--accent-tint", "meter tokens", "stacked stage bar tokens"],
      },
      stories: [
        { name: "Laptop", viewport: "laptop" },
        { name: "Desktop", viewport: "desktop" },
        { name: "Held up by another ticket", viewport: "laptop", args: { blockedBy: true } },
        { name: "A check failed", viewport: "laptop", args: { ci: "failed" } },
        { name: "All checks passed", viewport: "desktop", args: { ci: "passed" } },
        { name: "No pull request yet", viewport: "laptop", args: { noPr: true } },
        { name: "Not part of an epic", viewport: "laptop", args: { noEpic: true } },
        { name: "Nothing connected: no Connected panel", viewport: "laptop", args: { noEpic: true, holdsNothing: true } },
      ],
    },
    {
      title: "Timeline",
      wide: true,
      args: { runOpen: false, runNowOpen: false },
      controls: [{ name: "runNowOpen", label: "The run now unfolded", type: "toggle" }, { name: "runOpen", label: "Run 1 unfolded", type: "toggle" }],
      render: (p) => frame(timelineSection(p)),
      docs: {
        what: "A day of a ticket's history, newest first, so the latest event is the first thing read: phase moves, pauses, questions, runs folded into groups, the Director's own actions and the rules Symphony applied.",
        responsive: ["Laptop: one column of at most 780 pt.", "Desktop: the same column, with a list of days beside it that jumps between them; the extra width goes to finding your way, never to longer lines.", "On the ticket page the timeline keeps one column at both widths, directly under the lifecycle: the day list belongs to the full history view.", "Newest first at every level: days, entries in a day, and the entries inside an unfolded run.", "A run's steps are folded into its line: a short bar per step and the step it is on (or stopped at). Unfolding the run shows the full step strip above its entries."],
        tokens: ["timeline entry tokens", "--measure"],
      },
      stories: VIEWPORT_STORIES([{ name: "The run now unfolded", viewport: "laptop", args: { runNowOpen: true } }, { name: "Failed run unfolded", viewport: "laptop", args: { runOpen: true } }]),
    },
    {
      title: "Question block",
      wide: true,
      args: { selected: 0, text: "" },
      controls: [{ name: "selected", label: "Picked answer", type: "select", options: [{ value: 0, label: "None yet" }, { value: 1, label: "Approve the catalog" }, { value: 2, label: "Ask for changes" }, { value: 3, label: "My own words" }] }, { name: "text", label: "Own words", type: "textarea", when: (p) => Number(p.selected) === 3 }],
      render: (p) => frame(questionBlock(p)),
      docs: {
        what: "A Question as the Director answers it: the callout with the question, why it is asked and what happens if it waits, the option cards, the own-words card, and a large Send that repeats the picked answer.",
        when: ["Send stays off until an answer is picked (and, for own words, written), and says so.", "On the ticket page Questions open in the decisions sheet; see Decision sheet."],
        responsive: ["Laptop: one column. The option cards fill the column's width, and Send sits under them, its right edge on theirs.", "Desktop: Send moves into a column on the far right (300 pt), sticky, with the picked answer above it; the options fill the rest, up to 1240 pt in all.", "The option cards stretch; the text inside them stops at the measure."],
        tokens: ["--tint-you", "--status-you", "option card tokens", "--control-lg", "--measure"],
      },
      stories: VIEWPORT_STORIES([{ name: "Option picked", viewport: "laptop", args: { selected: 1 } }, { name: "Option picked, desktop", viewport: "desktop", args: { selected: 1 } }, { name: "Own words", viewport: "laptop", args: { selected: 3, text: "Approve, but make the dark status tints a step stronger first." } }]),
    },
    {
      title: "Decision sheet",
      wide: true,
      args: { questions: 2, sheetOpen: true, selected: 0, text: "", selected2: 0, text2: "" },
      controls: [
        { name: "questions", label: "Open questions", type: "select", options: [{ value: 1, label: "One" }, { value: 2, label: "Two" }] },
        { name: "sheetOpen", label: "Open", type: "toggle" },
        { name: "selected", label: "First answer", type: "select", options: [{ value: 0, label: "None yet" }, { value: 1, label: "Approve the catalog" }, { value: 2, label: "Ask for changes" }, { value: 3, label: "My own words" }] },
        { name: "selected2", label: "Second answer", type: "select", options: [{ value: 0, label: "None yet" }, { value: 1, label: "Allow this change" }, { value: 2, label: "Keep the file as it is" }, { value: 3, label: "My own words" }], when: (p) => Number(p.questions) === 2 },
      ],
      render: (p) => frame('<div class="sheet-stage"><div class="ghost-page" aria-hidden="true"><span></span><span></span><span></span><span></span></div>' + (p.sheetOpen ? decisionSheet(p) : '<div class="ghost-cta">' + decisionCta(p) + "</div>") + "</div>"),
      docs: {
        what: "Every Question open on a ticket, in a side sheet on the right: a header with the count and a close button, the Questions one under the other, and one Send at the foot that sends every answered one. On a laptop the ticket page keeps only one line about them (the decisions line with Answer), so it stays quiet; on a desktop the same panel is a column of the page, always open.",
        when: ["Open it from the decisions line at the top of a ticket page. Close it with the close button, Esc, or a click on the dimmed page.", "Answer one, some or all: Send counts what is answered and leaves the rest open."],
        responsive: ["Laptop: 520 pt over the right of the page, the page dimmed behind it.", "Desktop: on the ticket page, a 640 pt column on the far right under the header, always open, with no close button; the page stays bright and readable beside it. Shown alone, as here, it is the 640 pt sheet.", "As tall as the window; the Questions scroll inside it while its header and Send stay put."],
        motion: "Slides in from the right on a spring (0.5 s); the dimmed page fades in at 0.28 s.",
        tokens: ["--radius-sheet", "--material-glass-thick", "--elevation-4", "--surface-overlay", "--motion-spring"],
      },
      stories: VIEWPORT_STORIES([{ name: "One question", viewport: "laptop", args: { questions: 1 } }, { name: "Answered one of two", viewport: "laptop", args: { selected: 1 } }, { name: "Both answered", viewport: "desktop", args: { selected: 1, selected2: 1 } }]),
    },
    {
      title: "Board group",
      wide: true,
      args: { g1: true, g2: true, g3: true, g4: false, emptyYou: false, selected: "" },
      controls: [{ name: "g1", label: "Waiting on you open", type: "toggle" }, { name: "g2", label: "Needs attention open", type: "toggle" }, { name: "g3", label: "Working open", type: "toggle" }, { name: "emptyYou", label: "Nothing waits on you", type: "toggle" }, { name: "selected", label: "Picked ticket", type: "select", options: [{ value: "", label: "None" }, { value: "TP-1382", label: "TP-1382" }, { value: "TP-1375", label: "TP-1375" }, { value: "TP-1376", label: "TP-1376" }] }],
      render: (p) => frame(board(p)),
      docs: {
        what: "Tickets grouped by their situation, each group a card with a heading (glyph, count, a hint) and its rows. A group with nothing in it stays as a quiet heading that says so.",
        when: ["Groups always stack, in the order the Director acts on them: Waiting on you, Needs attention, Working, Forced. Click a heading to fold it; click a row to pick it."],
        avoid: "Groups side by side: a situation is read with the ones above and below it, and side by side would cut every title short.",
        responsive: ["Laptop: groups stacked full width; each row has two lines (the title, then where it stands). Picking a row opens its page.", "Desktop: groups still stacked. Each row becomes one line of aligned columns (title, what it waits on, repo, steps, age), and a preview of the picked ticket sits beside the list, sticky, with its moves.", "Rows cut their title at the end before the age or the fix button would wrap."],
        motion: "A group folds on a 0.28 s height animation while its rows fade down in turn, 35 ms apart; the chevron turns on a spring. The preview rises in when a row is picked.",
        tokens: ["row tokens", "--status-*", "--radius-card", "--motion-standard", "--motion-stagger"],
      },
      stories: [
        { name: "Laptop", viewport: "laptop" }, { name: "Desktop", viewport: "desktop", args: { selected: "TP-1375" } },
        { name: "Desktop, nothing picked", viewport: "desktop" },
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
        what: "A table of tickets with a search field and filter chips, and a Columns menu that picks which columns show. Its controls are small (24 pt).",
        responsive: ["Laptop: the filters sit in one bar above the table and wrap if they must; the Repo column hides (the repo chip says it); the Title column wraps at 42 characters.", "Desktop: the filters move into a sticky column on the left, grouped by Status, Repo and Epic with a count on each chip; every chosen column shows; the Title column still wraps at its measure."],
        tokens: ["table tokens", "chip tokens", "--control-sm", "--elevation-3"],
      },
      stories: VIEWPORT_STORIES([{ name: "Column chooser open", viewport: "laptop", args: { chooser: true } }, { name: "Filtered", viewport: "desktop", args: { filtered: true } }]),
    },
    {
      title: "Control bar",
      wide: true,
      args: { period: 1, unit: "Tokens", repo: "All repos", epic: "All epics", summary: "Mar 3 to Mar 9 · 18.4M tokens" },
      controls: [{ name: "period", label: "Period", type: "select", options: [{ value: 0, label: "Day" }, { value: 1, label: "Week" }, { value: 2, label: "Month" }] }, { name: "unit", label: "Unit", type: "select", options: ["Tokens", "Runs", "Hours"] }, { name: "repo", label: "Repo", type: "select", options: ["All repos", "symphony", "web-shop"] }, { name: "epic", label: "Epic", type: "select", options: ["All epics", "Phase 3b", "Phase 3a"] }, { name: "summary", label: "Summary", type: "text" }],
      render: (p) => frame(controlBar(p)),
      docs: {
        what: "The glass bar above Usage and Shipped that sets what the page shows: the period, the unit, the repo and the epic, with a one-line summary of the result. Its controls are small (24 pt).",
        responsive: ["Laptop: the controls on one line, the summary on its own line under them.", "Desktop: one line, the summary right aligned.", "Clear appears only when a repo or an epic is picked."],
        tokens: ["--material-glass", "--radius-card", "--control-sm", "segmented control and pop-up tokens"],
      },
      stories: VIEWPORT_STORIES([{ name: "Filtered", viewport: "laptop", args: { repo: "symphony", epic: "Phase 3b", summary: "Mar 3 to Mar 9 · 6.2M tokens in Phase 3b" } }]),
    },
  ];




  /* ---------- Home: what is in progress, and the queue behind it ---------- */

  /* Two lists. "In progress" is every ticket that has started and has not landed, whatever it is doing right now
     (a run is working, CI is running, it waits on the Director, it retries later), under its epic when it has one:
     an epic with a ticket in progress is in progress too. "Queue" is every ticket that has not started, as the tree
     Symphony holds: a ticket sits under the ticket it waits on. A chain runs straight down; a fork indents. */
  const T = (ident, title, o) => Object.assign({ ident: ident, title: title, role: "idle" }, o || {});
  const PROGRESS = [
    { epic: T("SHOP-280", "Checkout that survives a reload", { parts: [["done", 4], ["working", 2], ["idle", 3]] }), kids: [
      { t: T("SHOP-305", "Checkout total rounding", { role: "working", live: true, badge: "Coding", age: "14 min" }) },
      { t: T("SHOP-301", "Saved carts", { role: "working", badge: "Waiting for CI", age: "6 min" }) }] },
    { epic: T("BIL-300", "Annual plans", { parts: [["done", 1], ["you", 1], ["working", 1], ["idle", 1]] }), kids: [
      { t: T("BIL-306", "Proration when a plan changes mid-cycle", { role: "you", badge: "Question", fix: "Answer", age: "3 h 12 min" }) },
      { t: T("BIL-307", "Invoice PDF shows the plan’s period", { role: "working", live: true, badge: "Code Review", age: "4 min" }) }] },
    { t: T("TP-1492", "Symphony tells the Director when a ticket changed", { role: "working", live: true, badge: "QA", age: "9 min" }) },
    { t: T("TP-1480", "A poll that changes nothing redraws nothing", { role: "you", badge: "Stopped by you", fix: "Unblock…", age: "5 min" }) },
    { t: T("TP-1376", "A CI-wait pause lifts itself when the commit’s CI finishes", { badge: "Retrying at 16:02", age: "40 min" }) },
  ];
  const QUEUE = [
    { t: T("TP-1481", "A long timeline draws only the rows on screen", { after: "TP-1480" }), kids: [
      { t: T("TP-1482", "A sheet that puts each native snapshot beside the prototype"), kids: [
        { t: T("TP-1483", "The catalog’s type scale, surfaces and elevation in Swift"), kids: [
          { t: T("TP-1493", "Design guard: no raw font, colour or spacing number"), kids: [
            { t: T("TP-1484", "The catalog’s panel, zone title and chip as shared components"), kids: [
              { t: T("TP-1485", "Header, moves and window toolbar as designed"), kids: [
                { t: T("TP-1486", "The lifecycle card says where the ticket is in a sentence"), kids: [
                  { t: T("TP-1487", "Timeline rows as designed, in a person’s words"), kids: [
                    { t: T("TP-1488", "The Pull request and Connected cards as designed") }] }] }] }] }] }] }] }] },
    { t: T("SHOP-311", "Gift card balance on the receipt", { after: "SHOP-305", epicName: "Checkout" }), kids: [
      { t: T("SHOP-312", "Gift card as a payment method at checkout", { epicName: "Checkout" }), kids: [
        { t: T("SHOP-314", "Split a payment between a card and a gift card", { epicName: "Checkout" }) }] },
      { t: T("SHOP-313", "Gift card balance in the account page", { epicName: "Checkout" }) }] },
    { t: T("BIL-308", "A refund follows the plan’s proration", { after: "BIL-307", epicName: "Annual plans" }) },
    { t: T("MOT-93", "Translate Cycle into Brazilian Portuguese, Spanish and German", { badge: "Waiting for a slot" }), kids: [
      { t: T("MOT-94", "Choose Cycle’s language in Settings"), kids: [{ t: T("MOT-95", "Final verification: Language settings") }] }] },
  ];

  /* One line per ticket: state glyph, identifier, title; then the ticket it comes after (when that one is in progress),
     its epic, its state as a badge, the move when it needs the Director, and for how long. Nothing under the line. */
  function homeRow(t) {
    const trail = (t.after ? '<span class="q-after" title="Starts when ' + esc(t.after) + ' lands">' + icon("arrow") + esc(t.after) + "</span>" : "") +
      (t.epicName ? chip({ kind: "epic", text: t.epicName, interactive: false }) : "") + (t.badge ? badge(t.role, t.badge, "small") : "") +
      (t.fix ? button({ label: t.fix, variant: "primary", size: "small" }) : "") + (t.age ? '<span class="age">' + esc(t.age) + "</span>" : "");
    return '<div role="option" tabindex="0" class="row role-' + esc(t.role) + '"><span class="lead">' + (t.live ? '<span class="dot live role-working"></span>' : icon(t.badge || t.role !== "idle" ? ROLES[t.role].glyph : "clock")) + "</span>" +
      '<span class="main"><span class="line1"><span class="ident">' + esc(t.ident) + '</span><span class="title">' + esc(t.title) + '</span></span></span><span class="trail">' + trail + "</span></div>";
  }

  function epicRow(e) {
    const total = e.parts.reduce((n, x) => n + x[1], 0);
    const done = (e.parts.find((x) => x[0] === "done") || [0, 0])[1];
    return '<div role="option" tabindex="0" class="row epic-row"><span class="lead">' + icon("epic") + '</span><span class="main"><span class="line1"><span class="ident">' + esc(e.ident) + '</span><span class="title">' + esc(e.title) + "</span></span></span>" +
      '<span class="trail">' + epicStrip(e.parts, true) + '<span class="age">' + done + " of " + total + "</span></span></div>";
  }

  /* The tickets under one are the tickets that wait on it, each indented one step: the tree is the dependencies, so
     a chain steps down and to the right, and two tickets on the same rail both wait on the ticket above the rail.
     Past two steps the rest is folded into a count until asked for. */
  const countUnder = (node) => (node.kids || []).reduce((n, k) => n + 1 + countUnder(k), 0);
  function homeKids(node, p, rootIdent, depth) {
    const kids = node.kids || [];
    if (!kids.length) return "";
    if (depth >= 2 && p.chainOpen !== rootIdent) return '<ul class="t-kids"><li class="t-more"><button type="button" class="q-behind" title="Show the ' + countUnder(node) + ' behind it" data-set="chainOpen=' + esc(rootIdent) + '" data-key="more-' + esc(rootIdent) + '">+' + countUnder(node) + icon("chevron-right") + "</button></li></ul>";
    return '<ul class="t-kids">' + kids.map((k) => "<li>" + homeRow(k.t) + homeKids(k, p, rootIdent, depth + 1) + "</li>").join("") + "</ul>";
  }

  function homePage(p) {
    const progress = PROGRESS.map((n) => n.epic ? '<li class="t-epic">' + epicRow(n.epic) + '<ul class="t-kids">' + n.kids.map((k) => "<li>" + homeRow(k.t) + "</li>").join("") + "</ul></li>" : "<li>" + homeRow(n.t) + "</li>").join("");
    const queue = QUEUE.map((n) => "<li>" + homeRow(n.t) + homeKids(n, p, n.t.ident, 0) + "</li>").join("");
    return '<div class="home"><h2 class="home-title">In progress</h2><ul class="t-root" role="listbox" aria-label="In progress">' + progress + "</ul>" +
      '<h2 class="home-title">Queue</h2><ul class="t-root" role="listbox" aria-label="Queue">' + queue + "</ul></div>";
  }

  /* ---------- Work: Initiatives and Tickets ---------- */

  const STORY_TITLES = ["The shared styles", "The Situation line", "The Action rail", "The Situation line everywhere", "The Question block", "The Run group and the Step list", "The Timeline", "The ticket page at laptop width", "The ticket page at desktop width", "The Lifecycle section", "The facts rail", "The decisions editor", "The labels and priority editors", "Home’s board", "Home’s top", "The five destinations", "Tickets as the table", "Saved views on Tickets", "The Inbox drawer", "Initiatives as the epic’s story", "The Journal page", "Insights", "Factory", "The menu bar", "Keyboard pass", "Accessibility pass"];
  const EPICS = [
    { ident: "TP-1381", title: "Phase 3b: the Director redesigned around a ticket’s situation", group: "Active", parts: [["done", 3], ["working", 1], ["idle", 22]] },
    { ident: "BIL-300", title: "Annual plans", group: "Active", parts: [["done", 1], ["you", 1], ["idle", 2]] },
    { ident: "SHOP-280", title: "Checkout that survives a reload", group: "Active", parts: [["done", 4], ["problem", 1], ["working", 1], ["idle", 3]] },
    { ident: "SHOP-500", title: "Gift cards", group: "Done recently", parts: [["done", 3]] },
  ];
  const PART_WORD = { done: "done", working: "working", you: "waits on you", problem: "needs a fix", idle: "waiting" };

  const epicStrip = (parts, live) => '<div class="epic-strip" role="img" aria-label="Progress">' + parts.map((x) =>
    new Array(x[1] + 1).join('<i class="' + x[0] + (live && x[0] === "working" ? " live" : "") + '"></i>')).join("") + "</div>";
  const epicTotal = (e) => e.parts.reduce((n, x) => n + x[1], 0);
  const epicDone = (e) => (e.parts.find((x) => x[0] === "done") || [0, 0])[1];

  function epicItem(e, p) {
    const here = p.epic === e.ident;
    return '<button type="button" class="ini-item' + (p.focused ? "" : " unfocused") + '"' + (here ? ' aria-selected="true"' : "") + ' data-set="epic=' + esc(e.ident) + '" data-key="epic-' + esc(e.ident) + '">' +
      '<span class="top"><span class="ident">' + esc(e.ident) + '</span><span class="n">' + epicDone(e) + " of " + epicTotal(e) + " done</span></span>" +
      '<span class="name">' + esc(e.title) + "</span>" + epicStrip(e.parts) +
      '<span class="legend">' + e.parts.filter((x) => x[0] !== "done").map((x) => '<span><span class="dot role-' + x[0] + '"></span>' + x[1] + " " + PART_WORD[x[0]] + "</span>").join("") +
      (e.parts.length === 1 ? "<span>Landed Mon 9 Nov</span>" : "") + "</span></button>";
  }

  function storyRow(i, p) {
    const n = i + 1;
    const ident = "TP-" + (1438 + i);
    const title = STORY_TITLES[i];
    const open = ' data-toggle="ticketOpen" data-key="story-' + n + '"';
    if (i < 3) return '<div class="story-row done" role="link" tabindex="0"' + open + '><span class="n">' + n + '</span><span class="mark role-done">' + icon("done") + '</span><span class="what"><span class="line1"><span class="ident">' + ident + '</span><span class="title">' + esc(title) + '</span></span></span>' +
      '<span class="trail">Landed ' + ["Tue 10 Nov", "Wed 11 Nov", "Wed 11 Nov"][i] + " · PR #" + (859 + i) + "</span>" + icon("chevron-right", "go") + "</div>";
    if (i === 3) return '<div class="story-row current role-working" role="link" tabindex="0" aria-current="step"' + open + '><span class="n">' + n + '</span><span class="mark role-working"><span class="dot live role-working"></span></span><span class="what"><span class="line1"><span class="ident">' + ident + '</span><span class="title">' + esc(title) + "</span></span>" +
      situation({ role: "working", word: "Working", cause: "Implementation run 1 is writing the code.", waits: "Code Review starts when it pushes.", compact: false }) + '</span>' +
      '<span class="trail">' + '<span class="mini-steps" aria-label="Steps">' + "passed current pending pending pending".split(" ").map((k) => '<i class="' + k + '"></i>').join("") + '</span><span class="age">25 min</span></span>' + icon("chevron-right", "go") + "</div>";
    return '<div class="story-row waiting" role="link" tabindex="0"' + open + '><span class="n">' + n + '</span><span class="mark role-idle">' + icon(i === 4 ? "clock" : "idle") + '</span><span class="what"><span class="line1"><span class="ident">' + ident + '</span><span class="title">' + esc(title) + "</span></span></span>" +
      '<span class="trail">' + (i === 4 ? "Next: starts when TP-1441 lands" : "Waits for TP-" + (1437 + i)) + "</span>" + icon("chevron-right", "go") + "</div>";
  }

  function initiativesPage(p) {
    const groups = ["Active", "Done recently"].map((g) => '<h3 class="zone-title">' + g + '</h3><div class="ini-list">' + EPICS.filter((e) => e.group === g).map((e) => epicItem(e, p)).join("") + "</div>").join("");
    const e = EPICS.find((x) => x.ident === p.epic) || EPICS[0];
    const main = e.ident !== "TP-1381" ?
      '<div class="story-head"><div class="idline"><span class="ident">' + esc(e.ident) + "</span></div><h2>" + esc(e.title) + '</h2><p class="sentence">' + epicDone(e) + " of " + epicTotal(e) + " done.</p>" + epicStrip(e.parts, true) + '</div><p class="t-secondary">Pick Phase 3b to see a whole story drawn.</p>' :
      '<div class="story-head"><div class="idline"><span class="ident">TP-1381</span>' + chip({ kind: "repo", text: "symphony", interactive: false }) + '<span class="grow"></span>' + button({ label: "Open TP-1441", variant: "secondary", size: "small", glyph: "arrow" }) + "</div>" +
      "<h2>" + esc(e.title) + '</h2><p class="sentence">3 of 26 done. <span class="soft">TP-1441 is being worked on; 22 wait behind it, in order.</span></p>' + epicStrip(e.parts, true) +
      '<p class="strip-note">Started Tue 10 Nov · 2 days so far · 14.6M tokens</p></div>' +
      '<h3 class="zone-title">Sub-tickets <span class="zone-note">in landing order</span></h3><section class="panel story">' +
      [0, 1, 2, 3, 4, 5].map((i) => storyRow(i, p)).join("") +
      (p.allRows ? STORY_TITLES.slice(6).map((t, k) => storyRow(k + 6, p)).join("") : "") +
      '<button type="button" class="story-more" data-toggle="allRows" data-key="story-more">' + icon(p.allRows ? "chevron-down" : "chevron-right") + (p.allRows ? "Show only what is near" : "20 more wait in line, in this order") + "</button></section>";
    return '<div class="ini"><aside class="ini-side">' + groups + '</aside><div class="ini-main">' + main + "</div></div>";
  }

  const TICKET_ROWS = [
    { ident: "TP-1441", title: "The Situation line everywhere", repo: "symphony", epic: "Phase 3b", role: "working", word: "Working", cause: "Implementation run 1 is writing the code.", since: "25 min", labels: [["mac", "working"]], priority: "Urgent" },
    { ident: "BIL-306", title: "Proration when a plan changes mid-cycle", repo: "billing", epic: "Annual plans", role: "you", word: "Waiting on you", cause: "A question: which day does the new price start?", since: "3 h 12 min", labels: [["billing", "forced"], ["decision", "you"]], priority: "High" },
    { ident: "SHOP-305", title: "Checkout total rounding", repo: "web-shop", epic: "Checkout", role: "problem", word: "Needs a fix", cause: "Two checks failed on PR #812.", since: "22 min", labels: [["checkout", "idle"], ["bug", "problem"]], priority: "Urgent" },
    { ident: "SHOP-301", title: "Saved carts", repo: "web-shop", epic: "Checkout", role: "working", word: "Waiting for CI", cause: "Checks are running on PR #790.", since: "6 min", labels: [["checkout", "idle"]], priority: "High" },
    { ident: "TP-1442", title: "The Question block", repo: "symphony", epic: "Phase 3b", role: "idle", word: "Blocked", cause: "Starts when TP-1441 lands.", since: "1 day", labels: [["mac", "working"]], priority: "Urgent" },
    { ident: "TP-1480", title: "A poll that changes nothing redraws nothing", repo: "symphony", epic: "", role: "working", word: "Code Review", cause: "Review run 2 is reading the change.", since: "9 min", labels: [["speed", "done"]], priority: "Urgent" },
    { ident: "BIL-307", title: "Invoice PDF shows the plan’s period", repo: "billing", epic: "Annual plans", role: "idle", word: "Queued", cause: "Waits for a slot.", since: "40 min", labels: [["billing", "forced"]], priority: "Medium" },
    { ident: "SHOP-311", title: "Gift card balance on the receipt", repo: "web-shop", epic: "", role: "forced", word: "Forced", cause: "You pushed it ahead of the queue.", since: "2 min", labels: [], priority: "High" },
    { ident: "TP-1443", title: "The Run group and the Step list", repo: "symphony", epic: "Phase 3b", role: "idle", word: "Blocked", cause: "Starts when TP-1442 lands.", since: "1 day", labels: [["mac", "working"]], priority: "Urgent" },
    { ident: "SHOP-298", title: "Address form remembers the country", repo: "web-shop", epic: "Checkout", role: "done", word: "Merging", cause: "PR #781 is green and merges next.", since: "1 min", labels: [["checkout", "idle"]], priority: "Medium" },
  ];

  function ticketsPage(p) {
    const sel = Number(p.ticketRow);
    const fchip = (text, key) => '<span class="fchip"><button type="button" class="chip chip-filter" aria-haspopup="menu">' + text + '</button><button type="button" class="fchip-x" aria-label="Remove this filter" data-toggle="' + key + '" data-key="x-' + key + '">' + icon("close") + "</button></span>";
    const rows = TICKET_ROWS.filter((r) => !p.filtered || r.epic === "Phase 3b");
    const bar = '<div class="tk-bar">' +
      '<button type="button" class="popup sz-sm" aria-haspopup="listbox"><span class="popup-label"><span>View</span><span>All open' + (p.filtered ? '<i class="unsaved" title="This view has changes that are not saved"></i>' : "") + "</span></span>" + icon("updown", "chev") + "</button>" +
      '<span class="sep"></span>' + (p.filtered ? fchip("<span>Epic is</span> <b>Phase 3b</b>", "filtered") : "") +
      '<button type="button" class="menu-btn sz-sm quiet"' + (p.filtered ? "" : ' data-toggle="filtered" data-key="add-filter"') + ">" + icon("plus") + "Filter</button>" +
      (p.filtered ? button({ label: "Save View", variant: "quiet", size: "small" }) : "") +
      '<span class="grow"></span><span class="tk-count">' + rows.length + " tickets</span>" +
      '<button type="button" class="menu-btn sz-sm" aria-haspopup="menu">' + icon("columns") + "Columns" + icon("chevron-down", "chev") + "</button>" +
      iconBtn("inspector", p.inspector ? "Hide the details" : "Show the details", { toggle: "inspector", on: p.inspector, size: "sm" }) + "</div>";
    const th = (label, cls, sorted) => "<th" + (cls ? ' class="' + cls + '"' : "") + (sorted ? ' aria-sort="descending"' : "") + '><button type="button">' + label + (sorted ? icon("sort-down", "sort") : "") + "</button></th>";
    const table = '<table class="table tk-table"><thead><tr>' + th("Ticket") + th("Title") + th("Repo", "col-wide") + th("Epic") + th("Situation") + th("Since", "num", true) + th("Labels", "col-wide") + th("Priority") + "</tr></thead><tbody>" +
      rows.map((r, i) => '<tr class="role-' + r.role + '"' + (i === sel ? ' aria-selected="true"' : "") + ' data-set="ticketRow=' + (i === sel ? -1 : i) + '" data-key="tk-' + i + '">' +
        "<td><b>" + esc(r.ident) + '</b></td><td class="tk-title">' + esc(r.title) + '</td><td class="col-wide">' + chip({ kind: "repo", text: r.repo, interactive: false }) + "</td><td>" + (r.epic ? chip({ kind: "epic", text: r.epic, interactive: false }) : '<span class="muted">None</span>') + "</td>" +
        '<td class="tk-sit">' + situation({ role: r.role, word: r.word, cause: r.cause, compact: true }) + '</td><td class="num">' + esc(r.since) + '</td><td class="col-wide">' + (r.labels.map((l) => chip({ kind: "label", text: l[0], role: l[1], interactive: false })).join(" ") || '<span class="muted">None</span>') + "</td>" +
        '<td class="' + (r.priority === "Urgent" ? "tk-urgent" : "") + '">' + esc(r.priority) + "</td></tr>").join("") + "</tbody></table>";
    const r = rows[sel];
    const inspector = !p.inspector ? "" : '<aside class="panel tk-inspector">' + (!r ? '<p class="empty-line">Pick a ticket to see where it stands.</p>' :
      '<div class="idline"><span class="ident">' + esc(r.ident) + "</span>" + chip({ kind: "repo", text: r.repo, interactive: false }) + (r.epic ? chip({ kind: "epic", text: r.epic, interactive: false }) : "") + "</div>" +
      '<h3 class="tk-name">' + esc(r.title) + "</h3>" + situation({ role: r.role, word: r.word, cause: r.cause }) +
      '<dl class="facts"><dt>Since</dt><dd>' + esc(r.since) + '</dd><dt>Phase</dt><dd>' + esc(r.role === "you" ? "In Progress" : r.word === "Code Review" ? "Code Review" : r.role === "idle" ? "Todo" : "In Progress") + "</dd><dt>Pull request</dt><dd>" + (r.role === "idle" ? "None yet" : "PR #812 · 14 files") + "</dd><dt>Priority</dt><dd>" + esc(r.priority) + "</dd><dt>Tokens</dt><dd>" + (r.role === "idle" ? "0" : "1.8M of 8M") + "</dd></dl>" +
      '<div class="tk-moves">' + button({ label: "Open Ticket", variant: "primary", size: "medium", key: "open-ticket" }).replace("<button", '<button data-toggle="ticketOpen"') + button({ label: "Force…", variant: "secondary", size: "medium", glyph: "forced" }) + "</div>") + "</aside>";
    return '<div class="tk' + (p.inspector ? " with-inspector" : "") + '"><div class="tk-main">' + bar + '<section class="panel tk-wrap">' + table + "</section></div>" + inspector + "</div>";
  }

  /* ---------- The window: sidebar, toolbar, status bar and background around a page ---------- */

  const DESTINATIONS = [
    { id: "home", label: "Home", glyph: "home", key: "⌘ 1", count: 2, role: "you" },
    { id: "journal", label: "Journal", glyph: "journal", key: "⌘ 2" },
    { id: "work", label: "Work", glyph: "grid", key: "⌘ 3" },
    { id: "insights", label: "Insights", glyph: "chart", key: "⌘ 4" },
    { id: "factory", label: "Factory", glyph: "factory", key: "⌘ 5", count: 2, role: "problem", children: [
      { id: "setup", label: "Setup", glyph: "wrench" }, { id: "repos", label: "Repos", glyph: "repo" },
      { id: "diagnostics", label: "Diagnostics", glyph: "pulse" }, { id: "settings", label: "Settings", glyph: "gear" }] },
  ];

  function navRow(d, p, child) {
    const here = p.dest === d.id;
    const count = d.count ? '<span class="count' + " role-" + esc(d.role) + '" aria-label="' + d.count + ' waiting">' + d.count + "</span>" : "";
    return '<button type="button" class="nav-row' + (child ? " child" : "") + (p.navHover === d.id && !here ? " is-hover" : "") + '"' + (here ? ' aria-current="page"' : "") +
      ' data-set="dest=' + esc(d.id) + '" data-key="nav-' + esc(d.id) + '" title="' + esc(d.label + (d.key ? "  " + d.key.replace(" ", "") : "")) + '">' +
      icon(d.glyph) + '<span class="label">' + esc(d.label) + "</span>" + count + "</button>";
  }

  function winSidebar(p) {
    const rows = DESTINATIONS.map((d) => navRow(d, p) + (d.children ? d.children.map((c) => navRow(c, p, true)).join("") : "")).join("");
    return '<aside class="win-side" aria-label="Destinations"><div class="win-lights" aria-hidden="true"><i></i><i></i><i></i></div>' +
      '<nav class="win-nav">' + rows + "</nav></aside>";
  }

  const dispatchControl = (p) => '<button type="button" class="dispatch" title="Dispatch: pause or resume starting new runs"><span class="dot role-' + (p.paused ? "you" : "done") + (p.paused ? "" : " live") + '"></span><span>' +
    (p.paused ? "Dispatch paused" : "Dispatch on") + "</span>" + icon("chevron-down", "chev") + "</button>";

  const iconBtn = (glyph, label, o) => '<button type="button" class="icon-btn sz-' + ((o && o.size) || "md") + '" aria-label="' + esc(label) + '" title="' + esc(label) + '"' +
    (o && o.toggle ? ' aria-pressed="' + !!o.on + '" data-toggle="' + esc(o.toggle) + '" data-key="ib-' + esc(o.toggle) + '"' : "") + (o && o.disabled ? ' aria-disabled="true"' : "") + ">" + icon(glyph) + "</button>";

  function winToolbar(p) {
    const onTicket = p.dest === "work" && !!p.ticketOpen;
    const tabs = p.dest === "work" && !p.ticketOpen ? segmented(["Initiatives", "Tickets"], p.workTab, { size: "small", prop: "workTab", anim: "worktab", label: "Work shows" }) : "";
    const place = (DESTINATIONS.concat(DESTINATIONS[4].children).find((d) => d.id === p.dest) || {}).label || "Home";
    const crumbs = '<nav class="win-crumbs" aria-label="Where you are">' + (onTicket ?
      '<a class="win-crumb" href="#" onclick="return false">Work</a>' + icon("chevron-right") + '<a class="win-crumb" href="#" onclick="return false">' + icon("epic") + "Phase 3b</a>" + icon("chevron-right") + '<span class="here">' + esc(p.ident) + "</span>" :
      '<span class="here">' + esc(place) + "</span>") + "</nav>";
    const search = '<div class="field sz-sm win-search"><div class="input search">' + icon("search") + '<input type="search" aria-label="Find a ticket" placeholder="Find a ticket">' + kbd("⌘ F") + "</div></div>";
    const inbox = '<span class="with-count">' + iconBtn("tray", "Inbox: 2 need you", { toggle: "inboxOpen", on: p.inboxOpen }) + '<span class="count role-you">2</span></span>';
    return '<header class="win-bar" role="toolbar" aria-label="Window">' +
      iconBtn("sidebar", p.collapsed ? "Show the sidebar" : "Hide the sidebar", { toggle: "collapsed", on: false }) +
      '<span class="nav-pair">' + (onTicket ? iconBtn("chevron-left", "Back  ⌘[").replace("<button", '<button data-toggle="ticketOpen" data-key="back"') : iconBtn("chevron-left", "Back  ⌘[")) + iconBtn("chevron-right", "Forward  ⌘]", { disabled: true }) + "</span>" +
      '<span class="sep"></span>' + crumbs + tabs +
      '<span class="grow"></span>' + search + inbox + iconBtn("refresh", "Refresh  ⌘R") + "</header>";
  }

  function winStatus(p) {
    return '<footer class="win-status">' + dispatchControl(p) + '<span class="sep"></span><span>7 in progress</span><span>18 in the queue</span><span>2 need you</span>' +
      '<span class="grow"></span><span class="build">Symphony 0.0.1.926</span><span class="dot-label"><span class="dot role-done"></span><span>Connected</span></span></footer>';
  }

  function windowShell(p) {
    const body = p.dest === "home" ? homePage(p) :
      p.dest === "work" ? (p.ticketOpen ? ticketPage(p) : Number(p.workTab) ? ticketsPage(p) : initiativesPage(p)) :
      '<div class="empty"><span class="glyph-wrap">' + icon("doc") + "</span><h3>" + esc((DESTINATIONS.concat(DESTINATIONS[4].children).find((d) => d.id === p.dest) || {}).label) + '</h3><p>This page has its own section. The window around it is what this story shows.</p></div>';
    return '<div class="win' + (p.collapsed ? " side-collapsed" : "") + (p.focused ? "" : " unfocused") + '">' +
      winSidebar(p) + '<div class="win-main">' + winToolbar(p) + '<div class="win-body">' + frame(body) + "</div>" + winStatus(p) + "</div></div>";
  }

  sections.push({
    title: "Window",
    wide: true,
    args: Object.assign({}, sections[0].args, { dest: "work", workTab: 0, ticketOpen: false, epic: "TP-1381", allRows: false, filtered: false, inspector: false, ticketRow: -1, role: "working", collapsed: false, focused: true, paused: false, inboxOpen: false, navHover: "" }),
    controls: [
      { name: "dest", label: "Destination", type: "select", options: [{ value: "home", label: "Home (the board)" }, { value: "work", label: "Work (a ticket page)" }, { value: "journal", label: "Journal" }, { value: "insights", label: "Insights" }, { value: "factory", label: "Factory" }, { value: "settings", label: "Factory › Settings" }] },
      { name: "workTab", label: "Work shows", type: "select", options: [{ value: 0, label: "Initiatives" }, { value: 1, label: "Tickets" }], when: (p) => p.dest === "work" },
      { name: "ticketOpen", label: "A ticket is open", type: "toggle", when: (p) => p.dest === "work" },
      { name: "chainOpen", label: "A long chain shown whole", type: "select", options: [{ value: "", label: "None" }, { value: "TP-1481", label: "TP-1481’s" }], when: (p) => p.dest === "home" },
      { name: "briefOpen", label: "Brief read in full", type: "toggle" },
      { name: "noBrief", label: "No run has written a brief yet", type: "toggle" },
      { name: "note", label: "A message sent to the ticket", type: "select", options: [{ value: "none", label: "None" }, { value: "written", label: "Sent, not read yet" }, { value: "read", label: "Read by a run" }] },
      { name: "noteDraft", label: "A message is being typed", type: "toggle" },
      { name: "decisions", label: "Decisions recorded", type: "toggle" },
      { name: "more", label: "More menu open", type: "toggle" },
      { name: "allRows", label: "Every sub-ticket shown", type: "toggle", when: (p) => p.dest === "work" && !p.ticketOpen && !Number(p.workTab) },
      { name: "filtered", label: "A filter is on", type: "toggle", when: (p) => p.dest === "work" && !p.ticketOpen && !!Number(p.workTab) },
      { name: "inspector", label: "Details beside the table", type: "toggle", when: (p) => p.dest === "work" && !p.ticketOpen && !!Number(p.workTab) },
      { name: "collapsed", label: "Sidebar collapsed", type: "toggle" },
      { name: "focused", label: "Window focused", type: "toggle" },
      { name: "paused", label: "Dispatch paused", type: "toggle" },
    ],
    render: (p) => windowShell(p),
    docs: {
      what: "The window around every page: the sidebar with the five destinations, the toolbar, the status line and the background the page sits on. The Director draws all of it; macOS draws only the three window buttons.",
      when: ["The sidebar holds destinations, never actions. A count beside a destination is coloured only for what waits on the Director (orange) or a problem (red).", "The toolbar holds what is true on every page: show or hide the sidebar, back and forward, where you are, Find a ticket, the Inbox and Refresh. Where you are is a breadcrumb, never the page's title: the page's own header carries that. On Work the Initiatives and Tickets switch sits right after it. Any other control a page needs lives in the page.", "The status line says whether Symphony dispatches and how many tickets are in each state; the dispatch control pauses and resumes."],
      responsive: ["Laptop (1440 × 900 window): the sidebar is 232 pt, the page gets about 1180 pt.", "Desktop (2460 × 1360 window): the same sidebar; the page gets about 2200 pt and uses its desktop layout.", "Collapsed, the sidebar is 60 pt of glyphs with their counts as dots; the names are the help text."],
      motion: "The sidebar folds on the fold spring. The selection slides from the old destination to the new one. The toolbar and the status line are glass: the page scrolls under them.",
      tokens: ["--surface-window", "--backdrop-glow", "--material-glass", "--stroke-separator", "--accent-tint", "--control-md", "--radius-control-md", "icon button, search field, count badge and status dot tokens"],
      access: "The sidebar is a navigation landmark; the current destination is announced as the current page. ⌘1 to ⌘5 pick a destination, ⌘F finds a ticket, ⌘[ and ⌘] go back and forward.",
    },
    stories: [
      { name: "Ticket page, laptop", viewport: "laptop", args: { dest: "work", ticketOpen: true } },
      { name: "Initiatives, laptop", viewport: "laptop", args: { dest: "work", workTab: 0 } },
      { name: "Initiatives, every sub-ticket", viewport: "laptop", args: { dest: "work", workTab: 0, allRows: true } },
      { name: "Tickets, laptop", viewport: "laptop", args: { dest: "work", workTab: 1 } },
      { name: "Tickets, filtered, with the details", viewport: "laptop", args: { dest: "work", workTab: 1, filtered: true, inspector: true, ticketRow: 0 } },
      { name: "Tickets, desktop", viewport: "desktop", args: { dest: "work", workTab: 1, inspector: true, ticketRow: 2 } },
      { name: "Initiatives, desktop", viewport: "desktop", args: { dest: "work", workTab: 0 } },
      { name: "Home, laptop", viewport: "laptop", args: { dest: "home" } },
      { name: "Home, a long chain shown whole", viewport: "laptop", args: { dest: "home", chainOpen: "TP-1481" } },
      { name: "Home, desktop", viewport: "desktop", args: { dest: "home" } },
      { name: "Ticket page, desktop", viewport: "desktop", args: { dest: "work", ticketOpen: true, role: "you" } },
      { name: "Sidebar collapsed", viewport: "laptop", args: { collapsed: true, ticketOpen: true } },
      { name: "Window not focused", viewport: "laptop", args: { focused: false, ticketOpen: true } },
      { name: "Dispatch paused", viewport: "laptop", args: { paused: true, dest: "home" } },
    ],
  });

  return {
    esc: esc,
    ROLE_OPTIONS: ROLE_OPTIONS,
    /* The building blocks, for pages built from the catalog (the prototypes under docs/design/prototypes) */
    kit: { esc: esc, icon: icon, refusal: refusal, ownWords: ownWords, tlEntry: tlEntry, ROLES: ROLES, TL: TL, button: button, badge: badge, kbd: kbd, situation: situation, chip: chip, fold: fold, kv: kv, tags: tags, option: option, steps: steps, miniSteps: miniSteps, stageBar: stageBar, phasePath: phasePath, stepList: stepList },
    groups: [
      { id: "tokens", title: "Tokens", items: tokens },
      { id: "components", title: "Components", items: components },
      { id: "sections", title: "Sections", items: sections },
    ],
  };
})();
