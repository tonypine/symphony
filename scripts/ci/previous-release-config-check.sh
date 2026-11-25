#!/bin/sh
# Loads the previous release's symphony.yml and WORKFLOW.md on this build, with their migration
# applied, so a change that renames or removes a settings key without a migration fails on its pull
# request instead of stopping every operator's update.
#
# The files are written next to this checkout's symphony.yml, so their relative paths resolve the
# same, and removed afterwards. Run from the repository root.
#
# Usage:
#   scripts/ci/previous-release-config-check.sh BINARY
set -eu

if [ $# -ne 1 ]; then
  echo "usage: $0 BINARY" >&2
  exit 2
fi

binary="$1"
tag="$(git ls-remote --tags --refs --sort=-v:refname origin 'v*' | head -n 1 | sed 's|.*refs/tags/||')"
if [ -z "$tag" ]; then
  echo "no release tag found on origin" >&2
  exit 1
fi

git fetch --quiet --no-tags --depth=1 origin "refs/tags/$tag:refs/previous-release"
config=".previous-release-symphony.yml"
workflow=".previous-release-WORKFLOW.md"
home="$(mktemp -d "${TMPDIR:-/tmp}/symphony-previous-release.XXXXXX")"
trap 'rm -rf "$config" "$workflow" "$home"; git update-ref -d refs/previous-release' EXIT
# The copy's repositories read the previous release's WORKFLOW.md, which an open ticket's branch
# may still carry: it loads with its migration applied too.
git show "refs/previous-release:WORKFLOW.md" > "$workflow"
git show "refs/previous-release:symphony.yml" |
  sed "s|^\([[:space:]]*workflow:[[:space:]]*\)WORKFLOW\.md[[:space:]]*$|\1$workflow|" > "$config"

# `check` rejects a `strategy: worktree` repo that doesn't exist, so the fresh HOME gets an empty git
# repo at every `repo: ~/...` path the file names, as `smoke_test.sh` does.
for repo in $(sed -n 's|^[[:space:]]*repo:[[:space:]]*~/\([^[:space:]#]*\).*|\1|p' "$config"); do
  git init -q "$home/$repo"
done

# The escript runs on the Erlang on PATH, found here with the real HOME: a version manager's shims
# may not resolve under a fresh one.
PATH="$(erl -noshell -eval 'io:put_chars(code:root_dir()), halt().')/bin:$PATH"
export PATH

echo "Checking symphony.yml and WORKFLOW.md from $tag"
HOME="$home" "$binary" check --migrate --config "$PWD/$config"
