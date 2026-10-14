---
# Drafted by Symphony's Add Repo sheet from the files at the repo's top. Check the commands, then run
# `symphony workflow preview --file WORKFLOW.md` to see the prompt agents get.
hooks:
  # Runs once in each new workspace, before the agent starts.
  after_create: |
    pnpm install --frozen-lockfile
# To have Auto Review test the web app in a browser, serve it on Symphony's port:
# verification:
#   dev_server:
#     start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"
#     health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/"
# The body's last line expands to Symphony's playbook. It leaves out these two partials, which the
# body's Step 1 relies on.
playbook:
  lockfile: pnpm-lock.yaml
  partials:
    workpad_bootstrap: 55
    reproduce_and_blast_radius: 56
---

You are working on a Linear ticket `{{ issue.identifier }}` in the `acme/web` repository.

## Repository

- Stack: TypeScript, built with pnpm.
- Base branch: `main`. Branch from `origin/main` and open pull requests against it.
- Read the repo's own docs (`README.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`) before changing code, and
  follow their conventions.

## Commands

- Set up: `pnpm install --frozen-lockfile`. The `after_create` hook runs it in each new workspace.
- Test: `pnpm test`. Before each push, run the tests of the code you changed, not the whole suite.
- Checks before each push: `pnpm lint`, `pnpm typecheck`.
- CI runs the full suite on every push and is the gate: leave the whole suite and slow checks to it.
- For long-running commands, use long tool waits, and keep the output you read back small: the failing
  command, its exit code and the relevant error lines.

## Steps

- Step 0, route: fetch the issue and route it per the Status map below. For `Todo`, move the issue to
  `In Progress` before any other tool call. If the branch's pull request is closed or merged, start a fresh
  branch from `origin/main`. A ticket with the `plan` label follows `Parent tickets` instead of Steps 1 and 2.
- Step 1, start: find or create the workpad, then capture a reproduction signal and the blast radius before
  the first edit (both below).
- Step 2, execute: merge the latest `origin/main` into the branch, implement the plan with the workpad
  checklist current, and run the checks and the tests of the changed code (see Commands) until they pass.
  Review `git diff origin/main..HEAD` for debug output, stray files and temporary edits, then commit. Push
  and open a pull request against `main` linked to the issue: that push hands the ticket to `Code Review`.
  Keep validation evidence in the workpad, not in the pull request body.
- Step 3, review: in `Code Review`, `QA` and `Merging`, make no changes; Symphony brings review comments back
  as `In Progress` on the same pull request.
- Step 4, rework: continue on the same pull request and branch, address what sent it back, and push.

{% render "playbook" %}
