#!/bin/sh
# Serves the Symphony dashboard from this checkout on $SYMPHONY_VERIFICATION_PORT, for
# `verification.dev_server` (Auto Review's web playbook). It runs with an in-memory
# tracker, so it never talks to Linear or starts agents. Symphony starts it in the dev
# server's sandbox, so it can write only this checkout, $TMPDIR and the agent cache folder.
# On macOS that sandbox allows no TCP listener: the dashboard listens on the unix socket
# $SYMPHONY_VERIFICATION_SOCKET instead, which Symphony serves on 127.0.0.1:$SYMPHONY_VERIFICATION_PORT.
# It runs no Mix: Mix loads deps through a TCP listener (see the guard below), so it serves the
# escript built outside the sandbox with `mix build`.
set -eu

port="${SYMPHONY_VERIFICATION_PORT:?SYMPHONY_VERIFICATION_PORT is not set}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${SYMPHONY_VERIFICATION_SOCKET:-}" ]; then
  host="unix:$SYMPHONY_VERIFICATION_SOCKET" listen_port=0
else
  host=127.0.0.1 listen_port="$port"
fi
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

# The dev server's sandbox allows no TCP listener at all, and Mix can't run without one: every
# task that loads deps starts `Mix.PubSub` (`Mix.Sync.PubSub.subscribe/1`) on an ephemeral
# 127.0.0.1 port, and Mix's build lock takes one too. So no Mix task can run here. Serve the
# escript this checkout built outside the sandbox with `mix build`.
if [ ! -x ./bin/symphony ]; then
  echo "scripts/qa-dashboard-server.sh: ./bin/symphony is missing." >&2
  echo "Build it first with \`mix build\`, in hooks.before_run (see docs/configuration.md#verification). Mix can't run inside the dev server sandbox on macOS: it opens TCP listeners for its build lock and pub/sub." >&2
  exit 1
fi

set --
if command -v mise >/dev/null 2>&1; then
  # The dev server's sandbox can't write mise's state and cache folders in the home folder, so
  # mise keeps them in this run's temp folder, and this checkout's config is trusted for this
  # process only (an untrusted `mise exec` would write the trust store).
  export MISE_STATE_DIR="$root/mise-state" MISE_CACHE_DIR="$root/mise-cache"
  export MISE_TRUSTED_CONFIG_PATHS="$repo${MISE_TRUSTED_CONFIG_PATHS:+:$MISE_TRUSTED_CONFIG_PATHS}"
  set -- mise exec --
fi

# A Symphony agent environment turns the orchestrator and its HTTP server off.
unset SYMPHONY_AGENT_RUNTIME SYMPHONY_DISABLE_ORCHESTRATOR
exec "$@" ./bin/symphony --config "$root/symphony.yml" --state-root "$root/state" --logs-root "$root/logs" \
  --host "$host" --port "$listen_port"
