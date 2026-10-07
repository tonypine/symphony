## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching. A human moves the issue to `Rework` when the approach itself is wrong; ordinary review comments come back as `In Progress` on the same PR (see Step 3).
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue. There is no scoped tool to close a PR; if you cannot close it, note it in the workpad so the human closes it.
4. Preserve the existing workpad as the audit trail — do not delete it. In the single workpad comment (`{{ agent.workpad_heading }}`, or a legacy `## Codex Workpad` / `## Claude Workpad` header you should rewrite to `{{ agent.workpad_heading }}`), move the prior `Plan`, `Acceptance Criteria`, and `Validation` content under a `### Superseded — attempt <n>` heading so the record of what was already tried stays on the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Write a fresh `Plan`, `Acceptance Criteria`, and `Validation` in the same workpad comment — do not create a second workpad — then execute end-to-end.
