#!/bin/sh
# Temporary, this branch only: why CGWindowList shows no windows in the ci-macos runner's
# session while the accessibility tree is full (qa-scroll-test and qa-key-test fail at
# [launch] there; the probe of run 43463045353 showed ax-ping ok, ax-tree complete,
# windows: [] for every fixture variant). This script runs as a CI job, which is the
# runner's own session, and answers:
#
# 1. what the window list enumerates at all from here (every window, or nothing);
# 2. whether a screenshot from this context captures the real screen or a blank one
#    (the window server is there for the apps, the question is what the *asking*
#    process sees);
# 3. what the system TCC database holds for the runner's node and for sshd, including
#    whether the rows the setup script copied kept sshd's Apple code-signing
#    requirement (csreq), which would let Accessibility match and ScreenCapture's
#    window list fall back to redacted-empty;
# 4. node's folders and code signature, and the runner service's state.

set -u
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/winlist.swift" <<'SWIFT'
import ApplicationServices
import CoreGraphics
import Foundation

print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
print("CGPreflightScreenCaptureAccess: \(CGPreflightScreenCaptureAccess())")

if let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
    print("optionAll windows: \(all.count)")
    for w in all.prefix(40) {
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let name = w[kCGWindowName as String] as? String ?? "?"
        let layer = w[kCGWindowLayer as String] as? Int ?? -999
        let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
        print("  pid=\(pid) owner=\(owner) name=\(name) layer=\(layer) onscreen=\(onscreen)")
    }
} else {
    print("optionAll: nil")
}

if let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
    print("onScreenOnly windows: \(visible.count)")
} else {
    print("onScreenOnly: nil")
}
SWIFT

cat > "$tmp/pixels.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count == 2,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("cannot decode")
    exit(0)
}
let width = img.width
let height = img.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var data = [UInt8](repeating: 0, count: width * height * 4)
let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
var distinct = Set<Int>()
var i = 0
while i + 2 < data.count && distinct.count <= 5000 {
    distinct.insert((Int(data[i]) << 16) | (Int(data[i + 1]) << 8) | Int(data[i + 2]))
    i += 4
}
print("decoded \(width)x\(height), distinct colors (cap 5000): \(distinct.count)")
SWIFT

echo "== compile =="
swiftc -o "$tmp/winlist" "$tmp/winlist.swift" || exit 1
swiftc -o "$tmp/pixels" "$tmp/pixels.swift" || exit 1

echo "== window list, asked from the runner's session =="
"$tmp/winlist"

echo "== screenshot content, taken from the runner's session =="
screencapture -x "$tmp/screen.png" || echo "screencapture failed with $?"
[ -f "$tmp/screen.png" ] && "$tmp/pixels" "$tmp/screen.png"

echo "== TCC rows: the runner's node and sshd =="
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, client, auth_value, case when csreq is null then 'no csreq' when length(csreq)=0 then 'empty csreq' else 'csreq ' || length(csreq) || ' bytes' end from access where client like '%/node' or client like '%sshd%' order by service, client;"

echo "== runner node folders and signatures =="
ls /Users/admin/runner/externals/ 2>/dev/null
for n in /Users/admin/runner/externals/node*/bin/node; do
    echo "-- $n"
    codesign -dvv "$n" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Signature|Authority)" | head -4
done

echo "== runner service =="
launchctl print "gui/$(id -u)/actions.runner.tonypine-symphony.ci-macos" 2>/dev/null | grep -E "state|pid|session" | head -8
