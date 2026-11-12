#!/usr/bin/env python3
"""The ticket page's speed in the running Director (TP-1491): an idle sample and a scripted scroll with a hitch budget.

It launches the built app (build/Symphony.app, from `make app`) in QA mode over the committed `ticket-page-speed` API
fixtures: TP-1244 with a long history, 500 events over 15 runs, the feed TicketPageSpeedTests builds. The app opens
its window on TP-1244's page (`SYMPHONY_BAR_QA_OPEN_TICKET`) and polls the fixtures as it polls Symphony, every 2 s
while the window shows, reading the ticket and its feed after each poll. Then:

1. With the page open and untouched, `sample` takes 5 s of the app, and the main thread's busy share is the part of
   its samples not spent waiting in its run loop (`__CFRunLoopServiceMachPort`).
2. The app starts counting frames (SIGUSR1, `QAFrameMeter`: a display link on the main run loop, QA mode only), the
   QA driver scrolls the page to its bottom and back to its top while polls land, and the app stops and writes what it
   counted (SIGUSR2, `frames.json` under the QA root). A tick later than one frame and a half is a hitch: the time past
   one frame is hitch time, and the frames that fit in the gap are dropped. The hitch ratio is the hitch time per
   second counted, in ms/s, Apple's measure (under 5 ms/s reads smooth, over 10 ms/s a person feels it). The seconds
   counted include the driver's pauses between its rounds of scroll events, when the page settles.

It prints both numbers on every run. It fails when it cannot measure: the page never shows, the sample has no main
thread, the app counts no frames or exits. The budgets fail it only once ENFORCE_BUDGETS is on.

The budgets, and why they report only for now (the Director's decision on TP-1491). The idle one is the ticket's:
the main thread busy at most IDLE_BUDGET_PERCENT, 5 %. The hitch budget was to be main's hitch ratio with room for
the runner's noise, but main before TP-1480 (Ticket page speed 3/4) measured at the ceiling, in PR #903's first Mac
CI build (GitHub's macos-26 runner):

- idle: the main thread 100.0 % busy over 5 s, every sample inside SwiftUI's view graph update (the page redraws
  while untouched);
- scroll: a hitch ratio of 874.2 ms/s, 5113 dropped frames, 85130 ms of hitch over 97.4 s, the longest frame 1098 ms;
  the QA driver reached neither end of the page in its 40 s per edge.

A budget picked from those numbers would sit near 1000 ms/s and never fail, and the 5 % budget would fail every
pull request that touches the app. So until TP-1480 the test reports each number against its budget, and a scroll
that cannot reach an edge is reported too, since a page that never settles is what it measures. TP-1480 turns
ENFORCE_BUDGETS on and sets HITCH_BUDGET_MS_PER_S from the hitch ratio it measures after its fix, with room for the
runner's noise; from then a change that redraws the whole page on every poll fails, naming the ratio and the budget.

It launches a window and needs the Accessibility grant (the QA driver's scroll), so it runs in the Mac CI build only,
never in an agent's sandbox.

Usage (from macos/, after `make app`): python3 -I Tests/ticket-page-scroll-test.py [path/to/Symphony.app]
"""

import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PRIV = os.path.normpath(os.path.join(HERE, "..", "..", "priv", "qa_driver"))
FIXTURES = os.path.join(HERE, "Fixtures", "director-app", "ticket-page-speed")
TICKET = "TP-1244"
TITLE = "The paused line on the ticket page"

# Off until TP-1480: main measured 100 % idle-busy and 874.2 ms/s of hitch, so the budgets report and do not fail
# (see the module's doc comment). TP-1480 turns it on.
ENFORCE_BUDGETS = False
# The ticket's budget for the page left open and untouched.
IDLE_BUDGET_PERCENT = 5.0
# Milliseconds of hitch per second of scrolling. None until TP-1480 sets it from its own measured ratio plus room for
# the runner's noise: main's 874.2 ms/s leaves no room under the 1000 ms/s ceiling.
HITCH_BUDGET_MS_PER_S = None

SAMPLE_SECONDS = 5
# Polls land every 2 s while the window shows: wait for a few before measuring.
SETTLE_SECONDS = 7


def compile_swift(root, source, output, flags=()):
    cache = os.path.join(root, "module-cache")
    command = ["swiftc", *flags, "-module-cache-path", cache, "-o", output, source]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"swiftc failed for {source}:\n{result.stderr[-4000:]}")


def driver(binary, *args, timeout=90):
    result = subprocess.run([binary, *map(str, args)], capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"error": {"code": "unreadable", "message": result.stdout[-500:] + result.stderr[-500:]}}


