#!/bin/sh
# Gives a QA VM (`auto_review.worker_host`) the toolchain project QA passes build with: Go,
# Postgres 18's server binaries and jq. Run it from the Symphony Mac; it runs itself on the VM over
# SSH, as the QA user, and needs that user's passwordless sudo for the links in /usr/local/bin.
#
#   * Go from the official go.dev darwin-arm64 package, under /usr/local/go. The version is the
#     newest release of --go-version (default 1.26, the job-search-hub server/go.mod pin), or
#     exactly that release when it names a patch (1.26.1). The package's SHA-256 is checked
#     against go.dev's.
#   * Postgres 18 from Homebrew's postgresql@18: initdb, pg_ctl, postgres, psql and pg_dump. It
#     never starts a Postgres service and never creates a cluster: the project's dev server owns
#     its cluster for each pass.
#   * jq, from Homebrew when the VM has none.
#
# Each tool is linked into /usr/local/bin, and ~/.zshenv puts /usr/local/bin first on the PATH,
# so a non-login SSH shell (the one the QA build and the QA host check run in) finds it. Running it
# again installs nothing. It prints what it installed and skipped, then a report block with each
# tool's version, read from a fresh non-login SSH shell.
#
# It refuses a VM that holds push credentials (a private key in ~/.ssh, GitHub CLI credentials, a
# global git credential helper or a forwarded SSH agent), the checks QA makes before every pass
# (`qa_worker_unsafe`), and never adds any.
#
# Usage:
#   scripts/qa-vm/provision.sh [--go-version 1.26] admin@<host>
#
# Exit status: 0 provisioned, 1 a step failed, 2 a bad argument, 3 the VM holds push credentials.
set -eu

usage() {
  echo "usage: $0 [--go-version <major.minor[.patch]>] <user@host>" >&2
  exit 2
}

valid_go_version() {
  printf '%s\n' "$1" | grep -Eq '^1\.[0-9]+(\.[0-9]+)?$'
}

# -- On the VM ---------------------------------------------------------------------------------

