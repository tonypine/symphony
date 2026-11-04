# Design system: Symphony for Mac

- **Ticket:** [TP-747](https://linear.app/tonypine/issue/TP-747/create-a-native-foreground-dashboard-to-the-macos-app),
  approved by the Director on 2026-10-07. Companion documents: [Stories and journeys](director-app.md) and
  [Screens](director-app-screens.md).
- **Catalog:** [`catalog/index.html`](catalog/index.html) shows every token, component and section below as stories,
  one per state, with live controls and light, dark, laptop and desktop switches (TP-1382). Open it from disk in a
  browser; section 5 links straight to each story.
- **Specimen:** the first pages of the mock [`journeys/director-app.html`](journeys/director-app.html) render the
  tokens and the first components, in light and dark (DS1, DS2).
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
When the word itself is drawn in a status colour (the situation line, a failed step), it uses that status's text
step (`status.*.text`: the hue darkened in light, lightened in dark), which keeps 4.5:1 on content.

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
| `type.title` | `.title.weight(.semibold)` | 22 semibold | A page's title (the ticket page header) |
| `type.sentence` | `.title2.weight(.semibold)` | 17 semibold | The status sentence that opens a view |
| `type.figure` | `.system(size: 28, weight: .semibold)` | 28 semibold | Stat tile values (flow strip, Quality tiles) |
| `type.section` | `.title3.weight(.semibold)` | 15 semibold | Section titles in content |
| `type.rowTitle` | `.headline` | 13 semibold | Ticket identifier and title in a row |
| `type.body` | `.body` | 13 regular | Text, table cells |
| `type.callout` | `.callout` | 12 regular | Secondary lines in rows, sheet explanations |
| `type.label` | `.subheadline.weight(.medium)` | 11 medium | Badges, tile labels, column headers |
| `type.caption` | `.caption` | 10 regular | Timestamps under charts, footnotes |
| `type.mono` | `.system(.callout, design: .monospaced)` | 12 SF Mono | Commit hashes, paths, commands, session ids, transcript; never prose or numbers |

Reading text never runs past a measure of 68 characters (`measure`), 52 for help lines (`measure.narrow`).

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
| Toolbar title and subtitle | at most 260, one line each, cut at the end (a page's header shows its title whole) |
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
| `radius.control` | 6 | Buttons, fields, pop-ups, the segments of a segmented control |
| `radius.mark` | 4 | Chart data-ends, meter ends |
| `radius.capsule` | height / 2 | Badges, buttons on glass, the dispatch control, count pills |

Windows, sheets, popovers, toolbars and the sidebar take their radius from the system.

### 3.7 Materials and depth

| Token | What | Where |
| --- | --- | --- |
| `material.glass` | System Liquid Glass (automatic) | Toolbar, sidebar, popovers, menus, sheet chrome, notifications |
| `material.glass.control` | `.glassEffect(.regular.interactive(), in: .capsule)` | The dispatch control only |
| `material.content` | Solid `surface.content` | Everything with data |

No custom shadows. Depth comes from the system's glass layer over solid content. The catalog draws the system's
depth as four levels so reviews can see it: 0 inside a card, 1 a card (hairline only), 2 menus, tooltips and toasts,
3 sheets (`elevation.0`…`elevation.3`).

### 3.8 Motion

| Token | SwiftUI | Use |
| --- | --- | --- |
| `motion.fast` | `.smooth(duration: 0.12)` | Hover and pressed |
| `motion.standard` | `.smooth(duration: 0.25)` | Sections appearing or leaving, folding, selection |
| `motion.slow` | `.smooth(duration: 0.4)` | A sheet arriving |
| `motion.hoverDelay` | 0.5 s | Before a tooltip or a chip's popover opens |
| `motion.value` | `.contentTransition(.numericText())` | A count or figure that changes on a poll |
| `motion.live` | `.symbolEffect(.variableColor.iterative)` on `status.working` symbols | Only in Now working and on the ticket page, only while visible |

Easings: `ease.standard` for moves within the page, `ease.enter` for what appears, `ease.exit` for what leaves.
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
| Plan / PR / Action / Clarify / Blocked | `doc.text.magnifyingglass` / `arrow.triangle.pull` / `hand.raised` / `questionmark.bubble` / `hand.raised.slash` |

### 3.10 Focus ring

A 3 pt ring in the accent at half strength (`focus.ring`), drawn only when focus came from the keyboard, on every
control, row, card and option that takes focus. A pointer click never draws it, and nothing may hide it.

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

The stages a ticket passes through, left to right, as stat tiles joined by chevrons: Queued → Working → Code Review &
QA → Waiting on you → Merging → Shipped today. Each tile is a count, a label and one line of context, and opens Tickets (or
the Inbox) filtered to that stage. "Waiting on you" is the only tile with a status tint. Stages at 0 keep their place
in `text.tertiary`. It replaces nine equal metric cards.

### P3. Exceptions list ("Needs attention")

Shown only when not empty. One row per problem: the status symbol, a sentence that names the ticket and the problem,
the age, and its fix buttons (one prominent, the rest plain). Sorted by severity, then age. A row leaves on the next
poll after its problem clears, with `motion.standard`.

### P4. Inbox: list and review

A three-pane layout like Mail: sidebar, the list grouped by kind (oldest first inside each group; decisions apart from
older actions with steps), and the review of the selected item. The review's actions live in the toolbar over the detail pane, the default one prominent. After an
item is answered, the selection moves to the next item.

### P5. Consequence sheet

Every action that changes Linear, a run or dispatch opens a small sheet:

- the title is the question ("Stop the run on SHOP-305?");
- one paragraph on what happens, one on what stays the same;
- the options that change the outcome (a checkbox, a reason field);
- **Cancel** and the action, named with its verb; destructive actions use the destructive style.

A Linear move made from the app shows a banner with **Undo** for 10 seconds. An answer that leaves the ticket in
place (Send Decision, Send Decisions) has no move to take back, so the app holds it for those 10 seconds instead: the
banner reads "Sending your decision · Undo", the answer is sent when they end, and Undo keeps it from ever being sent
("Not sent; your pick is kept"). Closing the window or quitting the app sends it at once. Resume Dispatch needs no
sheet: it changes nothing that is already running.

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
peek (N4) for a ticket or PR a decision mentions, the ticket page for everything, the pull request page (D15) for a
PR's story, Diagnostics for Symphony's own internals.

### P10. Navigation and keyboard

Sidebar views on ⌘1–⌘8 in sidebar order; ⌘[ / ⌘] go back and forward between a list and a ticket or pull request
page (⌘[ pops the
peek's page first while it has one); Return opens
the selection; Space toggles the inspector; ⌘F searches the current view; ⌘R refreshes; ⇧⌘F forces a ticket; ⌘W
closes the window and leaves the app in the menu bar.

### P11. Notifications

One per new item in the Inbox and per new problem in Needs attention, grouped by kind, with actions (**Open**, and
**Approve and Merge…** for a PR whose checks are green, which opens the app on the approve sheet). Nothing for routine
progress. Each kind can be turned off in Settings; Focus modes apply.

## 5. Components

### 5.1 The catalog

Every component and section exists once, in every state, in the [design catalog](catalog/index.html). Each one has
stories (one per state or variant: Button / Primary hover, Row / Selected, Situation line / Waiting for CI), a docs tab
with the text below, and live controls to change its label, state, colour role or count. The toolbar switches the
theme (system, light, dark), the stage width (laptop 1180 pt, desktop 2200 pt, or fit the window) and the background
(page or card), and shows every state of a component side by side. A link such as
`catalog/index.html#components/button/primary-hover` opens a story directly; `…/docs` opens a component's docs.

States that every interactive component has, named the same way everywhere: **default**, **hover**, **pressed**,
**selected**, **focused** (keyboard only), **disabled with reason** (the reason is always shown, in an inline refusal
under the control) and **empty** where one exists. Hover, pressed and focused work live in the catalog and also exist
as named stories.

The stories are the source of truth for how a component looks; the tables below say what each is for and link to its
docs and to every story.

### 5.2 Components

| Component | What it is for and when to use it | Stories (states) | Tokens |
| --- | --- | --- | --- |
| [Button](catalog/index.html#components/button/docs) | A labelled action. One primary button per place (the move we expect), secondary for the others, destructive for what stops or throws work away, quiet for low-stakes actions inside text and cards. Name it with its verb in title case: Approve Plan, Stop Run…, Send Decision…. End the label with “…” when it opens a sheet that asks for more. Disabled always says why, in an inline refusal under it and as its help text. Not for: two primary buttons side by side, or a disabled button without a reason. | [Primary](catalog/index.html#components/button/primary), [Primary hover](catalog/index.html#components/button/primary-hover), [Primary pressed](catalog/index.html#components/button/primary-pressed), [Primary focused](catalog/index.html#components/button/primary-focused), [Primary disabled with reason](catalog/index.html#components/button/primary-disabled-with-reason), [Secondary](catalog/index.html#components/button/secondary), [Secondary hover](catalog/index.html#components/button/secondary-hover), [Secondary pressed](catalog/index.html#components/button/secondary-pressed), [Secondary disabled with reason](catalog/index.html#components/button/secondary-disabled-with-reason), [Destructive](catalog/index.html#components/button/destructive), [Destructive hover](catalog/index.html#components/button/destructive-hover), [Destructive in a sheet](catalog/index.html#components/button/destructive-in-a-sheet), [Quiet](catalog/index.html#components/button/quiet), [Quiet hover](catalog/index.html#components/button/quiet-hover), [With a glyph](catalog/index.html#components/button/with-a-glyph), [Small](catalog/index.html#components/button/small), [Large](catalog/index.html#components/button/large) | `--accent`, `--accent-hover`, `--accent-pressed`, `--status-problem`, `--radius-control`, `--motion-fast`, `--focus-ring` |
| [Icon button](catalog/index.html#components/icon-button/docs) | A glyph-only action for toolbars and card corners, where the glyph is well known (close, more, refresh, the details pane). Always has help text that names the action; that text is what VoiceOver reads. A toggle (show or hide a pane) shows its on state with the accent tint. Not for: an icon button for a move that changes Linear or a run: those get a labelled button. | [Default](catalog/index.html#components/icon-button/default), [Hover](catalog/index.html#components/icon-button/hover), [Pressed](catalog/index.html#components/icon-button/pressed), [Focused](catalog/index.html#components/icon-button/focused), [On](catalog/index.html#components/icon-button/on), [Disabled with reason](catalog/index.html#components/icon-button/disabled-with-reason) | `--surface-hover`, `--surface-pressed`, `--accent-tint`, `--radius-control` |
| [Menu button](catalog/index.html#components/menu-button/docs) | A button that opens a short menu of related moves, for a set that does not fit the action rail. The label names the set and ends with “…” or a chevron; each item is a verb or a destination. Destructive items sit last, under a separator. | [Closed](catalog/index.html#components/menu-button/closed), [Hover](catalog/index.html#components/menu-button/hover), [Pressed](catalog/index.html#components/menu-button/pressed), [Open](catalog/index.html#components/menu-button/open), [Focused](catalog/index.html#components/menu-button/focused), [Disabled with reason](catalog/index.html#components/menu-button/disabled-with-reason) | `--elevation-2`, `--radius-row`, `--accent` |
| [Segmented control](catalog/index.html#components/segmented-control/docs) | Two to five mutually exclusive views of the same thing: a period, a unit, a layout. Segments are short nouns. The choice applies at once, with no confirmation. Not for: more than five segments (use a pop-up), or segments that trigger moves. | [Default](catalog/index.html#components/segmented-control/default), [Segment hover](catalog/index.html#components/segmented-control/segment-hover), [Focused](catalog/index.html#components/segmented-control/focused), [Two segments](catalog/index.html#components/segmented-control/two-segments), [Disabled with reason](catalog/index.html#components/segmented-control/disabled-with-reason) | `--surface-sunken`, `--surface-content`, `--radius-control`, `--motion-fast` |
| [Chip](catalog/index.html#components/chip/docs) | A compact tag for what a ticket is or where it belongs: its status, its repo, its epic, a label. As a filter it toggles on and off. Status chips carry the status glyph and word on the status tint. Repo and epic chips carry their glyph; label chips a small colour swatch. In a filter bar every chip is a toggle; selected chips show the accent outline. Not for: chips as buttons for moves, or a status chip without its word. | [Status](catalog/index.html#components/chip/status), [Status working](catalog/index.html#components/chip/status-working), [Repo](catalog/index.html#components/chip/repo), [Epic](catalog/index.html#components/chip/epic), [Label](catalog/index.html#components/chip/label), [Hover](catalog/index.html#components/chip/hover), [Pressed](catalog/index.html#components/chip/pressed), [Selected](catalog/index.html#components/chip/selected), [Focused](catalog/index.html#components/chip/focused), [Removable](catalog/index.html#components/chip/removable), [Disabled with reason](catalog/index.html#components/chip/disabled-with-reason) | `--tint-*`, `--surface-raised`, `--accent-tint`, `--radius-capsule`, `--type-label` |
| [Badge](catalog/index.html#components/badge/docs) | A status glyph and word on the status tint: the one way the Director says what state something is in. In rows, headers and popovers, next to what it describes. Recommended on a Question option is not a status: it uses the accent tint and no glyph. Not for: a badge as a button, or colour without the word. | [Waiting on you](catalog/index.html#components/badge/waiting-on-you), [Working](catalog/index.html#components/badge/working), [Needs attention](catalog/index.html#components/badge/needs-attention), [Done](catalog/index.html#components/badge/done), [Paused](catalog/index.html#components/badge/paused), [Forced](catalog/index.html#components/badge/forced), [Small](catalog/index.html#components/badge/small), [Large](catalog/index.html#components/badge/large), [Recommended](catalog/index.html#components/badge/recommended) | `--tint-*`, `--status-*`, `--text-primary`, `--radius-capsule` |
| [Count badge](catalog/index.html#components/count-badge/docs) | How many things wait in a place: the Inbox, a board group, a filter. Coloured only for what needs the Director (orange) or a problem (red); every other count is quiet. | [Waiting on you](catalog/index.html#components/count-badge/waiting-on-you), [Problems](catalog/index.html#components/count-badge/problems), [Over 99](catalog/index.html#components/count-badge/over-99), [Quiet](catalog/index.html#components/count-badge/quiet), [Zero](catalog/index.html#components/count-badge/zero) | `--status-you`, `--status-problem`, `--surface-sunken`, `--radius-capsule` |
| [Status dot](catalog/index.html#components/status-dot/docs) | The smallest status mark, for a dense place where a glyph would be too heavy: the dispatch control, a connection state, a legend. Always beside a word. It pulses only for something live and visible, and never with Reduce Motion. | [Waiting on you](catalog/index.html#components/status-dot/waiting-on-you), [Working](catalog/index.html#components/status-dot/working), [Needs attention](catalog/index.html#components/status-dot/needs-attention), [Done](catalog/index.html#components/status-dot/done), [Paused](catalog/index.html#components/status-dot/paused), [Forced](catalog/index.html#components/status-dot/forced), [Working, live](catalog/index.html#components/status-dot/working-live) | `--status-*`, `--motion-standard` |
| [Situation line](catalog/index.html#components/situation-line/docs) | One line that says where a ticket stands: a glyph and a word in its status colour, the cause, what it waits on, and for how long. It opens the ticket page and sits under every row that needs a reason. The word is the situation in the Director's words (Waiting for CI, Waiting on you, Writing the code, Needs attention). The cause is one short sentence of fact; the wait names who or what moves it next. The age counts from when this situation began, not from when the ticket was filed. Not for: internal state names, two situations in one line, or a line that runs past the measure. | [Waiting for CI](catalog/index.html#components/situation-line/waiting-for-ci), [Waiting on you](catalog/index.html#components/situation-line/waiting-on-you), [Writing the code](catalog/index.html#components/situation-line/writing-the-code), [Needs attention](catalog/index.html#components/situation-line/needs-attention), [Paused](catalog/index.html#components/situation-line/paused), [Forced](catalog/index.html#components/situation-line/forced), [Shipped](catalog/index.html#components/situation-line/shipped), [Large](catalog/index.html#components/situation-line/large), [Compact](catalog/index.html#components/situation-line/compact) | `--status-*`, `--status-*-text`, `--type-body`, `--measure` |
| [Progress meter](catalog/index.html#components/progress-meter/docs) | How much of a cap is used: tokens against the daily budget, a ticket against its token cap, runs against a limit. The fill carries severity: accent below 75 %, orange from 75 %, red from 95 %. The note under it says what happens at the cap, in words. | [Calm](catalog/index.html#components/progress-meter/calm), [Near the cap](catalog/index.html#components/progress-meter/near-the-cap), [At the cap](catalog/index.html#components/progress-meter/at-the-cap), [Ticket cap](catalog/index.html#components/progress-meter/ticket-cap), [Empty](catalog/index.html#components/progress-meter/empty) | `--accent`, `--status-you`, `--status-problem`, `--radius-mark`, `--motion-standard` |
| [Stacked stage bar](catalog/index.html#components/stacked-stage-bar/docs) | Where a ticket's time or tokens went, stage by stage, as one bar split into segments with a legend that carries the numbers. Segments keep their landing order left to right. The legend is always there, so colour is never the only way to read it. Not for: status colours in the segments (they are stages, not states) other than the gray for waiting. | [Typical ticket](catalog/index.html#components/stacked-stage-bar/typical-ticket), [Stuck in review](catalog/index.html#components/stacked-stage-bar/stuck-in-review), [Tokens by stage](catalog/index.html#components/stacked-stage-bar/tokens-by-stage), [Empty](catalog/index.html#components/stacked-stage-bar/empty) | `chart series 1 to 4`, `--status-idle`, `--radius-mark` |
| [Text field](catalog/index.html#components/text-field/docs) | One line of text the Director types: a reason, a name, a number. The label sits above; help or the error sits under it, never both. The error says what to change. | [Empty](catalog/index.html#components/text-field/empty), [Filled](catalog/index.html#components/text-field/filled), [Hover](catalog/index.html#components/text-field/hover), [Focused](catalog/index.html#components/text-field/focused), [Error](catalog/index.html#components/text-field/error), [Disabled with reason](catalog/index.html#components/text-field/disabled-with-reason) | `--surface-content`, `--stroke-strong`, `--accent`, `--status-problem`, `--radius-control`, `--focus-ring` |
| [Search field](catalog/index.html#components/search-field/docs) | Filters the current list as the Director types. Its shortcut is ⌘F. The count of matches shows inside the field; the clear button appears once there is a query. | [Empty](catalog/index.html#components/search-field/empty), [Hover](catalog/index.html#components/search-field/hover), [Focused](catalog/index.html#components/search-field/focused), [With a query](catalog/index.html#components/search-field/with-a-query), [No results](catalog/index.html#components/search-field/no-results) | `--surface-sunken`, `--focus-ring`, `--text-tertiary` |
| [Pop-up](catalog/index.html#components/pop-up/docs) | One choice out of a list too long for a segmented control: a repo, an epic, a unit. The label names what is chosen and the value shows the choice; the open list ticks the current one. | [Default](catalog/index.html#components/pop-up/default), [Hover](catalog/index.html#components/pop-up/hover), [Pressed](catalog/index.html#components/pop-up/pressed), [Open](catalog/index.html#components/pop-up/open), [Focused](catalog/index.html#components/pop-up/focused), [Disabled with reason](catalog/index.html#components/pop-up/disabled-with-reason) | `--elevation-2`, `--radius-control`, `--accent` |
| [Toggle](catalog/index.html#components/toggle/docs) | A setting that is on or off, with one line under its label that says what being on does. The effect line is a consequence, not a restatement of the label. The change applies at once. | [On](catalog/index.html#components/toggle/on), [Off](catalog/index.html#components/toggle/off), [Hover](catalog/index.html#components/toggle/hover), [Pressed](catalog/index.html#components/toggle/pressed), [Focused](catalog/index.html#components/toggle/focused), [Disabled with reason](catalog/index.html#components/toggle/disabled-with-reason) | `--accent`, `--surface-sunken`, `--motion-standard`, `--radius-capsule` |
| [Tooltip](catalog/index.html#components/tooltip/docs) | Help that appears after 0.5 s of hover: the full text of something cut short, the reason a control is off, an absolute time. Short, plain sentences, at most 260 pt wide. Not for: anything the Director needs to act: that goes on the page, not in a tooltip. | [Above](catalog/index.html#components/tooltip/above), [Below](catalog/index.html#components/tooltip/below), [Long text wraps](catalog/index.html#components/tooltip/long-text-wraps), [On hover (live)](catalog/index.html#components/tooltip/on-hover-live) | `--elevation-2`, `--motion-hover-delay`, `--radius-control`, `--type-secondary` |
| [Row](catalog/index.html#components/row/docs) | One ticket in a list: its status glyph, identifier and title, a badge, its age, and when it has a problem, the button that fixes it. One line (28 pt) in dense lists, two lines (44 pt) when the second line carries the situation. Clicking selects; Return or a double click opens the ticket page. A problem row ends with its fix button; a disabled fix says why in place of the button's action. | [Default](catalog/index.html#components/row/default), [Hover](catalog/index.html#components/row/hover), [Pressed](catalog/index.html#components/row/pressed), [Selected](catalog/index.html#components/row/selected), [Selected, window not focused](catalog/index.html#components/row/selected-window-not-focused), [Focused](catalog/index.html#components/row/focused), [Two lines](catalog/index.html#components/row/two-lines), [Working, live](catalog/index.html#components/row/working-live), [With a fix](catalog/index.html#components/row/with-a-fix), [Fix disabled with reason](catalog/index.html#components/row/fix-disabled-with-reason), [Waiting on you](catalog/index.html#components/row/waiting-on-you) | `--surface-hover`, `--surface-pressed`, `--accent`, `--radius-row`, `--type-row-title`, `--motion-fast` |
| [Table header and row](catalog/index.html#components/table-header-and-row/docs) | A sortable table for comparing many tickets on the same columns: Tickets, Usage, Shipped. Header labels are short nouns; clicking one sorts by it, clicking again reverses. The sorted column shows its arrow. Numbers align right with tabular figures. | [Default](catalog/index.html#components/table-header-and-row/default), [Header hover](catalog/index.html#components/table-header-and-row/header-hover), [Sorted by tokens](catalog/index.html#components/table-header-and-row/sorted-by-tokens), [Row hover](catalog/index.html#components/table-header-and-row/row-hover), [Row selected](catalog/index.html#components/table-header-and-row/row-selected), [Row focused](catalog/index.html#components/table-header-and-row/row-focused), [Empty](catalog/index.html#components/table-header-and-row/empty) | `--stroke-separator`, `--surface-hover`, `--accent`, `--type-label`, `--radius-row` |
| [Card](catalog/index.html#components/card/docs) | A titled block of content on the content surface. Most of a page is cards. Title in sentence case; an optional trailing link (Show All) opens more of the same. A card that opens something as a whole is clickable and gets hover and pressed; others have no hover. Not for: a card with nothing to say: hide it (Quiet when healthy). Use the empty state only where its absence would confuse. | [Default](catalog/index.html#components/card/default), [With a link](catalog/index.html#components/card/with-a-link), [Clickable](catalog/index.html#components/card/clickable), [Clickable hover](catalog/index.html#components/card/clickable-hover), [Clickable pressed](catalog/index.html#components/card/clickable-pressed), [Focused](catalog/index.html#components/card/focused), [Selected](catalog/index.html#components/card/selected), [Empty](catalog/index.html#components/card/empty) | `--surface-content`, `--elevation-1`, `--radius-card`, `--space-4`, `--type-heading` |
| [Collapsible card](catalog/index.html#components/collapsible-card/docs) | A card whose body folds away, for history and detail the Director opens on demand. Folded, the header still says what is inside (a count, a duration). The fold is remembered per card. | [Open](catalog/index.html#components/collapsible-card/open), [Folded](catalog/index.html#components/collapsible-card/folded), [Header hover](catalog/index.html#components/collapsible-card/header-hover), [Header focused](catalog/index.html#components/collapsible-card/header-focused), [Empty](catalog/index.html#components/collapsible-card/empty) | `--radius-card`, `--surface-hover`, `--motion-standard` |
| [Key-value list](catalog/index.html#components/key-value-list/docs) | Facts about one thing as label and value pairs: the facts rail, popovers, the review's context card. Labels in secondary, values in primary; a value can be a chip or a badge. A fact that is unknown is left out, never shown as a dash or “unknown”. | [Default](catalog/index.html#components/key-value-list/default), [Grouped](catalog/index.html#components/key-value-list/grouped), [Stacked](catalog/index.html#components/key-value-list/stacked), [Values left out](catalog/index.html#components/key-value-list/values-left-out) | `--text-secondary`, `--space-4`, `--type-label` |
| [Timeline entry](catalog/index.html#components/timeline-entry/docs) | One thing that happened to a ticket, at a time, with a glyph and colour per class so a day reads at a glance. Phase move: arrow, accent. Pause set: pause, gray. Pause cleared: play, blue. Question asked: speech bubble, orange. Question answered: bubble with a tick, green. Run started: play circle, blue. Run ended: its verdict (passed green, failed red, stopped gray). Person action: hand, accent. Rule action: gear, gray. The first words in bold say what happened; detail and who did it follow in secondary. | [Phase move](catalog/index.html#components/timeline-entry/phase-move), [Pause set](catalog/index.html#components/timeline-entry/pause-set), [Pause cleared](catalog/index.html#components/timeline-entry/pause-cleared), [Question asked](catalog/index.html#components/timeline-entry/question-asked), [Question answered](catalog/index.html#components/timeline-entry/question-answered), [Run started](catalog/index.html#components/timeline-entry/run-started), [Run ended, passed](catalog/index.html#components/timeline-entry/run-ended-passed), [Run ended, failed](catalog/index.html#components/timeline-entry/run-ended-failed), [Run ended, stopped](catalog/index.html#components/timeline-entry/run-ended-stopped), [Person action](catalog/index.html#components/timeline-entry/person-action), [Rule action](catalog/index.html#components/timeline-entry/rule-action), [Hover](catalog/index.html#components/timeline-entry/hover) | `--tint-*`, `--status-*`, `--accent`, `--type-secondary`, `--measure` |
| [Run group](catalog/index.html#components/run-group/docs) | One run of an agent on the timeline, folded to a single line with its verdict and duration, unfolding into its steps. Folded by default once it ended; the running one is unfolded and live. | [Folded](catalog/index.html#components/run-group/folded), [Unfolded](catalog/index.html#components/run-group/unfolded), [Running](catalog/index.html#components/run-group/running), [Failed](catalog/index.html#components/run-group/failed), [Header hover](catalog/index.html#components/run-group/header-hover), [Header pressed](catalog/index.html#components/run-group/header-pressed), [Header focused](catalog/index.html#components/run-group/header-focused) | `--status-*`, `--tint-*`, `--radius-row`, `--motion-standard` |
| [Step strip](catalog/index.html#components/step-strip/docs) | The five steps of an implementation run, left to right, so where a run stands or where it stopped reads at once. Writing the code, Build, Checks, Tests, Handoff, always in that order. Each step says its state in words under its name. | [Current: tests](catalog/index.html#components/step-strip/current-tests), [All passed](catalog/index.html#components/step-strip/all-passed), [Failed at checks](catalog/index.html#components/step-strip/failed-at-checks), [Paused at build](catalog/index.html#components/step-strip/paused-at-build), [Tests skipped](catalog/index.html#components/step-strip/tests-skipped), [Not started](catalog/index.html#components/step-strip/not-started) | `--status-done`, `--status-problem`, `--status-working`, `--status-idle`, `--radius-row` |
| [Option card](catalog/index.html#components/option-card/docs) | One answer to a Question: its label, what it does, its trade-offs, and whether we recommend it. The cards of a Question form a radio group. Label first, the effect under it, never on one line together. Trade-offs are tagged good, cost or risk, one line each. The recommended card carries the Recommended badge and a line saying why. | [Default](catalog/index.html#components/option-card/default), [Hover](catalog/index.html#components/option-card/hover), [Pressed](catalog/index.html#components/option-card/pressed), [Focused](catalog/index.html#components/option-card/focused), [Selected](catalog/index.html#components/option-card/selected), [Recommended](catalog/index.html#components/option-card/recommended), [Recommended and selected](catalog/index.html#components/option-card/recommended-and-selected), [With trade-offs](catalog/index.html#components/option-card/with-trade-offs), [Not answerable](catalog/index.html#components/option-card/not-answerable) | `--accent`, `--accent-tint`, `--radius-row`, `--status-done / you / problem`, `--focus-ring` |
| [Answer in my own words](catalog/index.html#components/answer-in-my-own-words/docs) | The last card of every Question: the Director's own answer instead of the options. Picking it opens a field under the cards. The field starts three lines tall and grows to eight. Send stays off until there are words, and says so. | [Not picked](catalog/index.html#components/answer-in-my-own-words/not-picked), [Not picked, hover](catalog/index.html#components/answer-in-my-own-words/not-picked-hover), [Picked, empty](catalog/index.html#components/answer-in-my-own-words/picked-empty), [Picked, focused](catalog/index.html#components/answer-in-my-own-words/picked-focused), [Picked, with words](catalog/index.html#components/answer-in-my-own-words/picked-with-words) | `--accent`, `--radius-row`, `--type-body`, `--focus-ring` |
| [Attachment thumbnail](catalog/index.html#components/attachment-thumbnail/docs) | A file attached to a ticket (a screenshot, a PDF, a log), as a thumbnail with its name. Clicking opens it in Quick Look. | [Image](catalog/index.html#components/attachment-thumbnail/image), [PDF](catalog/index.html#components/attachment-thumbnail/pdf), [Log](catalog/index.html#components/attachment-thumbnail/log), [Hover](catalog/index.html#components/attachment-thumbnail/hover), [Pressed](catalog/index.html#components/attachment-thumbnail/pressed), [Focused](catalog/index.html#components/attachment-thumbnail/focused), [Loading](catalog/index.html#components/attachment-thumbnail/loading), [Failed to load](catalog/index.html#components/attachment-thumbnail/failed-to-load) | `--surface-raised`, `--radius-row`, `--radius-control`, `--surface-hover` |
| [Empty state](catalog/index.html#components/empty-state/docs) | What a view shows when it has nothing: a glyph, a sentence that says what that means, at most one action. An empty Inbox is good news and says so. No results says what was searched and how to widen it. Symphony stopped is one placeholder per view, with Start Symphony. Not for: an empty state for a section with nothing to say on a busy page: hide the section instead. | [Inbox empty](catalog/index.html#components/empty-state/inbox-empty), [No results](catalog/index.html#components/empty-state/no-results), [Symphony stopped](catalog/index.html#components/empty-state/symphony-stopped) | `--text-tertiary`, `--status-done`, `--space-8`, `--measure-narrow` |
| [Toast](catalog/index.html#components/toast/docs) | A short note at the foot of the window about something that just happened, with Undo when it can be taken back. A move made from the app shows one for 10 seconds with Undo. A decision is held for those 10 seconds and sent when they end. Not for: toasts for routine progress, or more than one at a time. | [Sending a decision](catalog/index.html#components/toast/sending-a-decision), [Moved, with Undo](catalog/index.html#components/toast/moved-with-undo), [Warning](catalog/index.html#components/toast/warning), [Error](catalog/index.html#components/toast/error) | `--elevation-2`, `--radius-row`, `--status-*` |
| [Sheet header](catalog/index.html#components/sheet-header/docs) | The top of every consequence sheet: the move asked as a question, then one line on what it does. The title is the question (“Stop the run on TP-1382?”), the explanation says what happens and what doesn't. The footer names the action with its verb. | [Destructive](catalog/index.html#components/sheet-header/destructive), [Question only](catalog/index.html#components/sheet-header/question-only), [With explanation](catalog/index.html#components/sheet-header/with-explanation), [Without close](catalog/index.html#components/sheet-header/without-close) | `--elevation-3`, `--radius-card`, `--type-sentence`, `--space-5` |
| [Inline refusal](catalog/index.html#components/inline-refusal/docs) | Why an action is off, in one line under it. Every disabled action in the Director has one. Say the cause, then what lifts it if the Director can do something: “A run is still finishing. Stop it first.” Not for: “Not available”, or a reason only in a tooltip. | [Under a button](catalog/index.html#components/inline-refusal/under-a-button), [Standalone](catalog/index.html#components/inline-refusal/standalone), [With a way to fix it](catalog/index.html#components/inline-refusal/with-a-way-to-fix-it) | `--text-secondary`, `--text-tertiary`, `--accent`, `--type-secondary`, `--measure-narrow` |
| [Keyboard hint](catalog/index.html#components/keyboard-hint/docs) | The keys for an action, drawn as key caps: on option cards, in menus (plain), in the search field. Modifier symbols in the macOS order: ⌃ ⌥ ⇧ ⌘, then the key. | [Combination](catalog/index.html#components/keyboard-hint/combination), [Single key](catalog/index.html#components/keyboard-hint/single-key), [Plain](catalog/index.html#components/keyboard-hint/plain), [In a menu](catalog/index.html#components/keyboard-hint/in-a-menu), [On an option](catalog/index.html#components/keyboard-hint/on-an-option) | `--surface-raised`, `--stroke-strong`, `--type-label` |

### 5.3 Sections

| Section | What it is and its laptop / desktop rule | Stories | Tokens |
| --- | --- | --- | --- |
| [Page header](catalog/index.html#sections/page-header/docs) | The top of a ticket page: the identifier with its repo and epic, the title, the situation line, and the action rail. Laptop (1180 pt): the action rail sits on its own row under the situation line, left aligned, so the title keeps the full width. Desktop (2200 pt): the action rail moves to the right of the title, top aligned with it. The title wraps (balanced) and stops at 30 em; the situation line stops at the measure (68 characters). | [Laptop](catalog/index.html#sections/page-header/laptop), [Desktop](catalog/index.html#sections/page-header/desktop), [Waiting on you](catalog/index.html#sections/page-header/waiting-on-you), [Short title](catalog/index.html#sections/page-header/short-title) | `--type-title`, `--space-6`, `--measure` |
| [Action rail](catalog/index.html#sections/action-rail/docs) | The moves a ticket allows, in one row: the expected move first and primary, then the others, the destructive one last, and More for the rest. A disabled move stays in its place and says why under it, so the rail never jumps. Laptop: the rail wraps onto a second line before any button shrinks; More always stays last. Desktop: one row, beside the title in the page header. | [Laptop](catalog/index.html#sections/action-rail/laptop), [Desktop](catalog/index.html#sections/action-rail/desktop), [Waiting on you](catalog/index.html#sections/action-rail/waiting-on-you), [Nothing running](catalog/index.html#sections/action-rail/nothing-running) | `--space-2`, button tokens |
| [Facts rail](catalog/index.html#sections/facts-rail/docs) | The ticket's facts in small grouped cards: Now, Work, Connected. Unknown facts are left out. Laptop: one column, 300 pt, beside the page's main column. Desktop: the groups spread into three columns of up to 300 pt each, under the header, so the timeline below gets the full width. Values wrap inside their column; labels never wrap. | [Laptop](catalog/index.html#sections/facts-rail/laptop), [Desktop](catalog/index.html#sections/facts-rail/desktop), [Stacked labels](catalog/index.html#sections/facts-rail/stacked-labels) | `--radius-card`, `--space-4`, key-value list tokens |
| [Timeline](catalog/index.html#sections/timeline/docs) | A day of a ticket's history, newest last: phase moves, pauses, questions, runs folded into groups, the Director's own actions and the rules Symphony applied. Laptop and desktop: the timeline keeps one column of at most 760 pt so every line stays under the measure; the extra width on desktop goes to the facts and the margins, never to longer lines. | [Laptop](catalog/index.html#sections/timeline/laptop), [Desktop](catalog/index.html#sections/timeline/desktop), [Run unfolded](catalog/index.html#sections/timeline/run-unfolded) | timeline entry tokens, `--measure` |
| [Question block](catalog/index.html#sections/question-block/docs) | A Question as the Director answers it: the callout with the question, why it is asked and what happens if it waits, the option cards, the own-words card, and Send. Send stays off until an answer is picked (and, for own words, written), and says so. Laptop: one column of at most 720 pt. Desktop: the same column, with “Where this ticket sits” as a 300 pt card beside it instead of under it. Every paragraph stops at the measure. | [Laptop](catalog/index.html#sections/question-block/laptop), [Desktop](catalog/index.html#sections/question-block/desktop), [Option picked](catalog/index.html#sections/question-block/option-picked), [Own words](catalog/index.html#sections/question-block/own-words) | `--tint-you`, `--status-you`, option card tokens, `--measure` |
| [Board group](catalog/index.html#sections/board-group/docs) | Tickets grouped by their situation, each group a heading with its glyph, count and a hint, then its rows. A group with nothing in it stays as a collapsed heading that says so. Laptop: groups stack in one column, rows full width. Desktop: groups sit side by side in three columns, each its own list. Rows cut their title at the end before the age or the fix button would wrap. | [Laptop](catalog/index.html#sections/board-group/laptop), [Desktop](catalog/index.html#sections/board-group/desktop), [Empty group collapsed](catalog/index.html#sections/board-group/empty-group-collapsed), [Groups folded](catalog/index.html#sections/board-group/groups-folded) | row tokens, `--status-*`, `--radius-row` |
| [Table with filters](catalog/index.html#sections/table-with-filters/docs) | A table of tickets with a search field and filter chips above it, and a Columns menu that picks which columns show. Laptop: the Repo column hides (the repo filter chip says it); the filter bar wraps onto two lines if it must; the Title column wraps at 42 characters. Desktop: every chosen column shows; the table fills the width, but the Title column still wraps at its measure. | [Laptop](catalog/index.html#sections/table-with-filters/laptop), [Desktop](catalog/index.html#sections/table-with-filters/desktop), [Column chooser open](catalog/index.html#sections/table-with-filters/column-chooser-open), [Filtered](catalog/index.html#sections/table-with-filters/filtered) | table tokens, chip tokens, `--elevation-2` |
| [Control bar](catalog/index.html#sections/control-bar/docs) | The bar above Usage and Shipped that sets what the page shows: the period, the unit, the repo and the epic, with a one-line summary of the result. Laptop: the controls keep one line and the summary drops to the next line when they do not fit together. Desktop: one line, the summary right aligned. Clear appears only when a repo or an epic is picked. | [Laptop](catalog/index.html#sections/control-bar/laptop), [Desktop](catalog/index.html#sections/control-bar/desktop), [Filtered](catalog/index.html#sections/control-bar/filtered) | `--surface-raised`, `--radius-row`, segmented control and pop-up tokens |

### 5.4 App component reference

The components as the app builds them today: each names its SwiftUI base, its parts, its states and what VoiceOver
reads. Where a row and the catalog differ, the catalog is the design and the row is what the code does now.

| # | Component | Base | Parts | States | VoiceOver |
| --- | --- | --- | --- | --- | --- |
| C1 | Sidebar item | `List` row in `NavigationSplitView` sidebar, `.badge(n)` | Symbol, title, badge | Default, selected, badge (Inbox in `status.you`, Overview in `status.problem` when Needs attention isn't empty, Setup in `status.problem` for its errors or else `status.you` for its warnings) | "Inbox, 4 waiting" |
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
| C15 | Review view | `ScrollView` of C10 sections | Header (kind badge, waiting, state, repo, actions), title, then by kind: a decision's question (N5), what happened (N6) and options (N7) ending with the write-in (N11); a plan's what to review, decisions (C16), sub-tickets and moves; a PR's checks; an older action's steps; last, where the ticket sits (N9) when it has a row | Plan, PR, decision, action, clarify, blocked; narrow under 560 pt | Headings per section |
| C16 | Decision card | A plan's question (N5's type) over what happened, what waits and N7 cards | One per open request of the plan: question, why, if unanswered, one N7 card per option with its effect and trade-offs, "Recommended" with the request's reason, then the write-in (N11) | Recommended picked by default; **Send Decisions** on once every question has an answer | A radio group named "Decision 1, <question>"; each option as N7 reads |
| C17 | Consequence sheet | `.sheet` with `Form` | Title as a question, what happens, what stays, options, Cancel + verb. Send Decision: `Send "<label>"?`, the option's effect, "<ID> stays in <stage> until its next run picks up your answer."; for a write-in (N11), "Send your answer?" and its words quoted under the title on `surface.raised` with an accent leading bar | Default, working (spinner in the footer), error inline | Standard sheet |
| C18 | Banner | Custom `HStack` on glass at the foot of the window, or tinted `surface.raised` inline | Symbol, text, actions (Undo), close | Info, warning, error, success with Undo | Announced once when it appears; not repeated on later polls |
| C19 | Data table | `Table` with sortable columns | Columns per view, context menu per row | Sorted, filtered (scope bar above; extra filters fold into **More** when narrow) | Standard table |
| C20 | Empty state | `ContentUnavailableView` | Symbol, sentence, one action | | Standard |
| C21 | Menu bar menu | `NSStatusItem` menu (AppKit, as today) | Header (status, counts), Waiting on you items (top 5, age), Open Symphony, dispatch, force, Symphony start/stop, updates, Repos, Settings, Developer, Quit | Badge when the Inbox isn't empty (orange), or while Setup has errors (red, with a "Setup: N errors, M warnings" row) | Standard menu |
| C22 | Notification | `UNUserNotificationCenter` with categories | Title (ticket and ask), body (title of the ticket and its state), actions | Per kind | Standard |
| N1 | Reference chip | A range of an AppKit TextKit 2 text view (`ChipTextView`, in `ChipText`; DD-5 below), one per paragraph | The mention's own characters ("TP-891", "#448"); "TP-891 (Short name)" in the text reads `TP-891 · Short name`; `arrow.triangle.pull` before a pull request number; `accent` tint 14 % behind, `radius` 6, 4 pt each side. Spaces inside a chip don't break, so a chip never splits across lines | Hover: tint 26 % and a hairline, and after 0.5 s its popover (N2, N3) opens, closing when the pointer leaves the chip and the popover; focused: a 2 pt focus ring along the tint's edge, inside it, on the chip with the keyboard only; missing (not in `references`, or a kind the app doesn't know): no tint, a dotted underline, the "can't see" popover. Click opens the ticket page (D3) or the PR on GitHub; the menu has Copy Link and Open in Linear / Open on GitHub. Tab enters the paragraph's first chip and moves between chips, Space shows the popover, Return clicks. A selection takes a chip whole and copies the text as written | The paragraph reads as one text; each chip is a link "TP-891, Remove the retired review states, Code Review", hint "Shows details", with the custom action **Show Details** (and Show Alternate UI) opening its popover |
| N2 | Ticket popover | `NSPopover` on the system's glass hosting SwiftUI, 330 pt | `TP-891 · symphony` (`type.label`, secondary) with its stage as C7; the title (`type.rowTitle`); the summary (`type.callout`, secondary); facts **Part of**, **Work** (its PR and checks), **Waiting on**; footer: what a click does and **Open in Linear** | Facts left out when unknown | Each fact as one element |
| N3 | Pull request popover | As N2 | `arrow.triangle.pull`, `#448`, "for TP-892", the review state as C7 (Open, Changes asked, Approved, Merged, Closed); title; summary; two figures a row: review rounds, files, `+added −removed` lines, checks with their status symbol; footer with **Open on GitHub**. No commit hash, branch or file name | A figure left out when unknown, review rounds while Code Review hasn't judged it | Each figure as one element: "2 review rounds" |
| N4 | Peek | The window's `.inspector` (320–400 pt) beside the review, holding a stack of pages (no `NavigationStack`, whose pushes would land in the window's split view); a `.sheet` over the window when the review would be under 560 pt beside the inspector | Header: Back (`chevron.left`, on a pushed page), the identifier or `#448` (`type.section`), Close (`xmark`, Esc). Ticket: N2's head; **Now** (Stage, Waiting, Work: the PR as N1); **Connected** (Part of with N10's strip and "4 of 7 done", Sub-tickets, Blocked by, Blocks, Related, each an N1 chip and its stage); **Latest review brief**; **Open Ticket Page** (prominent), **Open in Linear**. PR: N3's head and figures, **Open Pull Request Page** (D15, prominent when Symphony knows its repo), **Open on GitHub** | Tracked (Now, Connected) or not (the reference's facts only); a chip inside pushes, ⌘-click opens the ticket's or the PR's page; closed keeps its pages for the toolbar toggle (⌥⌘I) | The title is a heading; each section title a heading; chips as N1 |
| N5 | Question callout | `VStack` on `surface.raised` tinted 10 % with `status.you`, `radius.row`, 3 pt leading bar in `status.you` | Label "YOUR DECISION" (`type.label`, `status.you`), the question (16 pt semibold) in N1 text | | A heading containing the label and the question, its chips links inside it |
| N6 | Story card | C10 titled **What happened** | `why` split on blank lines (at most two paragraphs); a row with `exclamationmark.triangle` (`status.you`) and "If you don't answer:" + `if_unanswered`, all in N1 text | Either part left out when missing; not drawn without both | Title as a heading; each paragraph as one text with its chips |
| N7 | Option card | Full-width `Button(.plain)`, `radius.row`, hairline | Leading radio; first line: label (13.5 pt semibold, N1 text that a click outside a chip passes to the card), **Recommended** badge, trailing key hint; effect under the label in secondary, at the label's leading edge; N8 tags; on the recommended card a tinted "Why we recommend it:" line. Never label and effect in one row | Default, selected (2 pt accent ring and 7 % accent tint), not answerable (no radio, no button); narrow: badge under the label, no key hint | The cards are a radio group; each reads "Option 1 of 3, <label>, recommended, selected. <effect>. <tags>" |
| N8 | Trade-off tag | `Label`, 12 pt, text wraps | good `checkmark.circle` in `status.done`; cost `exclamationmark.triangle` in `status.you`; risk `xmark.circle` in `status.problem` | | "Good: <text>", "Cost: <text>", "Risk: <text>" |
| N9 | Context card | C10 titled **Where this ticket sits**, last in the review; a two-column `Grid` (labels in secondary, values in N1 text) | **Part of**: the parent chip and title, then N10; **Its work**: the PR chip, "checks passing" / "checks failing" / "checks running", "sent back once / twice / N times"; **Connected**: one line per ticket blocked by, blocking or related, its chip, its stage as C7 and the relation ("TP-892 waits on it", "waits on TP-892", "related"); **Your answer**: "Unblocks …." from the request's `unblocks`; **Earlier calls**: `HH:mm` today, else the date and time, then the title and "You chose “…”". Chips for context tickets the text never mentions get their popover from the context | Each row only when known; no row, no card; narrow (under 560 pt): each label above its value. No time estimate (DD-2) | Title as a heading; each line reads in order, the strip as N10 |
| N10 | Progress strip | `HStack` of 14 × 5 pt capsules, 2 pt apart (they narrow, to 3 pt, when the row is short), then "4 of 7 done" in `type.callout` secondary | One segment per sub-ticket in landing order: done `status.done`, working `status.working`, waiting on you (triage) `status.you`, not started `surface.separator` | No sub-tickets: no strip | One element, "4 of 7 sub-tickets done"; the words beside it mean color is never the only signal |
| N11 | Write-in option | The last N7 card of a request the Inbox answers, then a `TextEditor` under the cards | Card: **Answer in my own words…**, "Tell the agent what to do instead." under it, the key after the last option's; field (`type.body`, `surface.content`, `radius.row`, accent hairline) three lines tall, growing to eight, then scrolling; hint under it in `type.callout` secondary: "The agent reads this as your answer. Name tickets by their number; they become links." | Not picked (no field); picked (field shown and focused, number keys type in it); blank (**Send Decision…** off). Not on a plan's decisions (C16) | The card reads as N7, "Option 4 of 4, Answer in my own words…, selected. Tell the agent what to do instead."; the field is labelled "Answer in my own words…" with the hint as its help |
| N12 | Pull request page cards (D15) | A header (C7 review state, dates, then **Open on GitHub** and **Open Ticket** on the same row, or on their own row under it when narrow; the title as a sentence), then C10 cards in two columns (left flexible from 460 pt, right 330 pt), one column below 776 pt of content | **What it does** (summary in N1 text); **Review history** (time in `type.callout` monospaced digits, the verdict as C7 in words, Code Review or QA in `type.rowTitle`, the reason in N1 text); **What it changes** (a `Grid` of area, files, `+added` in `status.done`, `−removed` in `status.problem`, then "Grouped by area, not by file. Open on GitHub for the diff." in `type.caption`); **Health** (a `Grid`: Checks, Code Review, QA, Overlaps, each value with its status symbol and in N1 text, overlaps as PR chips); **Size** (files, lines, commits as figures); **Ticket** (the ticket's N1 chip, its stage as C7, "Waiting on you") | Loading (redacted placeholder lines); GitHub unavailable (`icloud.slash` "GitHub didn't answer." and **Try Again** in the cards that need it); no verdicts or areas yet (a quiet line) | Card titles are headings; a history row reads "Oct 6, 11:40, Code Review, Changes asked. <reason>"; an area "Agent instructions, 5 files, 18 lines added, 240 removed" |

### DD-5 · Chips inside text: a native text view

A chip sits inside a sentence, so the sentence stays native Mac text: one TextKit 2 text view per paragraph
(`ChipTextView`, an `NSTextView`), wrapped for SwiftUI by `ChipText`, which reports its height for the width SwiftUI
proposes, as a `Text` does. The text reads, wraps, selects, copies and speaks like Mail's or Notes'; the chips are
drawn behind their own characters by the paragraph's layout fragment, and hover, click, the keyboard and VoiceOver
come from the text view. A word-flow layout (each word its own view) was set aside: it can't select or copy a
sentence, spaces it by the layout rather than the font, and reads word by word. Plain links were set aside: they have
no hover. `ImageRenderer` can't draw an AppKit view, so in snapshots the text view draws itself into an image
offscreen, with no window, and `ChipText` shows that image.

N1 is used wherever the Director reads Symphony's text about tickets: on the decision review (D2c) in N5, N6, N7 and
N8; on the plan and pull request reviews (D2a, D2b) in the ask, What to review, What changed, C16's questions and
recommendation, and the moves; on the clarify review (D2d) in what the gate found and its questions; on the blocked
review (D2f) in the reason and what clears it; and on the ticket page (D3) in the summary, the latest brief, Earlier
decisions and the last message. External links stay links. Text whose item has no `references` (an older Symphony,
or a ticket page whose ticket isn't in the Inbox) is drawn as a plain `Text`, as before chips.

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

- Use the workflow's words: Todo, In Progress, Code Review, QA, Plan Review, Merging, Done, Rework, Backlog; and the
  Director's words for stages: Queued, Working, Code Review & QA, Waiting on you, Merging, Shipped.
- A ticket is always its identifier and its title together.
- Durations are short and exact: "14 min", "3 h 12 min", "2 days". Times: relative in rows ("12 min ago"), absolute on
  hover ("Today 14:03").
- Numbers: 1,284 / 3.1M tokens / 62%. Never a bare token count without "tokens".
- Internal names stay out of the main path: `forced_max` → "forced allowance", `finishing_max` → "landing slots", epic
  lanes → "initiative slots", `human_review` → "Waiting on you", "watching" → its stage.
- An error says what happened, why if known, and what to do: "Linear rejected the API key. Check it in Settings." with
  **Open Settings…**.
