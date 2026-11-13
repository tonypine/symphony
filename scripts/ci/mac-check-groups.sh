#!/bin/sh
# Which groups of Mac checks (.github/workflows/mac-checks.yml) a pull request needs, from the
# paths it changed, one per line on stdin. Prints `<group>=true|false` for each group and `any`,
# as GitHub's step outputs. The first argument is the conclusion of the release gate's last run on
# main: while it is `failure`, every group runs, so a pull request proves a fix for a check its own
# paths would skip, and nothing merges onto a red main unchecked.
#
# A group listed here with too few paths skips a check a change needed; main's gate still runs it,
# after the merge. When unsure, list the path.
set -eu

gate="${1:-}"
build=false unit=false sandbox=false helpers=false driver=false speed=false update=false smoke=false installer=false
all() { build=true unit=true sandbox=true helpers=true driver=true speed=true update=true smoke=true installer=true; }

while IFS= read -r path; do
  case "$path" in
    # The checks themselves: prove the whole set.
    .github/workflows/macos.yml | .github/workflows/mac-checks.yml | scripts/ci/mac-check-groups.sh) all ;;
  esac
  case "$path" in
    macos/Sources/* | macos/Package.swift | macos/Makefile | macos/Info.plist | macos/Resources/* | priv/qa_driver/* | .xcode-version) build=true ;;
  esac
  case "$path" in
    macos/Sources/* | macos/Tests/* | macos/Package.swift | test/fixtures/api/* | .xcode-version) unit=true ;;
  esac
  case "$path" in
    macos/Sources/* | macos/Tests/ticket-page-scroll-test.py | macos/Tests/Fixtures/* | priv/qa_driver/* | .xcode-version) speed=true build=true ;;
  esac
  case "$path" in
    macos/Package.swift | macos/Makefile | .xcode-version | lib/symphony_elixir/agent_tmp_dir.ex) sandbox=true ;;
  esac
  case "$path" in
    scripts/ci/* | scripts/qa/* | test/support/* | macos/Resources/update-helper.sh | macos/Tests/update-helper-test.sh | .xcode-version) helpers=true ;;
  esac
  case "$path" in
    priv/qa_driver/* | macos/Tests/qa-* | .xcode-version) driver=true ;;
  esac
  case "$path" in
    macos/Resources/update-helper.sh | macos/Sources/*/Update* | macos/Sources/*/AutoUpdate* | macos/Sources/*Updater* | macos/Tests/e2e/* | macos/Info.plist | macos/Makefile | rel/* | mix.exs | mix.lock | \
      scripts/release/* | test/support/macos_release/* | test/support/stubs/* | lib/symphony_elixir/tracker/memory.ex | .xcode-version) update=true ;;
  esac
  case "$path" in
    rel/* | mix.exs | mix.lock | mise.toml | Makefile | config/config.exs | config/runtime.exs | lib/symphony_elixir/cli.ex | lib/symphony_elixir/paths.ex | \
      lib/symphony_elixir/release_node.ex | lib/symphony_elixir/release_cookie.ex | scripts/release/* | .xcode-version | macos/Package.swift | \
      macos/Info.plist | macos/Makefile | symphony.yml | .github/workflows/release.yml) smoke=true ;;
  esac
  case "$path" in
    scripts/install-macos.sh) installer=true ;;
  esac
done

if [ "$gate" = failure ]; then all; fi

any=false
for value in $build $unit $sandbox $helpers $driver $speed $update $smoke $installer; do
  if [ "$value" = true ]; then any=true; fi
done

for group in any build unit sandbox helpers driver speed update smoke installer; do
  eval "echo \"$group=\$$group\""
done
