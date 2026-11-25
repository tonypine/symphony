(() => {
  const I = {
    home: '<path d="M2.5 7.5 8 2.8l5.5 4.7v6H9.9V9.8H6.1v3.7H2.5z"/>',
    journal: '<rect x="3" y="2" width="10" height="12" rx="1.5"/><path d="M5.8 5.5h4.4M5.8 8h4.4M5.8 10.5h2.6"/>',
    grid: '<rect x="2.5" y="2.5" width="4.5" height="4.5" rx="1"/><rect x="9" y="2.5" width="4.5" height="4.5" rx="1"/><rect x="2.5" y="9" width="4.5" height="4.5" rx="1"/><rect x="9" y="9" width="4.5" height="4.5" rx="1"/>',
    chart: '<path d="M2.5 13.5h11"/><path d="m3 10.5 3.2-3.6 2.6 2.2L13 4"/>',
    factory: '<path d="M2.5 13.5V7l3.5 2V7l3.5 2V3.5h3v10z"/><path d="M5 11.2h1.2M8.2 11.2h1.2"/>',
    sidebar: '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M6 3v10"/>',
    clock: '<circle cx="8" cy="8" r="6.3"/><path d="M8 4.5V8l2.5 1.5"/>',
    down: '<path d="m4 6 4 4 4-4"/>', left: '<path d="m10 4-4 4 4 4"/>', right: '<path d="m6 4 4 4-4 4"/>',
    search: '<circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3.5 3.5"/>',
    epic: '<path d="M3.5 14.5V2.5M3.5 3h8.5l-1.8 3 1.8 3H3.5"/>',
    arrow: '<path d="M2.5 8h10M9 4.5 12.5 8 9 11.5"/>',
    tray: '<path d="M2 9.5 3.8 3h8.4L14 9.5V13H2z"/><path d="M2 9.5h3.5l1 1.5h3l1-1.5H14"/>',
    refresh: '<path d="M13 2v2.8h-2.8"/><path d="M12.9 4.6A5.5 5.5 0 1 0 13.5 8"/>',
    plus: '<path d="M8 3v10M3 8h10"/>', minus: '<path d="M3 8h10"/>',
    pause: '<circle cx="8" cy="8" r="6.3"/><path d="M6.5 5.8v4.4M9.5 5.8v4.4"/>',
    you: '<circle cx="8" cy="5.5" r="2.6"/><path d="M3 13.5c.6-2.6 2.6-4 5-4s4.4 1.4 5 4"/>',
    pr: '<circle cx="4" cy="3.6" r="1.6"/><circle cx="4" cy="12.4" r="1.6"/><circle cx="12" cy="12.4" r="1.6"/><path d="M4 5.2v5.6M12 10.8V7a2.4 2.4 0 0 0-2.4-2.4H7.4M9 2.8 7.2 4.6 9 6.4"/>',
    working: '<circle cx="8" cy="8" r="6.3" stroke-dasharray="2 2.4"/><circle cx="8" cy="8" r="2" fill="currentColor" stroke="none"/>',
    stop: '<rect x="2.5" y="2.5" width="11" height="11" rx="2.5" fill="currentColor" stroke="none"/>',
    done: '<circle cx="8" cy="8" r="6.6" fill="currentColor" stroke="none"/><path d="m5.1 8.3 2 2 3.8-4.3" stroke="var(--surface-content)" stroke-width="1.7"/>',
    now: '<circle cx="8" cy="8" r="6.2"/><circle cx="8" cy="8" r="2.7"/>',
    elbow: '<path d="M8 0.5v5a2.5 2.5 0 0 0 2.5 2.5h5"/>',
    flag: '<path d="M3.5 14V2.5M3.5 3h8.5l-1.8 3 1.8 3H3.5"/>',
    grip: '<circle cx="5" cy="3.5" r=".9" fill="currentColor"/><circle cx="11" cy="3.5" r=".9" fill="currentColor"/><circle cx="5" cy="8" r=".9" fill="currentColor"/><circle cx="11" cy="8" r=".9" fill="currentColor"/><circle cx="5" cy="12.5" r=".9" fill="currentColor"/><circle cx="11" cy="12.5" r=".9" fill="currentColor"/>',
  };
  const icon = (n, c) => '<svg class="glyph' + (c ? " " + c : "") + '" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + I[n] + "</svg>";
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const $ = (s) => document.querySelector(s);
  const PHASES = ["Coding", "Code Review", "QA", "Merging", "Done"];
  const RH = 36;

  /* The first rows are the factory's real tickets on 2026-11-21. The rest are generated to show the list at scale. */
  const T = (ident, title, o) => Object.assign({ ident, title, repo: ident.startsWith("MOT") ? "cycle" : ident.startsWith("HUB") ? "hub" : "symphony" }, o || {});
  const D = (ident, title, pr, when, o) => Object.assign({ ident, title, pr, when, repo: ident.startsWith("MOT") ? "cycle" : ident.startsWith("HUB") ? "hub" : "symphony" }, o || {});
  const EPIC = { ident: "TP-1597", title: "A real queue: a slot belongs to one ticket until it is done, and Home is the window to the queue", repo: "symphony", done: 7, of: 14, since: "3 d", kids: [], doneList: [
    D("TP-1622", "Engine: the queue's order is stored as one sort key per ticket", "#1053", "20 min ago"),
    D("TP-1606", "Engine: a ticket without a slot does not react to anything", "#1052", "3 h ago"),
    D("TP-1616", "Config: remove finishing_max, max_by_issue_state and epic_lanes from symphony.yml", "#1050", "4 h ago"),
    D("TP-1615", "Engine: a slot belongs to one ticket until it is done", "#1049", "5 h ago"),
    D("TP-1608", "Gallery: the Home queue components", "#1046", "yesterday"),
    D("TP-1612", "Engine: the queue has a stored order", "#1048", "yesterday"),
    D("TP-1611", "Engine: remove the force label, the forced queue and the forced allowance", "#1047", "yesterday"),
  ] };
  /* What finished in the last 7 days, most recent first; `today` marks what finished since local midnight. */
  let done = [
    D("TP-1622", "Engine: the queue's order is stored as one sort key per ticket", "#1053", "20 min ago", { epic: "TP-1597", today: 1 }),
    D("MOT-104", "Record a ride's track while the screen is off", "#88", "1 h ago", { epic: "MOT-105", today: 1 }),
    D("TP-1606", "Engine: a ticket without a slot does not react to anything", "#1052", "3 h ago", { epic: "TP-1597", today: 1 }),
    D("TP-1616", "Config: remove finishing_max, max_by_issue_state and epic_lanes from symphony.yml", "#1050", "4 h ago", { epic: "TP-1597", today: 1 }),
    D("TP-1615", "Engine: a slot belongs to one ticket until it is done", "#1049", "5 h ago", { epic: "TP-1597", today: 1 }),
    D("TP-1608", "Gallery: the Home queue components", "#1046", "yesterday", { epic: "TP-1597" }),
    D("HUB-211", "Show the date of the last reply on each application", "#340", "yesterday"),
    D("TP-1612", "Engine: the queue has a stored order", "#1048", "yesterday", { epic: "TP-1597" }),
    D("TP-1611", "Engine: remove the force label, the forced queue and the forced allowance", "#1047", "yesterday", { epic: "TP-1597" }),
    D("TP-1603", "Reading a config starts no file watcher; the app watches only its settings folders", "#1045", "yesterday"),
    D("MOT-103", "Keep the map centred on the rider while a ride is recording", "#87", "Sat"),
    D("TP-1591", "The release gate runs as three parallel jobs", "#1040", "Sat"),
    D("TP-1589", "A pull request merges only when every check of its plan is proved", "#1037", "Fri"),
    D("HUB-210", "Keep a job's notes when its posting changes", "#338", "Fri"),
    D("TP-1588", "Grooming writes no check that can only be proved after the merge", "#1036", "Thu"),
    D("MOT-102", "Show speed and distance in the rider's own units", "#86", "Thu"),
  ];
  let slots = [
    T("TP-1619", "Engine: one queue of top-level tickets with sort keys, sub-tickets inside their parent, explicit dependencies", { wrap: EPIC, at: 0, part: 62, role: "working", word: "Coding", now: "tests and coverage, round 2", plan: "The queue's order becomes one sort key per ticket, sub-tickets live inside their parent, and a dependency is a fact Symphony stores. Linear's blocker links are no longer read.", proved: 3, total: 11, next: "Adding a dependency on a lower ticket moves the depending ticket just below it.", runs: [["Coding", "14.2M", "s1"]], tokens: "14.2M", pct: 14, since: "1 h 5 min" }),
    T("TP-1594", "A QA pass walks the checks that share a screen and state in one session", { at: 1, part: 70, role: "you", word: "Waiting on you", now: "may a grouped step hold more than six checks?", plan: "The plan of a pass groups the checks that share a screen and state, and each group is walked in one session. Every check keeps its own result and its own evidence.", proved: 8, total: 9, next: "The timeline shows each check of a grouped step with its own result.", pr: "#1043", files: "11 files · +524 −61", branch: "auto/TP-1594 into main", ci: ["done", "17 checks passed"], review: ["you", "Review asked a question"], runs: [["Coding", "7.9M", "s1"], ["Code Review", "1.9M", "s2"]], tokens: "9.8M", pct: 10, since: "48 min" }),
  ];
  EPIC.kids = [
    T("TP-1623", "Engine: explicit dependencies stored by Symphony replace Linear's blocker links"),
    T("TP-1624", "Engine: a parent uses a spare slot for its next sub-ticket that can start", { after: "TP-1623" }),
    T("TP-1607", "Engine and API: Start shifts the queue, the queue can be reordered, and Home reads slots and a paged queue", { after: "TP-1619" }),
    T("TP-1609", "Home: slot cards stuck at the top and the whole queue below, with filters and infinite scroll", { after: "TP-1607" }),
    T("TP-1610", "Home: drag and drop reorders the queue, and dragging a ticket onto a slot starts it", { after: "TP-1609" }),
    T("TP-1620", "Initiatives: list a parent because Symphony split it, from Symphony's own record", { after: "TP-1610" }),
  ];
  let queue = [
    T("TP-1590", "App updates stop the factory for most of an hour when several tickets merge in a row", { state: "Code Review", pr: "#1038" }),
    T("TP-1592", "A check that needs the pull request's own CI run is proved between handoff and merge", { state: "Code Review", pr: "#1042" }),
    T("TP-1593", "QA judges the cursor by sight from an image around the pointer", { state: "Coding" }),
    T("TP-1595", "Mac app QA checks only the target: dark appearance at the big 2560×1440 window", { state: "Coding" }),
    T("TP-1596", "An answer that says “back to Code Review unchanged” moves the ticket there", { state: "Coding", stopped: true }),
    T("TP-975", "Protected-change requests: ask, allow, record", { done: 2, of: 11, open: true, doneList: [D("TP-983", "Read the list of protected paths from one place", "#611", "3 d ago"), D("TP-982", "Name the files a change may never touch", "#598", "last week")], kids: [
      T("TP-976", "Record every protected-change request and its answer as ticket events", { you: "Needs your approval" }),
      T("TP-977", "Give agents one tool to request a protected change, and pause the ticket on it", { after: "TP-976" }),
      T("TP-978", "Allow or decline a protected change from the control API", { after: "TP-977" }),
      T("TP-979", "Let github_push_branch and github_sync_base accept exactly the granted change", { after: "TP-976" }),
      T("TP-980", "Pass CI's protected-paths check on a Symphony-signed grant attestation", { after: "TP-979" }),
      T("TP-981", "Show protected-change requests in the Inbox and on the ticket page", { after: "TP-978" }),
      T("TP-984", "Describe each protected file and its risk in plain words", { after: "TP-976" }),
      T("TP-985", "Settings: files that can never be allowed, and how long an Allow lasts", { after: "TP-976" }),
      T("TP-986", "Signal a waiting permission in the menu bar and with a notification", { after: "TP-981" }),
    ] }),
    T("TP-1051", "Keep a record of each background update check that survives a relaunch", { after: "TP-1590", kind: "released" }),
    T("MOT-105", "Ride recording: pause, resume and recover a ride", { done: 1, of: 4, open: false, doneList: [D("MOT-104", "Record a ride's track while the screen is off", "#88", "1 h ago")], kids: [
      T("MOT-106", "Show the ride's elevation profile under the map"),
      T("MOT-107", "Pause a ride automatically when the bike stops for a minute", { after: "MOT-106" }),
      T("MOT-108", "Recover a ride the app was closed in the middle of"),
    ] }),
    T("HUB-212", "Group follow-ups by company on the outreach page"),
    T("HUB-213", "Mark a job as stale when its posting disappears", { after: "HUB-212" }),
  ];
  const V = ["Show", "Keep", "Let", "Draw", "Sort", "Remember", "Stop", "Explain", "Group", "Read", "Name", "Open", "Carry", "Check"];
  const O = ["the timeline's filters", "a run's token use", "the Inbox's undo", "each repo's last merge", "the ticket page's facts rail", "a stopped run's reason", "the release notes", "a QA pass's evidence", "the status menu's counts", "a saved filter", "the journal's day headings", "a ride's splits", "the outreach calendar", "a company's contacts"];
  const W = ["after a relaunch", "in one line", "without a second poll", "when the window is narrow", "from the keyboard", "the moment it changes", "for every repo", "on the first open", "beside its ticket", "in the Director's words"];
  const P = [["TP", 1700], ["MOT", 110], ["HUB", 215]];
  for (let i = 0; i < 1223; i++) {
    const p = P[i % 7 === 3 ? 1 : i % 11 === 5 ? 2 : 0];
    queue.push(T(p[0] + "-" + (p[1] + i), V[i % V.length] + " " + O[(i * 5 + 3) % O.length] + " " + W[(i * 3 + 1) % W.length]));
  }
  let view = "all", drag = null, noneReady = false, toastTimer = 0;
  const FORCE = {};
  let recentOpen = true, range = "today";
  try { recentOpen = localStorage.getItem("home.recent.open") !== "0"; if (localStorage.getItem("home.recent.range") === "week") range = "week"; } catch (e) { /* no storage: open, today */ }
  const keep = (k, v) => { try { localStorage.setItem(k, v); } catch (e) { /* not kept */ } };
  const VIEWS = [
    { id: "all", label: "All tickets", test: () => true },
    { id: "ready", label: "Ready", test: (t) => ready(t) },
    { id: "started", label: "Started", test: (t) => !!t.state },
    { id: "you", label: "Needs you", test: (t) => !!t.you },
    { id: "symphony", label: "Symphony", test: (t) => t.repo === "symphony" },
    { id: "cycle", label: "Cycle", test: (t) => t.repo === "cycle" },
  ];
  const each = (f) => { slots.forEach((s) => { if (s) { f(s); if (s.wrap) s.wrap.kids.forEach(f); } }); queue.forEach((t) => { f(t); if (t.kids) t.kids.forEach(f); }); };
  const open = (ident) => { let hit = false; each((t) => { if (t.ident === ident) hit = true; }); return hit; };
  const unmet = (t) => !!(t.after && open(t.after));
  const ready = (t) => (t.kids ? t.kids.some(ready) : !unmet(t) && !t.you);
  const wrapsOf = (e) => slots.filter((s) => s && s.wrap === e).length;
  /* The queue as rows: one per top-level ticket, an open epic followed by its open sub-tickets. */
  const shown = () => {
    const f = VIEWS.find((v) => v.id === view).test, out = [];
    queue.forEach((t, i) => {
      if (!t.kids) { if (f(t)) out.push({ t, n: i + 1, k: 0, top: i }); return; }
      const kids = t.kids.map((c, k) => ({ c, k })).filter((x) => f(x.c));
      if (!kids.length && !f(t)) return;
      out.push({ t, n: i + 1, k: 0, top: i });
      if (!t.open) return;
      if (t.showDone) t.doneList.forEach((d) => out.push({ d, n: i + 1, k: null, top: i, parent: t }));
      kids.forEach((x) => out.push({ t: x.c, n: i + 1, k: x.k + 1, top: i, kid: x.k, parent: t }));
    });
    return out;
  };
  const tickets = () => queue.reduce((n, t) => n + (t.kids ? t.kids.length : 1), 0);

  function toast(msg) {
    const old = $(".ptoast"); if (old) old.remove();
    const el = document.createElement("div"); el.className = "ptoast"; el.setAttribute("role", "status"); el.textContent = msg; $(".win").appendChild(el);
    clearTimeout(toastTimer); toastTimer = setTimeout(() => el.remove(), 4200);
  }
  function enter(t) {
    const at = Math.max(0, PHASES.indexOf(t.state || "Coding"));
    return Object.assign(t, { at, part: 12, role: "working", word: PHASES[at], now: t.state ? "picks up where it stopped" : "the first coding run is starting", since: "just now", tokens: t.tokens || "0", pct: t.pct || 0, runs: t.runs || [],
      plan: t.plan || "Grooming planned it as one ticket: the change, its tests, and one check seen in the running app.", proved: t.proved || 0, total: t.total || 5, next: t.next || "The first check of the plan.",
      files: t.files || (t.pr ? "9 files · +310 −44" : ""), branch: t.branch || "auto/" + t.ident + " into main", ci: t.pr ? ["working", "Checks running"] : null, review: t.pr ? ["idle", "Review waits for CI"] : null, stopped: false, fresh: true });
  }
  function leave(t) { t.state = PHASES[t.at]; t.stopped = true; delete t.fresh; return t; }
  /* A ticket that leaves its slot goes back to the head of the queue; a sub-ticket goes back to the head of its epic,
     and the epic returns to the queue once it holds no slot. */
  function back(s) {
    const e = s.wrap; leave(s); delete s.wrap;
    if (!e) { queue.unshift(s); return s.ident + " stopped and is first in the queue."; }
    e.kids.unshift(s);
    if (wrapsOf(e)) return s.ident + " stopped and is first in " + e.ident + ".";
    e.open = true; queue.unshift(e); return s.ident + " stopped. " + e.ident + " is first in the queue.";
  }
  const take = (list, k) => list.splice(k, 1)[0];
  /* A free slot goes, in queue order, to the first ticket that can start. An epic that already holds a slot comes
     first with its next sub-ticket whose dependencies are met. */
  function fill() {
    if (noneReady) return;
    slots.forEach((s, i) => {
      if (s) return;
      const held = [...new Set(slots.filter((x) => x && x.wrap).map((x) => x.wrap))];
      for (const e of held) { const k = e.kids.findIndex(ready); if (k >= 0) { slots[i] = Object.assign(enter(take(e.kids, k)), { wrap: e }); return; } }
      const q = queue.findIndex(ready); if (q < 0) return;
      const t = queue[q];
      if (!t.kids) { slots[i] = enter(take(queue, q)); return; }
      const k = t.kids.findIndex(ready); take(queue, q);
      slots[i] = Object.assign(enter(take(t.kids, k)), { wrap: t }); t.since = "just now";
    });
  }
  function find(ident) {
    for (let q = 0; q < queue.length; q++) {
      if (queue[q].ident === ident) return { q, t: queue[q] };
      const k = queue[q].kids ? queue[q].kids.findIndex((c) => c.ident === ident) : -1;
      if (k >= 0) return { q, k, t: queue[q].kids[k], parent: queue[q] };
    }
    for (let i = 0; i < slots.length; i++) {
      const e = slots[i] && slots[i].wrap, k = e ? e.kids.findIndex((c) => c.ident === ident) : -1;
      if (k >= 0) return { slot: i, k, t: e.kids[k], parent: e };
    }
    return null;
  }
  function start(ident, i) {
    let at = find(ident); if (!at) return;
    if (at.t.kids) { const k = at.t.kids.findIndex((c) => !unmet(c)); if (k < 0) { toast(at.t.ident + " has no sub-ticket that can start yet."); return; } at = { q: at.q, k, t: at.t.kids[k], parent: at.t }; }
    if (unmet(at.t)) { toast(at.t.ident + " depends on " + at.t.after + " and can’t start before it is " + (at.t.kind === "released" ? "released" : "done") + "."); return; }
    if (at.slot != null) {
      /* A sub-ticket of an epic that holds a slot takes over from the one in work, which goes back to the head of the epic. */
      const e = at.parent, cur = slots[at.slot], t = take(e.kids, at.k);
      leave(cur); delete cur.wrap; e.kids.unshift(cur);
      slots[at.slot] = Object.assign(enter(t), { wrap: e });
      toast(t.ident + " took slot " + (at.slot + 1) + ". " + cur.ident + " stopped and is first in " + e.ident + ".");
      render(); return;
    }
    if (i == null) { i = slots.findIndex((s) => !s); if (i < 0) i = slots.length - 1; }
    const was = slots[i], t = at.t, e = at.parent;
    if (e) { take(e.kids, at.k); take(queue, at.q); e.since = "just now"; } else take(queue, at.q);
    slots[i] = null;
    const note = was ? " " + back(was) : "";
    slots[i] = Object.assign(enter(t), e ? { wrap: e } : {});
    toast(t.ident + " took slot " + (i + 1) + "." + note);
    render();
  }
  function finish(i) {
    const s = slots[i]; if (!s) return; const e = s.wrap;
    const d = D(s.ident, s.title, s.pr || "#1054", "just now", { epic: e ? e.ident : null, fresh: true });
    d.today = 1; done.unshift(d); slots[i] = null;
    if (e) { e.done++; e.doneList.unshift(d); const k = e.kids.findIndex((c) => !unmet(c)); if (k >= 0 && !wrapsOf(e)) slots[i] = Object.assign(enter(take(e.kids, k)), { wrap: e }); }
    toast(s.ident + " is done." + (slots[i] ? " " + slots[i].ident + " took slot " + (i + 1) + "." : ""));
    render(); if (!slots[i]) setTimeout(() => { fill(); render(); }, 650);
  }
  function setSlots(n) {
    n = Math.max(1, Math.min(6, n));
    while (slots.length > n) { const t = slots.pop(); if (t) toast(back(t)); }
    const grew = slots.length < n;
    while (slots.length < n) slots.push(null);
    render();
    if (grew) setTimeout(() => { fill(); render(); }, 650);
  }

  const fact = (f) => '<div class="prfact"><span class="dot role-' + f[0] + (f[0] === "working" ? " live" : "") + '"></span><span>' + esc(f[1]) + "</span></div>";
  function card(t, i) {
    if (!t) return '<div class="slot empty" data-slot="' + i + '"><span>Slot ' + (i + 1) + "</span></div>";
    const e = t.wrap;
    const nowWord = t.role === "you" ? "Waiting on you" : t.role === "problem" ? "Needs attention" : "Now";
    const ph = PHASES.map((p, k) => k < t.at
      ? '<div class="lstep passed"><div class="bar"></div><div class="nm">' + icon("done") + "<span>" + p + '</span></div><div class="st">Passed</div></div>'
      : k === t.at ? '<div class="lstep current role-' + t.role + '"><div class="bar"><b style="width:' + t.part + '%"></b></div><div class="nm">' + icon(t.role === "you" ? "you" : "now") + "<span>" + p + '</span></div><div class="st">' + nowWord + "</div></div>"
      : '<div class="lstep later"><div class="bar"></div><div class="nm">' + icon("clock") + "<span>" + p + '</span></div><div class="st">Not yet</div></div>').join("");
    const legend = '<ul class="stage-legend">' + t.runs.map((r) => '<li><span class="key stage-seg ' + r[2] + '"></span>' + esc(r[0]) + ' <span class="v">' + esc(r[1]) + "</span></li>").join("") + "</ul>";
    const band = e ? '<div class="epic-band" role="button" tabindex="0" aria-expanded="' + !!e.showUp + '" data-band="' + i + '"><span class="twist">' + icon(e.showUp ? "down" : "right") + '</span><span class="lead">' + icon("flag") + '</span><span class="ident">' + esc(e.ident) + '</span><span class="title">' + esc(e.title) + '</span><span class="grow"></span>' +
      '<button type="button" class="cbar b-done" data-bdone="' + i + '" aria-expanded="' + !!e.showDone + '"><i><b style="width:' + Math.round(100 * e.done / e.of) + '%"></b></i><span>' + e.done + " of " + e.of + ' done</span></button><span class="since">' + esc(e.since) + " in the slot</span></div>" +
      (e.showDone ? '<div class="dlist">' + e.doneList.slice().reverse().map((d) => doneRow(d, { pr: 1, lead: '<span class="pos"></span>' })).join("") + "</div>" : "") : "";
    const after = e && e.showUp && e.kids.length ? '<div class="ulist" data-ulist="' + i + '">' + e.kids.map((c, k) => rowHtml({ t: c, n: e.done + 2 + k, k: 0, kid: k, parent: e }, null)).join("") +
      (FORCE.uline != null ? '<div class="drop-line" style="top:' + FORCE.uline * RH + 'px"></div>' : "") + "</div>" : "";
    const inner =
      '<header class="slot-head"><span class="dot role-' + t.role + (t.role === "working" ? " live" : "") + '"></span><span class="ident">' + esc(t.ident) + '</span><h3 class="slot-title">' + esc(t.title) + "</h3>" +
      '<span class="grow"></span><span class="since">' + esc(t.since) + (e ? " on this ticket" : " in the slot") + '</span><span class="slot-acts">' +
      (t.role === "you" ? '<button type="button" class="btn btn-primary sz-sm">Answer…</button>' : "") + '<button type="button" class="btn sz-sm">Message…</button><button type="button" class="icon-btn sz-sm" data-stop="' + i + '" aria-label="Stop" title="Stop">' + icon("stop") + "</button></span></header>" +
      '<div class="slot-body">' +
      '<div class="slot-col"><h4 class="zone-title">Status</h4><div class="lsteps">' + ph + "</div>" +
      '<div class="tokline">' + legend + '<span class="total"><b>' + esc(t.tokens) + "</b> of 100M tokens · " + t.pct + " %</span></div>" +
      '<div><div class="situation situation-pill role-' + t.role + '">' + icon(t.role === "you" ? "you" : "working") + '<span class="word">' + esc(t.word) + '</span><span class="cause">' + esc(t.now) + "</span></div></div></div>" +
      '<div class="slot-col"><h4 class="zone-title">Plan</h4><p class="slot-plan">' + esc(t.plan) + "</p>" +
      '<div class="cbar"><i><b style="width:' + Math.round(100 * t.proved / t.total) + '%"></b></i><span>' + t.proved + " of " + t.total + " checks proved</span></div>" +
      '<p class="slot-next">Next<span>' + esc(t.next) + "</span></p></div>" +
      '<div class="slot-col"><h4 class="zone-title">Pull request</h4>' +
      (t.pr ? '<div class="prbox"><a class="pr-line" href="#" onclick="return false">' + icon("pr", "pr-glyph") + '<span class="pr-name">PR ' + esc(t.pr) + '</span></a><span class="sub">' + esc(t.files) + '</span><span class="sub mono">' + esc(t.branch) + "</span></div>" + fact(t.ci) + fact(t.review)
        : '<div class="prbox"><span class="sub">Not opened yet</span></div><div></div><div></div>') +
      "</div></div>";
    const cls = "slot role-" + t.role + (t.fresh ? " arrive" : ""), label = 'tabindex="0" aria-label="Slot ' + (i + 1) + ": " + esc(t.ident) + (e ? ", part of " + esc(e.ident) : "") + '"';
    return e ? '<article class="eslot' + (t.fresh ? " arrive" : "") + '" data-slot="' + i + '" ' + label + ">" + band + '<div class="' + cls + '">' + inner + "</div>" + after + "</article>"
      : '<article class="' + cls + '" data-slot="' + i + '" ' + label + ">" + inner + "</article>";
  }
  /* A done ticket, one line: check, identifier, title, then what the place asks for (its epic, its pull request, its repo) and when. */
  const doneRow = (d, o) => '<div class="row drow' + (o.fresh ? " arrive" : "") + '"' + (o.style ? ' style="' + o.style + '"' : "") + ' tabindex="0">' + (o.lead || "") + '<span class="lead">' + icon("done") + '</span>' +
    '<span class="main"><span class="line1"><span class="ident">' + esc(d.ident) + '</span><span class="title">' + esc(d.title) + '</span></span></span><span class="trail">' +
    (o.epic && d.epic ? '<span class="q-epic">' + icon("flag") + esc(d.epic) + "</span>" : "") + (o.pr ? '<span class="q-pr">' + icon("pr") + esc(d.pr) + "</span>" : "") +
    (o.repo ? '<span class="repo-c">' + esc(d.repo) + "</span>" : "") + '<span class="when">' + esc(d.when) + "</span></span></div>";
  const mini = (t, i) => !t ? '<div class="mslot empty" data-slot="' + i + '">Slot ' + (i + 1) + "</div>" :
    '<div class="mslot role-' + t.role + '" data-slot="' + i + '"><span class="lead"><span class="dot role-' + t.role + (t.role === "working" ? " live" : "") + '"></span></span><span class="ident">' + esc(t.ident) + '</span><span class="title">' + esc(t.title) + "</span>" +
    (t.wrap ? '<span class="q-epic">' + icon("flag") + esc(t.wrap.ident) + "</span>" : "") + '<span class="badge badge-sm role-' + t.role + '">' + esc(t.word) + '</span><span class="since">' + esc(t.since) + "</span></div>";
  function rowHtml(e, top) {
    if (e.d) return doneRow(e.d, { style: "top:" + top + "px", lead: '<span class="pos"></span><span class="elbow">' + icon("elbow") + "</span>" }).replace('class="row drow', 'class="row drow sub' + (FORCE.drag && e.parent.ident === FORCE.drag ? " dragging" : ""));
    const t = e.t, epic = !!t.kids, held = unmet(t);
    const role = t.you ? "you" : t.state ? "working" : "idle";
    const lead = epic ? '<button type="button" class="twist" data-twist="' + esc(t.ident) + '" aria-expanded="' + !!t.open + '" aria-label="' + (t.open ? "Hide" : "Show") + " the sub-tickets of " + esc(t.ident) + '">' + icon(t.open ? "down" : "right") + "</button>"
      : t.you ? icon("you") : t.stopped ? icon("pause") : t.state ? '<span class="dot role-working"></span>' : icon("clock");
    const trail = (epic ? '<button type="button" class="q-done" data-done="' + esc(t.ident) + '" aria-expanded="' + !!(t.open && t.showDone) + '">' + t.done + " of " + t.of + " done</button>" : "") +
      (held ? '<span class="q-after" title="Starts when ' + esc(t.after) + (t.kind === "released" ? " is released" : " is done") + '">' + icon("arrow") + esc(t.after) + (t.kind === "released" ? " released" : "") + "</span>" : "") +
      (t.you ? '<span class="badge badge-sm role-you">' + esc(t.you) + "</span>" : "") +
      (t.state ? '<span class="badge badge-sm role-idle">' + (t.stopped ? "Stopped in " : "") + esc(t.state) + "</span>" : "") +
      '<span class="end"><span class="repo">' + esc(t.repo) + '</span><button type="button" class="btn sz-sm start" data-start="' + esc(t.ident) + '">Start</button></span>';
    const st = FORCE.hover === t.ident ? " hov" : "", dr = FORCE.drag === t.ident || (FORCE.drag && top != null && e.parent && e.parent.ident === FORCE.drag) ? " dragging" : "";
    const place = top == null ? "" : ' style="top:' + top + 'px"', canDrag = top == null || view === "all";
    return '<div role="option" tabindex="0" class="row role-' + role + (e.k ? " sub" : "") + (epic ? " epic" : "") + st + dr + '"' + place + ' data-id="' + esc(t.ident) + '"' + (canDrag ? ' draggable="true"' : "") + '>' +
      '<span class="pos"><span class="n" style="--d:' + e.n.toLocaleString("en-US").length + '"><b>' + e.n.toLocaleString("en-US") + "</b><i>" + (e.k ? "." + e.k : "") + '</i></span><span class="grip">' + icon("grip") + '</span></span>' + (e.k ? '<span class="elbow">' + icon("elbow") + "</span>" : "") + '<span class="lead">' + lead + "</span>" +
      '<span class="main"><span class="line1"><span class="ident">' + esc(t.ident) + '</span><span class="title">' + esc(t.title) + '</span></span></span><span class="trail">' + trail + "</span></div>";
  }
  let list = [];
  const line = document.createElement("div"); line.className = "drop-line";
  function paint() {
    const body = $(".win-body"), v = $(".vlist"); if (!v) return;
    const top = body.scrollTop - v.offsetTop;
    const a = Math.max(0, Math.floor(top / RH) - 10), b = Math.min(list.length, Math.ceil((top + body.clientHeight) / RH) + 10);
    let h = "", nw = 2, kw = 0;
    for (let k = a; k < b; k++) h += rowHtml(list[k], k * RH);
    v.innerHTML = h;
    const lo = Math.max(0, Math.floor(top / RH)), hi = Math.min(list.length, Math.max(1, Math.ceil((top + body.clientHeight) / RH)));
    for (let k = lo; k < hi; k++) { nw = Math.max(nw, list[k].n.toLocaleString("en-US").length); if (list[k].k) kw = Math.max(kw, String(list[k].k).length + 0.5); }
    const pq = $(".pq"); pq.style.setProperty("--int-w", nw + "ch"); pq.style.setProperty("--frac-w", kw + "ch"); pq.style.setProperty("--pos-w", nw + kw + "ch");
    $(".pq-mini").classList.toggle("on", body.scrollTop > $(".pq-queue").offsetTop - 24);
    if (FORCE.line != null) { line.style.top = FORCE.line * RH + "px"; line.classList.toggle("sub", !!FORCE.sub); v.appendChild(line); }
  }
  function render() {
    list = shown();
    const used = slots.filter(Boolean).length, count = (f) => { let n = 0; queue.forEach((t) => { if (t.kids) t.kids.forEach((c) => { if (f(c)) n++; }); else if (f(t)) n++; }); return n; };
    const recent = range === "week" ? done : done.filter((d) => d.today), rc = $(".pq-recent"), rows = recentOpen && recent.length;
    rc.hidden = !done.length; rc.classList.toggle("shut", !rows);
    $("#rcount").textContent = recent.length || ""; $("#rtwist").innerHTML = icon(recentOpen ? "down" : "right"); $("#rtwist").setAttribute("aria-expanded", recentOpen);
    $("#range").style.setProperty("--i", range === "week" ? 1 : 0); document.querySelectorAll("#range .segment").forEach((b) => b.setAttribute("aria-checked", b.dataset.range === range));
    $("#rlist").hidden = !rows; $("#rlist").innerHTML = rows ? recent.map((d) => doneRow(d, { epic: 1, pr: 1, repo: 1, fresh: d.fresh })).join("") : "";
    done.forEach((d) => { delete d.fresh; });
    $("#slots").innerHTML = slots.map(card).join("");
    $("#mini").innerHTML = slots.map(mini).join("");
    slots.forEach((s) => { if (s) delete s.fresh; });
    document.querySelectorAll(".eslot .dlist").forEach((el) => { el.scrollTop = el.scrollHeight; });
    $("#slotsOut").textContent = slots.length + (slots.length === 1 ? " slot" : " slots");
    $("#less").disabled = slots.length <= 1; $("#more").disabled = slots.length >= 6;
    $("#qcount").textContent = tickets().toLocaleString("en-US");
    $("#views").innerHTML = VIEWS.map((x) => '<button type="button" class="fview" aria-pressed="' + (x.id === view) + '" data-view="' + x.id + '">' + x.label + "<b>" + count(x.test).toLocaleString("en-US") + "</b></button>").join("");
    const v = $(".vlist"); v.style.height = list.length * RH + "px"; v.classList.toggle("filtered", view !== "all");
    $("#st").innerHTML = "<span>" + used + " in progress</span><span>" + tickets().toLocaleString("en-US") + " in the queue</span><span>" + (count((t) => !!t.you) + slots.filter((s) => s && s.role === "you").length) + " need you</span>";
    paint();
  }

  document.addEventListener("click", (e) => {
    const s = e.target.closest("[data-start]"); if (s) { start(s.dataset.start); return; }
    const st = e.target.closest("[data-stop]");
    if (st) { const i = +st.dataset.stop, t = slots[i]; slots[i] = null; toast(back(t)); render(); setTimeout(() => { fill(); render(); }, 650); return; }
    const vw = e.target.closest("[data-view]"); if (vw) { view = vw.dataset.view; $(".win-body").scrollTop = Math.min($(".win-body").scrollTop, $(".pq-queue").offsetTop - $(".pq-mini > div").offsetHeight); render(); return; }
    const dn = e.target.closest("[data-done]"); if (dn) { const t = find(dn.dataset.done).t; if (t.open && t.showDone) t.showDone = false; else { t.open = true; t.showDone = true; } render(); return; }
    const tw = e.target.closest(".vlist .row.epic"); if (tw) { const t = find(tw.dataset.id).t; t.open = !t.open; render(); return; }
    const bn = e.target.closest("[data-bdone]"); if (bn) { const w = slots[+bn.dataset.bdone].wrap; w.showDone = !w.showDone; render(); return; }
    const bd = e.target.closest("[data-band]"); if (bd) { const w = slots[+bd.dataset.band].wrap; w.showUp = !w.showUp; render(); return; }
    const rg = e.target.closest("[data-range]"); if (rg) { range = rg.dataset.range; keep("home.recent.range", range); render(); return; }
    if (e.target.closest(".pq-recent .pq-head")) { recentOpen = !recentOpen; keep("home.recent.open", recentOpen ? "1" : "0"); render(); return; }
    if (e.target.closest("#less")) setSlots(slots.length - 1);
    if (e.target.closest("#more")) setSlots(slots.length + 1);
  });
  $("#none").addEventListener("change", (e) => { noneReady = e.target.checked; if (!noneReady) { fill(); render(); } });
  $(".win-body").addEventListener("scroll", () => requestAnimationFrame(paint), { passive: true });
  addEventListener("resize", paint);

  /* Drag a queue row: onto another row to reorder, onto a slot to start it there. An epic moves with its sub-tickets;
     a sub-ticket moves only among its siblings. A move that would put a ticket above one it depends on is refused. */
  let target = -1;
  /* The gaps a dragged row may land in, as row indexes of the list: between top-level tickets for a top-level row,
     inside its parent's block for a sub-ticket. Each gap carries the place it stands for among the siblings. */
  function gaps(ident) {
    const at = find(ident), out = [];
    if (at.parent) { const first = list.findIndex((e) => e.parent === at.parent && e.kid != null); at.parent.kids.forEach((_, k) => out.push({ row: first + k, to: k })); out.push({ row: first + at.parent.kids.length, to: at.parent.kids.length }); }
    else { list.forEach((e, r) => { if (e.k === 0) out.push({ row: r, to: e.top }); }); out.push({ row: list.length, to: queue.length }); }
    return out;
  }
  /* Why a list can't hold `t` at place `to`, or nothing: a dependency points upward. */
  function refusal(items, from, to) {
    const next = items.slice(), t = take(next, from); next.splice(to > from ? to - 1 : to, 0, t);
    for (let a = 0; a < next.length; a++) for (let b = a + 1; b < next.length; b++) if (next[a].after === next[b].ident) return next[a].ident + " depends on " + next[b].ident + " and must stay below it.";
    return null;
  }
  function move(ident, to) {
    const at = find(ident), items = at.parent ? at.parent.kids : queue, from = at.parent ? at.k : at.q;
    const no = refusal(items, from, to); if (no) { toast(no); return; }
    const t = take(items, from), put = to > from ? to - 1 : to; items.splice(put, 0, t);
    if (put !== from) toast(t.ident + " is now number " + (at.slot != null ? at.parent.done + 2 + put : at.parent ? at.q + 1 + "." + (put + 1) : put + 1) + (at.parent ? " in " + at.parent.ident + "." : " in the queue."));
  }
  let inside = null;
  document.addEventListener("dragstart", (e) => {
    const r = e.target.closest && e.target.closest(".ulist .row"); if (!r) return;
    drag = r.dataset.id; inside = r.closest(".ulist"); e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", drag); requestAnimationFrame(() => r.classList.add("dragging"));
  });
  document.addEventListener("dragstart", (e) => { const r = e.target.closest && e.target.closest(".vlist .row"); if (!r || view !== "all") return; inside = null; drag = r.dataset.id; e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", drag); requestAnimationFrame(() => { r.classList.add("dragging"); const at = find(drag); if (at && at.t.kids) document.querySelectorAll(".vlist .row.sub[data-id]").forEach((x) => { const c = find(x.dataset.id); if (c && c.parent === at.t) x.classList.add("dragging"); }); }); });
  document.addEventListener("dragover", (e) => {
    if (!drag) return;
    if (inside) {
      const box = inside.getBoundingClientRect(), n = find(drag).parent.kids.length;
      if (e.clientY < box.top - 20 || e.clientY > box.bottom + 20 || e.clientX < box.left || e.clientX > box.right) { line.remove(); target = -1; return; }
      e.preventDefault(); target = Math.max(0, Math.min(n, Math.round((e.clientY - box.top + inside.scrollTop) / RH)));
      line.classList.remove("sub"); line.style.top = target * RH + "px"; if (line.parentNode !== inside) inside.appendChild(line);
      return;
    }
    const slot = e.target.closest && e.target.closest("[data-slot]");
    document.querySelectorAll(".drop").forEach((x) => x !== slot && x.classList.remove("drop"));
    if (slot) { e.preventDefault(); slot.classList.add("drop"); line.remove(); target = -1; return; }
    const v = $(".vlist"), box = v.getBoundingClientRect();
    if (e.clientY < box.top - 20 || e.clientX < box.left || e.clientX > box.right) { line.remove(); target = -1; return; }
    e.preventDefault();
    const y = (e.clientY - box.top) / RH, g = gaps(drag).reduce((best, x) => (Math.abs(x.row - y) < Math.abs(best.row - y) ? x : best));
    target = g.to; line.style.top = g.row * RH + "px"; line.classList.toggle("sub", !!find(drag).parent); if (line.parentNode !== v) v.appendChild(line);
    const body = $(".win-body"), bb = body.getBoundingClientRect();
    if (e.clientY > bb.bottom - 48) body.scrollTop += 14; else if (e.clientY < bb.top + $(".pq-mini > div").offsetHeight + 36) body.scrollTop -= 14;
  });
  document.addEventListener("drop", (e) => {
    if (!drag) return; e.preventDefault();
    if (inside) { if (target >= 0) move(drag, target); drag = null; inside = null; target = -1; line.remove(); render(); return; }
    const slot = e.target.closest && e.target.closest("[data-slot]");
    if (slot) start(drag, +slot.dataset.slot);
    else if (target >= 0) move(drag, target);
    drag = null; target = -1; line.remove(); render();
  });
  document.addEventListener("dragend", () => { drag = null; inside = null; target = -1; line.remove(); document.querySelectorAll(".drop").forEach((x) => x.classList.remove("drop")); paint(); });

  const nav = [["home", "Home", 1], ["journal", "Journal"], ["grid", "Work"], ["chart", "Insights"], ["factory", "Factory"]];
  $(".win-nav").innerHTML = nav.map((n) => '<button type="button" class="nav-row"' + (n[2] ? ' aria-current="page"' : "") + ">" + icon(n[0]) + '<span class="label">' + n[1] + "</span>" + (n[2] ? '<span class="count role-you">2</span>' : "") + "</button>").join("");
  document.querySelectorAll("[data-icon]").forEach((el) => { el.innerHTML = icon(el.dataset.icon) + el.innerHTML; });
  render();

  /* States forced from the address, for renders: ?scroll=420&hover=TP-977&drag=TP-977&line=9&toast=…&collapse=TP-975&rects=1 */
  if (location.search) {
    const q = new URLSearchParams(location.search);
    document.head.insertAdjacentHTML("beforeend", "<style>*,*::before,*::after{transition:none!important;animation:none!important}</style>");
    if (q.get("collapse")) q.get("collapse").split(",").forEach((id) => { const at = find(id); if (at) at.t.open = !at.t.open; });
    (q.get("do") || "").split(",").filter(Boolean).forEach((op) => { const p = op.split(":"); if (p[0] === "start") start(p[1], p[2] == null ? undefined : +p[2]); if (p[0] === "move") { move(p[1], +p[2]); render(); } if (p[0] === "stop") { const t = slots[+p[1]]; slots[+p[1]] = null; toast(back(t)); render(); } if (p[0] === "slots") setSlots(+p[1]); if (p[0] === "nodone") { done = []; render(); } if (p[0] === "notoday") { done = done.filter((d) => !d.today); render(); } if (p[0] === "range") { range = p[1]; render(); } if (p[0] === "finish") finish(+p[1]); if (p[0] === "band") { const w = slots[+p[1]].wrap; w.showUp = !w.showUp; render(); } if (p[0] === "bdone") { const w = slots[+p[1]].wrap; w.showDone = !w.showDone; render(); } if (p[0] === "done") { const t = find(p[1]).t; t.open = true; t.showDone = true; render(); } if (p[0] === "recent") { recentOpen = p[1] !== "0"; render(); } if (p[0] === "toggle") { const t = find(p[1]).t; t.open = !t.open; render(); } if (p[0] === "view") { view = p[1]; render(); } });
    FORCE.hover = q.get("hover"); FORCE.drag = q.get("drag"); if (q.get("uline")) FORCE.uline = +q.get("uline");
    render();
    if (q.get("scroll")) { $(".win-body").scrollTop = +q.get("scroll"); paint(); }
    if (q.get("rscroll")) $("#rlist").scrollTop = +q.get("rscroll");
    if (q.get("line")) { FORCE.line = +q.get("line"); FORCE.sub = q.get("sub") === "1"; paint(); }
    if (q.get("toast")) toast(q.get("toast"));
    clearTimeout(toastTimer);
    const probe = document.createElement("pre"); probe.id = "probe"; probe.hidden = true; probe.textContent = JSON.stringify({ toast: ($(".ptoast") || {}).textContent || "", slots: slots.map((s) => s && (s.wrap ? s.wrap.ident + ">" : "") + s.ident), recent: [range, $("#rcount").textContent].concat(done.slice(0, 2).map((d) => d.ident)), up: slots.map((s) => s && s.wrap ? s.wrap.done + "/" + s.wrap.of + " " + s.wrap.kids.map((c) => c.ident).join(" ") : null), rows: list.slice(0, 12).map((e) => e.d ? "done " + e.d.ident : e.n + (e.k ? "." + e.k : "") + " " + e.t.ident) }); document.body.appendChild(probe);
    if (q.get("rects")) {
      const r = {}; q.get("rects").split("|").forEach((sel) => { const el = document.querySelector(sel); if (el) { const b = el.getBoundingClientRect(); r[sel] = [Math.round(b.left), Math.round(b.top), Math.round(b.width), Math.round(b.height)]; } });
      const pre = document.createElement("pre"); pre.id = "rects"; pre.hidden = true; pre.textContent = JSON.stringify(r); document.body.appendChild(pre);
    }
  }
})();
