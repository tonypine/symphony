# Ticket page: a run reads as a conversation (approved 2026-11-24)

The approved design of what a run shows on the ticket page, unfolded: its steps and, inside each, what the
agent said and did. Open `index.html` in a browser. It holds four scenes on real runs, each with a
**Before | After** switch on the same data; `shots/` holds reference renders at 2x.

This folder is the reference for shape, spacing and behaviour. Colours, type and spacing come from the Swift
design tokens and the Gallery, as for every screen; the page's own `<style>` holds the exact values used here.

## Why

Today every line of a run is drawn the same: the agent's notes, each tool call and each tool result, at one
size, one indent, a timestamp each, results in monospace. In the "Write the code" step of TP-1644, 207 rows
are drawn for 27 notes. The notes are what a person reads; the rest is needed for audit only. A note written
in Markdown is shown raw and cut with "…". A run that walks no steps (Code Review, QA) loses its whole
conversation when it ends and reads "This run recorded no steps."

## The design

- **Notes are the content.** Reading size (14 pt, the compact reading style), the text face, the full width
  of the column. A note renders its Markdown: bold, inline code, lists, paragraphs, code blocks. A note is
  never cut and has no "Show more".
- **What a note did folds under it into one line:** a count and a gist, "3 actions · wrote
  RecentlyDoneTests.swift, ran 2 commands". Files written or edited are named as chips. A click unfolds the
  actions as the rows drawn today (tool, short description, result), monospace only there.
- **Actions with no note before them** are one folded line, "23 actions · read 1 file, ran 22 commands".
  No sentence is invented for them.
- **A failure is never folded.** A failed command or a red test is its own row in the problem treatment, with
  the first lines of what came back. The same failure repeated back to back is one row with "×8".
- **The time is a small line above the entry**, shown only when the minute changes. It takes no column.
- **Spacing:** 12 pt between entries, 4 pt between a note and its fold line.
- **Facts drawn as components, where the run recorded them:** a verdict chip (Code Review's "Request
  changes", with the files and line ranges of its findings), a step's answer in QA (pass, fail, blocked),
  evidence counts, a test-result line, the checks a test file covers, and screenshots where they were taken,
  named.
- **While the run works,** the last entry carries "Working"; its fold line reads "N actions so far".
- **Show all events** unfolds every group at once: in the step's header, or on the run's meta line for a run
  with no steps.
- **A finished run keeps its conversation.** A run with no steps shows the same notes, verdict and fold
  lines as while it ran. The body never reads "This run recorded no steps."
- **A review that sends work back looks like it:** "Request changes" in the Sent back treatment (amber,
  return arrow), not a green check, and no "Pushed and handed off" on a run that pushes nothing.
- **Blocked** is the idle grey with a struck circle; amber stays for what waits on the person.

## The scenes

| Scene | Run | Rows before | Rows after |
| --- | --- | --- | --- |
| Implementation | TP-1644, "Write the code": 27 notes, 90 tool calls, 1 failed | 207 | 55 |
| QA | TP-1610, a walk session: 9 notes, 67 tool calls, 9 failed | 143 | 20 |
| Silent stretch | made from the first scene: 23 actions with no note, a red test run | 59 | 8 |
| Code Review | TP-1644, pull request #1070: 1 note, 6 tool calls; Running and Finished | 13 | 2 |

## What the prototype had to guess, and the app must not

The page draws only what a run hands over as facts. The prototype read three things out of command text
because no fact existed for them; in the app each comes from Symphony's own record:

- a QA step's answer (pass, fail, blocked);
- the files a run edited through shell commands (only files written with the Write tool are named here);
- the commit a run made.

Screenshot thumbnails are placeholders here; the app shows the pictures. The **Before** view is rebuilt from
the design catalog's step list, so it is close to the app's look today, not exact.
