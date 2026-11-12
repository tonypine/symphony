#!/usr/bin/env python3
"""Tests the QA driver's `key` command (`qa_key`) on an app menu's shortcuts, and its
`click` command (`qa_click`) on SwiftUI controls.

It builds priv/qa_driver/symphony-qa-driver.swift as the copy Symphony builds for a
separate QA host (`-D SYMPHONY_QA_SSH`, which runs its commands directly) and a small
AppKit fixture with the Director's menus: it starts as a status-bar app (accessory),
opens its window and turns into a regular app, as the Director does, and its main menu
holds Settings… (⌘,), View › Inbox (⌘1) and Back (⌘[), and Window › Close (⌘W). A
label in the window shows the last View command. It then checks that, pressed through
the driver's `key` command:

1. ⌘[ runs Back and ⌘1 runs Inbox;
2. ⌘, opens the Settings window;
3. ⌘W closes the Settings window, then the main window;
4. a plain key still reaches the focused field as typed text.

Before TP-1469 the driver posted every key to the app's PID, and AppKit's menu never
saw a ⌘ shortcut sent that way: each of 1 to 3 did nothing.

The window also holds a SwiftUI pane, as the Director's pages are: a button, a list, a
link inside text and a button that opens a popover, with a label naming the last thing
clicked. Through the driver's `click` command, as a mouse sends it (`via: hid`) and with
no AXPress fallback:

5. a click on the button, a list row and the link each take effect;
6. a click on the popover's button opens it, and a click on a point outside it closes it.

Before TP-1474 the driver posted clicks to the app's PID: they never went through the
window server, SwiftUI's controls ignored them, and the driver pressed the control
through accessibility instead (`fallback: AXPress`), so no click path was proven.

It launches windows and needs the Accessibility grant, so it runs in CI only, never
in an agent's sandbox.

Usage (from macos/): python3 -I Tests/qa-key-test.py
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

// What the pane shows; a model rather than `@State`, which is a macro and needs the
// compiler's plugin server.
final class PaneState: ObservableObject {
    @Published var last = "nothing"
    @Published var row: String?
    @Published var showing = false
}

// The Director's kind of controls, each naming itself in the label when it takes a click.
struct ClickPane: View {
    @ObservedObject var state: PaneState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clicked: \(state.last)")
            HStack {
                Button("Count") { state.last = "Count" }
                Button("Details") { state.showing = true }
                    .popover(isPresented: $state.showing, arrowEdge: .trailing) {
                        Text("Popover open")
                            .padding(20)
                            .onAppear { state.last = "Popover" }
                            .onDisappear { state.last = "Closed" }
                    }
            }
            List(["Alpha", "Beta"], id: \.self, selection: $state.row) { Text("Row \($0)") }
                .frame(width: 240, height: 70)
                .onChange(of: state.row) { _, value in if let value { state.last = "Row \(value)" } }
            Text(try! AttributedString(markdown: "[the report](qa://report)"))
                .environment(\.openURL, OpenURLAction { url in
                    state.last = "Link \(url.host ?? "")"
                    return .handled
                })
        }
        .padding(8)
        .frame(width: 300, alignment: .leading)
    }
}

final class Controller: NSObject, NSWindowDelegate {
    let status = NSTextField(labelWithString: "Shown: Home")
    let field = NSTextField(string: "")
    var window: NSWindow!
    var settings: NSWindow?

    func show(_ page: String) { status.stringValue = "Shown: \(page)" }
    @objc func back(_ sender: Any?) { show("Back") }
    @objc func inbox(_ sender: Any?) { show("Inbox") }

    @objc func openSettings(_ sender: Any?) {
        if settings == nil {
            let panel = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 320, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "qa-key-settings"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSTextField(labelWithString: "Settings")
            settings = panel
        }
        settings?.makeKeyAndOrderFront(nil)
    }

    func install() {
        let app = NSMenu(title: "Fixture")
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        app.addItem(settingsItem)
        app.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let view = NSMenu(title: "View")
        let inboxItem = NSMenuItem(title: "Inbox", action: #selector(inbox(_:)), keyEquivalent: "1")
        inboxItem.target = self
        view.addItem(inboxItem)
        let backItem = NSMenuItem(title: "Back", action: #selector(back(_:)), keyEquivalent: "[")
        backItem.target = self
        view.addItem(backItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let main = NSMenu()
        for menu in [app, view, windowMenu] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    func open() {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "qa-key-fixture"
        window.isReleasedWhenClosed = false
        let stack = NSStackView(views: [status, field, NSHostingView(rootView: ClickPane(state: PaneState()))])
        stack.orientation = .vertical
        window.contentView = stack
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.install()
DispatchQueue.main.async { controller.open() }
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


def shown(binary, pid):
    """The label's text: what the last View command showed."""
    reply = driver(binary, "ax-tree", pid, 40, 5, "AXStaticText", "Shown:")
    for match in reply.get("matches", []):
        value = match.get("value") or match.get("title") or ""
        if value.startswith("Shown:"):
            return value
    return None


def onscreen(binary, pid, title):
    windows = driver(binary, "windows", pid).get("windows", [])
    return any(w.get("onscreen") and w.get("layer") == 0 and w.get("title") == title for w in windows)


def wait(condition, seconds=5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.2)
    return condition()


def press(binary, pid, key, modifiers="command"):
    reply = driver(binary, "key", pid, key, modifiers)
    print(f"  key {key} ({modifiers or 'plain'}): {json.dumps(reply)[:300]}")
    if "error" in reply:
        return reply["error"]
    return None


