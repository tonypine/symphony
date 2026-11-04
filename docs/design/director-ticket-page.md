# The Director's ticket page

Design research for the ticket page, and the three prototypes built on it (TP-1383, second design
ticket of Phase 3b, TP-1381). The page is designed again from scratch around one question: **where
does this ticket stand, and why?**

**Choice:** not made yet. Tony picks one of the three prototypes in the Inbox; the pick, its date and
its reason are recorded here and in the chosen prototype's page title.

The prototypes are plain HTML, CSS and JavaScript built from the design catalog
([`catalog/index.html`](catalog/index.html), TP-1382). They open from disk in a browser, with no build
and no network:

| Prototype | File | The idea |
| --- | --- | --- |
| A · Story | [`prototypes/ticket-page/a.html`](prototypes/ticket-page/a.html) | The timeline is the page. The run that is running now is its newest entry, unfolded and live; the open Question sits above it; the facts sit in a rail beside it. |
| B · Stage | [`prototypes/ticket-page/b.html`](prototypes/ticket-page/b.html) | A stage on top answers "does anything need me" and "where does it stand and why" on its own: one sentence, the phases, the Question. Below it the page splits: the run, step by step, beside the ticket's history. |
| C · Desk | [`prototypes/ticket-page/c.html`](prototypes/ticket-page/c.html) | A desk of cards, one question each. The full timeline is a drawer: it slides over the cards on a laptop and stays docked on the right on a desktop. |

Each page has the same control bar on top: switch between A, B and C; pick the **moment** in the
ticket's life (Running, Waiting on you, Shipped); pick the **width** (Laptop, content 1180 pt;
Desktop, content 2200 pt); **Fit** scales the page down to the window, off shows it at its real size;
**Theme** follows the system or forces light or dark; **Reduce motion** shows the page as it moves with
the system setting on. The settings travel in the address, so switching prototype keeps them.

All three draw the same ticket from one file, [`fixtures.js`](prototypes/ticket-page/fixtures.js):
TP-1244, "The paused line on the ticket page", merged as PR #741 on 30 October 2026. Its blocker
TP-1251 (PR #728), its merge commit and the screenshots QA shows are this repository's own (the
snapshots under `macos/Tests/Snapshots`). The run-by-run detail between them is a reconstruction of how
such a ticket moves through Symphony, so the page has one of everything it must show: an
implementation run, a CI fix, a review round that sent it back, a QA pass with a finding and a
screenshot, a question asked and answered, two pauses, and the merge.

## 1. The facts a ticket page can show

Every fact the page can show, ranked by how often a person needs it on a visit and how much it
matters when they do. **Often**: every visit, most visits, some visits, rarely. **Matters**: *acts*
(the person must do something, or the ticket stops), *decides* (it changes what the person does next),
*explains* (it says why), *records* (it is there to look up). The rank sets the tier: tier 1 is on the
first screen without scrolling at both widths, tier 2 is visible on the page, tier 3 is one click away
(a fold, a filter, a drawer), tier 4 is on demand (a menu, a link out).

