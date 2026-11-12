# The Director's ticket page

> **Changed on 2026-11-12.** The brief's place, the note, the Details and Decisions panels and the Connected
> panel changed: see [The window, Home, Work and the ticket page's top](director-window-and-home.md), which
> wins where the two differ.

Design research for the ticket page, and the prototype built on it (TP-1383, second design ticket of
Phase 3b, TP-1381). The page is designed again from scratch around one question: **where does this
ticket stand, and why?**

**Chosen: the catalog's Page layout (TP-1382, Sections › Page layout, laptop and desktop), on
2026-11-04, because** Tony found it more polished than the three alternatives this ticket first built
(A · Story, B · Stage, C · Desk; see [Earlier alternatives](#earlier-alternatives)). It is decision D2
on TP-1383. The prototype below rebuilds that layout as one page, with the life of a real ticket in
it. Tony approved the rebuilt page on 2026-11-04 (decision D3 on TP-1383): it is the design the
Swift ticket page is built from.

The prototype is plain HTML, CSS and JavaScript built from the design catalog
([`catalog/index.html`](catalog/index.html), TP-1382). It opens from disk in a browser, with no build
and no network: [`prototypes/ticket-page/index.html`](prototypes/ticket-page/index.html).

It keeps the catalog's structure and markup zone by zone (the header across the page; on a laptop the
decisions line, then the lifecycle on top of the timeline, with the facts rail beside them and the
decisions in a side sheet; on a desktop the decisions as a third column on the far right) and draws
every part with the catalog's own components and tokens. Its own CSS adds only the frame around the
page and the pieces the catalog's story leaves out: a run's transcript in its line, a finding with
its screenshot, the note for the next run, the earlier decisions, the details, and the Question's exit.

The bar on top picks the **moment** in the ticket's life (Running, Waiting on you, Shipped), the
**width** (Laptop, a 1440 × 900 window with 1180 × 820 pt of content; Desktop, a 1440p display with
2200 × 1360 pt), the **theme** (System, Light, Dark) and **Reduce motion**; **Fit** scales the window
down as one when the browser is smaller, so what is seen is always the layout at that width. The
settings travel in the address.

The page draws one ticket from one file, [`fixtures.js`](prototypes/ticket-page/fixtures.js):
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
(a fold, the decision sheet), tier 4 is on demand (a menu, a link out).

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

How the page answers them, top to bottom, then left to right:

| Question | Laptop (1180 pt) | Desktop (2200 pt) |
| --- | --- | --- |
| 1 Needs me | the decisions line under the header ("A question waits on you"), whose Answer opens the decision sheet | the decisions column on the far right, always open |
| 2 Where and why | the header's situation (kind, cause, what moves it next, for how long); the lifecycle under it: the stages with their state, visits and time, and the tokens by stage | the same |
| 3 Running now | the newest line of the timeline: the run now, unfolded, its current step open and live | the same |
| 4 Since I looked | the line "Since you last looked, at 16:50" in the timeline, and a dot on everything newer; the count beside the Timeline title | the same |
| 5 Run in detail | unfold any run, then any step; findings and screenshots sit in the run | the same |
| 6 Moves | the header's moves (Stop Run… inside More); the note for the next run in the facts rail | the same, Stop Run… in the rail |

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

Every control is one of the catalog's, and has all of its states; the prototype shows each one live, and the pointer turns into a hand on everything that acts on a click.

| Control | Hover | Pressed | Selected | Focused | Disabled, with its reason |
| --- | --- | --- | --- | --- | --- |
| Button (moves, Send, Save Note) | raised surface; primary brightens | settles to 97 % | – | ring outside the shape, keyboard only | faint, the pointer says not allowed; pressing it shows the reason under it: "No run is working.", "A run is already working on it.", "It waits on your answer first.", "Pick an answer first.", "Write a note first." |
| More menu and its items | overlay | settles | the open menu's button stays pressed | ring | an item that can't act says why when chosen ("The ticket is done.") |
| Option card (the Question) | lifts a point on a spring; its radio rings in accent | settles to 99 % | accent ring and tint, radio filled with a bounce | ring | – |
| Answer in my own words | as an option card | | its field unfolds under it and takes focus | ring on the field | Send stays off with "Write your answer first." until there is text |
| Timeline entry (a row) | overlay | – | accent tint and ring; arrows move the selection | ring | – |
| Run line (fold) | overlay | pressed overlay | unfolded: a tint on the whole group | ring | – |
| Step line (fold) | overlay | pressed overlay | unfolded: a tint on the step | ring | a step with nothing in it yet can't unfold and says so on hover |
| Decisions line, Answer | primary brightens | settles | Answer stays pressed while the sheet is open | ring | – |
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

**An answered Question leaves the page.** Send: the Question settles (98.5 %), fades and lifts away
(0.45 s); on a laptop the sheet then slides out to the right as the dimmed page clears, and the
decisions line fades with it; on a desktop the decisions column slides out to the right. The page
then glides into its new shape (a view transition where the browser has one): the situation turns to
"Starting a run", the desktop gives the columns back to the main column, and the timeline gains
"Answered" and "Pause cleared" at its top with the enter motion; a toast confirms the answer was sent.

**The decision sheet** (laptop) slides in from the right on a spring (0.5 s) while the page dims
(0.28 s), and focus moves to the first answer; it closes the same way out, on the close button,
Escape or a click on the dimmed page, and focus returns to Answer.

**Reduce Motion.** Every duration drops to 0.01 s, presses don't scale, nothing lifts or slides: folds
open at once, new entries and lines appear without moving or flashing, the live dot and the flowing
step bar stand still, the answered Question disappears at once, and scrolling to an item jumps instead
of gliding. Nothing that carries meaning is lost: the new-since dot, the tints and the words stay.

**Keyboard.** Tab reaches every control in reading order. 1 to 4 pick an option of the open Question
when focus is not in a text field. Arrow keys move the selection in the timeline. Return and Space
toggle a fold or select a row. Escape closes a menu, a screenshot or the decision sheet; inside the More menu the arrow keys move between its items.

## 5. Responsive rules

Two widths: a **laptop** window (1440 × 900 pt, content about 1180 pt, the functional viewport: every
control reachable, scroll and fold allowed, nothing clipped) and a **1440p display** (content about
2200 pt, the optimize viewport: use the space). Each section is laid out by its own width, not the
window's (a container query at 1600 pt, the catalog's breakpoint). A wider window gives the same
structure more room; it never moves sections around.

**What never stretches.** Reading text keeps its measure (68 characters): the situation's cause, the
Question's why and its options' effects, a finding, a step's lines. Controls keep their three heights
(24, 30, 36 pt). The facts rail keeps a fixed width (340 pt on a laptop, 440 pt on a desktop), the
decisions keep theirs (a 520 pt sheet on a laptop, a 600 pt column on a desktop), and the main column
stops at 1040 pt on a desktop when nothing waits on the person. Screenshots keep their aspect ratio.
The timeline keeps its column of times and marks.

| | Laptop (1180 pt) | Desktop (2200 pt) |
| --- | --- | --- |
| Header | the identifier, title and situation; the moves on their own row under them | one row across the page; the moves on the identifier's line, so the title has the whole width |
| Decisions | one line under the header; Answer opens the side sheet over a dimmed page | a column on the far right, always open, scrolling on its own; no line, no Answer |
| Main column | the lifecycle on top of the timeline, fluid | the same, fluid next to the decisions, up to 1040 pt without them |
| Facts rail | 340 pt: pull request and every check, connected tickets, the note for the next run, decisions, details | the same, 440 pt |

**What collapses.** Ended runs fold into their line (a short bar per step and where it stopped); a
run's steps fold into their name and state. The rarer moves sit in More; on a laptop Stop Run… is the
last item there, in red.

**Scrolling.** The page scrolls as one inside the window; nothing scrolls sideways at either width.
The decision sheet and the desktop's decisions column scroll on their own, with their header and Send
in place. The facts rail is sticky: when it is taller than the window it scrolls with the page until
its foot is in view and stays there, so no fact is out of reach.

## Earlier alternatives

This ticket first built three other architectures for the same page, from the same fixtures:
**A · Story** (the timeline is the page, the facts in a rail beside it), **B · Stage** (a stage on top
with the situation and the Question, then the run beside the history) and **C · Desk** (a desk of
cards, the timeline as a drawer). Tony chose none of them (decision D2): the catalog's Page layout
reads more polished. They are kept in the PR's history (its first commit) and are no longer in the
tree, so there is one page to review.

## Catalog additions

Added to the catalog in this change, with their stories and their rows in
[`design-system.md`](design-system.md):

- **Step list** (new component): a run's steps top to bottom, each unfolding into what the agent did,
  with a live state for the run now. It is the run's transcript, in place; the prototype draws every
  run's steps with it.
- **Phase path** (new component): the phases a ticket went through in order, with counts and times.
  The chosen layout shows the same facts in the lifecycle's stages; the component stays for the
  board's preview and the history view.
- **Situation line**: the five kinds it lacked (waiting for a slot, waiting for a build, blocked by a
  ticket, retrying, cancelled) and a glyph per kind.
- **Timeline entry**: selected, new since you looked, the marker line, and the entering motion.

The catalog's building blocks are exported (`window.CATALOG.kit`) so the prototype draws with the
catalog's own markup instead of copies.

## The choice

Chosen: the catalog's Page layout, on 2026-11-04, because it is more polished than A, B or C
(decision D2 on TP-1383).

Approved: the rebuilt prototype, [`prototypes/ticket-page/index.html`](prototypes/ticket-page/index.html),
on 2026-11-04, because Tony reviewed it at both widths and in both themes and approved it as it is
(decision D3 on TP-1383). The Swift implementation is filed by hand after Phase 3a.
