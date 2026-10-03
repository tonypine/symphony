#!/bin/sh
# Serves the Symphony dashboard from this checkout on $SYMPHONY_VERIFICATION_PORT, for
# `verification.dev_server` (Auto Review's web playbook). It runs with an in-memory
# tracker, so it never talks to Linear or starts agents.
set -eu

port="${SYMPHONY_VERIFICATION_PORT:?SYMPHONY_VERIFICATION_PORT is not set}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
root="$(mktemp -d "${TMPDIR:-/tmp}/symphony-qa-dashboard.XXXXXX")"

cat >"$root/symphony.yml" <<EOF
issues:
  provider: memory
repositories:
  - key: dashboard
    workflow: $repo/WORKFLOW.md
workspaces:
  root: $root/workspaces
agent:
  runtime: codex
  command: "false"
EOF

cd "$repo"
set --
if command -v mise >/dev/null 2>&1; then
  mise trust --quiet >/dev/null 2>&1 || true
  set -- mise exec --
fi

"$@" mix deps.get >&2
"$@" mix build >&2

# A Symphony agent environment turns the orchestrator and its HTTP server off.
unset SYMPHONY_AGENT_RUNTIME SYMPHONY_DISABLE_ORCHESTRATOR
exec "$@" ./bin/symphony --config "$root/symphony.yml" --state-root "$root/state" --logs-root "$root/logs" \
  --host 127.0.0.1 --port "$port"
