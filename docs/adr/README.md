# Architecture decision records

An architecture decision record (ADR) is a short document that records one design decision: the
problem it answers, what was decided, what follows from it, and the options that were turned
down. An accepted ADR is the design of record for its subject. When the code and an ADR disagree,
either the code is unfinished (the ADR says which tickets deliver it) or the ADR needs a new
version.

## Numbering

- Each ADR is one file, `NNNN-short-title.md`, numbered with four digits in the order it was
  written: `0001`, `0002`, and so on. A number is never reused.
- An accepted ADR is not rewritten to change its decision. A later ADR replaces it, and the old one
  keeps its text with its status set to `Superseded by NNNN`. Fixing a typo or a broken link is
  fine.

## Sections

Every ADR has a status line (`Proposed`, `Accepted`, or `Superseded by NNNN`, with a date) and
these sections:

- **Context**: the problem and the forces behind it.
- **Decision**: what was decided, in enough detail to build it.
- **Consequences**: what changes, what gets easier, what gets harder.
- **Alternatives**: the options considered and why each was not chosen.

## Records

| ADR | Title | Status |
| --- | --- | --- |
| [0001](0001-director-workflow.md) | The Director workflow: ticket types, plan review and artifacts | Accepted |
