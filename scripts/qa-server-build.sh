#!/bin/sh
# Builds the escript scripts/qa-server-start.sh serves: Symphony's own server for a live QA pass
# of the Director (the `macos_app` playbook's `live.build_cmd`, TP-1311). Symphony runs it on the
# QA host in the pass's own copy of the PR head, as the QA user and outside any sandbox, with HOME
# set to a fresh folder of that pass. So the Hex, deps and build caches live under the QA user's
# real home instead ($SYMPHONY_QA_SERVER_CACHE, default ~/Library/Caches/symphony-qa-server), and
# a second pass reuses them: it fetches and compiles only what changed.
set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

# HOME is the pass's fresh folder; the account's own home holds mise's tools and the caches.
user_home="$(eval "printf '%s' ~$(id -un)")"
cache="${SYMPHONY_QA_SERVER_CACHE:-$user_home/Library/Caches/symphony-qa-server}"
mkdir -p "$cache"

export MIX_ENV=dev
export MIX_HOME="$cache/mix" HEX_HOME="$cache/hex"
export MIX_DEPS_PATH="$cache/deps" MIX_BUILD_ROOT="$cache/_build"

set --
if command -v mise >/dev/null 2>&1; then
  # mise keeps its installed tools under the account's home, which the fresh HOME hides, and this
  # checkout's config is trusted for this process only (an untrusted `mise exec` would write the
  # trust store).
  export MISE_DATA_DIR="${MISE_DATA_DIR:-$user_home/.local/share/mise}"
  export MISE_STATE_DIR="$cache/mise-state" MISE_CACHE_DIR="$cache/mise-cache"
  export MISE_TRUSTED_CONFIG_PATHS="$repo${MISE_TRUSTED_CONFIG_PATHS:+:$MISE_TRUSTED_CONFIG_PATHS}"
  set -- mise exec --
elif ! command -v mix >/dev/null 2>&1; then
  echo "scripts/qa-server-build.sh: neither mise nor mix is on the QA host's PATH; provision Erlang and Elixir (mise.toml names the versions)." >&2
  exit 1
fi

"$@" mix local.hex --force --if-missing
"$@" mix local.rebar --force --if-missing
"$@" mix deps.get
"$@" mix build
test -x bin/symphony
echo "scripts/qa-server-build.sh: built $repo/bin/symphony (caches in $cache)"
