#!/usr/bin/env python3
"""Temporary, this branch only (ci/own-runner-test): why the QA fixtures' windows never show
in the ci-macos runner's session, while the real app's do.

Run 43445049358: qa-scroll-test and qa-key-test fail at [launch] — a bare swiftc fixture's
window never shows — yet ticket-page-scroll-test drives the bundled Symphony.app in the same
session, launched the same way (a Popen of its executable). This probe builds the scroll
fixture in four launch variants and prints, for each, what the real test throws away:

1. bare, .regular     — the test's exact launch;
2. bare, .accessory   — the same source with the Director's policy;
3. bundled, Popen     — the same binary inside a .app bundle, launched exactly as 1;
4. bundled, open -n   — the same bundle through LaunchServices.

For each variant: the process state, the driver's ax-ping (does it answer accessibility at
all), windows (CGWindowList's windows for its pid, the test's window criterion), the first
levels of its AX tree, and the search for "List row 1"; then the fixture's stdout+stderr,
which the real test sends to /dev/null. It starts by naming its launchd session and
WindowServer's, and ends with a screenshot of the screen for the workflow to upload.

Usage (from macos/): python3 -I Tests/qa-launch-probe.py
"""

import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PRIV = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "priv", "qa_driver"))

WAIT_SECONDS = 15
POLL_SECONDS = 5
SCREENSHOT = "/tmp/qa-launch-probe.png"

