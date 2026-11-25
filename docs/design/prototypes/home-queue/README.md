# Home: the queue (approved 2026-11-21; epics, dependencies and Recently done approved 2026-11-23)

The approved design of Home for TP-1597. Open `index.html` in a browser: it works (slots, epics, drag and
drop, filters, a virtual list of more than 1,200 rows). `shots/` holds reference renders at 2x.

This folder is the reference for shape, spacing and behaviour. Colours, type and spacing come from the Swift
design tokens and the Gallery, as for every screen; `page.css` holds the exact values used here.

## The screen

Three sections on one 32 pt gutter: **Recently done**, **In progress**, then **Queue**.

### Recently done

- The section head, one line: the title, the count, a two-segment control **Today | Week** (the segmented
  control at the small size), and at the right end a chevron that folds the section to its head. The whole
  head toggles the fold.
- Today is what finished since local midnight; Week is the last 7 days. The count follows the range. The
  range and the fold are remembered; the defaults are Today and open.
- Rows, most recent first. Six rows show (216 pt); the rest is reached by scrolling inside the section.
- The section is not drawn when nothing finished in the last 7 days. When Today is empty and Week is not,
  the head stays with the control, without a count and without rows.
- `shots/recently-done-2x.png`, `recently-done-week-2x.png`, `recently-done-collapsed-2x.png`,
  `recently-done-today-empty-2x.png`.

A done row, one line, the queue row's height (34 pt on a 36 pt pitch), type and 8 pt inner padding:

- the green check of a passed stage, the identifier (fixed column), the title;
- then, as the place asks: the ticket's epic as a quiet flag and identifier, the pull request number
  (58 pt cell), the repo (68 pt cell), and when it was done, right-aligned (76 pt cell): "20 min ago",
  "3 h ago", "yesterday", then the day ("Sat").
- Recently done shows all of them. An epic's done list on a slot card shows the pull request and when. An
  epic's done rows in the queue show only when.

### In progress

- One card per slot, stacked. As many slots as the setting says; a slot with no ticket is an empty outline
  reading "Slot N".
- The slot count is changed here, with the control beside the title (1 to 6).
- A ticket in a slot is never listed in the queue.

A slot card:

- **Header, one line:** status dot, identifier, title, time in the slot, then the actions: Answer… (only
  when it waits on the person), Message…, and Stop as an icon button.
- **Three labelled columns** on shared rows, so each row sits level across the card:
  - **Status:** the ticket page's lifecycle stepper (Coding, Code Review, QA, Merging, Done) without run counts
    and timings: a passed stage is green with "Passed"; the current stage is tinted with its role colour and
    reads "Now", "Waiting on you" or "Needs attention"; a later stage reads "Not yet". Under it, one dot per
    stage that ran with its tokens on the left, and "21.4M of 100M tokens · 21 %" right-aligned, with no bar.
    Last, the status pill with its sentence.
  - **Plan:** the plan's summary (three lines), a bar with "5 of 9 checks proved", the next open check.
  - **Pull request:** number, files and diff size, branch, CI status, review status.
- The Status column takes about half the card.

An epic slot card (`shots/epic-card-closed-2x.png`): when the ticket in the slot is a sub-ticket, its epic
wraps the card.

- **The frame:** 4 pt around the card on the left, right and bottom, corner radius the card's plus 4 pt, half
  the card's surface, a 1 pt separator edge. The card inside is the slot card, unchanged, with 16 pt inner
  padding at the sides so its dot, identifier and title stand on the same columns as an ordinary card's.
- **The band,** 36 pt, one line: a chevron, the epic's flag, its identifier, its title; at the right the
  progress bar (96 pt) with "7 of 14 done", then the time the epic has held the slot ("3 d in the slot").
  The card's own header then reads "1 h 5 min on this ticket".
- **Two controls on the band, independent, both closed at first:**
  - the band itself (its chevron) opens and closes **what is still to come**: the epic's open sub-tickets, in
    their order, below the card (`epic-card-upcoming-2x.png`);
  - the progress bar with its count is one button, with a pressed state, that opens and closes **what is
    done**: the epic's done sub-tickets above the card, oldest at the top and the most recent next to the
    card (`epic-card-done-2x.png`). A click on it does not toggle the band.
  - With both open the wrapper reads as the epic's whole run: done, the one in work, to come
    (`epic-card-both-2x.png`).
- Each list shows six rows (216 pt) and scrolls inside itself; the done list opens at its most recent rows.
- The band's rows share one set of columns: a number cell, the lead icon under the band's flag, the
  identifier under the band's identifier.
- An upcoming row is a queue row: its number, state glyph, identifier, title, dependency marker, repo, and
  on hover the drag handle and Start. Its number continues the epic's count: with 7 done and one in work,
  the first to come is 9.

Once the cards scroll out of view, a strip sticks to the top with one line per slot (dot, identifier, title,
state, time in the slot). Its columns sit exactly over the queue's columns, and each line is a drop target.
For an epic slot the line is the sub-ticket's, with the epic's flag and identifier in quiet text after the
title (`shots/strip-2x.png`).