| # | Fact | Often | Matters | Tier |
| --- | --- | --- | --- | --- |
| 1 | The open Question: its title, why, the options with their effects and trade-offs, the recommendation, what happens if unanswered | every visit while open | acts | 1 |
| 2 | The situation: one kind (§3), its cause, what it waits on, since when | every visit | decides | 1 |
| 3 | Identifier and title | every visit | records | 1 |
| 4 | The run now: its kind, the step it is on, how long so far | most visits while running | explains | 1 |
| 5 | The moves: Answer, Start Now, Stop Run, Move to, Force, Restart, each saying why when it can't act | most visits | acts | 1 |
| 6 | What happened since the person last looked | most visits | decides | 1 (a marker) |
| 7 | The phase and the phases it went through, with counts (Code Review ×3, Rework ×2) | most visits | explains | 2 |
| 8 | The newest message of the run now | most visits while running | explains | 2 |
| 9 | The pull request: number, state, head commit | most visits | decides | 2 |
| 10 | The checks, by workflow, each with its state and time | some visits; every visit when red | acts when red | 2 when red, 3 when green |
| 11 | Open findings from Code Review and QA, with screenshots | some visits | decides | 2 while open |
| 12 | The timeline: runs, phase moves, pauses set and cleared, questions asked and answered, person actions, rule actions, verdicts | some visits | explains | 2 |
| 13 | A run's steps, unfolded into what it said, the tools it called and what they returned | some visits | explains | 3 |
| 14 | Pauses now: each reason and since when, and whether the Director may release it | some visits | acts | 1 when paused (it is the situation) |
| 15 | Blockers it waits on, open and resolved | some visits | decides | 2 when open, 3 when resolved |
| 16 | Tickets it holds up | some visits | decides | 2 |
| 17 | Earlier decisions (D1, D2…) with the question and the answer | some visits | explains | 2 |
| 18 | The note for the next run: what is set, whether a run read it, and the field to write one | some visits | acts | 2 |
| 19 | Tokens: spent so far by stage, against the ticket's cap | some visits | decides near the cap | 2 |
| 20 | Time: agent work, time in each phase | some visits | explains | 2 (in the phase path) |
| 21 | The epic and its progress | some visits | explains | 2 |
| 22 | Priority | rarely | decides | 2 |
| 23 | Labels | rarely | records | 3 |
| 24 | Repo | rarely | records | 2 (one chip) |
| 25 | The brief and its walkthrough | rarely | explains | 3 |
| 26 | Screenshots and other attachments | rarely, unless QA failed | explains | 2 when tied to an open finding, 3 otherwise |
| 27 | Each run's model | rarely | records | 3 |
| 28 | Each run's tokens and duration | rarely | records | 3 |
| 29 | Retry count and when the next try starts | rarely; every visit while retrying | decides | 1 while retrying (it is the situation) |
| 30 | The workspace path, with a copy button | rarely | records | 3 |
| 31 | The forced flag (ahead of the queue) | rarely | explains | 2 (a chip) |
| 32 | Who did each thing: Symphony, a rule (named), a person, an agent run | some visits | explains | 2 (in each timeline entry) |
| 33 | Links out: the ticket in Linear, the PR on GitHub, a check's log | rarely | records | 4 |

Today's page shows most of these in cards (Now, Last message, Timeline, Ticket, Earlier decisions,
blockers, labels, priority, screenshots), and that is its trouble: a phase badge, counters and status
text can say different things about where the ticket stands (2), the Question is read-only (1), the
timeline is dense, has no phase moves and cannot unfold a run into its steps (12, 13), the run's
transcript is a separate window of rows (4, 8, 13), and the note field is nearly hidden (18). Three
facts are new: the phase path with counts (7), a run's steps unfolded into its transcript (13), and the
marker for what is new since the person last looked (6).

## 2. The questions a person asks, in order

A person opens a ticket page to answer these, in this order, and stops as soon as they have their
answer. The layout answers them top to bottom, or left to right on a desktop, in the same order.

1. **Does anything need me on this ticket?** The open Question, with its options on the page, or one
   quiet line saying nothing needs you. It is the first thing under the title; its place never jumps
   when there is none.
2. **Where does it stand, and why?** The situation in one line (§3): the kind, its cause, what moves it
   next, since when. Under it, the phases it went through with their counts and times.
3. **What is running now, and how far is it?** The run now: its kind, its steps with the current one
   live, its newest lines, its time and tokens so far. On the page, never in another window. When
   nothing runs, the place says why (waiting on you, waiting for a slot, done).
4. **What happened since I looked?** A marker in the timeline at the moment the person last looked,
   and a dot on everything newer.
5. **What did that run do, in detail?** Any run unfolds into its steps, and any step into what the agent
   said, the tools it called and what came back, with the findings it produced and their screenshots.
6. **What can I do from here?** The moves, always in the same place, each saying why when it can't act
   now; the note for the next run; the facts to look up.

