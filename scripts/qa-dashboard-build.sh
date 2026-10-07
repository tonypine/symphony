#!/bin/sh
# Builds the escript scripts/qa-dashboard-server.sh serves, for `verification.dev_server.build_cmd`
# (Auto Review's web playbook). Symphony runs it in the dev server's checkout before the server
# starts, in the build sandbox: like the agent's, it can write only this checkout, $TMPDIR and the
# agent cache folder, and reaches the dependency hosts only through the egress proxy. Unlike the
# dev server's sandbox, it lets Mix listen on loopback for its build lock and pub/sub.
set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

# The dashboard serves the dev build, whatever env Symphony itself runs in.
export MIX_ENV=dev

set --
if command -v mise >/dev/null 2>&1; then
  # The sandbox can't write mise's state and cache folders in the home folder, so mise keeps them
  # in this run's temp folder, and this checkout's config is trusted for this process only (an
  # untrusted `mise exec` would write the trust store).
  export MISE_STATE_DIR="${TMPDIR:-/tmp}/mise-state" MISE_CACHE_DIR="${TMPDIR:-/tmp}/mise-cache"
  export MISE_TRUSTED_CONFIG_PATHS="$repo${MISE_TRUSTED_CONFIG_PATHS:+:$MISE_TRUSTED_CONFIG_PATHS}"
  set -- mise exec --
fi

"$@" mix deps.get
"$@" mix build
