#!/bin/sh
# Installs the QA host's code-signing identity for the QA release pair (the QA driver's
# qa_build_release_pair signs release N and its update N+1 with it, so N accepts N+1).
#
# It is a self-signed identity named for QA tests, never Symphony's release certificate, in a
# keychain of its own for the QA user. The keychain goes on the user's keychain search list
# (codesign finds an identity only there) and the certificate is trusted for code signing only.
# Run it once on the QA host, as the QA user: trusting the certificate is the one step that needs
# sudo. Running it again changes nothing when the identity is installed and trusted, and finishes
# an install that stopped half way.
#
# Usage:
#   scripts/qa/install-test-signing-identity.sh          install it, or finish installing it
#   scripts/qa/install-test-signing-identity.sh --check  say whether it is installed and trusted;
#                                                        changes nothing and needs no sudo
#   scripts/qa/install-test-signing-identity.sh --use    unlock its keychain for a build, check that
#                                                        codesign accepts what it signs, and print it
#                                                        (what the QA driver runs)
#
# Exit status: 0 ready, 3 not installed, 4 installed but not trusted for code signing, 1 any other
# failure, 2 a bad argument.
#
# Environment, for tests:
#   SYMPHONY_QA_SIGNING_KEYCHAIN  the keychain (default ~/Library/Keychains/symphony-qa-signing.keychain-db);
#                                 its password is kept next to it, in <name>.password
#   SYMPHONY_QA_SIGNING_SUDO      the command the trust step runs under (default sudo)
set -u

name="Symphony QA Test Signing"
keychain="${SYMPHONY_QA_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/symphony-qa-signing.keychain-db}"
password_file="${keychain%.keychain-db}.password"
sudo_command="${SYMPHONY_QA_SIGNING_SUDO:-sudo}"
openssl=/usr/bin/openssl
fix="Run scripts/qa/install-test-signing-identity.sh once on this host as this user (it asks for sudo to trust the certificate)."

mode=install
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  --use) mode=use ;;
  *)
    echo "usage: $0 [--check | --use]" >&2
    exit 2
    ;;
esac

say() {
  echo "install-test-signing-identity: $*"
}

die() {
  say "$1" >&2
  exit "${2:-1}"
}

# The path with its folder resolved, as the keychain search list prints it.
canonical() {
  dir="$(cd "$(dirname "$1")" 2> /dev/null && pwd -P)" || {
    printf '%s\n' "$1"
    return
  }
  printf '%s/%s\n' "$dir" "$(basename "$1")"
}

search_list() {
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
}

on_search_list() {
  wanted="$(canonical "$keychain")"
  search_list | while IFS= read -r entry; do
    if [ -n "$entry" ] && [ "$(canonical "$entry")" = "$wanted" ]; then
      echo yes
      break
    fi
  done | grep -q yes
}

# The SHA-1 of the identity, from every code-signing identity in the keychain (`-v`: only the
# ones codesign accepts, which a self-signed one is once it is trusted for code signing).
identity_sha() {
  security find-identity "$@" -p codesigning "$keychain" 2> /dev/null |
    sed -n "s/^[[:space:]]*[0-9][0-9]*) \([0-9A-F]\{40\}\) \"$name\".*/\1/p" | head -n 1
}

# 0 ready, 3 not installed, 4 not trusted; says why when it is not ready. Reads only.
status() {
  if [ ! -f "$keychain" ]; then
    say "not installed: there is no keychain $keychain. $fix"
    return 3
  fi
  if [ -z "$(identity_sha)" ]; then
    say "not installed: the keychain $keychain has no code-signing identity \"$name\". $fix"
    return 3
  fi
  if ! on_search_list; then
    say "not installed: the keychain $keychain is not on this user's keychain search list, so codesign can't find \"$name\". $fix"
    return 3
  fi
  if [ -z "$(identity_sha -v)" ]; then
    say "not trusted: \"$name\" in $keychain is installed but not trusted for code signing, so the app would refuse an update it signs. $fix"
    return 4
  fi
  return 0
}

unlock() {
  [ -f "$password_file" ] || die "the keychain $keychain has no password file $password_file; delete the keychain (security delete-keychain \"$keychain\") and run this script again"
  security unlock-keychain -p "$(cat "$password_file")" "$keychain" || die "couldn't unlock $keychain"
}