How each prototype orders them:

| Question | A · Story | B · Stage | C · Desk |
| --- | --- | --- | --- |
| 1 Needs me | the Question, first in the body | the Question, inside the stage | the Question, a card across the desk |
| 2 Where and why | the header's situation and phase path | the stage's sentence, phases and tokens | "Where it stands" card |
| 3 Running now | the newest timeline entry, unfolded and live | the run pane, left of the history | "Running now" card |
| 4 Since I looked | a marker in the timeline | a marker in the history | "Since you last looked" card; a line opens the drawer at it |
| 5 Run in detail | unfold the run, then a step | pick a run in the history; the run pane shows it | unfold it in the drawer |
| 6 Moves | header rail; note in the rail | header rail; note under the split | header rail; note card |

## 3. The situation vocabulary

A ticket is in exactly one situation at a time. The situation line says it in one pattern: **the
word** (in its status colour, with its glyph), **the cause** (one sentence of fact), **what moves it
next**, and **since when**. Colours and glyphs are the catalog's (Situation line component); colour is
never alone: the glyph and the word always come with it.

| Kind | Pattern | Glyph | Colour | Example |
| --- | --- | --- | --- | --- |
| Working on step X | **Working on the *step* step** · *Run* is *doing what*. · It hands off to *next phase* when it *ends*. · for *age* | dashed circle (working) | blue, working | Working on the tests step · Implementation run 2 is answering Code Review's finding. · It hands off to Code Review when it pushes. · for 8 min |
| Waiting for a slot | **Waiting for a slot** · *n* runs are ahead of it; Symphony runs *limit* at a time. · Starts when a slot frees. | clock | gray, idle | Waiting for a slot · Three runs are ahead of it; Symphony runs four at a time. · Starts when a slot frees. · for 12 min |
| Waiting for CI | **Waiting for CI** · Checks are running on PR #*n*. · *Next phase* starts when they pass. | dashed circle (working) | blue, working | Waiting for CI · Checks are running on PR #741. · Code Review starts when they pass. · for 6 min |
| Waiting for a build | **Waiting for a build** · The app for this commit is being built for QA. · QA starts when the build is ready. | box | blue, working | Waiting for a build · … · for 4 min |
| Waiting on you | **Waiting on you** · *Run* asked *the question, in short*. · Answer below; the next run starts at once. | person with a mark | orange, you | Waiting on you · Implementation run 3 asked how the paused line's times should read. · for 8 min |
| Blocked by a ticket | **Blocked by *TP-n*** · It is in *its phase*. · Starts when *TP-n* lands. | lock | gray, idle | Blocked by TP-1251 · It is in Code Review. · Starts when TP-1251 lands. · for 17 h |
| Paused by a rule | **Paused** · *The rule's reason in plain words*. · *What lifts it*. | pause | gray, idle | Paused · Dispatch is paused: Deploy freeze. · Starts when you resume dispatch. · for 1 h 4 min |
| Retrying | **Retrying** · The run stopped: *cause*. · Try *k* of *n* starts at *time*. | arrow round | red, problem | Retrying · The run stopped: the agent hit its usage limit. · Try 2 of 3 starts at 16:20. · for 3 min |
| Done | **Shipped** · Merged as PR #*n* at *time*. | filled tick | green, done | Shipped · Merged as PR #741 at 21:05. |
| Cancelled | **Cancelled** · *Who* cancelled it; PR #*n* was closed. | slashed circle | gray, idle | Cancelled · You cancelled it; PR #812 was closed. · 2 days ago |

When more than one is true, the line shows the first in this order and the others stay visible where
they live (the paused line's rows, the blockers, the checks): **Waiting on you** (only a person moves
it) · **Retrying** (something broke) · **Blocked by a ticket** · **Paused by a rule** · **Waiting for
CI** · **Waiting for a build** · **Waiting for a slot** · **Working on step X** · **Done** ·
**Cancelled**. A ticket paused for several reasons names the first by this order and says "and *n*
more", which the paused line lists.

