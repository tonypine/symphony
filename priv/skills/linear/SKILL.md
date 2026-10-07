---
name: linear
description: |
  Use Symphony's scoped Linear dynamic tools for current-issue reads and narrow
  current-issue writes.
---

# Linear Tools

Use the scoped `linear_*` tools exposed by Symphony's app-server session. These
tools inject the current issue id server-side and do not accept issue id
arguments from prompts.

## Read Tools

- `linear_get_current_issue` with `{}`: full fields for the current issue.
- `linear_get_subissues` with `{}`: direct children of the current issue.
- `linear_get_parent_issue` with `{}`: parent issue, or `null`.
- `linear_get_comments` with optional `{"limit": 50}`: current issue comments,
  newest first.
- `linear_get_related_issues` with `{}`: the current issue's family as summaries
  (relation, id, identifier, title, state): the issues it blocks and is blocked
  by, its parent, its siblings and its sub-issues. With
  `{"identifier": "TP-12", "comment_limit": 50}` it reads one of them in full
  (description, state, labels, `relations`, comments newest first), for example
  a sibling's QA report or the parent's workpad. Any issue outside the family is
  refused with `issue_outside_family` and the list of identifiers it can read.

## Write Tools

- `linear_update_state` with `{"state_name_or_id": "In Review"}`: resolves the
  state against the current issue team's workflow. Unknown states are a no-op.
- `linear_set_assignee` with `{"assignee": "self"}`, `{"assignee": "unassign"}`,
  or `{"assignee": "<user_id>"}`.
- `linear_add_comment` with `{"body": "..."}`: adds a comment to the current
  issue and records ownership for this run. Add `"parent_id": "<comment id>"`
  to reply under a comment on the current issue (`linear_get_comments` shows a
  reply's thread in `parent.id`).
- `linear_update_comment` with `{"comment_id": "...", "body": "..."}`: only for
  comments created earlier by this run.
- `linear_delete_comment` with `{"comment_id": "..."}`: only for comments
  created earlier by this run.
- `linear_attach_url` with `{"url": "https://...", "title": "..."}`: attaches a
  valid HTTP(S) URL to the current issue. Titles are capped.
- `linear_attach_file` with `{"local_path": "path/in/workspace", "title": "...", "make_public": false}`:
  uploads and attaches a file only when the path resolves inside the workspace.
  Uploads are private by default. Set `make_public` to `true` only for artifacts
  intentionally safe to expose through a world-readable Linear CDN URL.
- `linear_create_subissue` with `{"title": "...", "description": "...", "priority": 3, "blocked_by": ["TP-12"]}`:
  creates a child of the current issue in its team and project, assigned to its
  assignee, in `Backlog`. `priority` is optional (0 none, 1 urgent, 2 high,
  3 medium, 4 low). `blocked_by` is optional: identifiers of the current issue's
  sub-issues (existing ones or ones this run created) that block the new one;
  any other identifier is refused before the issue is created. Title and
  description are secret-scanned. At most 10 per run. Use it to split a ticket
  into sub-tickets or to file out-of-scope work.
- `linear_update_subissue` with `{"identifier": "TP-13", "title": "...", "description": "...", "blocked_by": ["TP-12"]}`
  or `{"identifier": "TP-13", "cancel_reason": "..."}`: changes a `Backlog`
  sub-issue of the current issue when a plan run revises its plan.
  `blocked_by` is the complete list of sibling sub-issues that block it (sibling
  links left out are removed). `cancel_reason` alone posts the reason on the
  sub-issue and cancels it. A sub-issue outside `Backlog` was promoted by a person
  and is refused. Text fields are secret-scanned.
- `linear_add_blocked_by` with `{"blocked_by": ["TP-12"]}`: marks the current
  issue blocked by existing issues. Symphony holds an issue in `Todo` until every
  blocker is `Done` or `Canceled`, then runs it again. Unknown identifiers and the
  current issue itself are refused before anything is linked. Use it when a final
  verification files gaps.
- `linear_create_project_update` with `{"body": "...", "health": "onTrack"}`:
  posts an update to the current issue's project. `health` is optional
  (`onTrack`, `atRisk`, `offTrack`). The body is secret-scanned. At most one per
  run. Use it when a plan ticket (label `plan`) closes out.
- `linear_create_document` with `{"title": "...", "content": "..."}`: creates a
  document in the current issue's project titled `<identifier> · <title>` and
  attaches it to the issue, so later runs on the issue can read and edit it. Use
  it for long-lived artifacts (domain brief, journeys, Kano map, screens, ADR
  draft) instead of comments. Title and content are secret-scanned. At most 10
  per run; an issue outside a project is refused.
- `linear_update_document` with `{"document_id": "...", "content": "...", "title": "..."}`:
  replaces the whole content, and the title when given (it keeps the identifier
  prefix), of a document this issue's runs created. `title` is optional. Content
  and title are secret-scanned. Any other document is refused.
- `linear_get_document` with `{}`: lists the documents this issue's runs created
  (id, title, url). With `{"document_id": "..."}` it reads one in full, its
  content secret-redacted. Any other document is refused. It is read-only.
- `linear_request_human_action` with `{"title": "...", "why": "...", "decision": {"question": "...", "options": [{"label": "...", "effect": "...", "recommended": true}, {"label": "...", "effect": "..."}]}, "unblocks": "...", "est_minutes": 10}`:
  asks a person for a decision only they can make (a product call, a missing
  secret or permission: add it or drop what needs it, an account setup). It posts
  a `## Decision needed:` request that Symphony lists for the operator. `title`
  (up to 120 characters) names the decision; `decision` holds one question and 2
  to 4 options, each with what it does, exactly one recommended. A request
  without options is refused. Never ask a person to run a check: a check an agent
  can't run (launching the app, a host crash check, a check on a device) goes to
  the supervisor as a `## Supervisor check` block with the ticket moved to
  `In Review`, and a manual check that could be a test becomes a test.
  `unblocks` and `est_minutes` (1 to 480) are optional. Every field is refused
  when it holds a secret. A request with the same title still open is not posted
  again. At most 5 per run.
- `linear_withdraw_human_action` with `{"reason": "...", "title": "..."}`:
  withdraws a human-action request that is no longer needed. It replies with the
  reason under the request and removes the human-action label once no open
  request is left, so the next project update drops it. `title` is optional;
  without it every open request on the issue is withdrawn.

## Rules

- Do not use or request `linear_graphql`; it is intentionally unavailable to
  prompts.
- Do not include `issue_id`, `issueId`, or `id` arguments. The server rejects
  prompt-supplied issue ids.
- Create issues only with `linear_create_subissue`; it takes no team, project,
  parent, assignee or state arguments.
- Do not delete issues, update issue titles/descriptions (except a `Backlog`
  sub-issue's, with `linear_update_subissue`), move issues between
  teams/projects/parents/cycles, or write labels.
- If a task truly requires a Linear operation outside this surface, stop and
  record the missing capability as a follow-up instead of trying to bypass the
  tool boundary.
