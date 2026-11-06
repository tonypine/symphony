#!/bin/sh
# Loads the previous release's symphony.yml on this build, with its migration applied, so a change
# that renames or removes a settings key without a migration fails on its pull request instead of
# stopping every operator's update.
#
# The file is written next to this checkout's symphony.yml, so its relative paths resolve the same,
# and removed afterwards. Run from the repository root.
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
home="$(mktemp -d "${TMPDIR:-/tmp}/symphony-previous-release.XXXXXX")"
trap 'rm -rf "$config" "$home"; git update-ref -d refs/previous-release' EXIT
git show "refs/previous-release:symphony.yml" > "$config"

# `check` rejects a `strategy: worktree` repo that doesn't exist, so the fresh HOME gets an empty git
# repo at every `repo: ~/...` path the file names, as `smoke_test.sh` does.
for repo in $(sed -n 's|^[[:space:]]*repo:[[:space:]]*~/\([^[:space:]#]*\).*|\1|p' "$config"); do
  git init -q "$home/$repo"
done

echo "Checking symphony.yml from $tag"
HOME="$home" "$binary" check --migrate --config "$PWD/$config"
