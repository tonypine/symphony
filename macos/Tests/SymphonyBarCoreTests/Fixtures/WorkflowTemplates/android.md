---
# Drafted by Symphony's Add Repo sheet from the files at the repo's top. Check the commands, then run
# `symphony workflow preview --file WORKFLOW.md` to see the prompt agents get.
# No setup command was found. To install dependencies in each new workspace, before the agent starts:
#   after_create: |
#     ./scripts/setup
hooks: {}
# Auto Review's QA playbooks this repo turns on; symphony.yml's `auto_review.android.avd` names the emulator.
auto_review:
  playbooks:
    android_app:
      build: 'ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew :app:assembleDebug'
      apk_path: app/build/outputs/apk/debug/app-debug.apk
      application_ids: ['com.acme.notes']
---

You are working on a Linear ticket `{{ issue.identifier }}` in the `acme/notes-android` repository.

{% render "continuation_context", attempt: attempt %}

{% render "issue_context", issue: issue %}

{% render "default_posture" %}

{% render "scoped_tools" %}

## Repository

- Stack: Kotlin, built with Gradle (Android).
- Base branch: `develop`. Branch from `origin/develop` and open pull requests against it.
- Read the repo's own docs (`README.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`) before changing code, and
  follow their conventions.

## Commands

- Test: `./gradlew testDebugUnitTest`. Before each push, run the tests of the code you changed, not the whole suite.
- Checks before each push: `./gradlew lintDebug`.
- CI runs the full suite on every push and is the gate: leave the whole suite and slow checks to it.
- For long-running commands, use long tool waits, and keep the output you read back small: the failing
  command, its exit code and the relevant error lines.

{% render "status_map" %}

## Step 0: Determine current ticket state and route

1. Fetch the issue and read its current state.
2. Route per the Status map above. For `Todo`, move the issue to `In Progress` before any other tool call.
3. If the branch's pull request is closed or merged, start a fresh branch from `origin/develop`.
4. For a ticket with the `breakdown` label, or whose title starts with `Final verification:`, follow
   `Parent tickets` below instead of Steps 1 and 2.

## Step 1: Start or continue execution

{% render "workpad_bootstrap", agent: agent %}

{% render "reproduce_and_blast_radius" %}

## Step 2: Execution phase

1. Merge the latest `origin/develop` into the branch before the first edit.
2. Implement the plan, keeping the workpad checklist current.
3. Run the checks and the tests of the changed code (see Commands) until they pass.
4. Review `git diff origin/develop..HEAD` for debug output, stray files and temporary edits, then commit.
5. Push, and open a pull request against `develop` linked to the issue. Keep validation evidence in the
   workpad, not in the pull request body.
6. Once the checks are green and every review comment is answered, move the issue to `In Review`.

{% render "pr_feedback_sweep" %}

{% render "ci_triage" %}

{% render "escape_hatches" %}

## Step 3: In Review and merge handling

- In `In Review`, make no changes: Symphony brings review comments back as `In Progress` on the same pull
  request.
- In `Merging`, Symphony lands the pull request. When it dispatches you there, merge with the scoped
  `github_merge_pull_request` tool once the checks are green.

## Step 4: Rework handling

- `Rework` resets the approach: close the old pull request, start a fresh branch from `origin/develop`, and
  keep the old plan in the workpad under a `Superseded` heading.

{% render "completion_bar" %}

{% render "guardrails" %}

{% render "parent_tickets" %}

{% render "out_of_scope_backlog" %}

{% render "dependency_guardrail", lockfile: "gradle/libs.versions.toml" %}

{% render "workpad_template", agent: agent %}