remote() {
  go_version=$1
  installed=""
  skipped=""
  note_installed() { installed="$installed $1"; echo "installed: $1"; }
  note_skipped() { skipped="$skipped $1"; echo "skipped: $1 ($2)"; }

  found=""
  for key in "$HOME"/.ssh/id_*; do
    case "$key" in *.pub) ;; *) if [ -e "$key" ]; then found="$found; has a private key ~/.ssh/${key##*/}"; fi ;; esac
  done
  if [ -e "$HOME/.config/gh/hosts.yml" ]; then found="$found; has GitHub CLI credentials in ~/.config/gh"; fi
  if [ -n "$(git config --global --get credential.helper 2>/dev/null || true)" ]; then found="$found; has a global git credential helper"; fi
  if [ -n "${SSH_AUTH_SOCK:-}" ]; then found="$found; has a forwarded SSH agent"; fi
  if [ -n "$found" ]; then
    echo "refused: this QA VM ${found#; }. QA must not run where PR code can reach push credentials; remove them first." >&2
    exit 3
  fi

  if ! sudo -n true 2>/dev/null; then
    echo "error: $(id -un) needs passwordless sudo on this VM to link the tools into /usr/local/bin" >&2
    exit 1
  fi

  brew=/opt/homebrew/bin/brew
  if [ ! -x "$brew" ]; then
    echo "error: Homebrew is not installed at /opt/homebrew on this VM" >&2
    exit 1
  fi
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
  export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
  sudo -n mkdir -p /usr/local/bin

  # Links /usr/local/bin/<name> to <target> unless it already points there.
  link() {
    if [ "$(readlink "/usr/local/bin/$1" 2>/dev/null || true)" = "$2" ]; then
      note_skipped "link $1" "already linked"
    else
      sudo -n ln -sf "$2" "/usr/local/bin/$1"
      note_installed "link $1 -> $2"
    fi
  }

  # jq first: the Go step reads go.dev's release list with it.
  if [ -x /opt/homebrew/bin/jq ] || [ -x /usr/local/bin/jq ] || [ -x /usr/bin/jq ]; then
    note_skipped jq "present"
  else
    "$brew" install --quiet jq
    note_installed jq
  fi
  if [ ! -e /usr/local/bin/jq ] && [ -x /opt/homebrew/bin/jq ]; then link jq /opt/homebrew/bin/jq; fi

  if "$brew" list --versions postgresql@18 >/dev/null 2>&1; then
    note_skipped postgresql@18 "present"
  else
    "$brew" install --quiet postgresql@18
    note_installed postgresql@18
  fi
  pg_bin="$("$brew" --prefix postgresql@18)/bin"
  for tool in initdb pg_ctl postgres psql pg_dump; do link "$tool" "$pg_bin/$tool"; done

  # 1.26 takes any 1.26.x already installed, and the newest one otherwise; 1.26.1 takes only itself.
  case "$go_version" in
    *.*.*) go_match="go$go_version" go_present="go$go_version" ;;
    *) go_match="go$go_version." go_present="go$go_version.[0-9]*" ;;
  esac
  current=$(/usr/local/go/bin/go env GOVERSION 2>/dev/null || true)
  # shellcheck disable=SC2254
  case "$current" in
    $go_present) note_skipped "Go $current" "present" ;;
    *)
      release=$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | jq -r --arg match "$go_match" '
        [.[] | select(.stable) | .files[]
          | select(.os == "darwin" and .arch == "arm64" and .kind == "installer")
          | select(.version == $match or ($match | endswith(".")) and (.version | startswith($match)))
        ] | first | select(.) | "\(.version) \(.filename) \(.sha256)"')
      if [ -z "$release" ]; then
        echo "error: go.dev lists no stable darwin-arm64 package for Go $go_version" >&2
        exit 1
      fi
      # shellcheck disable=SC2086
      set -- $release
      pkg=$(mktemp -d)/$2
      curl -fsSL -o "$pkg" "https://go.dev/dl/$2"
      if [ "$(shasum -a 256 "$pkg" | cut -d' ' -f1)" != "$3" ]; then
        echo "error: $2 does not match go.dev's SHA-256" >&2
        exit 1
      fi
      sudo -n installer -pkg "$pkg" -target / >/dev/null
      rm -rf "$(dirname "$pkg")"
      note_installed "Go $1"
      ;;
  esac
  for tool in go gofmt; do link "$tool" "/usr/local/go/bin/$tool"; done

  # A non-login zsh, which runs SSH commands, reads only ~/.zshenv.
  marker="# symphony-qa-vm: /usr/local/bin first"
  if grep -qF "$marker" "$HOME/.zshenv" 2>/dev/null; then
    note_skipped "~/.zshenv PATH" "present"
  else
    printf '\n%s\nexport PATH="/usr/local/bin:$PATH"\n' "$marker" >> "$HOME/.zshenv"
    note_installed "~/.zshenv PATH"
  fi

  echo "installed:${installed:- nothing}"
  echo "skipped:${skipped:- nothing}"
}

# -- On the Symphony Mac -----------------------------------------------------------------------

if [ "${1:-}" = "--remote" ]; then
  [ $# -eq 2 ] || usage
  # The rest of this script is still on stdin, so nothing it runs may read stdin.
  remote "$2" < /dev/null
  exit 0
fi

go_version=1.26
while [ $# -gt 1 ]; do
  case "$1" in
    --go-version) [ $# -ge 3 ] || usage; go_version=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ $# -eq 1 ] || usage
host=$1
case "$host" in -* | "") usage ;; esac
valid_go_version "$go_version" || { echo "error: --go-version takes a Go release such as 1.26 or 1.26.1" >&2; exit 2; }

ssh_opts="-o ForwardAgent=no -o ClearAllForwardings=yes"
# shellcheck disable=SC2086
ssh $ssh_opts "$host" /bin/sh -s -- --remote "$go_version" < "$0"

# A fresh SSH session, so the versions come from the PATH a non-login shell gets.
echo "symphony-qa-provision:begin host=$host"
# shellcheck disable=SC2086
ssh $ssh_opts "$host" 'for tool in go pg_ctl initdb jq; do command -v "$tool" >/dev/null || { echo "missing: $tool"; exit 1; }; done; go version; pg_ctl --version; initdb --version; jq --version'
echo "symphony-qa-provision:end"
