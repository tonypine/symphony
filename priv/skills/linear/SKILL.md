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
- `linear_get_related_issues` with `{}`: blocks and blocked-by issue summaries
  only: id, identifier, and title.

## Write Tools

- `linear_update_state` with `{"state_name_or_id": "In Review"}`: resolves the
  state against the current issue team's workflow. Unknown states are a no-op.
- `linear_set_assignee` with `{"assignee": "self"}`, `{"assignee": "unassign"}`,
  or `{"assignee": "<user_id>"}`.
- `linear_add_comment` with `{"body": "..."}`: adds a comment to the current
  issue and records ownership for this run.
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
- `linear_create_subissue` with `{"title": "...", "description": "...", "priority": 3}`:
  creates a child of the current issue in its team and project, assigned to its
  assignee, in `Backlog`. `priority` is optional (0 none, 1 urgent, 2 high,
  3 medium, 4 low). Title and description are secret-scanned. At most 10 per
  run. Use it to split a ticket into sub-tickets or to file out-of-scope work.
- `linear_create_project_update` with `{"body": "...", "health": "onTrack"}`:
  posts an update to the current issue's project. `health` is optional
  (`onTrack`, `atRisk`, `offTrack`). The body is secret-scanned. At most one per
  run. Use it when a `breakdown` parent ticket closes out.

## Rules

- Do not use or request `linear_graphql`; it is intentionally unavailable to
  prompts.
- Do not include `issue_id`, `issueId`, or `id` arguments. The server rejects
  prompt-supplied issue ids.
- Create issues only with `linear_create_subissue`; it takes no team, project,
  parent, assignee or state arguments.
- Do not delete issues, update issue titles/descriptions, move issues between
  teams/projects/parents/cycles, or write labels.
- If a task truly requires a Linear operation outside this surface, stop and
  record the missing capability as a follow-up instead of trying to bypass the
  tool boundary.
