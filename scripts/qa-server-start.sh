#!/bin/sh
# Starts Symphony's own server for a live QA pass of the Director (the `macos_app` playbook's
# `live.start_cmd`, TP-1311): the escript scripts/qa-server-build.sh built, on the QA host, beside
# the app under test, at http://127.0.0.1:$SYMPHONY_VERIFICATION_PORT. It runs over the memory
# tracker with the seed in priv/qa_seed/symphony/ (`--qa-seed`, SymphonyElixir.QaSeed), its agents
# run `false`, webhooks stay off, and the control API takes the token $SYMPHONY_QA_CONTROL_TOKEN
# (a fresh one is made and printed when it is unset, for a run by hand). Its health is
# /api/v1/state.
#
# Nothing in it reaches Linear or GitHub: the tracker is the seed's file, no Linear or GitHub token
# reaches the process, and the `gh` on its PATH is a stand-in that answers only for the seed's own
# pull requests and refuses every other call (scripts/qa-server-gh.sh).
#
# Nor does it reach OpenCode Go: an OpenRouter QA stub (`symphony openrouter-stub`) runs beside it,
# in its process group, and the server reads OpenCode Go's usage from it in QA mode with the stub's
# key, holding OpenCode Go at the reserve its symphony.yml sets (TP-1642). OpenCode Go is every kind
# of run's fallback there, as on the operator's own Symphony, so the Providers page lists it in use.
#
# By hand on the QA VM: scripts/qa-server-build.sh, then
#   SYMPHONY_VERIFICATION_PORT=8090 scripts/qa-server-start.sh
# and open http://127.0.0.1:8090/api/v1/state.
set -eu

port="${SYMPHONY_VERIFICATION_PORT:?SYMPHONY_VERIFICATION_PORT is not set}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
seed="$repo/priv/qa_seed/symphony"
root="$(mktemp -d "${TMPDIR:-/tmp}/symphony-qa-server.XXXXXX")"

if [ ! -x "$repo/bin/symphony" ]; then
  echo "scripts/qa-server-start.sh: $repo/bin/symphony is missing; build it first with scripts/qa-server-build.sh (the live server's build_cmd)." >&2
  exit 1
fi

token="${SYMPHONY_QA_CONTROL_TOKEN:-}"
if [ -z "$token" ]; then
  token="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  echo "scripts/qa-server-start.sh: control token $token"
fi

mkdir -p "$root/state" "$root/logs" "$root/workspaces" "$root/bin"
(umask 077 && printf '%s' "$token" > "$root/state/control_token")
# The tracker writes moves, labels, requests and replies back into its issues file, as Linear keeps
# them: a copy of its own. The Inbox reads it on every poll, so a Decide or an Undo shows within
# seconds.
cp "$seed/issues.json" "$root/issues.json"

cp "$repo/scripts/qa-server-gh.sh" "$root/bin/gh"

cat >"$root/WORKFLOW.md" <<'WORKFLOW'
---
---
The QA server's seeded repository: its agents run `false`, so no prompt is ever sent.
WORKFLOW

cat >"$root/symphony.yml" <<YAML
issues:
  provider: memory
  poll_interval_ms: 3000
  memory:
    issues_file: $root/issues.json
repositories:
  - key: symphony
    workflow: $root/WORKFLOW.md
    route:
      team: QA
workspaces:
  root: $root/workspaces
execution:
  harnesses:
    codex:
      command: "false"
  providers:
    opencode-go:
      reserve: 0.9
runs:
  default:
    harness: codex
    provider: openai
    model: none
    fallbacks:
      - { provider: opencode-go, model: none }
YAML

cd "$repo"

set --
if command -v mise >/dev/null 2>&1; then
  user_home="$(eval "printf '%s' ~$(id -un)")"
  export MISE_DATA_DIR="${MISE_DATA_DIR:-$user_home/.local/share/mise}"
  export MISE_STATE_DIR="$root/mise-state" MISE_CACHE_DIR="$root/mise-cache"
  export MISE_TRUSTED_CONFIG_PATHS="$repo${MISE_TRUSTED_CONFIG_PATHS:+:$MISE_TRUSTED_CONFIG_PATHS}"
  set -- mise exec --
fi

# The QA stub stands in for OpenCode Go's usage API: started on a free port, its URL read from the
# line it prints once it listens. It stops with the server's process group.
stub_log="$root/logs/openrouter-stub.log"
"$@" ./bin/symphony openrouter-stub --port 0 >"$stub_log" 2>&1 &
stub_pid=$!
stub_url=""
for _ in $(seq 300); do
  stub_url="$(sed -n 's/^OpenRouter QA stub listening on //p' "$stub_log")"
  [ -n "$stub_url" ] && break
  kill -0 "$stub_pid" 2>/dev/null || break
  sleep 0.1
done
if [ -z "$stub_url" ]; then
  echo "scripts/qa-server-start.sh: the OpenRouter QA stub did not start:" >&2
  cat "$stub_log" >&2
  exit 1
fi
export SYMPHONY_BAR_QA_ROOT="$root" SYMPHONY_QA_OPENROUTER_URL="$stub_url" OPENCODE_API_KEY="sk-or-v1-symphony-qa-stub"

# A Symphony agent environment turns the orchestrator and its HTTP server off; no token for Linear
# or GitHub crosses over, and `gh` is the stand-in.
unset SYMPHONY_AGENT_RUNTIME SYMPHONY_DISABLE_ORCHESTRATOR LINEAR_API_KEY GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN
export PATH="$root/bin:$PATH" SYMPHONY_STATE_ROOT="$root/state"
exec "$@" ./bin/symphony --config "$root/symphony.yml" --state-root "$root/state" --logs-root "$root/logs" \
  --host 127.0.0.1 --port "$port" --qa-seed "$seed"