### Queue

- One row per top-level ticket that holds no slot, in its stored order, each with its position number.
- Saved filters above the list. A filtered row keeps its real number; reordering is off while filtered.
- A row, one line: number, state glyph, identifier (fixed column), title; then what it waits on, its state
  badge, and its repo.
- The number is centred in a cell only as wide as the numbers on screen. On hover the drag handle takes the
  number's place, and Start takes the repo's place: nothing shifts.
- A hovered row ends on the slot cards' left and right edges, with 8 pt inside on both sides.
- The list is virtual: only the rows on screen are drawn.

An epic in the queue (`shots/queue-epic-2x.png`):

- **The epic's row:** a chevron in the state glyph's cell, the identifier, the title, and "2 of 11 done" in
  quiet text before the repo. A click on the row opens and closes its sub-tickets.
- **A sub-ticket's row** follows its epic, one step in: 28 pt, so its state glyph starts where the epic's
  identifier starts. The step is filled by an elbow (a rounded corner, 1.5 pt stroke, tertiary colour, a
  14 pt glyph in the 18 pt cell under the epic's chevron).
- **Numbers:** a sub-ticket is numbered inside its epic, "6.1", "6.2". The whole numbers stay in one column
  and the part after the point hangs to its right; the cell widens only while sub-rows are on screen.
- **The done count is a control,** with a pressed state: it shows the epic's done sub-tickets as quiet done
  rows at the top of its block, and hides them again (`queue-epic-done-2x.png`). They carry an elbow, no
  number and no drag handle, and cannot be dragged or started. Pressing it on a closed epic opens the epic.
- Indentation means "part of" and nothing else.

A dependency shows as a marker in the row's trail, in quiet text: an arrow and the identifier it waits for
("→ TP-976"), and for one that needs a release, the word after it ("→ TP-1590 released"). A dependency that
is met shows nothing.

With a saved filter the list keeps the same form (`queue-filtered-2x.png`): an epic's row shows when it or
any of its open sub-tickets matches, only the matching sub-rows are listed under it, with their real
numbers, and it opens and closes as always.

## Behaviour

- Drag a row onto another row: it moves to that position.
- Drag a row onto a slot (card or strip line), or press Start: it takes that slot. The ticket that held the
  slot stops and becomes number 1 in the queue.
- An epic's row moves with its sub-tickets (`queue-epic-drag-2x.png`). A sub-ticket moves only among its
  epic's sub-tickets; the drop line then starts at the sub-row's step. The same holds inside an epic slot
  card's upcoming list.
- A dependency points upward. A drop that would put a ticket above one it depends on is refused: the list
  stays as it was and a message says why, in these words: "TP-978 depends on TP-977 and must stay below it."
  (`queue-refused-drop-2x.png`, `epic-card-refused-drop-2x.png`).
- Start on a ticket with an unmet dependency is refused, in these words: "TP-977 depends on TP-976 and can’t
  start before it is done." For a dependency that needs a release the last word is "released".
- Start on an epic's row starts its first sub-ticket that can start; Start on a sub-ticket starts that one.
  The epic takes the slot and wraps it.
- Start on an upcoming row of an epic slot card swaps the sub-ticket in work: the started one takes the
  slot, and the one that was in work stops and becomes the first to come.
- Stop on a card frees the slot. A stopped sub-ticket goes back to the head of its epic, and the epic
  becomes number 1 in the queue, open.
- A free slot goes, in queue order, to the first ticket that can start. An epic that already holds a slot
  comes first, with its next sub-ticket whose dependencies are met.
- When a slot's ticket finishes, it appears at the top of Recently done (`finish-2x.png`). A sub-ticket's
  epic keeps the slot: its next sub-ticket that can start takes over at once and the band's count goes up.
  An ordinary ticket leaves the slot free, and the queue fills it.
- A ticket that cannot start (it waits on another ticket, or on the person) keeps its number and is skipped.

## New for the Gallery

The slot card with its empty state and its folded strip line; the checks bar; the token line; the slot count
control; the queue row with its number cell and drag handle. The lifecycle stepper is the ticket page's
component, reused.

Added on 2026-11-23: the epic slot card (closed, with what is to come, with what is done, with both); the
done row; the epic queue row; the sub-ticket row with its elbow; the dependency marker in its two kinds; the
Recently done section head with its range control.

## Sample data

The first queue rows and the slots are real tickets of the factory from 2026-11-21 to 2026-11-23, with two
epics made up of them. The other 1,223 rows are generated to show the list at scale.

`page.js` reads a state from the address so a render can show it: `?scroll=`, `hover=`, `drag=`, `toast=`,
and `do=` with a list of steps (`band:0`, `bdone:0`, `done:TP-975`, `finish:0`, `range:week`, `view:ready`,
`start:TP-977`, `move:TP-978:0`). It changes nothing when the address has no query.