def page_scroll_area(binary, pid):
    """The ticket page's scroll area once its title shows: the widest scroll area of the window (the sidebar's is
    narrow), or None."""
    if not driver(binary, "ax-tree", pid, 40, 5, "", TITLE).get("matches"):
        return None
    areas = driver(binary, "ax-tree", pid, 40, 20, "AXScrollArea", "").get("matches", [])
    areas = [a for a in areas if (a.get("frame") or {}).get("w", 0) >= 300 and (a.get("frame") or {}).get("h", 0) >= 200]
    return max(areas, key=lambda a: a["frame"]["w"] * a["frame"]["h"], default=None)


# -- the idle sample ------------------------------------------------------------------------------------------------

THREAD = re.compile(r"^ {4}(\d+) Thread_")
NODE = re.compile(r"^(\s+[+!:| ]*?)(\d+) (.+)$")
WAIT = "__CFRunLoopServiceMachPort"


def main_thread_busy(report):
    """(busy share in percent, samples) of the main thread in a `sample` report: the samples not under the run loop's
    wait for a message. None when the report has no main thread."""
    lines = report.splitlines()
    start = next((i for i, line in enumerate(lines) if THREAD.match(line) and "com.apple.main-thread" in line), None)
    if start is None:
        return None
    total = int(THREAD.match(lines[start]).group(1))
    idle = 0
    # The open frames above the current line: (column of its count, whether it is the run loop's wait).
    stack = []
    for line in lines[start + 1:]:
        if not line.strip() or THREAD.match(line):
            break
        node = NODE.match(line)
        if not node:
            continue
        column, count, name = len(node.group(1)), int(node.group(2)), node.group(3)
        while stack and stack[-1][0] >= column:
            stack.pop()
        waiting = name.startswith(WAIT)
        if waiting and not any(wait for _, wait in stack):
            idle += count
        stack.append((column, waiting))
    if total <= 0:
        return None
    return (100.0 * (total - idle) / total, total)


SELF_TEST_REPORT = """\
Call graph:
    1000 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 1000 start  (in dyld) + 6076  [0x1]
    +   1000 main  (in SymphonyBar) + 64  [0x2]
    +     1000 -[NSApplication run]  (in AppKit) + 480  [0x3]
    +       940 __CFRunLoopRun  (in CoreFoundation) + 1200  [0x4]
    +       ! 900 __CFRunLoopServiceMachPort  (in CoreFoundation) + 160  [0x5]
    +       ! : 900 mach_msg  (in libsystem_kernel.dylib) + 24  [0x6]
    +       ! 40 __CFRunLoopDoObservers  (in CoreFoundation) + 548  [0x7]
    +       60 -[NSWindow layoutIfNeeded]  (in AppKit) + 40  [0x8]
    1000 Thread_2
    + 1000 __CFRunLoopServiceMachPort  (in CoreFoundation) + 160  [0x9]
"""


def sample_idle(pid, root):
    report = os.path.join(root, "idle-sample.txt")
    for command in (["sample", str(pid), str(SAMPLE_SECONDS), "1", "-file", report],
                    ["sudo", "-n", "sample", str(pid), str(SAMPLE_SECONDS), "1", "-file", report]):
        result = subprocess.run(command, capture_output=True, text=True, timeout=180)
        if result.returncode == 0 and os.path.exists(report):
            with open(report, errors="replace") as handle:
                return main_thread_busy(handle.read()), report
        print(f"{' '.join(command[:2])} failed ({result.returncode}): {result.stderr.strip()[-500:]}")
    return None, report


# -- the scroll -----------------------------------------------------------------------------------------------------

def scroll_and_count(binary, pid, area, frames_file):
    signal_app(pid, signal.SIGUSR1)
    time.sleep(0.5)
    replies = [driver(binary, "scroll", pid, area["path"], edge, "pixel") for edge in ("bottom", "top")]
    signal_app(pid, signal.SIGUSR2)
    for _ in range(40):
        if os.path.exists(frames_file):
            with open(frames_file) as handle:
                return json.load(handle), replies
        time.sleep(0.25)
    return None, replies


def signal_app(pid, number):
    os.kill(pid, number)


