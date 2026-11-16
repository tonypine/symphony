#!/bin/sh
# The Component Gallery outside the checkout (TP-1520): a QA host gets the QA build and no source tree, so the built
# gallery must read every fixture from the copy the build carries (`make gallery-resources`, Gallery/Files.swift).
#
#   sh Tests/gallery-portable-test.sh build/SymphonyGallery
#
# It lays the helper out as the QA build does (Contents/Helpers/SymphonyGallery, its fixtures in
# Contents/Resources/GalleryResources) in a temporary folder, runs it from there, and checks that `--entries`,
# `--check`, `--shot` and `--open`'s lookup read from that copy and nothing else. `make build-gallery` runs it.
set -eu

macos="$(cd "$(dirname "$0")/.." && pwd)"
gallery="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d "${TMPDIR:-/tmp}/gallery-portable.XXXXXX")"
trap 'rm -rf "$work"' EXIT

contents="$work/Symphony.app/Contents"
mkdir -p "$contents/Helpers"
cp "$gallery" "$contents/Helpers/SymphonyGallery"
make -s -C "$macos" gallery-resources GALLERY_RESOURCES="$contents/Resources/GalleryResources"
helper="$contents/Helpers/SymphonyGallery"
copy="$(cd "$contents/Resources/GalleryResources" && pwd -P)"

fail() { echo "gallery-portable-test: $*" >&2; exit 1; }

# Nothing of the checkout around it: the folder it runs in holds only the build.
cd "$work"

"$helper" --entries > "$work/entries.json" || fail "--entries exited $?"
root="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["root"])' "$work/entries.json")"
[ "$root" = "$copy" ] || fail "--entries read its fixtures from $root, not from the copy the build carries ($copy)"
python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["entries"], "no entries"' "$work/entries.json" ||
  fail "--entries listed no entries"

"$helper" --check > "$work/check.txt" || { cat "$work/check.txt" >&2; fail "--check failed"; }

"$helper" --shot button --out "$work/shots" || fail "--shot button exited $?"
ls "$work/shots" | grep -q 'light' || fail "--shot button drew nothing"

# `--open` reads every story before it opens its window; an entry it does not know stops it there, with the list.
if "$helper" --open no-such-entry > "$work/open.txt" 2>&1; then fail "--open no-such-entry opened a window"; fi
grep -q 'The entries: button' "$work/open.txt" || { cat "$work/open.txt" >&2; fail "--open did not reach its entries"; }

echo "gallery-portable-test: the built gallery reads every story from the copy it carries"
