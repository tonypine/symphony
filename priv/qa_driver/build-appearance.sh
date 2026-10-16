#!/bin/sh
# Builds the QA appearance library (symphony-qa-appearance.m) into a dylib for
# both Mac architectures, signed ad hoc, and moves it into place only once it
# is whole. Symphony runs it on the machine the app runs on; the macOS CI job's
# Tests/qa-appearance-test.sh runs it too, so CI proves the library Symphony
# builds.
#
# Usage: sh build-appearance.sh <source.m> <output.dylib>
set -eu
source=$1
output=$2
part="$output.$$"
trap 'rm -f "$part"' EXIT
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch x86_64 -framework AppKit -o "$part" "$source"
codesign --force --sign - "$part"
mv -f "$part" "$output"
