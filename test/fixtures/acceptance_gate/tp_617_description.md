## Problem

A person has no single place that lists what waits on them. Tickets that need the operator sit in `In Review` or `Human Review`, spread across projects, and SymphonyBar and the dashboard don't show them.

## Fix

Show a "Waiting on you" list in SymphonyBar and the dashboard: list every ticket in `In Review` or `Human Review`, newest first, with its identifier, title, state and how long it has waited. Human Review tickets come first, since only a person can move them on; In Review tickets follow.

A ticket in the human review state shows a person badge.

* Read the states from the config (`tracker.human_review_state`), so a repository that names the state differently still lists it.
* A click opens the ticket in Linear.

## Acceptance criteria

- [ ] SymphonyBar shows the "Waiting on you" list with every ticket in In Review or Human Review.
- [ ] The dashboard shows the same list.
- [ ] A ticket moved out of Human Review leaves the list on the next poll.
- [ ] CI is green.