The forced flag is not a situation: a forced ticket shows its situation and a Forced chip beside it.
The phase (In Progress, Code Review…) is not the situation either: it is where the ticket is in its
workflow, shown in the phase path; the situation is what is happening to it now.

The catalog gains the five kinds it lacked as stories of the Situation line (slot, build, blocked,
retrying, cancelled), and the line takes a glyph of its own for each.

## 4. Interaction and motion

Every control is one of the catalog's, and has all of its states. The prototypes show each one live.

| Control | Hover | Pressed | Selected | Focused | Disabled, with its reason |
| --- | --- | --- | --- | --- | --- |
| Button (moves, Send, Save Note) | raised surface; primary brightens | settles to 97 % | – | ring outside the shape, keyboard only | faint, the pointer says not allowed; pressing it shows the reason under it: "No run is working.", "A run is already working on it.", "It waits on your answer first.", "Pick an answer first.", "Write a note first." |
| More menu and its items | overlay | settles | the open menu's button stays pressed | ring | an item that can't act says why when chosen ("The ticket is done.") |
| Option card (the Question) | lifts a point on a spring; its radio rings in accent | settles to 99 % | accent ring and tint, radio filled with a bounce | ring | – |
| Answer in my own words | as an option card | | its field unfolds under it and takes focus | ring on the field | Send stays off with "Write your answer first." until there is text |
| Timeline entry (a row) | overlay | – | accent tint and ring; arrows move the selection | ring | – |
| Run line (fold) | overlay | pressed overlay | unfolded: a tint on the whole group | ring | – |
| Step line (fold) | overlay | pressed overlay | unfolded: a tint on the step | ring | a step with nothing in it yet can't unfold and says so on hover |
| Filter chips and index | overlay | 95 % | accent ring, the count stays | ring | – |
| Check row, relation row, epic | overlay; the arrow slides 2 pt | pressed overlay | – | ring | – |
| Screenshot | the image grows 6 % inside its frame | 97 % | opens large in a sheet | ring | – |
| Segmented controls (page bar) | overlay | – | the thumb slides on a spring | ring | – |

**Expand and collapse.** A run unfolds into its steps and a step into its lines on the catalog's fold:
the height opens on the standard easing (0.28 s), the lines fade down into place staggered by 35 ms,
the chevron turns on a spring. Folding reverses it. The run now and its current step are unfolded by
default; ended runs are folded, and inside one, a step that failed or asked a question is unfolded.

**A new event enters the timeline** at the top: it drops in from 12 pt above on a spring (0.45 s) and
its accent tint fades out over 1.2 s, so the eye finds it once and then it is like the others. A new
line of the run now enters at the bottom of its step, fades up and flashes the working tint; the agent's
newest words carry a caret while it writes. Entries newer than the person's last look keep a small
accent dot; the marker line "Since you last looked, at 16:50" sits between old and new.

**An answered Question leaves the page.** Send: the Question block settles (98.5 %), fades and lifts
8 pt away in 0.42 s; the page redraws without it; the situation turns to "Starting a run"; the
timeline gains "Answered" and "Pause cleared" at the top with the enter motion; a toast confirms the
answer was sent. The place of the Question becomes the quiet line "Nothing needs you", so nothing
below it jumps further than the Question's own height.

**Reduce Motion.** Every duration drops to 0.01 s, presses don't scale, nothing lifts or slides: folds
open at once, new entries and lines appear without moving or flashing, the live dot and the flowing
step bar stand still, the answered Question disappears at once, and scrolling to an item jumps instead
of gliding. Nothing that carries meaning is lost: the new-since dot, the tints and the words stay.

**Keyboard.** Tab reaches every control in reading order. 1 to 4 pick an option of the open Question
when focus is not in a text field. Arrow keys move the selection in the timeline. Return and Space
toggle a fold or select a row. Escape closes a menu, a screenshot or the timeline drawer.

## 5. Responsive rules

