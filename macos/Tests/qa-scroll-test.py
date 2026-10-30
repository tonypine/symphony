#!/usr/bin/env python3
"""Tests the QA driver's `scroll` command (`qa_scroll`) against a SwiftUI app.

It builds priv/qa_driver/symphony-qa-driver.swift as the copy Symphony builds for a
separate QA host (`-D SYMPHONY_QA_SSH`, which runs its commands directly) and a small
SwiftUI fixture: a window with a `ScrollView` whose `LazyVStack` loads another page of
rows when its last row appears (60 at a time, up to 180, as a list of older runs does)
and a `List` of 200 rows. Rows off screen are not in the accessibility tree, so finding
the last row there proves the list was scrolled to it. It then checks that:

1. an edge scroll on the `ScrollView` reaches its end, past the pages it loads there, and
   its last row is on screen in the AX tree;
2. an edge scroll on the `List` reaches its last row;
3. an edge scroll at a point scrolls the `List` back to its first row;
4. a delta scroll moves the `List` by about the points asked for, and a line delta
   moves it down.

It launches a window and needs the Accessibility grant, so it runs in CI only, never
in an agent's sandbox.

Usage (from macos/): python3 -I Tests/qa-scroll-test.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

PRIV = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "priv", "qa_driver"))

FIXTURE = r"""
import AppKit
import SwiftUI

// The next page arrives a moment later, as one read from an API does.
final class Feed: ObservableObject {
    @Published var count = 60
    private var loading = false

    func loadMore() {
        guard !loading, count < 180 else { return }
        loading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.count += 60
            self.loading = false
        }
    }
}

struct Pages: View {
    @ObservedObject var feed: Feed

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(1...feed.count, id: \.self) { row in
                    Text("Page row \(row)")
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .onAppear { if row == feed.count { feed.loadMore() } }
                }
            }
        }
    }
}

struct Fixture: View {
    let feed = Feed()

