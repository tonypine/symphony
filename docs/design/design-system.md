# Design system: Symphony for Mac

- **Ticket:** [TP-747](https://linear.app/tonypine/issue/TP-747/create-a-native-foreground-dashboard-to-the-macos-app),
  approved by the Director on 2026-10-07. Companion documents: [Stories and journeys](director-app.md) and
  [Screens](director-app-screens.md).
- **Specimen:** the first pages of the mock [`journeys/director-app.html`](journeys/director-app.html) render every
  token and component below, in light and dark (DS1, DS2).
- **Target:** macOS 26 and later, built with the macOS 26 SDK (SwiftUI first, AppKit where SwiftUI falls short: the
  status item, window activation). See decision DD3 in [Screens](director-app-screens.md).
- **Scope:** the whole Mac app. The Symphony window follows it from the start; Settings and Repos move to it as they
  are next changed.

## 1. Where Apple's design is today, and what we take from it

- **macOS 26 (Tahoe) introduced Liquid Glass**: a translucent material for the *navigation layer* (toolbars, the
  sidebar, popovers, menus, sheets' chrome) that floats above the *content layer*. Content stays solid and readable;
  glass is never used for dense tables or text-heavy content. Controls are rounder, toolbar items group on glass
  capsules, the sidebar is an inset floating pane, shapes nest concentrically, and a scroll edge effect softens content
  as it slides under the toolbar.
- **macOS 27's refinements aim at readability**: less transparency and lighter shadows where they made text hard to
  read on Mac LCD displays. An app that uses the system materials gets these refinements for free; an app that paints
  its own blur doesn't.

So we follow three rules:

1. **System chrome, our content.** Use `NavigationSplitView`, `.toolbar`, `.inspector`, `.searchable`, `Table`,
   `List`, `Form`, `.sheet` and `.popover` as they come. They carry Liquid Glass and its later refinements. Never draw
   our own blur, glass or toolbar background.
2. **Glass for navigation, solid for data.** Custom `glassEffect` only on the one floating control that belongs to the
   navigation layer (the dispatch control in the toolbar). Tiles, lists, tables, charts and text sit on solid system
   backgrounds.
3. **Accessibility settings win.** Reduce Transparency, Increase Contrast and Reduce Motion are respected by using
   system materials, colors and animations, and every status is a symbol plus a word, never color alone.

## 2. Principles

1. **Decisions first.** What waits on the Director comes before everything else: the first item in the sidebar, the
   only tinted tile in the flow strip, a badge on the Dock and menu bar icons, a notification.
2. **Quiet when healthy.** A healthy factory is one sentence. Sections with nothing to say are hidden, not shown
   empty. Show exceptions, not inventory.
3. **Every problem carries its fix.** A problem row ends with the button that resolves it, or says why nothing needs
   doing.
4. **Say the consequence before acting.** Every move that changes Linear, a run or dispatch names what happens, what
   doesn't, and how to undo it.
5. **One ticket, one story.** Everything about a ticket (runs, PR, QA, gate, tokens, transcript) is on its page,
   reachable from any row that shows it.
6. **Plain words.** Workflow states and ticket identifiers, not Symphony internals: "Waiting on you", not
   `human_review`; "landing slots", not `finishing_max`.
7. **Native by default.** If a system component does the job, use it unchanged. Custom components are listed in
   section 5, and each has a reason.

## 3. Tokens

Tokens are named roles. In SwiftUI each maps to a system value, so light, dark, Increase Contrast and macOS 27's
refinements follow automatically. The hex values are for the HTML mock and for reviews only; code never hardcodes
them.

### 3.1 Color: surfaces and text

| Token | SwiftUI / AppKit | Light (mock) | Dark (mock) | Use |
| --- | --- | --- | --- | --- |
| `surface.window` | `.windowBackground` | `#ECECEC` | `#2B2B2B` | Behind content |
| `surface.content` | `NSColor.controlBackgroundColor` | `#FFFFFF` | `#1E1E1E` | Cards, lists, tables, the chart surface |
| `surface.raised` | `.background.secondary` | `#F5F5F7` | `#2C2C2E` | Inset groups inside a card, tile hover |
| `stroke.separator` | `.separator` | `rgba(0,0,0,.10)` | `rgba(255,255,255,.10)` | Hairlines between rows and around cards |
| `text.primary` | `.primary` (`labelColor`) | `rgba(0,0,0,.85)` | `rgba(255,255,255,.88)` | Titles, values |
| `text.secondary` | `.secondary` | `rgba(0,0,0,.55)` | `rgba(255,255,255,.58)` | Metadata, captions |
| `text.tertiary` | `.tertiary` | `rgba(0,0,0,.30)` | `rgba(255,255,255,.30)` | Placeholders, disabled, empty stages |
| `accent` | `.tint` (the user's accent color) | `#007AFF` | `#0A84FF` | Selection, links, the default button |

### 3.2 Color: status

Status colors are reserved. Each always ships with its symbol and its word; a chart never borrows one for a series.

| Token | System color | Light | Dark | Symbol | Word | Means |
| --- | --- | --- | --- | --- | --- | --- |
| `status.you` | `.orange` | `#FF9500` | `#FF9F0A` | `person.crop.circle.badge.exclamationmark` | Waiting on you | A decision or action only the Director can take |
| `status.working` | `.blue` | `#007AFF` | `#0A84FF` | `circle.dotted.circle` | Working | An agent, QA pass or landing is running |
| `status.problem` | `.red` | `#FF3B30` | `#FF453A` | `exclamationmark.triangle.fill` | Needs attention | Stuck, failing, conflicting, held |
| `status.done` | `.green` | `#28CD41` | `#32D74B` | `checkmark.circle.fill` | Shipped / Healthy | Merged, passed, agreed |
| `status.idle` | `.gray` | `#8E8E93` | `#98989D` | `pause.circle` / `clock` | Paused / Queued | Waiting on nothing in particular, or stopped on purpose |
| `status.forced` | `.purple` | `#AF52DE` | `#BF5AF2` | `bolt.fill` | Forced | The Director pushed it ahead of the queue |

Badges tint their background with the status color at 14% (light) / 22% (dark) and keep the word in `text.primary`,
so contrast never depends on the hue. "Recommended" on a decision is not a status: it uses the accent tint.

### 3.3 Color: charts

From the dataviz method: color comes last, follows the job, and is validated.

| Job | Rule | Tokens |
| --- | --- | --- |
| One series (shipped per day, agreement per repo) | One hue, no legend box (the title names it) | `chart.series1` |
| Identity (Claude vs Codex) | Categorical, fixed order, never cycled; legend always, direct labels when ≤ 4 | `chart.series1…4` |
| A ratio against a limit (budget, provider limits, per-ticket cap) | Meter: fill carries severity (accent below 75%, `status.you` from 75%, `status.problem` from 95%); track is a light step of the same hue | `meter.*` |
| Outcome of runs | Status colors with a legend (it is a state, not an identity) | `status.*` |

Categorical palette (validator PASS on CVD separation, normal-vision floor and contrast):

| Token | Light (on `#FFFFFF`) | Dark (on `#1E1E1E`) |
| --- | --- | --- |
| `chart.series1` | `#007AFF` | `#3D86F5` |
| `chart.series2` | `#E07800` | `#CC780A` |
| `chart.series3` | `#AF52DE` | `#AE5ADF` |
| `chart.series4` | `#1A9BB0` | `#2A9FB4` |
| `chart.grid` | `rgba(0,0,0,.08)` | `rgba(255,255,255,.10)` |

`chart.series2` sits near `status.you` in hue, so it never shares a chart or a card with a status color, and it always
comes with a legend (in the mock: Codex on Usage's tokens per day).

### 3.4 Typography

SF Pro through the macOS text styles, so the system's text size settings apply. Numbers that change live use
`.monospacedDigit()` so they don't jitter; numbers in table columns use tabular figures; a stat value keeps
proportional figures (dataviz rule).

| Token | SwiftUI | Size / weight (pt) | Use |
| --- | --- | --- | --- |
| `type.sentence` | `.title2.weight(.semibold)` | 17 semibold | The status sentence that opens a view |
| `type.figure` | `.system(size: 28, weight: .semibold)` | 28 semibold | Stat tile values (flow strip, Quality tiles) |
| `type.section` | `.title3.weight(.semibold)` | 15 semibold | Section titles in content |
| `type.rowTitle` | `.headline` | 13 semibold | Ticket identifier and title in a row |
| `type.body` | `.body` | 13 regular | Text, table cells |
| `type.callout` | `.callout` | 12 regular | Secondary lines in rows, sheet explanations |
| `type.label` | `.subheadline.weight(.medium)` | 11 medium | Badges, tile labels, column headers |
| `type.caption` | `.caption` | 10 regular | Timestamps under charts, footnotes |
| `type.mono` | `.system(.callout, design: .monospaced)` | 12 SF Mono | Paths, commands, session ids, transcript |

Content headings are sentence case ("Needs attention"); buttons and menu items are title case, with "…" when they ask
for more ("Stop Run…", "Approve Plan…").

### 3.5 Spacing and layout

A 4 pt grid.

| Token | Value | Use |
| --- | --- | --- |
| `space.1` | 4 | Icon to text inside a badge |
| `space.2` | 8 | Between related lines, between badges |
| `space.3` | 12 | Row padding, tile padding |
| `space.4` | 16 | Between cards in a column |
| `space.5` | 20 | Content inset from the window edges |
| `space.6` | 24 | Between sections |
| `space.8` | 32 | Above an empty state's text |

| Layout token | Value |
| --- | --- |
| Main window, default / minimum | 1200 × 760 / 960 × 600 |
| Sidebar | 200 (180–260) |
| List column (Inbox, Initiatives) | 340 (300–420) |
| Inspector | 300 (280–360) |
| Row height: one line / two lines | 28 / 44 |
| Sheet width: small / medium | 440 / 520, height ≤ 560 with a fixed footer |
| Overview columns | Main column flexible (min 480), side column 300 |

### 3.6 Shape

Shapes are concentric: an inner radius is the outer radius minus the padding between them, the macOS 26 rule
(`ConcentricRectangle` / `.containerShape`).

| Token | Value | Use |
| --- | --- | --- |
| `radius.card` | 14 | Cards and section containers in content |
| `radius.row` | 10 | Row selection and hover, tiles inside a card (14 − 4 inset) |
| `radius.mark` | 4 | Chart data-ends, meter ends |
| `radius.capsule` | height / 2 | Badges, buttons on glass, the dispatch control, count pills |

Windows, sheets, popovers, toolbars and the sidebar take their radius from the system.

### 3.7 Materials and depth

| Token | What | Where |
| --- | --- | --- |
| `material.glass` | System Liquid Glass (automatic) | Toolbar, sidebar, popovers, menus, sheet chrome, notifications |
| `material.glass.control` | `.glassEffect(.regular.interactive(), in: .capsule)` | The dispatch control only |
| `material.content` | Solid `surface.content` | Everything with data |

No custom shadows. Depth comes from the system's glass layer over solid content.

### 3.8 Motion

| Token | SwiftUI | Use |
| --- | --- | --- |
| `motion.standard` | `.smooth(duration: 0.25)` | Sections appearing or leaving, selection |
| `motion.value` | `.contentTransition(.numericText())` | A count or figure that changes on a poll |
| `motion.live` | `.symbolEffect(.variableColor.iterative)` on `status.working` symbols | Only in Now working and on the ticket page, only while visible |

With Reduce Motion on, sections cross-fade and nothing loops. Polls never move a row the Director is pointing at:
values update in place, new rows insert below the hover.

### 3.9 Iconography

SF Symbols 7, hierarchical rendering, `.imageScale(.medium)` in rows. (The mock draws stand-ins for them.)

| Place | Symbol |
| --- | --- |
| Inbox | `tray.full` |
| Overview | `gauge.with.needle` |
| Initiatives | `flag.pattern.checkered` |
| Tickets | `list.bullet.rectangle` |
| Quality | `checkmark.seal` |
| Usage | `chart.bar.xaxis` |
| Shipped / Learnings | `shippingbox` / `lightbulb` |
| Audit | `list.bullet.clipboard` |
| Repos | `square.stack.3d.up` |
| Diagnostics | `stethoscope` |
| Plan / PR / Action / Clarify / Final verification | `doc.text.magnifyingglass` / `arrow.triangle.pull` / `hand.raised` / `questionmark.bubble` / `checkmark.seal` |

## 4. Patterns

### P1. Status sentence

One line opens the Overview (and each view that has a state): what is true now, in words, then one line of context.
When something is wrong it says how many things, and the list below names them.

- Flowing: "The factory is flowing." / "10 tickets in progress across 3 repos. 4 wait on you, the oldest for 3 h 12
  min."
- Attention: "2 things need attention." / the rest as above.
- Paused: "Dispatch is paused since 14:03: Deploy freeze." / "3 runs are finishing. No new run starts until you
  resume, forced tickets included."
- Idle: "The factory is idle." / "Nothing is queued and nothing waits on you. Tickets moved to Todo in Linear start
  here."

### P2. Flow strip

The stages a ticket passes through, left to right, as stat tiles joined by chevrons: Queued → Working → Auto Review →
Waiting on you → Merging → Shipped today. Each tile is a count, a label and one line of context, and opens Tickets (or
the Inbox) filtered to that stage. "Waiting on you" is the only tile with a status tint. Stages at 0 keep their place
in `text.tertiary`. It replaces nine equal metric cards.

### P3. Exceptions list ("Needs attention")

Shown only when not empty. One row per problem: the status symbol, a sentence that names the ticket and the problem,
the age, and its fix buttons (one prominent, the rest plain). Sorted by severity, then age. A row leaves on the next
poll after its problem clears, with `motion.standard`.

### P4. Inbox: list and review

A three-pane layout like Mail: sidebar, the list grouped by kind (oldest first inside each group), and the review of
the selected item. The review's actions live in the toolbar over the detail pane, the default one prominent. After an
item is answered, the selection moves to the next item.

### P5. Consequence sheet

Every action that changes Linear, a run or dispatch opens a small sheet:

- the title is the question ("Stop the run on SHOP-305?");
- one paragraph on what happens, one on what stays the same;
- the options that change the outcome (a checkbox, a reason field);
- **Cancel** and the action, named with its verb; destructive actions use the destructive style.

A Linear move made from the app shows a banner with **Undo** for 10 seconds. Resume Dispatch needs no sheet: it
changes nothing that is already running.

### P6. Scope

A toolbar pop-up, "All repos" or one repo, filters every view at once and is remembered. When a scope hides something
that waits on the Director, the sidebar badge still counts it and the Inbox says "2 more in other repos".

### P7. Live values

The app polls the local Symphony API while the window is visible and slows down when it isn't. Values change in place
with `motion.value`; nothing scrolls or reorders under the pointer. The time of the last update is in the toolbar's
connection state on hover.

### P8. Empty and unavailable states

`ContentUnavailableView` with a symbol, a sentence and at most one action. An empty Inbox is good news and says so.
Symphony stopped, starting or not answering is one placeholder per view, with **Start Symphony** when it is stopped,
never "unavailable" in every field.

### P9. Progressive disclosure

The main path shows what the Director decides on. Detail opens on demand: the inspector for a selected row (⌥⌘I), the
ticket page for everything, Diagnostics for Symphony's own internals.

### P10. Navigation and keyboard

Sidebar views on ⌘1–⌘8 in sidebar order; ⌘[ / ⌘] go back and forward between a list and a ticket page; Return opens
the selection; Space toggles the inspector; ⌘F searches the current view; ⌘R refreshes; ⇧⌘F forces a ticket; ⌘W
closes the window and leaves the app in the menu bar.

### P11. Notifications

One per new item in the Inbox and per new problem in Needs attention, grouped by kind, with actions (**Open**, and
**Approve and Merge…** for a PR whose checks are green, which opens the app on the approve sheet). Nothing for routine
progress. Each kind can be turned off in Settings; Focus modes apply.

## 5. Components

Each component names its SwiftUI base, its parts, its states and what VoiceOver reads.

| # | Component | Base | Parts | States | VoiceOver |
| --- | --- | --- | --- | --- | --- |
| C1 | Sidebar item | `List` row in `NavigationSplitView` sidebar, `.badge(n)` | Symbol, title, badge | Default, selected, badge (Inbox in `status.you`, Overview in `status.problem` when Needs attention isn't empty) | "Inbox, 4 waiting" |
| C2 | Dispatch control | `ToolbarItem` with `material.glass.control` | Status dot, word ("Dispatch on", "Paused · Deploy freeze", "Holding · Claude limit"), chevron; popover with what is working and queued, **Pause Dispatch…** / **Resume Dispatch**, **Force a Ticket…** | On, paused, held by a limit, Symphony stopped (shows **Start Symphony**) | "Dispatch on, 3 working. Button." |
| C3 | Scope pop-up | `Picker(.menu)` in the toolbar | Repo symbol, "All repos" or the key | | "Scope, all repos" |
| C4 | Connection state | Toolbar subtitle and sidebar footer | "Starting…", "Not answering", "Stopped" with a dot | Quiet while connected; last update time in help | "Symphony not answering" |
| C5 | Stat tile | Custom `Button` with a `.plain` style on `surface.content` | Label (`type.label`), value (`type.figure`), context line (`type.callout`), optional 12-point sparkline | Default, hover (`surface.raised`), focused (focus ring), "Waiting on you" tinted, zero (`text.tertiary`) | "Waiting on you, 4, oldest 3 hours. Button." |
| C6 | Flow strip | `HStack` of C5 joined by `chevron.right` | 6 tiles | Stages with 0 keep their place | Reads each tile in order |
| C7 | Status badge | `Label` in a capsule | Status symbol, word | One per `status.*` token; small (11 pt) and regular (13 pt) | The word |
| C8 | Ticket row | `List` row, one or two lines | Identifier (`type.rowTitle`), title, repo, status badge, age (trailing, `type.callout`, monospaced digits), optional fix buttons | Default, hover, selected, working (with `motion.live`) | "SHOP-305, Checkout total rounding, web-shop, needs attention, 14 minutes" |
| C9 | Attention row | C8 with a leading severity symbol and trailing buttons | Sentence, age, primary fix (bordered prominent), secondary (bordered) | Warning (`status.you`), problem (`status.problem`) | The sentence, then the buttons |
| C10 | Card | `GroupBox` restyled to `surface.content`, `radius.card`, hairline | Title (`type.section`), optional trailing link ("Show All"), body | | Title as a heading |
| C11 | Meter | `Gauge(.linearCapacity)` | Label, value text ("3.1M of 5M"), bar, threshold note | Normal (accent), near (`status.you` ≥ 75%), at limit (`status.problem` ≥ 95%) | "Tokens today, 62 percent of budget" |
| C12 | Bar and column charts | Swift Charts `BarMark` / `RuleMark` | Bars ≤ 24 pt thick with 4 pt rounded data-ends; stacked segments split by a 2 pt gap; hairline grid; one reference line (budget); value on the last bar | Hover tooltip per bar; a table view behind **Show Data** | `AXChartDescriptor` with the series |
| C13 | Sparkline | Swift Charts `LineMark`, no axes | 2 pt line in `text.tertiary`, last point in the accent with a surface ring | | Summarised in the tile label |
| C14 | Run timeline | `List` of steps with a connecting line | Time, step symbol, step ("Implementation run", "QA pass", "Gate: approve"), result, duration, tokens; current step live | Done, current, failed, stopped | "13:03, implementation run 1, failed, 22 minutes" |
| C15 | Review view | `ScrollView` of C10 sections | Headline, what to review (links), decisions (C16), sub-tickets or checks, what changed | Plan, PR, action, clarify, final verification | Headings per section |
| C16 | Decision card | `GroupBox` with a `Picker(.radioGroup)` | Question, options (A/B/C, one line each), "Recommended" badge on one, the pick | Recommended picked by default; changed (enables **Send Decisions**) | "Decision 1, where gift cards are bought, option A, recommended, selected" |
| C17 | Consequence sheet | `.sheet` with `Form` | Title as a question, what happens, what stays, options, Cancel + verb | Default, working (spinner in the footer), error inline | Standard sheet |
| C18 | Banner | Custom `HStack` on glass at the foot of the window, or tinted `surface.raised` inline | Symbol, text, actions (Undo), close | Info, warning, error, success with Undo | Announced once when it appears; not repeated on later polls |
| C19 | Data table | `Table` with sortable columns | Columns per view, context menu per row | Sorted, filtered (scope bar above; extra filters fold into **More** when narrow) | Standard table |
| C20 | Empty state | `ContentUnavailableView` | Symbol, sentence, one action | | Standard |
| C21 | Menu bar menu | `NSStatusItem` menu (AppKit, as today) | Header (status, counts), Waiting on you items (top 5, age), Open Symphony, dispatch, force, Symphony start/stop, updates, Repos, Settings, Developer, Quit | Badge when the Inbox isn't empty | Standard menu |
| C22 | Notification | `UNUserNotificationCenter` with categories | Title (ticket and ask), body (title of the ticket and its state), actions | Per kind | Standard |

## 6. Accessibility

- Every status is symbol + word; color is never the only signal, including in charts (labels, legend, data table).
- Text contrast is at least 4.5:1 on its surface in light and dark; badges keep their word in `text.primary`.
- Full keyboard path (P10); focus rings on tiles and rows; the default button in every sheet.
- Rows and tiles are single accessibility elements with the labels in the table above; buttons inside rows are custom
  actions.
- Increase Contrast: hairlines become `separator` at full strength; badges get an outline.
- Reduce Transparency: system glass becomes opaque by itself; the dispatch control falls back to `surface.raised`.
- Reduce Motion: no looping symbol effects; cross-fades only.
- Live updates never steal focus; VoiceOver announces a new Inbox item once.

## 7. Content

- Use the workflow's words: Todo, In Progress, In Review, Human Review, Merging, Done, Rework, Backlog; and the
  Director's words for stages: Queued, Working, Auto Review, Waiting on you, Merging, Shipped.
- A ticket is always its identifier and its title together.
- Durations are short and exact: "14 min", "3 h 12 min", "2 days". Times: relative in rows ("12 min ago"), absolute on
  hover ("Today 14:03").
- Numbers: 1,284 / 3.1M tokens / 62%. Never a bare token count without "tokens".
- Internal names stay out of the main path: `forced_max` → "forced allowance", `finishing_max` → "landing slots", epic
  lanes → "initiative slots", `human_review` → "Waiting on you", "watching" → its stage.
- An error says what happened, why if known, and what to do: "Linear rejected the API key. Check it in Settings." with
  **Open Settings…**.
