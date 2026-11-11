#!/bin/sh
# Tests scripts/ci/apt-install.sh against a stub apt-get (and sudo) that fails a set number of
# times. Run: sh scripts/ci/apt-install-test.sh
set -eu

script="$(cd "$(dirname "$0")" && pwd)/apt-install.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/apt-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
# The stub fails `update` while the failure budget in $tmp/fail lasts, and logs every call.
cat > "$tmp/bin/apt-get" <<STUB
#!/bin/sh
echo "\$*" >> "$tmp/calls"
if [ "\$1" = update ]; then
  left="\$(cat "$tmp/fail")"
  if [ "\$left" -gt 0 ]; then
    echo \$((left - 1)) > "$tmp/fail"
    echo "Temporary failure resolving 'archive.ubuntu.com'" >&2
    exit 100
  fi
fi
exit 0
STUB
printf '#!/bin/sh\nexec "$@"\n' > "$tmp/bin/sudo"
chmod +x "$tmp/bin/apt-get" "$tmp/bin/sudo"
unset APT_INSTALL_ATTEMPTS
export PATH="$tmp/bin:$PATH" APT_INSTALL_PAUSE=0
failed=0

run() {
  echo "$1" > "$tmp/fail"
  : > "$tmp/calls"
  sh "$script" bubblewrap socat > "$tmp/out" 2>&1
}

if ! run 0; then echo "FAIL first try exited non-zero: $(cat "$tmp/out")"; failed=1; fi
case "$(cat "$tmp/out")" in
  *"attempt 1 of 5: bubblewrap socat"*"installed on attempt 1"*) ;;
  *) echo "FAIL first try output: $(cat "$tmp/out")"; failed=1 ;;
esac
if [ "$(cat "$tmp/calls")" != "$(printf 'update\ninstall -y --no-install-recommends bubblewrap socat')" ]; then
  echo "FAIL first try calls: $(cat "$tmp/calls")"; failed=1
fi

if ! run 2; then echo "FAIL third try exited non-zero: $(cat "$tmp/out")"; failed=1; fi
case "$(cat "$tmp/out")" in
  *"attempt 1 failed"*"attempt 2 failed"*"attempt 3 of 5"*"installed on attempt 3"*) ;;
  *) echo "FAIL third try output: $(cat "$tmp/out")"; failed=1 ;;
esac
if [ "$(grep -c '^update$' "$tmp/calls")" -ne 3 ] || [ "$(grep -c '^install' "$tmp/calls")" -ne 1 ]; then
  echo "FAIL third try calls: $(cat "$tmp/calls")"; failed=1
fi

if run 9; then echo "FAIL five failures exited 0"; failed=1; fi
case "$(cat "$tmp/out")" in
  *"attempt 5 of 5"*"gave up after 5 attempts: bubblewrap socat"*) ;;
  *) echo "FAIL five failures output: $(cat "$tmp/out")"; failed=1 ;;
esac
if [ "$(grep -c '^update$' "$tmp/calls")" -ne 5 ] || grep -q '^install' "$tmp/calls"; then
  echo "FAIL five failures calls: $(cat "$tmp/calls")"; failed=1
fi

if sh "$script" > "$tmp/out" 2>&1; then echo "FAIL no packages exited 0"; failed=1; fi

[ "$failed" -eq 0 ] && echo "ok"
exit "$failed"