# The fixture of qa-scroll-test.py, with the activation policy and the activate call as
# parameters. Everything else is copied as it is, so a difference in behaviour is a
# difference of the two lines below, never of the app.
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
app.setActivationPolicy({policy})
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "qa-scroll-fixture"
window.contentView = NSHostingView(rootView: Fixture())
window.makeKeyAndOrderFront(nil)
{activate}
app.run()
"""


def say(*parts):
    print(*parts, flush=True)


def run(command, timeout=90):
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout)


def compile_swift(root, source, output, flags=()):
    cache = os.path.join(root, "module-cache")
    command = ["swiftc", *flags, "-module-cache-path", cache, "-o", output, source]
    result = run(command)
    if result.returncode != 0:
        sys.exit(f"swiftc failed for {source}:\n{result.stderr[-4000:]}")


def driver(binary, *args, timeout=90):
    result = run([binary, *map(str, args)], timeout=timeout)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"error": {"code": "unreadable", "message": (result.stdout + result.stderr)[-800:]}}


def probe(binary, pid, label):
    state = run(["ps", "-p", str(pid), "-o", "pid,ppid,sess,stat,comm"]).stdout.strip()
    say(f"[{label}] {state or 'process gone'}")
    say(f"[{label}] ax-ping: {json.dumps(driver(binary, 'ax-ping', pid))}")
    say(f"[{label}] windows: {json.dumps(driver(binary, 'windows', pid))}")
    root = driver(binary, "ax-tree", pid, 3, 200, "", "")
    say(f"[{label}] ax root: {json.dumps(root)[:600]}")
    row = driver(binary, "ax-tree", pid, 40, 5, "AXStaticText", "List row 1")
    say(f"[{label}] find 'List row 1': {json.dumps(row)[:300]}")


def watch(binary, pid, label, process=None):
    deadline = time.time() + WAIT_SECONDS
    polls = 0
    while time.time() < deadline and (process is None or process.poll() is None):
        polls += 1
        say(f"[{label}] --- poll {polls}")
        probe(binary, pid, label)
        time.sleep(POLL_SECONDS)
    if process is not None:
        say(f"[{label}] exit code while probing: {process.poll()}")


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def report_output(label, log_path):
    try:
        with open(log_path, errors="replace") as handle:
            text = handle.read()
    except OSError:
        text = ""
    say(f"[{label}] output ({len(text)} chars): {text[-1500:] or '(empty)'}")


def make_bundle(root, app, name):
    bundle = os.path.join(root, name + ".app")
    os.makedirs(os.path.join(bundle, "Contents", "MacOS"))
    shutil.copy(app, os.path.join(bundle, "Contents", "MacOS", name))
    with open(os.path.join(bundle, "Contents", "Info.plist"), "wb") as handle:
        plistlib.dump({
            "CFBundleExecutable": name,
            "CFBundleIdentifier": "ci.qa.probe." + name,
            "CFBundleName": "qa probe " + name,
            "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": "11.0",
        }, handle)
    return bundle


def pid_of(path, seconds=10):
    deadline = time.time() + seconds
    while time.time() < deadline:
        found = run(["pgrep", "-f", path], timeout=10).stdout.split()
        if found:
            return int(found[0])
        time.sleep(0.5)
    return None


def launch_and_watch(binary, executable, label, log_path, process=None):
    if process is None:
        with open(log_path, "w") as log:
            process = subprocess.Popen([executable], stdout=log, stderr=log)
    watch(binary, process.pid, label, process)
    return process


def main():
    root = tempfile.mkdtemp(prefix="qa-launch-probe.")
    processes = []
    try:
        binary = os.path.join(root, "symphony-qa-driver")
        compile_swift(root, os.path.join(PRIV, "symphony-qa-driver.swift"), binary, ["-D", "SYMPHONY_QA_SSH"])

        say("permissions:", json.dumps(driver(binary, "permissions")))
        say("launchd manager:", run(["launchctl", "managername"]).stdout.strip())
        say("probe:", run(["ps", "-o", "pid,ppid,sess,comm", "-p", str(os.getpid())]).stdout.strip())
        window_server = run(["pgrep", "-x", "WindowServer"]).stdout.split()
        if window_server:
            say("WindowServer:", run(["ps", "-o", "pid,sess,comm", "-p", window_server[0]]).stdout.strip())

        sources = {
            "bare-regular": FIXTURE.replace("{policy}", ".regular").replace("{activate}", "app.activate(ignoringOtherApps: true)"),
            "bare-accessory": FIXTURE.replace("{policy}", ".accessory").replace("{activate}", ""),
        }
        apps = {}
        for name, source in sources.items():
            path = os.path.join(root, name + ".swift")
            with open(path, "w") as handle:
                handle.write(source)
            apps[name] = os.path.join(root, name)
            compile_swift(root, path, apps[name])

        for name in sources:
            processes.append(launch_and_watch(binary, apps[name], name, os.path.join(root, name + ".log")))
            stop(processes[-1])
            report_output(name, os.path.join(root, name + ".log"))

        bundle = make_bundle(root, apps["bare-regular"], "bundled-fixture")
        executable = os.path.join(bundle, "Contents", "MacOS", "bundled-fixture")

        processes.append(launch_and_watch(binary, executable, "bundled-popen", os.path.join(root, "bundled-popen.log")))
        stop(processes[-1])
        report_output("bundled-popen", os.path.join(root, "bundled-popen.log"))

        # The last variant stays up for the screenshot, then stops with the probe.
        opened = run(["open", "-n", bundle])
        say("open -n:", f"exit {opened.returncode} {opened.stderr.strip()}")
        pid = pid_of(executable)
        if pid is None:
            say("bundled-open: never found a process for the opened bundle")
        else:
            class Opened:
                "A stand-in with poll() and terminate(), so watch() treats it like a Popen."
                def __init__(self, pid): self.pid = pid
                def poll(self): return None if run(["kill", "-0", str(self.pid)]).returncode == 0 else 1
                def terminate(self): os.kill(self.pid, signal.SIGTERM)
            process = Opened(pid)
            watch(binary, pid, "bundled-open", process)
            shot = run(["screencapture", "-x", SCREENSHOT], timeout=30)
            say(f"screencapture: exit {shot.returncode} {shot.stderr.strip()} -> {SCREENSHOT}")
            report_output("bundled-open", os.path.join(root, "bundled-open.log"))
            stop(process)
    finally:
        for process in processes:
            if process.poll() is None:
                stop(process)
        shutil.rmtree(root, ignore_errors=True)

    print("qa-launch-probe: done")


if __name__ == "__main__":
    main()
