# The Director's window, Home, Work and the ticket page's top: decisions of 2026-11-12

Tony approved these on 2026-11-12, working in the design catalog. They are drawn in
[`catalog/index.html`](catalog/index.html) under **Sections › Window**, and that section is the design the
app is built from. Where an older document or the ticket-page prototype says otherwise, this page and the
catalog win; the list at the end names what each replaces.

## Rules that hold for every page

1. **Native means built natively for macOS. It does not mean drawn with system styles.** The approved design
   is carried into the app with its look, all of it: colours, type, cards, shadows, the window around the
   page. macOS draws only the three window buttons.
2. **A block is drawn only when it has something to say.** No empty groups, no "None yet", no "Nothing…"
   lines. A panel with nothing in it is absent.
3. **A row is one line.** A second line is allowed only when it carries a fact the Director needs and the
   row's badge does not already state it.
4. **No support text.** No summary sentence over a list, no caption or hint on a divider or a group, no
   wrapper card around a single list. The list explains itself.
5. **Style is foundational.** The order of building is tokens, then shared components, then pages. A page is
   composed of shared components wherever one fits; it is never the place a look is first drawn.
6. **One component per thing.** What is meant to look the same in several places is one shared component, built
   once from the catalog with every state it has there. A page may keep a private component only for something
   unique to it.

## The window

Stories: `#sections/window/ticket-page-laptop`, `…/sidebar-collapsed`, `…/window-not-focused`,
`…/dispatch-paused`. Markup in `stories.js`: `windowShell`, `winSidebar`, `winToolbar`, `winStatus`. Styles in
`components.css` under "Window".