Two widths: a **laptop** window (1440 × 900 pt, content about 1180 pt, the functional viewport: every
control reachable, scroll and fold allowed, nothing clipped) and a **1440p display** (content about
2200 pt, the optimize viewport: use the space). Each section is laid out by its own width, not the
window's (a container query at 1600 pt, the catalog's breakpoint).

**What never stretches.** Reading text keeps its measure (68 characters): the situation's cause, the
Question's why and its options' effects, a finding, the brief, a step's lines. Controls keep their
three heights (24, 30, 36 pt). A column of facts keeps a fixed width (340 to 420 pt on a laptop, about
420 to 440 pt on a desktop); C's cards share the width evenly, and their text still stops at the
measure. Screenshots keep their aspect ratio. The timeline keeps its column of times
and marks.

**What gains a column on a desktop**, prototype by prototype:

| | Laptop (1180 pt) | Desktop (2200 pt) |
| --- | --- | --- |
| A · Story | two columns: the timeline body (fluid) and the facts rail (340 pt); filters as chips above the timeline | three columns: a filter index (200 pt), the timeline body (up to 860 pt) and the facts rail, split into two columns of about 420 pt |
| B · Stage | the stage across; then the run pane (fluid) beside the history (420 pt); the facts in a two-column band under them | the stage across, its side column wider (520 pt); then three panes: history (560 pt), the run (fluid), the facts (440 pt) |
| C · Desk | two columns of cards; the Question and the four first cards across both; the timeline a drawer over the cards (600 pt) | four columns of cards; the timeline docked as a fifth column (640 pt), the cards in three |

**What collapses.** At both widths the checks fold behind "Show every check" while they pass (their
sum stays on the line); a red check would unfold them. The rarer moves sit in More at both widths. On
a laptop the timeline's filters become chips above it, and in C the timeline drawer covers the cards
and dims them; on a desktop it never covers anything.

**Scrolling.** The page scrolls as one; nothing scrolls sideways at either width. Only C's drawer
scrolls on its own, so the cards stay where they are.

## The three architectures, compared

| | A · Story | B · Stage | C · Desk |
| --- | --- | --- | --- |
| Reads as | one story, newest first | an answer, then the evidence | a set of answers side by side |
| Strength | everything in time order, nothing hidden; the run now is the story's latest line | the order of the questions is the order of the page; the run now has a whole pane | scans fastest; each card stands alone and could be reused on other pages |
| Cost | the situation and the phases live in the header only; a long timeline pushes the older facts down | the run pane and the history repeat the runs (as detail and as rows) | the story is split: what happened lives in a drawer, and the cards repeat parts of it |
| Laptop | dense but complete | the split leaves the history narrow (420 pt) | two columns of cards scroll long |
| Desktop | wide whitespace around a measured body | the best use of the width: three panes, no drawer | the docked drawer makes it a dashboard plus a timeline |

**Recommendation: B · Stage.** It is the only one whose layout is the list of questions in §2: the
stage answers "does anything need me" and "where does it stand and why" before anything else, the run
pane answers "what is running now" on the page with the run's own steps, and the history answers "what
happened since I looked" beside it. It keeps the timeline visible (unlike C) without making the person
read it to learn the situation (unlike A).

## Catalog additions

Added to the catalog in the same change, with their stories and their rows in
[`design-system.md`](design-system.md):

- **Phase path** (new component): the phases a ticket went through in order, with counts and times.
- **Step list** (new component): a run's steps top to bottom, each unfolding into what the agent did,
  with a live state for the run now. It is the run's transcript, in place.
- **Situation line**: the five kinds it lacked (waiting for a slot, waiting for a build, blocked by a
  ticket, retrying, cancelled) and a glyph per kind.
- **Timeline entry**: selected, new since you looked, the marker line, and the entering motion.

The catalog's building blocks are exported (`window.CATALOG.kit`) so the prototypes draw with the
catalog's own markup instead of copies.

## The choice

Pending: Tony's pick in the Inbox. Recorded here as "Chosen: …, on …, because …" when made.