def main():
    assert main_thread_busy(SELF_TEST_REPORT) == (10.0, 1000), main_thread_busy(SELF_TEST_REPORT)

    app = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "build", "Symphony.app"))
    executable = os.path.join(app, "Contents", "MacOS", "SymphonyBar")
    if not os.access(executable, os.X_OK):
        sys.exit(f"FAIL [build]: no app at {executable}; run `make app` first")

    root = tempfile.mkdtemp(prefix="ticket-page-scroll-test.")
    qa_root = os.path.join(root, "qa-root")
    os.makedirs(qa_root)
    # A config so the app opens on its window rather than on Settings' first-run sheet; nothing starts Symphony.
    config = os.path.join(root, "symphony.yml")
    with open(config, "w") as handle:
        handle.write("# The ticket page scroll test reads the API fixtures; no Symphony runs.\n")
    with open(os.path.join(qa_root, "settings.plist"), "wb") as handle:
        plistlib.dump({"configPath": config}, handle)

    failures = []
    process = None
    log_path = os.path.join(root, "app.log")
    try:
        binary = os.path.join(root, "symphony-qa-driver")
        compile_swift(root, os.path.join(PRIV, "symphony-qa-driver.swift"), binary, ["-D", "SYMPHONY_QA_SSH"])
        permissions = driver(binary, "permissions")
        if permissions.get("accessibility") is not True:
            sys.exit(f"FAIL [permissions]: this runner gives the driver no Accessibility grant: {permissions}")

        environment = dict(os.environ)
        environment.update({
            "SYMPHONY_BAR_QA_ROOT": qa_root,
            "SYMPHONY_BAR_QA_API_FIXTURES": FIXTURES,
            "SYMPHONY_BAR_QA_OPEN_TICKET": TICKET,
        })
        with open(log_path, "w") as log:
            process = subprocess.Popen([executable], env=environment, stdout=log, stderr=subprocess.STDOUT)
        pid = process.pid

        area = None
        for _ in range(90):
            if process.poll() is not None:
                break
            area = page_scroll_area(binary, pid)
            if area:
                break
            time.sleep(1)
        if not area:
            with open(log_path, errors="replace") as handle:
                tail = handle.read()[-3000:]
            sys.exit(f"FAIL [launch]: {TICKET}'s page never showed (exit {process.poll()}); the app's log:\n{tail}")
        print(f"ok [launch]: {TICKET}'s page shows, its scroll area at {area.get('frame')}")
        time.sleep(SETTLE_SECONDS)

        # 1. The page open and untouched while polls land.
        idle, report = sample_idle(pid, root)
        if idle is None:
            failures.append("idle sample")
            print(f"FAIL [idle sample]: no main thread in the sample ({report})")
        else:
            busy, samples = idle
            print(f"idle main thread: {busy:.1f} % busy over {SAMPLE_SECONDS} s ({samples} samples), budget {IDLE_BUDGET_PERCENT:.0f} %")
            if busy > IDLE_BUDGET_PERCENT:
                over = f"the main thread is {busy:.1f} % busy with the page untouched, over the {IDLE_BUDGET_PERCENT:.0f} % budget"
                if ENFORCE_BUDGETS:
                    failures.append("idle sample")
                    print(f"FAIL [idle sample]: {over}")
                else:
                    print(f"over budget [idle sample]: {over} (reported; the budgets fail the test from TP-1480)")
                with open(report, errors="replace") as handle:
                    print(handle.read()[:6000])

        # 2. Top to bottom and back while polls land.
        frames, replies = scroll_and_count(binary, pid, area, os.path.join(qa_root, "frames.json"))
        for edge, reply in zip(("bottom", "top"), replies):
            if "error" in reply or reply.get("at_edge") is not True:
                why = reply.get('error') or reply.get('note') or reply
                if ENFORCE_BUDGETS:
                    failures.append(f"scroll to the {edge}")
                    print(f"FAIL [scroll to the {edge}]: {why}")
                else:
                    print(f"short of the {edge} [scroll]: {why} (reported; the page never settling is what the hitch ratio measures)")
            else:
                print(f"ok [scroll to the {edge}]: {reply.get('rounds')} rounds via {reply.get('via')}, scroll bars {reply.get('scroll_bars')}")
        if not frames or frames.get("frames", 0) < 2:
            failures.append("frames")
            print(f"FAIL [frames]: the app counted no frames while scrolling: {frames}")
        else:
            ratio = frames["hitch_ratio"]
            budget = "none until TP-1480" if HITCH_BUDGET_MS_PER_S is None else f"{HITCH_BUDGET_MS_PER_S:.0f} ms/s"
            print(
                f"scroll: hitch ratio {ratio:.1f} ms/s, budget {budget}; "
                f"{frames['dropped']} dropped frames, {frames['hitch_ms']:.0f} ms of hitch over {frames['seconds']:.1f} s "
                f"({frames['frames']} frames of {frames['frame_ms']:.1f} ms, the longest {frames['longest_ms']:.0f} ms)"
            )
            if HITCH_BUDGET_MS_PER_S is not None and ratio > HITCH_BUDGET_MS_PER_S:
                over = f"scrolling {TICKET}'s page hitched {ratio:.1f} ms/s, over the {HITCH_BUDGET_MS_PER_S:.0f} ms/s budget"
                if ENFORCE_BUDGETS:
                    failures.append("hitch ratio")
                    print(f"FAIL [hitch ratio]: {over}")
                else:
                    print(f"over budget [hitch ratio]: {over} (reported; the budgets fail the test from TP-1480)")
        if process.poll() is not None:
            failures.append("app")
            print(f"FAIL [app]: the app exited ({process.returncode}) during the test")
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
        shutil.rmtree(root, ignore_errors=True)

    if failures:
        sys.exit(f"{len(failures)} failed: {', '.join(failures)}")
    print("all passed" if ENFORCE_BUDGETS else "measured (budgets reported, enforced from TP-1480)")


if __name__ == "__main__":
    main()