| Part | Decision |
| --- | --- |
| Background | `--surface-window` with `--backdrop-glow`, behind the sidebar and the page |
| Sidebar | 232 pt, flush with the window, a hairline (`--stroke-separator`) on its right. Rows are 30 pt (`--control-md`), radius `--radius-control-md`: Home, Journal, Work, Insights, Factory, and under Factory, indented, Setup, Repos, Diagnostics, Settings. The current destination has the accent tint (`--accent-tint`) with accent text, weight 600; with the window not focused it is `--surface-pressed` with primary text. Counts use the Count badge: orange for what needs the Director, red for a problem. Collapsed it is 60 pt of glyphs, the counts as 8 pt dots |
| Toolbar | The Director draws it; the system toolbar is not used. 44 pt, glass (`--material-glass`), a hairline under it. Left to right: show or hide the sidebar, Back and Forward, a hairline, where you are, then Find a ticket (small search field, 232 pt, ⌘F), the Inbox with its count, Refresh. Where you are is a breadcrumb (Work › the epic › the identifier on a ticket page; the destination's name elsewhere), never the page's title. On Work, the Initiatives and Tickets switch (small segmented control) follows the breadcrumb. A page's other controls live in the page: the toolbar never changes with the page beyond the breadcrumb and that switch |
| Status line | 30 pt, glass, under the page: the dispatch control (a status dot and "Dispatch on" or "Dispatch paused", opening its menu), the counts (in progress, in the queue, need you), then the build and the connection |

## Home

Story: `#sections/window/home-laptop`, `…/home-a-long-chain-shown-whole`, `…/home-desktop`. Markup:
`homePage`, `homeRow`, `epicRow`, `homeKids`. Styles under "Home".

Home is two lists and nothing else: no card around them, no sentence above them, no captions.

- **In progress** is every ticket that has started and has not landed, whatever it is doing now: a run is
  working, CI is running, it waits on the Director, it retries later. A ticket of an epic sits under its
  epic's row, so an epic with a ticket in progress is in progress too; the epic row carries its progress
  strip and "4 of 9". Tickets with no epic sit at the top level.
- **Queue** is every ticket that has not started, as the tree Symphony holds: a ticket sits one step in under
  the ticket it waits on. A chain steps down and to the right; two tickets on one rail both wait on the
  ticket above the rail. Past two steps the rest folds into a "+6" pill that opens it. A root that waits on a
  ticket in progress names it at the right ("→ TP-1480"). A queued ticket shows its epic as a chip.
- **Not on Home:** tickets in Backlog, tickets below the dispatched priority, and tickets behind one of
  those. They are found in Tickets.
- **A row** is one line: state glyph (a live dot while a run works), identifier, title; at the right the
  state as a badge, the move when it needs the Director (Answer, Unblock…), and for how long.
- The two titles, "In progress" and "Queue", are set in `--type-sentence`.
- "Waiting for a slot" is said only of a ticket that can start and has no free slot.

## Work: Initiatives

Stories: `#sections/window/initiatives-laptop`, `…/initiatives-every-sub-ticket`, `…/initiatives-desktop`.
Markup: `initiativesPage`, `epicItem`, `storyRow`, `epicStrip`.

Left, 340 pt (400 on a desktop): the epics, under "Active" and "Done recently", each a card with its
identifier, "3 of 26 done", its title on at most two lines, its progress strip and a legend of what is not
done. The picked epic has the accent ring. Right: the epic's identifier and repo, its title in
`--type-title`, a sentence ("3 of 26 done. TP-1441 is being worked on; 22 wait behind it, in order."), the
strip, then "Sub-tickets, in landing order": one 36 pt line each, numbered. A landed ticket shows its date
and pull request; the one being worked on is highlighted with its situation and step bars; the next one says
what it waits for; the rest fold behind "20 more wait in line, in this order". On a desktop the two columns
are centred and the story stops at 1040 pt.

## Work: Tickets

Stories: `#sections/window/tickets-laptop`, `…/tickets-filtered-with-the-details`, `…/tickets-desktop`.
Markup: `ticketsPage`.

A glass bar: the saved view (pop-up, a dot when it has unsaved changes), the filters as chips each with its
remove button, Filter, Save View when the view changed, the count, Columns, and the details toggle. Under
it the table in a panel: Ticket, Title, Repo, Epic, Situation, Since, Labels, Priority; Repo and Labels show
from 1600 pt. Title and Situation share the room that is left, two parts to three; a title or a cause is cut
with an ellipsis, the situation's word never is. The details panel, 340 pt at the right, shows the picked
ticket: identifier and chips, title, situation, Since, Phase, Pull request, Priority, Tokens, and Open Ticket.

## The ticket page

Story: `#sections/window/ticket-page-laptop` and `#sections/page-layout/…`. Markup: `ticketPage`,
`briefBlock`, `composer`, `pageHeader`, `connectedPanel`, `decisionsPanel`.

- **The brief is on top of the main column**, above the Lifecycle, across the card's width, in the reading
  style (`--type-reading`: 16 px, line height 1.4, letter spacing 0.02em; `--tracking-reading`). Three lines
  show; "Read all of it, with the walkthrough" unfolds the rest, the Walkthrough and "What was asked". Its
  label says who wrote it and when. Before a run has written one, the place shows "Asked for" and the
  ticket's goal.
- **Writing to the ticket** is one text box above the timeline. Send and its ⌘↩ hint appear once there is
  text. What is sent becomes an entry of the timeline ("You wrote: …"), with a line saying whether a run has
  read it and when. Each message is its own entry; none replaces another. There is no Note panel.
  *Open:* whether sending starts a run when none is working, or the message waits for the next run. Drawn
  as: it waits, and the next run reads it first.
- **Priority and labels** sit on the identifier's line in the header, after the epic chip. **The workspace
  path and the Linear link** are in the More menu (Copy Workspace Path, Open in Linear). There is no Details
  panel, and no Repo, Models or Links rows.
- **Decisions** is a panel only when the Director has answered something on the ticket.
- **Connected:** every ticket row is one line (dot, identifier, title, badge); the highlight marks this
  ticket. "Waiting on" and "Holding up" are drawn only when there is a ticket to list; a ticket with no epic
  has no Epic block; with nothing connected there is no Connected panel.
- **Laptop layout:** the timeline starts 24 pt under the Lifecycle card. The last grid row takes the height
  the facts rail adds (`grid-template-rows: auto auto 1fr`).
- The right-hand column is, in order: Pull request, Connected, Decisions.

## What this replaces

- `design-system.md` §2 principle 7 ("Native by default") and §3's "In SwiftUI each maps to a system value":
  rule 1 above. TP-1483 rewrote those lines.
- `director-app-screens.md` §0 "The window": its Structure, Toolbar and Design rows.
- `director-ticket-page.md`: the brief's rank ("rarely", tier 3), the Note, Decisions and Details panels, and
  the Connected panel's captions and its "Waiting on: Nothing now…" sentence.
- The ticket-page prototype (`prototypes/ticket-page/`): its Note and Details panels and its missing brief.
  Its Connected panel already follows this page. The catalog's Window section is the reference until the
  prototype is rebuilt from it.
- The catalog's Board group story with an empty group, and the board's "Waiting on you / Needs attention /
  Working / Forced" groups: Home above.
