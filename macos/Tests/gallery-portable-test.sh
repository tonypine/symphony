#!/bin/sh
# The Component Gallery outside the checkout (TP-1520): a QA host gets the QA build and no source tree, so the built
# gallery must read every fixture from the copy the build carries (`make gallery-resources`, Gallery/Files.swift).
#
#   sh Tests/gallery-portable-test.sh build/SymphonyGallery
#
# It lays the helper out as the QA build does (Contents/Helpers/SymphonyGallery, its fixtures in
# Contents/Resources/GalleryResources) in a temporary folder, runs it from there, and checks that `--entries`,
# `--check`, `--shot`, `--shot-all` and `--open`'s lookup read from that copy and nothing else. `make build-gallery` runs it.
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
# Foundation drops a leading /private from the paths it resolves (/private/tmp reads /tmp): compare real paths.
root="$(cd "$root" 2>/dev/null && pwd -P || echo "$root")"
[ "$root" = "$copy" ] || fail "--entries read its fixtures from $root, not from the copy the build carries ($copy)"
python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["entries"], "no entries"' "$work/entries.json" ||
  fail "--entries listed no entries"

"$helper" --check > "$work/check.txt" || { cat "$work/check.txt" >&2; fail "--check failed"; }

"$helper" --shot button --out "$work/shots" || fail "--shot button exited $?"
ls "$work/shots" | grep -q 'light' || fail "--shot button drew nothing"

# `--shot-all` draws every entry in one run, into one folder, under `--shot`'s file names (TP-1667): QA draws the
# change's gallery and its base's this way and compares them, so two runs of one build draw the same pictures.
"$helper" --shot-all --width desktop --appearance dark --out "$work/all" > "$work/all.txt" || fail "--shot-all exited $?"
"$helper" --shot-all --width desktop --appearance dark --out "$work/again" > /dev/null || fail "--shot-all exited $? the second time"
python3 - "$work/entries.json" "$work/all" "$work/again" <<'EOF' || fail "--shot-all did not draw every entry the same way twice"
import json, os, sys
entries, first, second = json.load(open(sys.argv[1]))["entries"], sys.argv[2], sys.argv[3]
drawn = sorted(os.listdir(first))
assert drawn, "no picture"
assert all(name.endswith("-dark.png") for name in drawn), "a picture in another appearance"
for entry in entries:
    names = [entry["id"] + "-1-dark.png"] if entry["kind"] == "component" else entry["variations"]
    assert any(any(name.startswith(n.removesuffix(".png")) for n in names) for name in drawn), "nothing of " + entry["id"]
assert drawn == sorted(os.listdir(second)), "the two runs drew other pictures"
changed = [name for name in drawn if open(os.path.join(first, name), "rb").read() != open(os.path.join(second, name), "rb").read()]
assert not changed, "drawn otherwise the second time: " + ", ".join(changed)
EOF

# `--open` reads every story before it opens its window; an entry it does not know stops it there, with the list.
if "$helper" --open no-such-entry > "$work/open.txt" 2>&1; then fail "--open no-such-entry opened a window"; fi
grep -q 'The entries: button' "$work/open.txt" || { cat "$work/open.txt" >&2; fail "--open did not reach its entries"; }

echo "gallery-portable-test: the built gallery reads every story from the copy it carries"