    var body: some View {
        HStack(spacing: 0) {
            Pages(feed: feed).frame(width: 300)
            List(1...200, id: \.self) { row in Text("List row \(row)") }.frame(width: 300)
        }
        .frame(width: 600, height: 400)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "qa-scroll-fixture"
window.contentView = NSHostingView(rootView: Fixture())
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
"""

failures = []


def fail(name, message):
    print(f"FAIL [{name}]: {message}")
    failures.append(name)


def compile_swift(root, source, output, flags=()):
    cache = os.path.join(root, "module-cache")
    command = ["swiftc", *flags, "-module-cache-path", cache, "-o", output, source]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"swiftc failed for {source}:\n{result.stderr[-4000:]}")


def driver(binary, *args):
    result = subprocess.run([binary, *map(str, args)], capture_output=True, text=True, timeout=60)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"error": {"code": "unreadable", "message": result.stdout[-500:] + result.stderr[-500:]}}


def find(binary, pid, text):
    """The first static text whose value contains `text`."""
    reply = driver(binary, "ax-tree", pid, 40, 5, "AXStaticText", text)
    matches = [m for m in reply.get("matches", []) if text in (m.get("value") or m.get("title") or "")]
    return matches[0] if matches else None


def inside(frame, area):
    """True when the frame's middle is inside the area's frame: the row is on screen."""
    if not frame or not area:
        return False
    mid_y = frame["y"] + frame["h"] / 2
    return area["y"] <= mid_y <= area["y"] + area["h"]


def wait_for_window(binary, pid):
    for _ in range(60):
        windows = driver(binary, "windows", pid).get("windows", [])
        if any(w.get("onscreen") and w.get("layer") == 0 for w in windows) and find(binary, pid, "List row 1"):
            return True
        time.sleep(0.5)
    return False


def scroll_to_end(binary, pid, name, first, last):
    failed = len(failures)
    start = find(binary, pid, first)
    if not start:
        return fail(name, f"no row {first!r} in the AX tree")
    if find(binary, pid, last):
        return fail(name, f"{last!r} is already in the AX tree before scrolling; the fixture shows too much")

    reply = driver(binary, "scroll", pid, start["path"], "bottom", "pixel")
    if "error" in reply:
        return fail(name, f"scroll failed: {reply['error']}")
    if reply.get("at_edge") is not True:
        fail(name, f"at_edge is {reply.get('at_edge')!r} after {reply.get('rounds')} rounds: {reply.get('note')}")

    row = find(binary, pid, last)
    if not row:
        return fail(name, f"{last!r} is not in the AX tree after scrolling to the bottom; visible: {reply.get('visible')}")
    area = reply.get("scroll_area", {}).get("frame")
    if not inside(row.get("frame"), area):
        fail(name, f"{last!r} at {row.get('frame')} is outside the scroll area {area}")
    if last not in (reply.get("visible", {}).get("last", {}) or {}).get("text", ""):
        fail(name, f"the reply's last visible row is {reply.get('visible', {}).get('last')}, not {last!r}")
    if len(failures) > failed:
        return None
    print(f"ok [{name}]: {last!r} on screen after {reply.get('rounds')} rounds via {reply.get('via')}")
    return reply


def main():
    root = tempfile.mkdtemp(prefix="qa-scroll-test.")
    fixture = None
    try:
        binary = os.path.join(root, "symphony-qa-driver")
        compile_swift(root, os.path.join(PRIV, "symphony-qa-driver.swift"), binary, ["-D", "SYMPHONY_QA_SSH"])
        source = os.path.join(root, "fixture.swift")
        with open(source, "w") as handle:
            handle.write(FIXTURE)
        app = os.path.join(root, "fixture")
        compile_swift(root, source, app)

        permissions = driver(binary, "permissions")
        if permissions.get("accessibility") is not True:
            sys.exit(f"FAIL [permissions]: this runner gives the driver no Accessibility grant: {permissions}")

        fixture = subprocess.Popen([app], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pid = fixture.pid
        if not wait_for_window(binary, pid):
            sys.exit("FAIL [launch]: the fixture's window and its List never showed in the AX tree")

        # 1. The ScrollView loads two more pages at its end; the edge scroll reaches the last.
        scroll_to_end(binary, pid, "scroll view to the end", "Page row 1", "Page row 180")

        # 2. The List's last row.
        list_end = scroll_to_end(binary, pid, "list to the end", "List row 1", "List row 200")
        if list_end:
            check_list_scrolls(binary, pid, list_end["scroll_area"]["frame"])
    finally:
        if fixture:
            fixture.terminate()
            fixture.wait(timeout=10)
        shutil.rmtree(root, ignore_errors=True)

    if failures:
        sys.exit(f"{len(failures)} failure(s)")
    print("qa-scroll-test: all passed")


def check_list_scrolls(binary, pid, area):
    # 3. Back to the top, at a point in the middle of the List.
    x, y = area["x"] + area["w"] // 2, area["y"] + area["h"] // 2
    reply = driver(binary, "scroll", pid, f"{x},{y}", "top", "pixel")
    top = find(binary, pid, "List row 1")
    if "error" in reply or reply.get("at_edge") is not True or not top or not inside(top.get("frame"), area):
        return fail("list to the top at a point", f"reply {reply}, row 1 {top}")
    print("ok [list to the top at a point]")

    # 4. A delta of 120 points moves row 5 up by about 120 points.
    name = "pixel delta"
    before = find(binary, pid, "List row 5")
    reply = driver(binary, "scroll", pid, top["path"], "0,120", "pixel")
    after = find(binary, pid, "List row 5")
    moved = (reply.get("moved") or {}).get("y")
    if "error" in reply or not before or not after:
        fail(name, f"reply {reply}, row 5 before {before}, after {after}")
    else:
        shifted = before["frame"]["y"] - after["frame"]["y"]
        if not 90 <= shifted <= 150:
            fail(name, f"row 5 moved {shifted} points for a 120 point scroll")
        if moved is None or not 90 <= moved <= 150:
            fail(name, f"the reply says the content moved {moved}")
        print(f"ok [{name}]: row 5 moved {shifted} points, reply says {moved}")

    name = "line delta"
    reply = driver(binary, "scroll", pid, after["path"] if after else top["path"], "0,3", "line")
    moved = (reply.get("moved") or {}).get("y")
    if "error" in reply or moved is None or moved <= 0:
        fail(name, f"a 3 line scroll down moved {moved}: {reply}")
    else:
        print(f"ok [{name}]: moved {moved} points")


if __name__ == "__main__":
    main()
