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
    grip: '<circle cx="5" cy="3.5" r=".9" fill="currentColor"/><circle cx="11" cy="3.5" r=".9" fill="currentColor"/><circle cx="5" cy="8" r=".9" fill="currentColor"/><circle cx="11" cy="8" r=".9" fill="currentColor"/><circle cx="5" cy="12.5" r=".9" fill="currentColor"/><circle cx="11" cy="12.5" r=".9" fill="currentColor"/>',
  };
  const icon = (n, c) => '<svg class="glyph' + (c ? " " + c : "") + '" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + I[n] + "</svg>";
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const $ = (s) => document.querySelector(s);
  const PHASES = ["Coding", "Code Review", "QA", "Merging", "Done"];
  const RH = 36;

  /* The first rows are the factory's real tickets on 2026-11-21. The rest are generated to show the list at scale. */
  const T = (ident, title, o) => Object.assign({ ident, title, repo: ident.startsWith("MOT") ? "cycle" : ident.startsWith("HUB") ? "hub" : "symphony" }, o || {});
  let slots = [
    T("TP-1576", "Rebuild the Settings page's sections from the design-system Gallery components", { at: 2, part: 55, role: "working", word: "QA", now: "walking the Settings sections, check 6 of 9", epic: "Settings as a real page", plan: "Each Settings section is rebuilt from Gallery components: rows, toggles, number fields and the save bar. No section keeps a hand-built control, and every setting keeps its binding and its validation.", proved: 5, total: 9, next: "The Runs section saves a changed model and shows Saved.", pr: "#1041", files: "38 files · +1,412 −986", branch: "auto/TP-1576 into main", ci: ["done", "18 checks passed"], review: ["done", "Approved on 507db3b"], runs: [["Coding", "9.6M", "s1"], ["Code Review", "3.1M", "s2"], ["QA", "8.7M", "s3"]], tokens: "21.4M", pct: 21, since: "2 h 40 min" }),
    T("TP-1594", "A QA pass walks the checks that share a screen and state in one session", { at: 1, part: 70, role: "you", word: "Waiting on you", now: "may a grouped step hold more than six checks?", plan: "The plan of a pass groups the checks that share a screen and state, and each group is walked in one session. Every check keeps its own result and its own evidence.", proved: 8, total: 9, next: "The timeline shows each check of a grouped step with its own result.", pr: "#1043", files: "11 files · +524 −61", branch: "auto/TP-1594 into main", ci: ["done", "17 checks passed"], review: ["you", "Review asked a question"], runs: [["Coding", "7.9M", "s1"], ["Code Review", "1.9M", "s2"]], tokens: "9.8M", pct: 10, since: "48 min" }),
  ];
  let queue = [
    T("TP-1590", "App updates stop the factory for most of an hour when several tickets merge in a row", { state: "Code Review", pr: "#1038" }),
    T("TP-1592", "A check that needs the pull request's own CI run is proved between handoff and merge", { state: "Code Review", pr: "#1042" }),
    T("TP-1593", "QA judges the cursor by sight from an image around the pointer", { state: "Coding", parent: "TP-1572" }),
    T("TP-1595", "Mac app QA checks only the target: dark appearance at the big 2560×1440 window", { state: "Coding" }),
    T("TP-1596", "An answer that says “back to Code Review unchanged” moves the ticket there", { state: "Coding", stopped: true }),
    T("TP-1597", "A real queue: a slot belongs to one ticket until it is done"),
    T("TP-976", "Record every protected-change request and its answer as ticket events", { you: "Needs your approval" }),
    T("TP-977", "Give agents one tool to request a protected change, and pause the ticket on it", { after: "TP-976" }),
    T("TP-978", "Allow or decline a protected change from the control API", { after: "TP-977" }),
    T("TP-979", "Let github_push_branch and github_sync_base accept exactly the granted change", { after: "TP-976" }),
    T("TP-980", "Pass CI's protected-paths check on a Symphony-signed grant attestation", { after: "TP-979" }),
    T("TP-981", "Show protected-change requests in the Inbox and on the ticket page", { after: "TP-978" }),
    T("TP-984", "Describe each protected file and its risk in plain words", { after: "TP-976" }),
    T("TP-985", "Settings: files that can never be allowed, and how long an Allow lasts", { after: "TP-976" }),
    T("TP-986", "Signal a waiting permission in the menu bar and with a notification", { after: "TP-981" }),
    T("TP-1051", "Keep a record of each background update check that survives a relaunch"),
    T("MOT-106", "Show the ride's elevation profile under the map"),
    T("MOT-107", "Pause a ride automatically when the bike stops for a minute", { after: "MOT-106" }),
    T("HUB-212", "Group follow-ups by company on the outreach page"),
    T("HUB-213", "Mark a job as stale when its posting disappears"),
  ];
  const V = ["Show", "Keep", "Let", "Draw", "Sort", "Remember", "Stop", "Explain", "Group", "Read", "Name", "Open", "Carry", "Check"];
  const O = ["the timeline's filters", "a run's token use", "the Inbox's undo", "each repo's last merge", "the ticket page's facts rail", "a stopped run's reason", "the release notes", "a QA pass's evidence", "the status menu's counts", "a saved filter", "the journal's day headings", "a ride's splits", "the outreach calendar", "a company's contacts"];
  const W = ["after a relaunch", "in one line", "without a second poll", "when the window is narrow", "from the keyboard", "the moment it changes", "for every repo", "on the first open", "beside its ticket", "in the Director's words"];
  const P = [["TP", 1600], ["MOT", 110], ["HUB", 215]];
  for (let i = 0; i < 1223; i++) {
    const p = P[i % 7 === 3 ? 1 : i % 11 === 5 ? 2 : 0];
    queue.push(T(p[0] + "-" + (p[1] + i), V[i % V.length] + " " + O[(i * 5 + 3) % O.length] + " " + W[(i * 3 + 1) % W.length]));
  }
  let view = "all", drag = null, noneReady = false, toastTimer = 0;
  const VIEWS = [
    { id: "all", label: "All tickets", test: () => true },
    { id: "ready", label: "Ready", test: (t) => ready(t) },
    { id: "started", label: "Started", test: (t) => !!t.state },
    { id: "you", label: "Needs you", test: (t) => !!t.you },
    { id: "symphony", label: "Symphony", test: (t) => t.repo === "symphony" },
    { id: "cycle", label: "Cycle", test: (t) => t.repo === "cycle" },
  ];
  const open = (ident) => slots.some((s) => s && s.ident === ident) || queue.some((q) => q.ident === ident);
  const ready = (t) => !(t.after && open(t.after)) && !t.you;
  const shown = () => { const f = VIEWS.find((v) => v.id === view).test; const out = []; queue.forEach((t, i) => { if (f(t)) out.push({ t, n: i + 1 }); }); return out; };

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
  /* A free slot goes to a sub-ticket of something in progress first, then to the first ready ticket in order. */
  function fill() {
    if (noneReady) return;
    const parents = slots.filter(Boolean).map((s) => s.ident);
    slots.forEach((s, i) => {
      if (s) return;
      let k = queue.findIndex((t) => ready(t) && t.parent && parents.includes(t.parent));
      if (k < 0) k = queue.findIndex(ready);
      if (k >= 0) slots[i] = enter(queue.splice(k, 1)[0]);
    });
  }
  function start(ident, i) {
    const k = queue.findIndex((t) => t.ident === ident); if (k < 0) return;
    if (i == null) { i = slots.findIndex((s) => !s); if (i < 0) i = slots.length - 1; }
    const t = queue.splice(k, 1)[0], was = slots[i];
    slots[i] = enter(t);
    if (was) { queue.unshift(leave(was)); toast(t.ident + " took slot " + (i + 1) + ". " + was.ident + " stopped and is first in the queue."); }
    else toast(t.ident + " took slot " + (i + 1) + ".");
    render();
  }
  function setSlots(n) {
    n = Math.max(1, Math.min(6, n));
    while (slots.length > n) { const t = slots.pop(); if (t) { queue.unshift(leave(t)); toast(t.ident + " stopped and is first in the queue."); } }
    const grew = slots.length < n;
    while (slots.length < n) slots.push(null);
    render();
    if (grew) setTimeout(() => { fill(); render(); }, 650);
  }

  const fact = (f) => '<div class="prfact"><span class="dot role-' + f[0] + (f[0] === "working" ? " live" : "") + '"></span><span>' + esc(f[1]) + "</span></div>";
  function card(t, i) {
    if (!t) return '<div class="slot empty" data-slot="' + i + '"><span>Slot ' + (i + 1) + "</span></div>";
    const nowWord = t.role === "you" ? "Waiting on you" : t.role === "problem" ? "Needs attention" : "Now";
    const ph = PHASES.map((p, k) => k < t.at
      ? '<div class="lstep passed"><div class="bar"></div><div class="nm">' + icon("done") + "<span>" + p + '</span></div><div class="st">Passed</div></div>'
      : k === t.at ? '<div class="lstep current role-' + t.role + '"><div class="bar"><b style="width:' + t.part + '%"></b></div><div class="nm">' + icon(t.role === "you" ? "you" : "now") + "<span>" + p + '</span></div><div class="st">' + nowWord + "</div></div>"
      : '<div class="lstep later"><div class="bar"></div><div class="nm">' + icon("clock") + "<span>" + p + '</span></div><div class="st">Not yet</div></div>').join("");
    const ref = t.epic || (t.parent ? t.parent.split(" · ")[0] : "");
    const legend = '<ul class="stage-legend">' + t.runs.map((r) => '<li><span class="key stage-seg ' + r[2] + '"></span>' + esc(r[0]) + ' <span class="v">' + esc(r[1]) + "</span></li>").join("") + "</ul>";
    return '<article class="slot role-' + t.role + (t.fresh ? " arrive" : "") + '" data-slot="' + i + '" tabindex="0" aria-label="Slot ' + (i + 1) + ": " + esc(t.ident) + '">' +
      '<header class="slot-head"><span class="dot role-' + t.role + (t.role === "working" ? " live" : "") + '"></span><span class="ident">' + esc(t.ident) + '</span><h3 class="slot-title">' + esc(t.title) + "</h3>" +
      (ref ? '<span class="chip">' + icon("epic") + esc(ref) + "</span>" : "") + '<span class="grow"></span><span class="since">' + esc(t.since) + ' in the slot</span><span class="slot-acts">' +
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
      "</div></div></article>";
  }
  const mini = (t, i) => !t ? '<div class="mslot empty" data-slot="' + i + '">Slot ' + (i + 1) + "</div>" :
    '<div class="mslot role-' + t.role + '" data-slot="' + i + '"><span class="lead"><span class="dot role-' + t.role + (t.role === "working" ? " live" : "") + '"></span></span><span class="ident">' + esc(t.ident) + '</span><span class="title">' + esc(t.title) + '</span><span class="badge badge-sm role-' + t.role + '">' + esc(t.word) + '</span><span class="since">' + esc(t.since) + "</span></div>";
  function rowHtml(e, top) {
    const t = e.t, held = t.after && open(t.after);
    const role = t.you ? "you" : t.state ? "working" : "idle";
    const lead = t.you ? icon("you") : t.stopped ? icon("pause") : t.state ? '<span class="dot role-working"></span>' : icon("clock");
    const trail = (held ? '<span class="q-after" title="Starts when ' + esc(t.after) + ' lands">' + icon("arrow") + esc(t.after) + "</span>" : "") +
      (t.you ? '<span class="badge badge-sm role-you">' + esc(t.you) + "</span>" : "") +
      (t.state ? '<span class="badge badge-sm role-idle">' + (t.stopped ? "Stopped in " : "") + esc(t.state) + "</span>" : "") +
      '<span class="end"><span class="repo">' + esc(t.repo) + '</span><button type="button" class="btn sz-sm start" data-start="' + esc(t.ident) + '">Start</button></span>';
    return '<div role="option" tabindex="0" class="row role-' + role + '" style="top:' + top + 'px" data-id="' + esc(t.ident) + '"' + (view === "all" ? ' draggable="true"' : "") + '>' +
      '<span class="pos"><span class="n">' + e.n.toLocaleString("en-US") + '</span><span class="grip">' + icon("grip") + '</span></span><span class="lead">' + lead + "</span>" +
      '<span class="main"><span class="line1"><span class="ident">' + esc(t.ident) + '</span><span class="title">' + esc(t.title) + '</span></span></span><span class="trail">' + trail + "</span></div>";
  }
  let list = [];
  function paint() {
    const body = $(".win-body"), v = $(".vlist"); if (!v) return;
    const top = body.scrollTop - v.offsetTop;
    const a = Math.max(0, Math.floor(top / RH) - 10), b = Math.min(list.length, Math.ceil((top + body.clientHeight) / RH) + 10);
    let h = "";
    for (let k = a; k < b; k++) h += rowHtml(list[k], k * RH);
    v.innerHTML = h;
    const last = list[Math.min(list.length, Math.max(1, Math.ceil((top + body.clientHeight) / RH))) - 1];
    $(".pq").style.setProperty("--pos-w", Math.max(2, last ? last.n.toLocaleString("en-US").length : 2) + "ch");
    $(".pq-mini").classList.toggle("on", body.scrollTop > $(".pq-queue").offsetTop - 24);
  }
  function render() {
    list = shown();
    const used = slots.filter(Boolean).length;
    $("#slots").innerHTML = slots.map(card).join("");
    $("#mini").innerHTML = slots.map(mini).join("");
    slots.forEach((s) => { if (s) delete s.fresh; });
    $("#slotsOut").textContent = slots.length + (slots.length === 1 ? " slot" : " slots");
    $("#less").disabled = slots.length <= 1; $("#more").disabled = slots.length >= 6;
    $("#qcount").textContent = queue.length.toLocaleString("en-US");
    $("#views").innerHTML = VIEWS.map((x) => '<button type="button" class="fview" aria-pressed="' + (x.id === view) + '" data-view="' + x.id + '">' + x.label + "<b>" + queue.filter(x.test).length.toLocaleString("en-US") + "</b></button>").join("");
    const v = $(".vlist"); v.style.height = list.length * RH + "px"; v.classList.toggle("filtered", view !== "all");
    $("#st").innerHTML = "<span>" + used + " in progress</span><span>" + queue.length.toLocaleString("en-US") + " in the queue</span><span>" + (queue.filter((t) => t.you).length + slots.filter((s) => s && s.role === "you").length) + " need you</span>";
    paint();
  }

  document.addEventListener("click", (e) => {
    const s = e.target.closest("[data-start]"); if (s) { start(s.dataset.start); return; }
    const st = e.target.closest("[data-stop]");
    if (st) { const i = +st.dataset.stop, t = slots[i]; slots[i] = null; queue.unshift(leave(t)); toast(t.ident + " stopped and is first in the queue."); render(); setTimeout(() => { fill(); render(); }, 650); return; }
    const vw = e.target.closest("[data-view]"); if (vw) { view = vw.dataset.view; $(".win-body").scrollTop = Math.min($(".win-body").scrollTop, $(".pq-queue").offsetTop - $(".pq-mini > div").offsetHeight); render(); return; }
    if (e.target.closest("#less")) setSlots(slots.length - 1);
    if (e.target.closest("#more")) setSlots(slots.length + 1);
  });
  $("#none").addEventListener("change", (e) => { noneReady = e.target.checked; if (!noneReady) { fill(); render(); } });
  $(".win-body").addEventListener("scroll", () => requestAnimationFrame(paint), { passive: true });
  addEventListener("resize", paint);

  /* Drag a queue row: onto another row to reorder, onto a slot to start it there. */
  const line = document.createElement("div"); line.className = "drop-line"; let target = -1;
  document.addEventListener("dragstart", (e) => { const r = e.target.closest && e.target.closest(".vlist .row"); if (!r || view !== "all") return; drag = r.dataset.id; e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", drag); requestAnimationFrame(() => r.classList.add("dragging")); });
  document.addEventListener("dragover", (e) => {
    if (!drag) return;
    const slot = e.target.closest && e.target.closest("[data-slot]");
    document.querySelectorAll(".drop").forEach((x) => x !== slot && x.classList.remove("drop"));
    if (slot) { e.preventDefault(); slot.classList.add("drop"); line.remove(); target = -1; return; }
    const v = $(".vlist"), box = v.getBoundingClientRect();
    if (e.clientY < box.top - 20 || e.clientX < box.left || e.clientX > box.right) { line.remove(); target = -1; return; }
    e.preventDefault();
    target = Math.max(0, Math.min(queue.length, Math.round((e.clientY - box.top) / RH)));
    line.style.top = target * RH + "px"; if (line.parentNode !== v) v.appendChild(line);
    const body = $(".win-body"), bb = body.getBoundingClientRect();
    if (e.clientY > bb.bottom - 48) body.scrollTop += 14; else if (e.clientY < bb.top + $(".pq-mini > div").offsetHeight + 36) body.scrollTop -= 14;
  });
  document.addEventListener("drop", (e) => {
    if (!drag) return; e.preventDefault();
    const slot = e.target.closest && e.target.closest("[data-slot]");
    if (slot) start(drag, +slot.dataset.slot);
    else if (target >= 0) {
      const from = queue.findIndex((t) => t.ident === drag);
      const t = queue.splice(from, 1)[0], to = target > from ? target - 1 : target;
      queue.splice(to, 0, t); if (to !== from) toast(t.ident + " is now number " + (to + 1) + " in the queue.");
    }
    drag = null; target = -1; line.remove(); render();
  });
  document.addEventListener("dragend", () => { drag = null; target = -1; line.remove(); document.querySelectorAll(".drop").forEach((x) => x.classList.remove("drop")); paint(); });

  const nav = [["home", "Home", 1], ["journal", "Journal"], ["grid", "Work"], ["chart", "Insights"], ["factory", "Factory"]];
  $(".win-nav").innerHTML = nav.map((n) => '<button type="button" class="nav-row"' + (n[2] ? ' aria-current="page"' : "") + ">" + icon(n[0]) + '<span class="label">' + n[1] + "</span>" + (n[2] ? '<span class="count role-you">2</span>' : "") + "</button>").join("");
  document.querySelectorAll("[data-icon]").forEach((el) => { el.innerHTML = icon(el.dataset.icon) + el.innerHTML; });
  render();
})();