def clicked(binary, pid):
    """The SwiftUI pane's label: what the last click reached."""
    reply = driver(binary, "ax-tree", pid, 60, 20, "AXStaticText", "Clicked:")
    for match in reply.get("matches", []):
        value = match.get("value") or match.get("title") or match.get("description") or ""
        if value.startswith("Clicked:"):
            return value
    return None


def find(binary, pid, needle, roles):
    """The path of the first element whose text is the needle, in the order of roles."""
    for role in roles:
        reply = driver(binary, "ax-tree", pid, 60, 20, role, needle)
        for match in reply.get("matches", []):
            texts = [match.get(key) or "" for key in ("value", "title", "description")]
            if needle in texts and match.get("frame"):
                return match["path"]
    return None


def check_click(binary, pid, target, expected, name):
    """Clicks a path or an `x,y` point and checks the label reads `Clicked: expected`."""
    if target is None:
        return fail(name, "the target is not in the accessibility tree")
    reply = driver(binary, "click", pid, target, 1)
    print(f"  click {target}: {json.dumps(reply)[:400]}")
    if "error" in reply:
        return fail(name, f"click failed: {reply['error']}")
    if reply.get("via") != "hid" or "fallback" in reply:
        return fail(name, f"the click was not a mouse's: via {reply.get('via')!r}, fallback {reply.get('fallback')!r}")
    if not wait(lambda: clicked(binary, pid) == f"Clicked: {expected}"):
        return fail(name, f"the label reads {clicked(binary, pid)!r}")
    print(f"ok [{name}]")


def check_shortcut(binary, pid, key, expected):
    name = f"⌘{key} runs {expected}"
    error = press(binary, pid, key)
    if error:
        return fail(name, f"key failed: {error}")
    if not wait(lambda: shown(binary, pid) == f"Shown: {expected}"):
        return fail(name, f"the label reads {shown(binary, pid)!r}")
    print(f"ok [{name}]")


def main():
    root = tempfile.mkdtemp(prefix="qa-key-test.")
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
        if not wait(lambda: onscreen(binary, pid, "qa-key-fixture") and shown(binary, pid), 30):
            sys.exit("FAIL [launch]: the fixture's window and its label never showed")

        # 1. Back and Inbox from the View menu.
        check_shortcut(binary, pid, "[", "Back")
        check_shortcut(binary, pid, "1", "Inbox")

        # 2. Settings opens.
        name = "⌘, opens Settings"
        error = press(binary, pid, ",")
        if error or not wait(lambda: onscreen(binary, pid, "qa-key-settings")):
            fail(name, f"no Settings window: {error}")
        else:
            print(f"ok [{name}]")

        # 3. ⌘W closes the window in front: Settings, then the main window.
        name = "⌘W closes Settings"
        error = press(binary, pid, "w")
        if error or not wait(lambda: not onscreen(binary, pid, "qa-key-settings")):
            fail(name, f"Settings is still on screen: {error}")
        else:
            print(f"ok [{name}]")

        # 4. A plain key is still typed into the focused field, through the app's PID.
        name = "a plain key types text"
        reply = driver(binary, "key", pid, "x", "")
        typed = lambda: any(
            (m.get("value") or "") == "x" for m in driver(binary, "ax-tree", pid, 40, 5, "AXTextField", "").get("matches", [])
        )
        if "error" in reply or reply.get("via") != "pid" or not wait(typed):
            fail(name, f"reply {reply}; the field holds no 'x'")
        else:
            print(f"ok [{name}]")

        # 5. Real clicks on the SwiftUI pane's button, list row and link.
        if not wait(lambda: clicked(binary, pid) == "Clicked: nothing", 10):
            fail("click pane", f"the pane's label reads {clicked(binary, pid)!r}")
        check_click(binary, pid, find(binary, pid, "Count", ["AXButton"]), "Count", "a click presses a button")
        check_click(binary, pid, find(binary, pid, "Row Alpha", ["AXStaticText", "AXCell", "AXRow"]), "Row Alpha", "a click selects a row")
        check_click(binary, pid, find(binary, pid, "the report", ["AXLink", "AXStaticText"]), "Link report", "a click opens a link in text")

        # 6. The popover opens on a click, and a click outside it, on the window's title
        # bar far from the popover, closes it.
        check_click(binary, pid, find(binary, pid, "Details", ["AXButton"]), "Popover", "a click opens the popover")
        main = next((w for w in driver(binary, "windows", pid).get("windows", []) if w.get("title") == "qa-key-fixture"), None)
        if main is None:
            fail("a click outside closes the popover", "the main window is not in the window list")
        else:
            frame = main["frame"]
            outside = f"{frame['x'] + frame['w'] - 40},{frame['y'] + 12}"
            check_click(binary, pid, outside, "Closed", "a click outside closes the popover")

        name = "⌘W closes the main window"
        error = press(binary, pid, "w")
        if error or not wait(lambda: not onscreen(binary, pid, "qa-key-fixture")):
            fail(name, f"the main window is still on screen: {error}")
        else:
            print(f"ok [{name}]")
    finally:
        if fixture:
            fixture.terminate()
            fixture.wait(timeout=10)
        shutil.rmtree(root, ignore_errors=True)

    if failures:
        sys.exit(f"{len(failures)} failure(s)")
    print("qa-key-test: all passed")


if __name__ == "__main__":
    main()
