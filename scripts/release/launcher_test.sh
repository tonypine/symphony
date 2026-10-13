#!/usr/bin/env bash
# Checks the argument contract of rel/overlays/bin/symphony-app without a real
# release: a fake release tree whose `erl` prints its argv. The arguments after
# `-extra` must be exactly the caller's, and SYMPHONY_RELEASE_ROOT the release root.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd -P)"
launcher="$repo/rel/overlays/bin/symphony-app"
work="$(mktemp -d "${TMPDIR:-/tmp}/symphony-launcher-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
failures=0

# Lays out a fake release under $1: ERTS 99.1, release 1.2.3.
make_release() {
  local root="$1"
  mkdir -p "$root/erts-99.1/bin" "$root/releases/1.2.3" "$root/lib"
  # Mix writes this file without a trailing newline.
  printf '99.1 1.2.3' > "$root/releases/start_erl.data"
  cat > "$root/erts-99.1/bin/erl" <<'ERL'
#!/bin/sh
printf 'ROOT=%s\n' "$SYMPHONY_RELEASE_ROOT"
for arg in "$@"; do printf '%s\n' "$arg"; done
ERL
  chmod +x "$root/erts-99.1/bin/erl"
}

# Runs <program> <args...> and checks the fake erl's output for release root $1.
check() {
  local name="$1" root="$2" program="$3"
  shift 3
  local expected actual
  expected="$(
    printf 'ROOT=%s\n' "$root"
    printf '%s\n' -boot "$root/releases/1.2.3/start" -boot_var RELEASE_LIB "$root/lib" \
      -config "$root/releases/1.2.3/sys" -args_file "$root/releases/1.2.3/vm.args" \
      -mode embedded -noshell -extra
    for arg in "$@"; do printf '%s\n' "$arg"; done
  )"
  actual="$("$program" "$@")"
  if [ "$actual" = "$expected" ]; then
    echo "ok - $name"
  else
    echo "not ok - $name"
    diff <(echo "$expected") <(echo "$actual") || true
    failures=$((failures + 1))
  fi
}

# Inside the release, as bin/symphony-app.
release="$work/release"
make_release "$release"
mkdir -p "$release/bin"
cp "$launcher" "$release/bin/symphony-app"
release="$(cd "$release" && pwd -P)"

check "check --config" "$release" "$release/bin/symphony-app" check --config "/tmp/x.yml"
check "--config --port" "$release" "$release/bin/symphony-app" --config "/tmp/x.yml" --port 4040
check "argument with spaces" "$release" "$release/bin/symphony-app" check --config "/tmp/my settings/s y.yml"
check "no arguments" "$release" "$release/bin/symphony-app"

# In the app bundle: Resources/symphony next to Resources/symphony-release/.
resources="$work/App.app/Contents/Resources"
mkdir -p "$resources"
make_release "$resources/symphony-release"
cp "$launcher" "$resources/symphony"
bundle_root="$(cd "$resources/symphony-release" && pwd -P)"

check "bundle layout" "$bundle_root" "$resources/symphony" --config "/tmp/x.yml" --port 4040

# Through symlinks, absolute and relative, to the bundled launcher.
mkdir -p "$work/links/nested"
ln -s "$resources/symphony" "$work/links/symphony"
ln -s ../symphony "$work/links/nested/symphony"
check "absolute symlink" "$bundle_root" "$work/links/symphony" check --config "/tmp/a b.yml"
check "chained relative symlink" "$bundle_root" "$work/links/nested/symphony" check --config "/tmp/x.yml"

# With runtime config, -config points at a writable copy of sys.config in RELEASE_TMP.
printf '%%%% RUNTIME_CONFIG=true\n[].\n' > "$release/releases/1.2.3/sys.config"
config="$(RELEASE_TMP="$work/rt" "$release/bin/symphony-app" check | sed -n '/^-config$/{n;p;}')"
if [[ "$config" == "$work/rt/symphony-1.2.3-"*.runtime ]] && cmp -s "$config.config" "$release/releases/1.2.3/sys.config"; then
  echo "ok - runtime config copied to RELEASE_TMP"
else
  echo "not ok - runtime config copied to RELEASE_TMP (got -config $config)"
  failures=$((failures + 1))
fi
rm "$release/releases/1.2.3/sys.config"

# No release next to the launcher.
mkdir -p "$work/empty/bin"
cp "$launcher" "$work/empty/bin/symphony-app"
if "$work/empty/bin/symphony-app" check 2>/dev/null; then
  echo "not ok - missing release fails"
  failures=$((failures + 1))
else
  echo "ok - missing release fails"
fi

[ "$failures" -eq 0 ]
