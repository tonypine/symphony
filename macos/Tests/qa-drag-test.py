#!/usr/bin/env python3
"""Tests the QA driver's `drag` command (`qa_drag`): a real mouse drag, as a person's hand makes it.

It builds priv/qa_driver/symphony-qa-driver.swift as the copy Symphony builds for a separate QA
host (`-D SYMPHONY_QA_SSH`, which runs its commands directly) and a small AppKit fixture: a window
with a pad that counts the mouse events it gets (button down, drags with the button held, button
up) and shows them, with how far the pointer went between the press and the last event, in a
label. Through the driver's `drag` command it checks that:

1. a drag from the pad's element path to a point on it arrives as one button down, a run of
   drags and one button up, and ends where it was aimed (`via: hid`);
2. a drag from a point to the pad's element path does the same, from that point to the pad's
   centre;
3. a drag whose end is off the app's windows is refused (`not_on_screen`) and sends nothing.

Before TP-1676 no QA tool dragged, and two QA passes of TP-1610 ended blocked on a drag step.

It launches windows and needs the Accessibility grant, so it runs in the QA VM's Window tests
step (macos/Tests/window-tests.json), never in an agent's sandbox.

Usage (from macos/): python3 -I Tests/qa-drag-test.py
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

PRIV = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "priv", "qa_driver"))

FIXTURE = r"""
import AppKit

// Counts the mouse events it gets and shows them in the label, with how far the pointer went
// from the press, in points on screen (x right, y down).
final class Pad: NSView {
    var label: NSTextField!
    var downs = 0
    var moves = 0
    var ups = 0
    var start = NSPoint.zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downs += 1
        start = event.locationInWindow
        show(event)
    }

    override func mouseDragged(with event: NSEvent) {
        moves += 1
        show(event)
    }

    override func mouseUp(with event: NSEvent) {
        ups += 1
        show(event)
    }

    func show(_ event: NSEvent) {
        let point = event.locationInWindow
        let dx = Int((point.x - start.x).rounded())
        let dy = Int((start.y - point.y).rounded())
        label.stringValue = "Drag: down \(downs) moved \(moves) up \(ups) dx \(dx) dy \(dy)"
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemTeal.setFill()
        dirtyRect.fill()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "qa-drag-fixture"
window.isReleasedWhenClosed = false

let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
let label = NSTextField(labelWithString: "Drag: none")
label.frame = NSRect(x: 20, y: 280, width: 440, height: 24)
let pad = Pad(frame: NSRect(x: 20, y: 20, width: 440, height: 240))
pad.label = label
pad.setAccessibilityElement(true)
pad.setAccessibilityRole(.group)
pad.setAccessibilityLabel("Drag pad")
content.addSubview(label)
content.addSubview(pad)
window.contentView = content

DispatchQueue.main.async {
    app.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
}
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


def wait(condition, seconds=5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.2)
    return condition()


def onscreen(binary, pid):
    windows = driver(binary, "windows", pid).get("windows", [])
    return any(w.get("onscreen") and w.get("layer") == 0 and w.get("title") == "qa-drag-fixture" for w in windows)


def shown(binary, pid):
    """The label's text: the mouse events the pad got."""
    reply = driver(binary, "ax-tree", pid, 40, 10, "AXStaticText", "Drag:")
    for match in reply.get("matches", []):
        value = match.get("value") or match.get("title") or match.get("description") or ""
        if value.startswith("Drag:"):
            return value
    return None


def pad(binary, pid):
    """The pad's element path and frame."""
    for role in ("AXGroup", ""):
        reply = driver(binary, "ax-tree", pid, 40, 20, role, "Drag pad")
        for match in reply.get("matches", []):
            if "Drag pad" in [match.get(key) or "" for key in ("description", "title", "value")] and match.get("frame"):
                return match["path"], match["frame"]
    return None, None


def drag(binary, pid, start, end):
    reply = driver(binary, "drag", pid, start, end, 150, 30)
    if reply.get("error", {}).get("code") == "covered":
        # The runner's session can show a system dialog (UserNotificationCenter) over the
        # fixture. The driver is right to refuse; the test clears the dialog and retries once.
        print(f"  covered, clearing the system dialog: {json.dumps(reply)}")
        subprocess.run(["killall", "UserNotificationCenter"], capture_output=True)
        time.sleep(1)
        reply = driver(binary, "drag", pid, start, end, 150, 30)
    print(f"  drag {start} -> {end}: {json.dumps(reply)[:400]}")
    return reply


def check_drag(binary, pid, start, end, downs, dx, dy, name):
    reply = drag(binary, pid, start, end)
    if "error" in reply:
        return fail(name, f"drag failed: {reply['error']}")
    if reply.get("via") != "hid":
        return fail(name, f"the drag did not go the mouse's way: via {reply.get('via')!r}")

    pattern = re.compile(r"Drag: down (\d+) moved (\d+) up (\d+) dx (-?\d+) dy (-?\d+)")

    def arrived():
        match = pattern.fullmatch(shown(binary, pid) or "")
        if not match:
            return False
        down, moved, up, got_dx, got_dy = map(int, match.groups())
        return down == downs and up == downs and moved >= 30 and abs(got_dx - dx) <= 1 and abs(got_dy - dy) <= 1

    if not wait(arrived):
        return fail(name, f"the pad reads {shown(binary, pid)!r}; expected {downs} down and up, at least 30 moves, dx {dx} dy {dy}")
    print(f"ok [{name}]")


def main():
    root = tempfile.mkdtemp(prefix="qa-drag-test.")
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
        if not wait(lambda: onscreen(binary, pid) and shown(binary, pid) == "Drag: none", 30):
            sys.exit(f"FAIL [launch]: the fixture's window and its label never showed: {shown(binary, pid)!r}")

        path, frame = pad(binary, pid)
        if path is None:
            sys.exit("FAIL [pad]: the pad is not in the accessibility tree")
        cx, cy = frame["x"] + frame["w"] // 2, frame["y"] + frame["h"] // 2

        # 1. From the pad's element path to a point on it.
        check_drag(binary, pid, path, f"{cx + 150},{cy + 60}", 1, 150, 60, "a drag from an element to a point")

        # 2. From a point to the pad's element path (its centre).
        check_drag(binary, pid, f"{cx - 120},{cy - 50}", path, 2, 120, 50, "a drag from a point to an element")

        # 3. An end off the app's windows is refused, and the pad gets nothing.
        name = "a drag to a point off the app is refused"
        before = shown(binary, pid)
        reply = driver(binary, "drag", pid, path, "-30000,-30000", 150, 30)
        print(f"  drag {path} -> off screen: {json.dumps(reply)[:300]}")
        if reply.get("error", {}).get("code") != "not_on_screen":
            fail(name, f"expected not_on_screen, got {reply}")
        elif shown(binary, pid) != before:
            fail(name, f"the pad changed to {shown(binary, pid)!r}")
        else:
            print(f"ok [{name}]")
    finally:
        if fixture:
            fixture.terminate()
            fixture.wait(timeout=10)
        shutil.rmtree(root, ignore_errors=True)

    if failures:
        sys.exit(f"{len(failures)} failure(s)")
    print("qa-drag-test: all passed")


if __name__ == "__main__":
    main()
