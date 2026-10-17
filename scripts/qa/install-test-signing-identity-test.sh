#!/bin/sh
# Tests scripts/qa/install-test-signing-identity.sh: TP-1038's walkthrough names this file as
# the script's shell test (a temporary keychain, no sudo). A fake sudo records the trust step
# instead of running it: the check on a host without the identity changes nothing, the install
# creates the keychain and the identity and asks to trust it, and a second install keeps both.
#
# With SYMPHONY_QA_SIGNING_TEST_TRUST=1 (a host where sudo needs no password and trust changes need
# no dialog, which the macOS 26 CI runner is not) it also trusts the certificate for real, checks
# that the identity is then ready and that a third install is a no-op, and removes the trust again
# when it ends.
#
# The temporary keychain is on the user's keychain search list while the test runs; the list is put
# back when it ends. Run: sh scripts/qa/install-test-signing-identity-test.sh
set -u

script="$(cd "$(dirname "$0")" && pwd)/install-test-signing-identity.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/qa-signing-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
keychain="$tmp/keychains/qa-signing.keychain-db"
calls="$tmp/sudo-calls"
original_list="$tmp/search-list"
security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' > "$original_list"

cleanup() {
  if [ -f "$tmp/trusted.pem" ]; then sudo -n security remove-trusted-cert -d "$tmp/trusted.pem" 2> /dev/null; fi
  set --
  while IFS= read -r entry; do
    if [ -n "$entry" ]; then set -- "$@" "$entry"; fi
  done < "$original_list"
  security list-keychains -d user -s "$@"
  security delete-keychain "$keychain" 2> /dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

# Records each call; the trust it would set is never set.
cat > "$tmp/fake-sudo" << EOF
#!/bin/sh
echo "\$*" >> "$calls"
EOF
chmod +x "$tmp/fake-sudo"
: > "$calls"
export SYMPHONY_QA_SIGNING_KEYCHAIN="$keychain" SYMPHONY_QA_SIGNING_SUDO="$tmp/fake-sudo"
failed=0

fail() {
  echo "FAIL $*"
  failed=1
}

run() {
  out="$(sh "$script" "$@" 2>&1)"
  status=$?
}

sha() {
  security find-identity -p codesigning "$keychain" | sed -n 's/^[[:space:]]*1) \([0-9A-F]\{40\}\) "Symphony QA Test Signing".*/\1/p' | head -n 1
}

listed() {
  security list-keychains -d user | grep -q "$keychain"
}

# 1. The check on a host without the identity says so and changes nothing.
run --check
[ "$status" -eq 3 ] || fail "check without the identity exited $status, not 3: $out"
case "$out" in *"not installed: there is no keychain $keychain"*"Run scripts/qa/install-test-signing-identity.sh once"*) ;; *) fail "check message: $out" ;; esac
[ ! -e "$keychain" ] || fail "check created $keychain"
[ ! -e "$tmp/keychains" ] || fail "check created $tmp/keychains"
listed && fail "check put the keychain on the search list"
[ -s "$calls" ] && fail "check ran sudo: $(cat "$calls")"
run --use
[ "$status" -eq 3 ] || fail "use without the identity exited $status, not 3: $out"
[ ! -e "$keychain" ] || fail "use created $keychain"

run --bogus
[ "$status" -eq 2 ] || fail "a bad argument exited $status, not 2: $out"

# 2. The install creates the keychain, its password and the identity, lists the keychain and asks to
# trust the certificate for code signing only; the fake sudo trusts nothing, so it is not ready.
run
[ "$status" -eq 4 ] || fail "install with the fake sudo exited $status, not 4: $out"
case "$out" in *"created the keychain $keychain"*"put $keychain on the keychain search list"*"created the code-signing identity"*"not trusted"*) ;; *) fail "install output: $out" ;; esac
[ -f "$keychain" ] || fail "install did not create $keychain"
[ "$(stat -f %Lp "$tmp/keychains/qa-signing.password")" = 600 ] || fail "the password file is not 0600"
listed || fail "install did not put the keychain on the search list"
first="$(sha)"
[ -n "$first" ] || fail "install created no identity named Symphony QA Test Signing"
grep -q '^security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain ' "$calls" ||
  fail "install did not trust the certificate for code signing: $(cat "$calls")"
[ "$(wc -l < "$calls" | tr -d ' ')" = 1 ] || fail "install ran sudo more than once: $(cat "$calls")"

run --check
[ "$status" -eq 4 ] || fail "check of an untrusted identity exited $status, not 4: $out"
case "$out" in *"not trusted"*) ;; *) fail "untrusted check message: $out" ;; esac
run --use
[ "$status" -eq 4 ] || fail "use of an untrusted identity exited $status, not 4: $out"

# 3. A second install keeps the keychain, its password and the identity, and asks to trust it again.
password="$(cat "$tmp/keychains/qa-signing.password")"
run
[ "$status" -eq 4 ] || fail "second install exited $status, not 4: $out"
case "$out" in *created*) fail "second install created something again: $out" ;; esac
[ "$(sha)" = "$first" ] || fail "second install replaced the identity"
[ "$(cat "$tmp/keychains/qa-signing.password")" = "$password" ] || fail "second install replaced the keychain password"
[ "$(security list-keychains -d user | grep -c "$keychain")" = 1 ] || fail "second install listed the keychain twice"
[ "$(wc -l < "$calls" | tr -d ' ')" = 2 ] || fail "second install did not ask to trust the certificate again"

# 4. Trusted for real (CI): ready, usable for a build, and a third install changes nothing.
if [ "${SYMPHONY_QA_SIGNING_TEST_TRUST:-}" = 1 ]; then
  security find-certificate -c "Symphony QA Test Signing" -p "$keychain" > "$tmp/trusted.pem"
  cat > "$tmp/real-sudo" << EOF
#!/bin/sh
echo "\$*" >> "$calls"
exec sudo -n "\$@"
EOF
  chmod +x "$tmp/real-sudo"
  export SYMPHONY_QA_SIGNING_SUDO="$tmp/real-sudo"
  run
  [ "$status" -eq 0 ] || fail "install with sudo exited $status, not 0: $out"
  run --check
  [ "$status" -eq 0 ] || fail "check of the trusted identity exited $status, not 0: $out"
  case "$out" in *"ready: \"Symphony QA Test Signing\" ($first)"*) ;; *) fail "ready check message: $out" ;; esac
  run --use
  [ "$status" -eq 0 ] || fail "use of the trusted identity exited $status, not 0: $out"
  case "$out" in *"symphony-qa-signing-identity:$first"*"symphony-qa-signing-keychain:$keychain"*) ;; *) fail "use output: $out" ;; esac
  trusts="$(wc -l < "$calls" | tr -d ' ')"
  run
  [ "$status" -eq 0 ] || fail "third install exited $status, not 0: $out"
  [ "$(wc -l < "$calls" | tr -d ' ')" = "$trusts" ] || fail "third install ran sudo again"
  case "$out" in *created* | *trusting*) fail "third install changed something: $out" ;; esac
else
  echo "skipped the real trust step (set SYMPHONY_QA_SIGNING_TEST_TRUST=1 where sudo needs no password)"
fi

if [ "$failed" -ne 0 ]; then exit 1; fi
echo "install-test-signing-identity: all checks passed"
