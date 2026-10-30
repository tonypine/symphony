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
# The tracker writes the seed's labels back into its issues file: a copy of its own.
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
  memory:
    issues_file: $root/issues.json
repositories:
  - key: symphony
    workflow: $root/WORKFLOW.md
    route:
      team: QA
workspaces:
  root: $root/workspaces
agent:
  runtime: codex
  command: "false"
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

# A Symphony agent environment turns the orchestrator and its HTTP server off; no token for Linear
# or GitHub crosses over, and `gh` is the stand-in.
unset SYMPHONY_AGENT_RUNTIME SYMPHONY_DISABLE_ORCHESTRATOR LINEAR_API_KEY GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN
export PATH="$root/bin:$PATH" SYMPHONY_STATE_ROOT="$root/state"
exec "$@" ./bin/symphony --config "$root/symphony.yml" --state-root "$root/state" --logs-root "$root/logs" \
  --host 127.0.0.1 --port "$port" --qa-seed "$seed"
