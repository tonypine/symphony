# Home: the queue (approved 2026-11-21)

The approved design of Home for TP-1597. Open `index.html` in a browser: it works (slots, drag and drop,
filters, a virtual list of 1,243 rows). `shots/` holds reference renders at 2x.

This folder is the reference for shape, spacing and behaviour. Colours, type and spacing come from the Swift
design tokens and the Gallery, as for every screen; `page.css` holds the exact values used here.

## The screen

Two sections on one 32 pt gutter: **In progress**, then **Queue**.

### In progress

- One card per slot, stacked. As many slots as the setting says; a slot with no ticket is an empty outline
  reading "Slot N".
- The slot count is changed here, with the control beside the title (1 to 6).
- A ticket in a slot is never listed in the queue.

A slot card:

- **Header, one line:** status dot, identifier, title, epic chip, time in the slot, then the actions:
  Answer… (only when it waits on the person), Message…, and Stop as an icon button.
- **Three labelled columns** on shared rows, so each row sits level across the card:
  - **Status:** the ticket page's lifecycle stepper (Coding, Code Review, QA, Merging, Done) without run counts
    and timings: a passed stage is green with "Passed"; the current stage is tinted with its role colour and
    reads "Now", "Waiting on you" or "Needs attention"; a later stage reads "Not yet". Under it, one dot per
    stage that ran with its tokens on the left, and "21.4M of 100M tokens · 21 %" right-aligned, with no bar.
    Last, the status pill with its sentence.
  - **Plan:** the plan's summary (three lines), a bar with "5 of 9 checks proved", the next open check.
  - **Pull request:** number, files and diff size, branch, CI status, review status.
- The Status column takes about half the card.

Once the cards scroll out of view, a strip sticks to the top with one line per slot (dot, identifier, title,
state, time in the slot). Its columns sit exactly over the queue's columns, and each line is a drop target.

### Queue

- Every ticket that holds no slot, in its stored order, each with its position number.
- Saved filters above the list. A filtered row keeps its real number; reordering is off while filtered.
- A row, one line: number, state glyph, identifier (fixed column), title; then what it waits on, its state
  badge, and its repo.
- The number is centred in a cell only as wide as the numbers on screen. On hover the drag handle takes the
  number's place, and Start takes the repo's place: nothing shifts.
- A hovered row ends on the slot cards' left and right edges, with 8 pt inside on both sides.
- The list is virtual: only the rows on screen are drawn.

## Behaviour

- Drag a row onto another row: it moves to that position.
- Drag a row onto a slot (card or strip line), or press Start: it takes that slot. The ticket that held the
  slot stops and becomes number 1 in the queue.
- Stop on a card frees the slot. A free slot goes first to a sub-ticket of a ticket in progress, then to the
  first ticket in order that can start.
- A ticket that cannot start (it waits on another ticket, or on the person) keeps its number and is skipped.

## New for the Gallery

The slot card with its empty state and its folded strip line; the checks bar; the token line; the slot count
control; the queue row with its number cell and drag handle. The lifecycle stepper is the ticket page's
component, reused.

## Sample data

The first 20 queue rows were the factory's real tickets on 2026-11-21. The other 1,223 are generated to show
the list at scale.
