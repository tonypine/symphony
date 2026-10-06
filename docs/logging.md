# Logging Best Practices

This guide defines logging conventions for Symphony so Codex can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging Codex execution lifecycle events, include:

- `session_id`: combined Codex thread/turn identifier.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it. Dispatch lines carry `slot=` and `forced=true|false` (whether the run uses the forced allowance).
  A callback that takes 1 s or more logs `Orchestrator slow handle_call|handle_info duration_ms= message=` (the message inspected with limits), and a snapshot build that does logs `Orchestrator snapshot build slow build_ms=` with `<part>_ms=` for its parts.
  The Linear calls the orchestrator needs an answer from run in tasks; one that dies logs `Async Linear task <kind> exited before replying:`, and one that cannot start logs `Failed to start async Linear task <kind>:`.
- `Codex.AppServer`: log session start/completion/error with issue context and `session_id`.
- `McpServer`: log JSON decode/framing failures, handler crashes, and response-send failures with MCP method, tool name, request ID, MCP session ID, payload byte size, and transport when available. Raw payload logging must stay redacted and preview-limited.

## Audit Events

General application logs are not the audit trail. Symphony writes side-effect audit events to
append-only NDJSON files under `<state-root>/audit/YYYY-MM-DD.ndjson`. Events include the Linear
issue ID, run ID, timestamp, event type, and structured details for prompt sends, tool calls, file
changes, PR actions, Linear state/comment actions, and token usage deltas when those fields are
available.

Prompt bodies are not stored in the audit stream. Audit prompt events store a SHA-256 prompt hash
and a redacted preview. Configured secrets such as tracker API keys, notification webhooks, and
common API key environment variables are scrubbed before records are written.

Each audit record includes `previous_hash` and `record_hash` fields. Use
`SymphonyElixir.AuditLog.verify_file/1` to verify a daily file, or `mix symphony.audit ISSUE_ID
--from YYYY-MM-DD --to YYYY-MM-DD --state-root /path/to/state-root` to print an issue-scoped
chronological event stream.

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a Codex session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?