create_keychain() {
  umask 077
  mkdir -p "$(dirname "$keychain")" || die "couldn't create the folder for $keychain"
  password="$($openssl rand -hex 24)" || die "couldn't make a keychain password"
  printf '%s\n' "$password" > "$password_file" || die "couldn't write $password_file"
  security create-keychain -p "$password" "$keychain" || die "couldn't create $keychain"
  # No timeout and no lock on sleep: a build unlocks it with --use, and a QA pass may run at any time.
  security set-keychain-settings "$keychain" || die "couldn't set $keychain's lock settings"
  say "created the keychain $keychain"
}

add_to_search_list() {
  list="$(search_list)"
  set -- "$keychain"
  while IFS= read -r entry; do
    if [ -n "$entry" ]; then set -- "$@" "$entry"; fi
  done << EOF
$list
EOF
  security list-keychains -d user -s "$@" || die "couldn't put $keychain on the keychain search list"
  say "put $keychain on the keychain search list"
}

create_identity() {
  work="$(mktemp -d "${TMPDIR:-/tmp}/qa-signing.XXXXXX")" || die "couldn't make a temporary folder"
  pass="$($openssl rand -hex 16)"
  cat > "$work/cert.cnf" << EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  if ! $openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 3650 \
    -config "$work/cert.cnf" > "$work/openssl.log" 2>&1 ||
    ! $openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/identity.p12" \
      -passout "pass:$pass" -name "$name" >> "$work/openssl.log" 2>&1; then
    cat "$work/openssl.log" >&2
    rm -rf "$work"
    die "couldn't make the self-signed certificate"
  fi
  security import "$work/identity.p12" -k "$keychain" -f pkcs12 -P "$pass" -T /usr/bin/codesign > /dev/null &&
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$password_file")" "$keychain" > /dev/null
  imported=$?
  rm -rf "$work"
  [ "$imported" -eq 0 ] || die "couldn't import the identity into $keychain"
  say "created the code-signing identity \"$name\" ($(identity_sha)) in $keychain"
}

trust() {
  work="$(mktemp -d "${TMPDIR:-/tmp}/qa-signing.XXXXXX")" || die "couldn't make a temporary folder"
  security find-certificate -c "$name" -p "$keychain" > "$work/cert.pem" || {
    rm -rf "$work"
    die "couldn't read the certificate of \"$name\" from $keychain"
  }
  say "trusting \"$name\" for code signing only (sudo security add-trusted-cert -p codeSign)"
  $sudo_command security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$work/cert.pem"
  trusted=$?
  rm -rf "$work"
  [ "$trusted" -eq 0 ] || die "couldn't trust the certificate for code signing" 4
}

# Signs a copy of /usr/bin/true and verifies it as the app verifies an update.
probe() {
  work="$(mktemp -d "${TMPDIR:-/tmp}/qa-signing.XXXXXX")" || die "couldn't make a temporary folder"
  cp /usr/bin/true "$work/probe"
  codesign --force --sign "$1" --keychain "$keychain" "$work/probe" > "$work/codesign.log" 2>&1 &&
    codesign --verify --strict "$work/probe" >> "$work/codesign.log" 2>&1
  verified=$?
  if [ "$verified" -ne 0 ]; then cat "$work/codesign.log"; fi
  rm -rf "$work"
  return "$verified"
}

case "$mode" in
  check)
    status
    checked=$?
    if [ "$checked" -eq 0 ]; then say "ready: \"$name\" ($(identity_sha -v)) in $keychain is trusted for code signing"; fi
    exit "$checked"
    ;;
  use)
    status
    checked=$?
    [ "$checked" -eq 0 ] || exit "$checked"
    unlock
    sha="$(identity_sha -v)"
    if ! probe "$sha"; then
      say "not trusted: codesign doesn't accept what \"$name\" signs. $fix"
      exit 4
    fi
    printf 'symphony-qa-signing-identity:%s\n' "$sha"
    printf 'symphony-qa-signing-keychain:%s\n' "$keychain"
    exit 0
    ;;
esac

if [ -f "$keychain" ]; then unlock; else create_keychain; fi
if ! on_search_list; then add_to_search_list; fi
if [ -z "$(identity_sha)" ]; then create_identity; fi
if [ -z "$(identity_sha -v)" ]; then trust; fi
status
installed=$?
if [ "$installed" -eq 0 ]; then say "ready: \"$name\" ($(identity_sha -v)) in $keychain is trusted for code signing"; fi
exit "$installed"
