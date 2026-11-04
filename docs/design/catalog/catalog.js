/*
 * The catalog shell: sidebar tree, hash routing, toolbar, canvas, controls and docs.
 * Plain JavaScript, no framework. Stories come from stories.js (window.CATALOG).
 *
 * A link is #<group>/<component>/<story>, for example #components/button/primary-hover.
 * #<group>/<component>/docs opens the component's docs tab.
 */
(function () {
  "use strict";

  var C = window.CATALOG;
  var $ = function (id) { return document.getElementById(id); };
  var esc = C.esc;

  function slug(text) {
    return String(text).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  }

  /* ---------- Index every component and story ---------- */

  var index = {};
  var order = [];
  C.groups.forEach(function (group) {
    group.items.forEach(function (item) {
      item.id = item.id || slug(item.title);
      item.group = group;
      item.key = group.id + "/" + item.id;
      item.args = item.args || {};
      item.controls = item.controls || [];
      item.stories.forEach(function (story) {
        story.id = story.id || slug(story.name);
        story.args = story.args || {};
      });
      index[item.key] = item;
      order.push(item);
    });
  });

  /* ---------- Preferences (kept between visits when the browser allows it) ---------- */

  var PREFS_KEY = "director-design-catalog";
  var prefs = { theme: "system", viewport: "fit", background: "page", allStates: false };
  try {
    var saved = JSON.parse(window.localStorage.getItem(PREFS_KEY) || "{}");
    Object.keys(prefs).forEach(function (k) { if (k in saved) prefs[k] = saved[k]; });
  } catch (e) { /* storage unavailable on this file URL: defaults stay */ }

  function savePrefs() {
    try { window.localStorage.setItem(PREFS_KEY, JSON.stringify(prefs)); } catch (e) { /* not kept */ }
  }

  /* ---------- State ---------- */

  var current = { item: order[0], story: order[0].stories[0], view: "canvas" };
  var props = {};
  var expanded = {};
  var query = "";

  function storyProps(item, story) {
    var p = {};
    Object.keys(item.args).forEach(function (k) { p[k] = item.args[k]; });
    Object.keys(story.args).forEach(function (k) { p[k] = story.args[k]; });
    return p;
  }

  function hashFor(item, story, view) {
    return "#" + item.key + "/" + (view === "docs" ? "docs" : story.id);
  }

  /* ---------- Routing ---------- */

  function route() {
    var parts = window.location.hash.replace(/^#\/?/, "").split("/").filter(Boolean);
    var item = index[parts[0] + "/" + parts[1]];
    var missing = parts.length > 0 && !item;
    item = item || order[0];
    var view = parts[2] === "docs" ? "docs" : "canvas";
    var story = item.stories[0];
    if (parts[2] && view === "canvas") {
      var found = item.stories.filter(function (s) { return s.id === parts[2]; })[0];
      if (found) story = found; else missing = true;
    }
    current = { item: item, story: story, view: view };
    props = storyProps(item, story);
    expanded[item.key] = true;
    if (story.viewport && view === "canvas") prefs.viewport = story.viewport;
    if (missing) flash("No story at that link. Showing " + item.title + " / " + story.name + ".");
    renderAll();
  }

  function go(item, story, view) {
    var next = hashFor(item, story, view);
    if (window.location.hash === next) route(); else window.location.hash = next;
  }

  /* ---------- Sidebar ---------- */

  function mark(text) {
    var safe = esc(text);
    if (!query) return safe;
    var at = text.toLowerCase().indexOf(query);
    if (at < 0) return safe;
    return esc(text.slice(0, at)) + "<mark>" + esc(text.slice(at, at + query.length)) + "</mark>" + esc(text.slice(at + query.length));
  }

  var TWISTY = '<svg class="tw" viewBox="0 0 10 10" aria-hidden="true"><path d="M3 1.5 7 5l-4 3.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  function renderTree() {
    var html = "";
    var any = false;
    C.groups.forEach(function (group) {
      var items = "";
      group.items.forEach(function (item) {
        var titleHit = !query || item.title.toLowerCase().indexOf(query) >= 0;
        var stories = item.stories.filter(function (s) {
          return titleHit || s.name.toLowerCase().indexOf(query) >= 0;
        });
        if (!stories.length) return;
        any = true;
        var open = query ? true : !!expanded[item.key];
        var isCurrent = item === current.item;
        items += '<li class="tree-item"><button type="button" data-item="' + esc(item.key) + '" aria-expanded="' + open + '">' +
          TWISTY + "<span>" + mark(item.title) + '</span><span class="n">' + item.stories.length + "</span></button>";
        if (open) {
          items += "<ul>";
          items += '<li><a class="docs-link" href="' + esc(hashFor(item, null, "docs")) + '"' +
            (isCurrent && current.view === "docs" ? ' aria-current="page"' : "") + ">Docs</a></li>";
          stories.forEach(function (s) {
            var here = isCurrent && current.view === "canvas" && s === current.story;
            items += '<li><a href="' + esc(hashFor(item, s, "canvas")) + '"' + (here ? ' aria-current="page"' : "") + ">" + mark(s.name) + "</a></li>";
          });
          items += "</ul>";
        }
        items += "</li>";
      });
      if (items) html += '<section class="tree-group"><h2>' + esc(group.title) + "</h2><ul>" + items + "</ul></section>";
    });
    if (!any) html = '<p class="none">Nothing matches “' + esc(query) + "”.</p>";
    $("tree").innerHTML = html;
  }

  /* ---------- Canvas ---------- */

  function renderStory(item, story, p) {
    try {
      return item.render(p, { story: story });
    } catch (err) {
      return '<p class="ds" style="color:var(--status-problem-text)">This story could not be drawn: ' + esc(err.message) + "</p>";
    }
  }

  function applyStageFrame(el) {
    el.className = "stage vp-" + prefs.viewport + (prefs.background === "card" ? " bg-card" : "");
  }

  /*
   * Motion across a redraw. A story redraws as new HTML, so a CSS transition would never
   * run. Before drawing, remember the state attributes of every element with a data-anim
   * or data-key; after drawing, give each new element its old values for one frame and
   * then its new ones, so folds, thumbs, knobs, radios and fills move instead of jumping.
   */
  var MORPH_ATTRS = ["aria-expanded", "aria-checked", "aria-pressed", "aria-selected", "data-open", "style"];

  function morphKeys(root) {
    var seen = {};
    var out = {};
    Array.prototype.forEach.call(root.querySelectorAll("[data-anim],[data-key]"), function (el) {
      var id = el.getAttribute("data-anim") || el.getAttribute("data-key");
      seen[id] = (seen[id] || 0) + 1;
      out[id + "#" + seen[id]] = el;
    });
    return out;
  }

  function snapshot(root) {
    var els = morphKeys(root);
    var snap = {};
    Object.keys(els).forEach(function (k) {
      var values = {};
      MORPH_ATTRS.forEach(function (a) { values[a] = els[k].getAttribute(a); });
      snap[k] = values;
    });
    return snap;
  }

  function morph(root, before) {
    var els = morphKeys(root);
    var pending = [];
    Object.keys(els).forEach(function (k) {
      var old = before[k];
      if (!old) return;
      var el = els[k];
      var now = {};
      var changed = false;
      MORPH_ATTRS.forEach(function (a) {
        now[a] = el.getAttribute(a);
        if (now[a] !== old[a]) changed = true;
      });
      if (!changed) return;
      MORPH_ATTRS.forEach(function (a) {
        if (old[a] === null) el.removeAttribute(a); else el.setAttribute(a, old[a]);
      });
      pending.push([el, now]);
    });
    if (!pending.length) return;
    void root.offsetWidth;
    window.requestAnimationFrame(function () {
      pending.forEach(function (x) {
        MORPH_ATTRS.forEach(function (a) {
          if (x[1][a] === null) x[0].removeAttribute(a); else x[0].setAttribute(a, x[1][a]);
        });
      });
    });
  }

  /*
   * Entrances (a menu, a toast, a count, a refusal) play when the element appears, not on
   * every redraw: one that was already on the stage, unchanged, keeps still. The Motion
   * token's Enter story marks its demo with data-replay so Play again replays it.
   */
  var ENTERS = ".count, .refusal, .own-words, .empty, .menu, .toast, .sheet, .clear, .preview-card, .error, .sort";

  function enterSig(el) {
    return (el.getAttribute("class") || "") + "|" + el.textContent;
  }

  function entrances(root) {
    var seen = {};
    Array.prototype.forEach.call(root.querySelectorAll(ENTERS), function (el) { seen[enterSig(el)] = true; });
    return seen;
  }

  function keepStill(root, seen) {
    Array.prototype.forEach.call(root.querySelectorAll(ENTERS), function (el) {
      if (seen[enterSig(el)] && !el.closest("[data-replay]")) el.style.animation = "none";
    });
  }

  function renderStage() {
    var stage = $("stage");
    var before = snapshot(stage);
    var entered = entrances(stage);
    applyStageFrame(stage);
    var item = current.item;
    var wide = !!item.wide;
    if (prefs.allStates) {
      var cells = item.stories.map(function (s) {
        var p = s === current.story ? props : storyProps(item, s);
        return '<div class="all-cell"><a href="' + esc(hashFor(item, s, "canvas")) + '">' + esc(s.name) + '</a><div class="ds' +
          (prefs.background === "card" ? " on-content" : "") + '">' + renderStory(item, s, p) + "</div></div>";
      }).join("");
      stage.innerHTML = '<div class="all-grid' + (wide ? " wide" : "") + '">' + cells + "</div>";
    } else {
      stage.innerHTML = '<div class="stage-inner ds' + (wide ? " wide" : "") + (prefs.background === "card" ? " on-content" : "") + '">' +
        renderStory(item, current.story, props) + "</div>";
    }
    keepStill(stage, entered);
    morph(stage, before);
    if (typeof item.mounted === "function") item.mounted(stage, props);
  }

  function renderCrumbs() {
    var item = current.item;
    var width = { fit: "fits the window", laptop: "1180 pt wide", desktop: "2200 pt wide" }[prefs.viewport];
    $("crumbs").innerHTML = "<span>" + esc(item.group.title) + "</span><span>/</span><strong>" + esc(item.title) + "</strong>" +
      (current.view === "canvas" ? "<span>/</span><span>" + esc(prefs.allStates ? "All states" : current.story.name) + "</span>" : "") +
      '<span class="vp">Stage ' + esc(width) + "</span>";
  }

  /* ---------- Controls ---------- */

  function optionList(control) {
    var opts = control.type === "role" ? C.ROLE_OPTIONS : control.options;
    return opts.map(function (o) { return typeof o === "object" ? o : { value: o, label: o }; });
  }

  function renderControls() {
    var item = current.item;
    var box = $("controls");
    var shown = item.controls.filter(function (c) { return !c.when || c.when(props); });
    $("controls-note").textContent = prefs.allStates ? "Changes apply to the open story, " + current.story.name + "." : "Change a value to redraw the story.";
    if (!shown.length) {
      box.innerHTML = '<p class="controls-empty">This story has no inputs.</p>';
      return;
    }
    box.innerHTML = shown.map(function (c) {
      var id = "ctl-" + c.name;
      var v = props[c.name];
      var input;
      if (c.type === "toggle") {
        input = '<input id="' + id + '" type="checkbox" data-ctl="' + c.name + '"' + (v ? " checked" : "") + ">";
      } else if (c.type === "select" || c.type === "role") {
        input = '<select id="' + id + '" data-ctl="' + c.name + '">' + optionList(c).map(function (o) {
          return '<option value="' + esc(o.value) + '"' + (String(o.value) === String(v) ? " selected" : "") + ">" + esc(o.label) + "</option>";
        }).join("") + "</select>";
      } else if (c.type === "number") {
        input = '<input id="' + id + '" type="number" data-ctl="' + c.name + '" value="' + esc(v) + '"' +
          (c.min !== undefined ? ' min="' + c.min + '"' : "") + (c.max !== undefined ? ' max="' + c.max + '"' : "") +
          ' step="' + (c.step || 1) + '">';
      } else if (c.type === "textarea") {
        input = '<textarea id="' + id + '" data-ctl="' + c.name + '" rows="2">' + esc(v) + "</textarea>";
      } else {
        input = '<input id="' + id + '" type="text" data-ctl="' + c.name + '" value="' + esc(v) + '">';
      }
      return '<label class="control" for="' + id + '"><span title="' + esc(c.label) + '">' + esc(c.label) + "</span>" + input + "</label>";
    }).join("");
  }

  function readControl(el) {
    var c = current.item.controls.filter(function (x) { return x.name === el.dataset.ctl; })[0];
    if (!c) return;
    if (c.type === "toggle") props[c.name] = el.checked;
    else if (c.type === "number") props[c.name] = el.value === "" ? 0 : Number(el.value);
    else props[c.name] = el.value;
  }

  /* ---------- Docs ---------- */

  function list(items) {
    return "<ul>" + items.map(function (x) { return "<li>" + x + "</li>"; }).join("") + "</ul>";
  }

  function renderDocs() {
    var item = current.item;
    var d = item.docs || {};
    var first = item.stories[0];
    var html = '<article class="docs"><p class="t-secondary">' + esc(item.group.title) + "</p><h1>" + esc(item.title) + "</h1>";
    if (d.what) html += "<p>" + d.what + "</p>";
    html += '<div class="preview ds' + (item.wide ? " wide" : "") + '">' + renderStory(item, first, storyProps(item, first)) + "</div>";
    if (d.when) html += "<h2>When to use it</h2>" + (Array.isArray(d.when) ? list(d.when) : "<p>" + d.when + "</p>");
    if (d.avoid) html += "<h2>When not to</h2>" + (Array.isArray(d.avoid) ? list(d.avoid) : "<p>" + d.avoid + "</p>");
    if (d.states) {
      html += "<h2>States</h2>" + list(d.states.map(function (s) { return "<b>" + esc(s[0]) + "</b>: " + s[1]; }));
    }
    html += "<h2>Stories</h2><ul class=\"story-links\">" + item.stories.map(function (s) {
      return '<li><a href="' + esc(hashFor(item, s, "canvas")) + '">' + esc(s.name) + "</a></li>";
    }).join("") + "</ul>";
    if (d.sizes) html += "<h2>Sizes</h2><p>" + d.sizes + "</p>";
    if (d.motion) html += "<h2>Motion</h2><p>" + d.motion + "</p>";
    if (d.tokens) html += "<h2>Tokens</h2>" + list(d.tokens.map(function (t) { return "<code>" + esc(t) + "</code>"; }));
    if (d.responsive) html += "<h2>Laptop and desktop</h2>" + (Array.isArray(d.responsive) ? list(d.responsive) : "<p>" + d.responsive + "</p>");
    if (d.access) html += "<h2>Keyboard and VoiceOver</h2><p>" + d.access + "</p>";
    html += "</article>";
    $("docs-view").innerHTML = html;
  }

  /* ---------- Render everything ---------- */

  function renderToolbar() {
    Array.prototype.forEach.call(document.querySelectorAll("[data-pref]"), function (group) {
      var name = group.getAttribute("data-pref");
      var buttons = group.querySelectorAll("button[data-value]");
      Array.prototype.forEach.call(buttons, function (b, i) {
        var on = b.getAttribute("data-value") === String(prefs[name]);
        b.setAttribute("aria-checked", String(on));
        if (on) group.style.setProperty("--i", i);
      });
      group.style.setProperty("--n", buttons.length);
    });
    $("all-states").setAttribute("aria-checked", String(!!prefs.allStates));
  }

  function renderAll() {
    document.documentElement.dataset.theme = prefs.theme;
    renderToolbar();
    var docs = current.view === "docs";
    $("tab-canvas").setAttribute("aria-selected", String(!docs));
    $("tab-docs").setAttribute("aria-selected", String(docs));
    $("canvas-view").hidden = docs;
    $("docs-view").hidden = !docs;
    renderTree();
    renderCrumbs();
    if (docs) renderDocs(); else { renderStage(); renderControls(); }
    document.title = current.item.title + (docs ? " · Docs" : " / " + current.story.name) + " · Director design catalog";
  }

  /* ---------- Flash message ---------- */

  var flashTimer = null;
  function flash(html) {
    var el = $("flash");
    el.innerHTML = html;
    el.classList.add("on");
    window.clearTimeout(flashTimer);
    flashTimer = window.setTimeout(function () { el.classList.remove("on"); }, 2600);
  }

  /* ---------- Copy link ---------- */

  function copyText(text) {
    function fallback() {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
      document.body.removeChild(ta);
      return ok;
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).then(function () { return true; }, function () { return fallback(); });
    }
    return Promise.resolve(fallback());
  }

  /* ---------- Events ---------- */

  window.addEventListener("hashchange", route);

  $("tree").addEventListener("click", function (e) {
    var btn = e.target.closest("button[data-item]");
    if (!btn) return;
    var item = index[btn.dataset.item];
    if (item === current.item) {
      expanded[item.key] = !expanded[item.key];
      renderTree();
    } else {
      expanded[item.key] = true;
      go(item, item.stories[0], "canvas");
    }
  });

  $("search").addEventListener("input", function (e) {
    query = e.target.value.trim().toLowerCase();
    renderTree();
  });

  $("search").addEventListener("keydown", function (e) {
    if (e.key === "Escape") { e.target.value = ""; query = ""; renderTree(); }
    if (e.key === "Enter") {
      var first = $("tree").querySelector("a:not(.docs-link)");
      if (first) window.location.hash = first.getAttribute("href");
    }
  });

  document.addEventListener("keydown", function (e) {
    var t = e.target;
    var typing = t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable);
    if (e.key === "/" && !typing) { e.preventDefault(); $("search").focus(); }
  });

  $("tab-canvas").addEventListener("click", function () { go(current.item, current.story, "canvas"); });
  $("tab-docs").addEventListener("click", function () { go(current.item, current.story, "docs"); });

  Array.prototype.forEach.call(document.querySelectorAll("[data-pref]"), function (group) {
    group.addEventListener("click", function (e) {
      var b = e.target.closest("button[data-value]");
      if (!b) return;
      prefs[group.getAttribute("data-pref")] = b.getAttribute("data-value");
      savePrefs();
      renderAll();
    });
  });

  $("all-states").addEventListener("click", function () {
    prefs.allStates = !prefs.allStates;
    savePrefs();
    if (current.view === "docs") go(current.item, current.story, "canvas"); else renderAll();
  });

  $("copy-link").addEventListener("click", function () {
    var link = window.location.href.split("#")[0] + hashFor(current.item, current.story, current.view);
    copyText(link).then(function (ok) {
      flash((ok ? "Link copied: " : "Copy this link: ") + "<code>" + esc(link) + "</code>");
    });
  });

  $("reset").addEventListener("click", function () {
    props = storyProps(current.item, current.story);
    renderStage();
    renderControls();
  });

  function onControl(e) {
    if (!e.target.dataset || !e.target.dataset.ctl) return;
    readControl(e.target);
    renderStage();
    if (e.type === "change") {
      var name = e.target.dataset.ctl;
      renderControls();
      var again = document.querySelector('[data-ctl="' + name + '"]');
      if (again) again.focus();
    }
  }

  $("controls").addEventListener("input", onControl);
  $("controls").addEventListener("change", onControl);

  /*
   * Live interaction on the canvas: an element with data-toggle="prop" flips a toggle
   * prop, data-set="prop=value" sets one. The story redraws and the controls follow.
   */
  $("stage").addEventListener("click", function (e) {
    if (prefs.allStates) return;
    var el = e.target.closest("[data-toggle],[data-set]");
    if (!el || el.getAttribute("aria-disabled") === "true") return;
    var key = el.dataset.key;
    if (el.dataset.toggle) {
      props[el.dataset.toggle] = !props[el.dataset.toggle];
    } else {
      var at = el.dataset.set.indexOf("=");
      var name = el.dataset.set.slice(0, at);
      var raw = el.dataset.set.slice(at + 1);
      props[name] = raw === "true" ? true : raw === "false" ? false : (raw !== "" && !isNaN(Number(raw)) ? Number(raw) : raw);
    }
    renderStage();
    renderControls();
    if (key) {
      var back = $("stage").querySelector('[data-key="' + key + '"]');
      if (back) back.focus();
    }
  });

  /* A field on the canvas with data-bind="prop" writes the prop as the Director types. */
  $("stage").addEventListener("input", function (e) {
    var name = e.target.dataset && e.target.dataset.bind;
    if (!name || prefs.allStates) return;
    props[name] = e.target.value;
    renderControls();
  });

  $("stage").addEventListener("change", function (e) {
    if (e.target.dataset && e.target.dataset.bind && !prefs.allStates) renderStage();
  });

  if (window.matchMedia) {
    var mq = window.matchMedia("(prefers-color-scheme: dark)");
    if (mq.addEventListener) mq.addEventListener("change", function () { if (prefs.theme === "system") renderAll(); });
  }

  route();
})();
