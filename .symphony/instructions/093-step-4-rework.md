## Step 4: Rework handling

1. `Rework` means the work came back for changes. Continue on the **same** pull request and the same branch: never close the PR, never cut a new branch, and never move the workpad's prior plan aside.
2. Read what sent it back — the reviewer's verdict and reasons, the failing assertions, the user journey QA ran — and address it directly. The old verdict does not survive the change: the new head is reviewed again from scratch.
3. Before planning, read every prior QA report and the workpad's superseded attempts, and list the findings by class (clipped, truncated, mechanism broken, state missing) in the workpad, with the head each was found on.
   - If the same class fails for the second time on this ticket, do not push a third attempt of the same kind. Write `## Action needed:` with the finding history and two layout options for a person to choose, and stop.
4. Keep the single workpad comment; extend its `Plan`, `Acceptance Criteria` and `Validation` with what the verdict adds instead of superseding what is there.
5. Push the changes to the same branch. That push is the handoff: it moves the ticket to `Code Review` for a review of the new head. Do not ask for the state by hand.
6. `Restart` is the full reset — close the pull request, a fresh branch from main, the prior attempt superseded in the workpad. It is a person's move from the Director app; an agent can neither request nor perform it. If you judge that the approach itself is wrong, say so plainly in the workpad and ask for a person with an `## Action needed:` request rather than starting over on your own.
