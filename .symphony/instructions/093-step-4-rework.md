## Step 4: Rework handling

{% if state_machine == "designed" -%}
1. `Rework` means the work came back for changes. Continue on the **same** pull request and the same branch: never close the PR, never cut a new branch, and never move the workpad's prior plan aside.
2. Read what sent it back — the reviewer's verdict and reasons, the failing assertions, the user journey QA ran — and address it directly. The old verdict does not survive the change: the new head is reviewed again from scratch.
3. Keep the single workpad comment; extend its `Plan`, `Acceptance Criteria` and `Validation` with what the verdict adds instead of superseding what is there.
4. Push the changes to the same branch. That push is the handoff: it moves the ticket to `Code Review` for a review of the new head. Do not ask for the state by hand.
5. `Restart` is the full reset — close the pull request, a fresh branch from main, the prior attempt superseded in the workpad. It is a person's move from the Director app; an agent can neither request nor perform it. If you judge that the approach itself is wrong, say so plainly in the workpad and ask for a person with an `## Action needed:` request rather than starting over on your own.
{%- else -%}
1. Treat `Rework` as a full approach reset, not incremental patching. A human moves the issue to `Rework` when the approach itself is wrong; ordinary review comments come back as `In Progress` on the same PR (see Step 3).
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue. There is no scoped tool to close a PR; if you cannot close it, note it in the workpad so the human closes it.
4. Preserve the existing workpad as the audit trail — do not delete it. In the single workpad comment (`{{ agent.workpad_heading }}`, or a legacy `## Codex Workpad` / `## Claude Workpad` header you should rewrite to `{{ agent.workpad_heading }}`), move the prior `Plan`, `Acceptance Criteria`, and `Validation` content under a `### Superseded — attempt <n>` heading so the record of what was already tried stays on the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Write a fresh `Plan`, `Acceptance Criteria`, and `Validation` in the same workpad comment — do not create a second workpad — then execute end-to-end.
{%- endif %}
