#!/usr/bin/env python3
"""Drags queue rows in the Director's Home with the mouse, as a person does (TP-1610).

It launches the QA build of the app (`SYMPHONY_QA_APP`, the bundle or its executable) in QA mode
on the committed fixture Tests/Fixtures/director-app/home-queue-drag: 2 slots, both taken
(TP-1619 in slot 1, TP-1594 in slot 2), a queue of 1246 rows in pages of 100, two saved views,
and a move of TP-1596 the engine refuses with its reason. The fixture applies each move and start
the app sends to the Home read that follows, as Symphony does.

The drags are real: a helper posts mouse down, moves with the button held and mouse up through
the window server's HID tap, so SwiftUI's DragGesture in Home takes them as it takes a person's.
While the button is held the test reads the window (the accessibility tree and a screenshot),
then it lets go and reads the result. Each scenario runs on a fresh launch with a fresh QA root,
so no move of one reaches another:

- hover: on hover the drag handle stands in the number's place and the row does not move
  (walkthrough step 6's drag part);
- reorder: scrolled past the first page, a row dragged up four rows is left behind dimmed, an
  accent line marks the gap, and once dropped the ticket is there and the numbers follow
  (step 7);
- strip: scrolled until the strip shows, a row dropped on its second line takes slot 2, leaves
  the queue, and the ticket that held slot 2 is number 1 (step 8);
- card: at the top, a row dropped on the first slot card takes slot 1, and the ticket that held it
  is number 1 (step 9);
- refused: TP-1596 dropped above TP-1590 is back at its place with its number, the other rows keep
  theirs, and Home shows the engine's reason (step 10);
- filter: with a saved view picked no drag starts, no drop line or target shows and the rows keep
  their real numbers; with All tickets picked again the row drags (step 11).

Epics and dependencies (TP-1645) run on Tests/Fixtures/director-app/home-queue-epics: the same two
slots, and a queue whose sixth ticket, the epic TP-975, has six open sub-tickets (6.1 to 6.6, each
waiting on another) and two done, then TP-1051 waiting on a release, the epic MOT-105 with three,
and more tickets after them:

- epic: TP-975's row dragged above TP-1596 is left behind dimmed with its sub-rows, and lands with
  them: TP-975 is number 3 and its sub-tickets 3.1 to 3.6;
- sub-row: TP-979 (6.4) dragged above TP-977 (6.2) shows a drop line that starts at the sub-row's
  step and lands at 6.2; MOT-106 (8.1) dropped two rows below its epic's block stays inside it, the
  last of its epic's sub-tickets (8.3);
- dependency: TP-978 dropped above TP-977, which it depends on, is back at its place with its number,
  and Home shows the engine's reason.

The epic slot card (TP-1646) runs on Tests/Fixtures/director-app/home-queue-epic-slot: slot 1 is
held by the epic TP-1597 (7 of 16 done, TP-1619 in work) and its band opens the sub-tickets to
come, numbered 9 to 16 (TP-1624 waits on TP-1623, TP-1609 on TP-1607):

- slot-epic: TP-1607 (11) dragged above TP-1623 (9) in the card's list shows the drop line, is
  sent as a move before TP-1623, and lands at 9, the others following;
- slot-epic-refused: TP-1624 (10) dropped above TP-1623, which it depends on, is back at its place
  with its number, and Home shows the engine's reason.

Each scenario prints `ok [name]` or `FAIL [name]: why`, and its screenshots (mid-drag and after the
drop) go to `HOME_DRAG_TEST_SHOTS` when it is set, otherwise to a folder the test names and keeps.

It launches the app's window and needs the Accessibility grant, so it runs in the QA VM (the
window tests step) only, never in an agent's sandbox.

Usage (from macos/): SYMPHONY_QA_APP=<the app> python3 -I Tests/home-drag-test.py [scenario ...]
"""

import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PRIV = os.path.normpath(os.path.join(HERE, "..", "..", "priv", "qa_driver"))
FIXTURES = os.path.join(HERE, "Fixtures", "director-app", "home-queue-drag")
EPICS = os.path.join(HERE, "Fixtures", "director-app", "home-queue-epics")
EPIC_SLOT = os.path.join(HERE, "Fixtures", "director-app", "home-queue-epic-slot")
SLOT_REFUSAL = "TP-1624 depends on TP-1623 and must stay below it."
REFUSAL = "TP-1596 depends on TP-1590 and must stay below it."
DEPENDENCY_REFUSAL = "TP-978 depends on TP-977 and must stay below it."
# The Mac's laptop viewport (WORKFLOW.md): 1440 × 900 pt.
WINDOW = (1440, 900)
PITCH = 36

# Posts a drag through the HID tap, as a mouse does: the pointer moves to the start, the button goes
# down, the pointer moves to the end in small steps with the button held, and the helper prints
# `held`. The button goes up at the end once a line arrives on stdin, so the test reads the window
# mid-drag first.
DRAG = r"""
import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType, _ point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
        FileHandle.standardError.write("could not create a mouse event\n".data(using: .utf8)!)
        exit(1)
    }
    event.post(tap: .cghidEventTap)
    usleep(16_000)
}

let numbers = CommandLine.arguments.dropFirst().compactMap { Double($0) }
guard numbers.count == 4 else {
    FileHandle.standardError.write("usage: drag x0 y0 x1 y1\n".data(using: .utf8)!)
    exit(2)
}
let start = CGPoint(x: numbers[0], y: numbers[1])
let end = CGPoint(x: numbers[2], y: numbers[3])
post(.mouseMoved, start)
usleep(200_000)
post(.leftMouseDown, start)
usleep(120_000)
let steps = 30
for step in 1...steps {
    let t = Double(step) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
}
// A last move at the end, so the view's last report is the end itself.
post(.leftMouseDragged, end)
print("held")
fflush(stdout)
_ = readLine()
post(.leftMouseUp, end)
print("released")
fflush(stdout)
"""

failures = []
passed = []


def fail(name, message):
    print(f"FAIL [{name}]: {message}")
    failures.append(name)
    return False


def ok(name):
    print(f"ok [{name}]")
    passed.append(name)
    return True


def compile_swift(root, source, output, flags=()):
    cache = os.path.join(root, "module-cache")
    command = ["swiftc", *flags, "-module-cache-path", cache, "-o", output, source]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"swiftc failed for {source}:\n{result.stderr[-4000:]}")


def wait(condition, seconds=8):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(0.25)
    return condition()


def app_executable(path):
    """The executable of the app at `path`: a bundle's CFBundleExecutable, or the file itself."""
    path = path.rstrip("/")
    if path.endswith(".app") and os.path.isdir(path):
        with open(os.path.join(path, "Contents", "Info.plist"), "rb") as handle:
            name = plistlib.load(handle)["CFBundleExecutable"]
        return os.path.join(path, "Contents", "MacOS", name)
    if os.path.isfile(path):
        return path
    if os.path.isdir(path):
        for entry in sorted(os.listdir(path)):
            if entry.endswith(".app"):
                return app_executable(os.path.join(path, entry))
    sys.exit(f"FAIL [launch]: SYMPHONY_QA_APP names no app: {path!r}")


class Home:
    """One launch of the app on the fixture, read and driven through the QA driver and the drag helper."""

    def __init__(self, driver, dragger, executable, shots, name, fixtures=FIXTURES):
        self.driver_binary = driver
        self.dragger = dragger
        self.shots = shots
        self.name = name
        self.root = tempfile.mkdtemp(prefix=f"home-drag-{name}.")
        # A config path, so the app opens no Settings at launch; it never starts Symphony in QA mode with fixtures.
        with open(os.path.join(self.root, "settings.plist"), "wb") as handle:
            plistlib.dump({"configPath": os.path.join(self.root, "symphony.yml"), "startOnLaunch": False}, handle)
        env = dict(os.environ)
        env.update({
            "SYMPHONY_BAR_QA_ROOT": self.root,
            "SYMPHONY_BAR_QA_API_FIXTURES": fixtures,
            "SYMPHONY_BAR_QA_OPEN_VIEW": "overview",
            "SYMPHONY_BAR_QA_APPEARANCE": "light",
        })
        self.process = subprocess.Popen([executable], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.pid = self.process.pid

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        shutil.rmtree(self.root, ignore_errors=True)

    def driver(self, *args):
        result = subprocess.run([self.driver_binary, *map(str, args)], capture_output=True, text=True, timeout=90)
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return {"error": {"code": "unreadable", "message": result.stdout[-500:] + result.stderr[-500:]}}

    def pointer(self, command, *args):
        """A driver pointer command, clearing a system dialog over the window once if one covers it."""
        reply = self.driver(command, self.pid, *args)
        if reply.get("error", {}).get("code") == "covered":
            print(f"  covered, clearing the system dialog: {json.dumps(reply)[:300]}")
            subprocess.run(["killall", "UserNotificationCenter"], capture_output=True)
            time.sleep(1)
            reply = self.driver(command, self.pid, *args)
        return reply

    def window(self):
        windows = [w for w in self.driver("windows", self.pid).get("windows", []) if w.get("onscreen") and w.get("layer") == 0]
        if not windows:
            return None
        return max(windows, key=lambda w: w["frame"]["w"] * w["frame"]["h"])

    def find(self, needle, role=""):
        return self.driver("ax-tree", self.pid, 60, 400, role, needle).get("matches", [])

    def element(self, identifier):
        """The element whose identifier is `identifier` exactly, nil when none is in the tree."""
        return next((m for m in self.find(identifier) if m.get("identifier") == identifier and m.get("frame")), None)

    def rows(self):
        """The queue rows in the tree, top to bottom: identifier, number, value, frame."""
        found = []
        for match in self.find("queue-row-"):
            identifier = match.get("identifier") or ""
            label = match.get("description") or match.get("title") or ""
            number = re.match(r"Number ([^,]+),", label)
            if identifier.startswith("queue-row-") and match.get("frame") and number:
                found.append({
                    "ticket": identifier[len("queue-row-"):], "number": number.group(1), "value": match.get("value") or "",
                    "label": label, "frame": match["frame"],
                })
        return sorted(found, key=lambda row: row["frame"]["y"])

    def row(self, ticket):
        return next((row for row in self.rows() if row["ticket"] == ticket), None)

    def dragged(self, ticket):
        """Whether `ticket`'s row says it is the one left behind under a drag, in its value or at its label's end."""
        row = self.row(ticket) or {}
        return row.get("value") == "Dragged" or (row.get("label") or "").endswith(", Dragged")

    def ready(self):
        if not wait(lambda: self.window(), 40):
            return fail(self.name, "the app's window never showed")
        self.driver("ax-resize", self.pid, "", *WINDOW)
        if not wait(lambda: self.row("TP-1590"), 30):
            return fail(self.name, "Home never showed the fixture's queue (no row TP-1590)")
        return True

    def visible(self):
        """The rows fully on screen, below the strip when it shows."""
        frame = self.window()["frame"]
        top = frame["y"] + 60
        strip = [self.element(f"slot-line-{slot}") for slot in (1, 2)]
        if all(strip):
            top = max(line["frame"]["y"] + line["frame"]["h"] for line in strip) + 4
        bottom = frame["y"] + frame["h"] - 4
        return [row for row in self.rows() if row["frame"]["y"] >= top and row["frame"]["y"] + row["frame"]["h"] <= bottom]

    def scroll(self, amount):
        # At the window's middle, over the queue: the queue's own element is as tall as all its rows, so its middle is
        # far off screen.
        frame = self.window()["frame"]
        point = f"{frame['x'] + frame['w'] // 2},{frame['y'] + frame['h'] * 2 // 3}"
        reply = self.pointer("scroll", point, amount, "pixel")
        print(f"  scroll {amount}: {json.dumps(reply)[:200]}")
        time.sleep(1)
        return "error" not in reply

    @staticmethod
    def grab_point(row):
        """Where the pointer takes a row: in its number's cell, mid-height."""
        frame = row["frame"]
        return f"{frame['x'] + 18},{frame['y'] + frame['h'] // 2}"

    def hover(self, row):
        reply = self.pointer("hover", self.grab_point(row))
        time.sleep(0.4)
        return reply

    def screenshot(self, label):
        window = self.window()
        if window is None:
            return None
        path = os.path.join(self.shots, f"{self.name}-{label}.png")
        if os.path.exists(path):
            os.remove(path)
        reply = self.driver("screenshot", self.pid, window["id"], path)
        if "error" in reply:
            print(f"  screenshot {label} failed: {reply['error']}")
            return None
        print(f"  screenshot {label}: {path}")
        return path

    def drag(self, start, end):
        """Holds a drag from `start` to `end` (x, y); returns the helper, mid-drag. `release` ends it."""
        helper = subprocess.Popen(
            [self.dragger, *map(str, (*start, *end))], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
        )
        line = helper.stdout.readline().strip()
        if line != "held":
            helper.kill()
            raise RuntimeError(f"the drag helper said {line!r}")
        time.sleep(0.6)
        return helper

    @staticmethod
    def release(helper):
        helper.stdin.write("\n")
        helper.stdin.flush()
        helper.stdout.readline()
        helper.wait(timeout=10)
        time.sleep(0.6)

    def requests(self, path):
        """The POSTs to `path` the fixtures logged, with their bodies."""
        log = os.path.join(self.root, "api-requests.jsonl")
        if not os.path.exists(log):
            return []
        entries = []
        with open(log) as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if entry.get("path") == path:
                    entries.append(entry.get("body") or {})
        return entries

    def accent_near(self, shot, x, y, radius=3):
        """Whether the screenshot holds the accent's colour within `radius` pt of the point (x, y) on screen."""
        pixels = Bitmap.of(shot)
        if pixels is None:
            return None
        frame = self.window()["frame"]
        scale = pixels.width / frame["w"]
        px, py = (x - frame["x"]) * scale, (y - frame["y"]) * scale
        reach = int(radius * scale) + 1
        for dy in range(-reach, reach + 1):
            for dx in range(-reach, reach + 1):
                colour = pixels.at(int(px) + dx, int(py) + dy)
                if colour and Bitmap.accent(colour):
                    return True
        return False


class Bitmap:
    """A screenshot's pixels, read from the BMP sips makes of it."""

    def __init__(self, data):
        offset, = struct.unpack_from("<I", data, 10)
        self.width, height = struct.unpack_from("<ii", data, 18)
        bits, = struct.unpack_from("<H", data, 28)
        self.bottom_up = height > 0
        self.height = abs(height)
        self.step = bits // 8
        self.stride = (self.width * self.step + 3) // 4 * 4
        self.data = data
        self.offset = offset

    @classmethod
    def of(cls, png):
        bmp = png[:-4] + ".bmp"
        result = subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp], capture_output=True, text=True)
        if result.returncode != 0 or not os.path.exists(bmp):
            print(f"  sips could not read {png}: {result.stderr[-300:]}")
            return None
        with open(bmp, "rb") as handle:
            data = handle.read()
        os.remove(bmp)
        return cls(data)

    def at(self, x, y):
        if not (0 <= x < self.width and 0 <= y < self.height):
            return None
        row = self.height - 1 - y if self.bottom_up else y
        index = self.offset + row * self.stride + x * self.step
        blue, green, red = self.data[index], self.data[index + 1], self.data[index + 2]
        return red, green, blue

    @staticmethod
    def accent(colour):
        # The accent (#5B4CF5 in light) and its glow: blue well over red and green.
        red, green, blue = colour
        return blue >= 150 and blue - red >= 70 and blue - green >= 70


def number(value):
    return int(value.replace(",", "").replace(".", ""))


def scenario_hover(home):
    name = "hover: the handle takes the number's place and nothing shifts"
    row = home.row("TP-1592")
    if row is None:
        return fail(name, "row TP-1592 is not on screen")
    if row["value"]:
        return fail(name, f"at rest the row says {row['value']!r}, not nothing")
    before = row["frame"]
    home.screenshot("rest")
    reply = home.hover(row)
    if "error" in reply:
        return fail(name, f"hover failed: {reply['error']}")
    shown = wait(lambda: (home.row("TP-1592") or {}).get("value") == "Drag handle" and home.row("TP-1592"))
    home.screenshot("hover")
    if not shown:
        return fail(name, f"under the pointer the row says {(home.row('TP-1592') or {}).get('value')!r}, not 'Drag handle'")
    if shown["frame"] != before or shown["number"] != row["number"]:
        return fail(name, f"the row moved or changed: {before} #{row['number']} became {shown['frame']} #{shown['number']}")
    return ok(name)


def scenario_reorder(home):
    name = "reorder: a row dragged up in the scrolled, paged queue lands where it is dropped"
    if not home.scroll("0,4400"):
        return fail(name, "the queue did not scroll")
    rows = wait(lambda: len(home.visible()) >= 10 and home.visible(), 10)
    if not rows:
        return fail(name, "fewer than 10 rows show once scrolled")
    if number(rows[0]["number"]) <= 100:
        return fail(name, f"the queue is not past its first page: the first row on screen is number {rows[0]['number']}")
    picked, below = rows[8], rows[4]
    above = rows[3]
    between = rows[4:8]
    print(f"  dragging {picked['ticket']} (#{picked['number']}) to the gap above {below['ticket']} (#{below['number']})")
    home.hover(picked)
    grab = home.grab_point(picked).split(",")
    start = (int(grab[0]), int(grab[1]))
    end = (start[0], below["frame"]["y"] - 1)
    helper = home.drag(start, end)
    try:
        left = wait(lambda: home.dragged(picked["ticket"]), 3)
        line = home.element("queue-drop-line")
        shot = home.screenshot("mid-drag")
        if not left:
            row = home.row(picked["ticket"]) or {}
            fail(name, f"mid-drag the row left behind says {row.get('value')!r} / {row.get('label')!r}, not 'Dragged'")
        if line is None:
            fail(name, "mid-drag no drop line shows")
        else:
            middle = line["frame"]["y"] + line["frame"]["h"] / 2
            if abs(middle - (below["frame"]["y"] - 1)) > 3:
                fail(name, f"the drop line is at y {middle}, not in the gap above {below['ticket']} at {below['frame']['y'] - 1}")
            if shot and home.accent_near(shot, line["frame"]["x"] + line["frame"]["w"] / 2, middle) is False:
                fail(name, "the drop line is not drawn in the accent")
    finally:
        home.release(helper)
    moves = wait(lambda: home.requests("/api/v1/control/queue/move"))
    if not moves or moves[-1].get("issue_identifier") != picked["ticket"] or moves[-1].get("before") != below["ticket"]:
        return fail(name, f"the move sent was {moves!r}, not {picked['ticket']} before {below['ticket']}")

    def landed():
        now = {row["ticket"]: row["number"] for row in home.rows()}
        expected = {picked["ticket"]: below["number"], above["ticket"]: above["number"]}
        for row in between:
            expected[row["ticket"]] = str(number(row["number"]) + 1)
        return all(now.get(ticket) == value for ticket, value in expected.items()) and now

    result = wait(landed)
    home.screenshot("after-drop")
    if not result:
        now = {row["ticket"]: row["number"] for row in home.rows()}
        return fail(name, f"after the drop the numbers are {now}")
    if name in failures:
        return False
    return ok(name)


def slot_drop(home, name, identifier, slot, holder, scrolled):
    """Drags the first row on screen onto `identifier` (a card or a strip line) and checks it took `slot`."""
    target = home.element(identifier)
    if target is None:
        return fail(name, f"{identifier} is not on screen")
    rows = home.visible()
    if not rows:
        return fail(name, "no queue row is on screen")
    picked = rows[min(3, len(rows) - 1)] if scrolled else rows[0]
    print(f"  dragging {picked['ticket']} (#{picked['number']}) onto {identifier}")
    home.hover(picked)
    grab = home.grab_point(picked).split(",")
    frame = target["frame"]
    end = (frame["x"] + frame["w"] // 3, frame["y"] + frame["h"] // 2)
    helper = home.drag((int(grab[0]), int(grab[1])), end)
    try:
        over = home.element(identifier)
        shot = home.screenshot("mid-drag")
        # A card and a strip line say it in their label (their value does not reach the tree mid-drag).
        def said_now():
            over = home.element(identifier)
            return [(over or {}).get(key) or "" for key in ("value", "description", "title")]
        said = wait(lambda: (lambda now: now if any("Drop target" in text for text in now) else None)(said_now()), 3) or said_now()
        if over is None or not any("Drop target" in text for text in said):
            fail(name, f"mid-drag {identifier} says {said!r}, not 'Drop target'")
        if home.element("queue-drop-line") is not None:
            fail(name, "a drop line shows while the pointer is over a slot")
        if shot and home.accent_near(shot, frame["x"] - 1, frame["y"] + frame["h"] / 2) is False:
            fail(name, f"{identifier} has no accent ring")
    finally:
        home.release(helper)
    starts = wait(lambda: home.requests("/api/v1/control/start"))
    if not starts or starts[-1].get("issue_identifier") != picked["ticket"] or starts[-1].get("slot") != slot:
        return fail(name, f"the start sent was {starts!r}, not {picked['ticket']} on slot {slot}")
    if not wait(lambda: picked["ticket"] in ((home.element(identifier) or {}).get("description") or "")
                or picked["ticket"] in ((home.element(identifier) or {}).get("title") or "")):
        held = home.element(identifier) or {}
        return fail(name, f"after the drop {identifier} reads {held.get('description') or held.get('title')!r}")
    if home.row(picked["ticket"]) is not None:
        return fail(name, f"{picked['ticket']} is still in the queue")
    home.screenshot("after-drop")
    if scrolled:
        home.scroll("top")
    first = wait(lambda: (home.row(holder) or {}).get("number") == "1" and home.row(holder))
    if scrolled:
        home.screenshot("after-drop-top")
    if not first:
        return fail(name, f"{holder}, which held slot {slot}, is not number 1: {home.row(holder)}")
    if name in failures:
        return False
    return ok(name)


def scenario_strip(home):
    name = "strip: a row dropped on the strip's second line while scrolled takes slot 2"
    if not home.scroll("0,1500"):
        return fail(name, "the queue did not scroll")
    if not wait(lambda: home.element("slot-line-2")):
        return fail(name, "the strip never showed")
    return slot_drop(home, name, "slot-line-2", 2, "TP-1594", scrolled=True)


def scenario_card(home):
    name = "card: a row dropped on the first slot card takes slot 1"
    if not wait(lambda: home.element("slot-card-1")):
        return fail(name, "the first slot card is not on screen")
    return slot_drop(home, name, "slot-card-1", 1, "TP-1619", scrolled=False)


def scenario_refused(home):
    name = "refused: a refused drop leaves the queue as it was and says why"
    before = {row["ticket"]: row["number"] for row in home.rows()}
    picked, first = home.row("TP-1596"), home.row("TP-1590")
    if picked is None or first is None:
        return fail(name, "TP-1596 or TP-1590 is not on screen")
    home.hover(picked)
    grab = home.grab_point(picked).split(",")
    helper = home.drag((int(grab[0]), int(grab[1])), (int(grab[0]), first["frame"]["y"] - 1))
    try:
        if home.element("queue-drop-line") is None:
            fail(name, "mid-drag no drop line shows above TP-1590")
        home.screenshot("mid-drag")
    finally:
        home.release(helper)
    moves = wait(lambda: home.requests("/api/v1/control/queue/move"))
    if not moves or moves[-1].get("issue_identifier") != "TP-1596":
        return fail(name, f"the move sent was {moves!r}")
    # The notice combines its text and its × into one element, so any role that holds the words counts.
    said = wait(lambda: home.find(REFUSAL), 10)
    home.screenshot("after-drop")
    if not said:
        return fail(name, f"Home does not show the engine's reason {REFUSAL!r}")
    after = wait(lambda: (lambda now: now if all(now.get(t) == n for t, n in before.items()) else None)(
        {row["ticket"]: row["number"] for row in home.rows()}))
    if not after:
        now = {row["ticket"]: row["number"] for row in home.rows()}
        return fail(name, f"the queue changed: {before} became {now}")
    if name in failures:
        return False
    return ok(name)


def scenario_filter(home):
    name = "filter: under a saved view no row drags; with All tickets it drags again"
    pill = next((m for m in home.find("In review", "AXButton") if m.get("frame")), None)
    if pill is None:
        return fail(name, "the 'In review' saved view is not on screen")
    reply = home.pointer("click", pill["path"], 1)
    if "error" in reply:
        return fail(name, f"the click on 'In review' failed: {reply['error']}")
    if not wait(lambda: home.row("TP-1590") and home.row("TP-1596") is None):
        return fail(name, f"the saved view did not apply: {[row['ticket'] for row in home.rows()]}")
    rows = home.rows()
    numbers = {row["ticket"]: row["number"] for row in rows}
    if numbers.get("TP-1590") != "1" or numbers.get("TP-1592") != "2":
        return fail(name, f"the filtered rows do not keep their real numbers: {numbers}")
    picked = home.row("TP-1592")
    home.hover(picked)
    hovered = home.row("TP-1592")
    if hovered["value"]:
        fail(name, f"under a saved view the hovered row says {hovered['value']!r}: its handle shows")
    grab = home.grab_point(picked).split(",")
    first = home.row("TP-1590")
    helper = home.drag((int(grab[0]), int(grab[1])), (int(grab[0]), first["frame"]["y"] - 1))
    try:
        home.screenshot("mid-drag")
        if home.element("queue-drop-line") is not None:
            fail(name, "a drop line shows under a saved view")
        if home.dragged("TP-1592"):
            fail(name, "a drag started under a saved view")
        for slot in (1, 2):
            said = [(home.element(f"slot-card-{slot}") or {}).get(key) or "" for key in ("value", "description", "title")]
            if any("Drop target" in text for text in said):
                fail(name, f"slot card {slot} shows as a drop target under a saved view")
    finally:
        home.release(helper)
    time.sleep(1)
    if home.requests("/api/v1/control/queue/move"):
        fail(name, "a move was sent under a saved view")
    now = {row["ticket"]: row["number"] for row in home.rows()}
    if now.get("TP-1590") != "1" or now.get("TP-1592") != "2":
        fail(name, f"the filtered rows changed: {now}")

    pill = next((m for m in home.find("All tickets", "AXButton") if m.get("frame")), None)
    if pill is None:
        return fail(name, "the 'All tickets' pill is not on screen")
    home.pointer("click", pill["path"], 1)
    if not wait(lambda: home.row("TP-1596")):
        return fail(name, "All tickets did not bring the whole queue back")
    picked = home.row("TP-1605")
    home.hover(picked)
    if not wait(lambda: (home.row("TP-1605") or {}).get("value") == "Drag handle"):
        fail(name, "with All tickets picked the hovered row shows no handle")
    grab = home.grab_point(picked).split(",")
    target = home.row("TP-1592")
    helper = home.drag((int(grab[0]), int(grab[1])), (int(grab[0]), target["frame"]["y"] - 1))
    try:
        home.screenshot("mid-drag-all")
        if not wait(lambda: home.dragged("TP-1605"), 3):
            left = home.row("TP-1605") or {}
            fail(name, f"with All tickets picked the row left behind says {left.get('value')!r} / {left.get('label')!r}, not 'Dragged'")
        if home.element("queue-drop-line") is None:
            fail(name, "with All tickets picked no drop line shows")
    finally:
        home.release(helper)
    if name in failures:
        return False
    return ok(name)


def bring(home, tickets, step="0,250", tries=10):
    """Scrolls down a step at a time until every one of `tickets` is fully on screen; their rows, or None."""
    for _ in range(tries):
        shown = {row["ticket"]: row for row in home.visible()}
        if all(ticket in shown for ticket in tickets):
            return shown
        home.scroll(step)
    shown = {row["ticket"]: row for row in home.visible()}
    return shown if all(ticket in shown for ticket in tickets) else None


def drop_on_row(home, name, picked, below):
    """Drags `picked` (a row) to the gap above `below` (a row) and lets go; returns the drop line seen mid-drag."""
    home.hover(picked)
    grab = home.grab_point(picked).split(",")
    start = (int(grab[0]), int(grab[1]))
    helper = home.drag(start, (start[0], below["frame"]["y"] - 1))
    try:
        line = home.element("queue-drop-line")
        home.screenshot("mid-drag")
    finally:
        home.release(helper)
    return line


def numbers(home):
    return {row["ticket"]: row["number"] for row in home.rows()}


def landed(home, expected):
    return wait(lambda: (lambda now: now if all(now.get(t) == n for t, n in expected.items()) else None)(numbers(home)))


def scenario_epic(home):
    name = "epic: an epic's row moves with its sub-tickets and the numbers follow"
    shown = bring(home, ["TP-1596", "TP-975", "TP-976"])
    if not shown:
        return fail(name, f"TP-1596, TP-975 and TP-976 are not on screen together: {sorted(numbers(home))}")
    if shown["TP-975"]["number"] != "6" or shown["TP-976"]["number"] != "6.1":
        return fail(name, f"the epic and its first sub-ticket are not 6 and 6.1: {numbers(home)}")
    picked, below = shown["TP-975"], shown["TP-1596"]
    home.hover(picked)
    grab = home.grab_point(picked).split(",")
    start = (int(grab[0]), int(grab[1]))
    helper = home.drag(start, (start[0], below["frame"]["y"] - 1))
    try:
        if not wait(lambda: home.dragged("TP-975") and home.dragged("TP-976"), 3):
            fail(name, "mid-drag the epic's row and its sub-rows are not left behind dimmed")
        if home.element("queue-drop-line") is None:
            fail(name, "mid-drag no drop line shows above TP-1596")
        home.screenshot("mid-drag")
    finally:
        home.release(helper)
    moves = wait(lambda: home.requests("/api/v1/control/queue/move"))
    if not moves or moves[-1].get("issue_identifier") != "TP-975" or moves[-1].get("before") != "TP-1596":
        return fail(name, f"the move sent was {moves!r}, not TP-975 before TP-1596")
    expected = {"TP-975": "3", "TP-976": "3.1", "TP-977": "3.2", "TP-981": "3.6", "TP-1596": "4", "TP-1605": "5", "HUB-212": "6"}
    result = landed(home, expected)
    home.screenshot("after-drop")
    if not result:
        return fail(name, f"after the drop the numbers are {numbers(home)}, not {expected}")
    if name in failures:
        return False
    return ok(name)


def scenario_sub_row(home):
    name = "sub-row: a sub-row moves among its epic's sub-tickets and nowhere else"
    shown = bring(home, ["TP-977", "TP-979"])
    if not shown:
        return fail(name, f"TP-977 and TP-979 are not on screen together: {sorted(numbers(home))}")
    picked, below = shown["TP-979"], shown["TP-977"]
    line = drop_on_row(home, name, picked, below)
    if line is None:
        fail(name, "mid-drag no drop line shows above TP-977")
    elif line["frame"]["x"] < picked["frame"]["x"] + 40:
        fail(name, f"the drop line starts at x {line['frame']['x']}, not at the sub-row's step (the row starts at {picked['frame']['x']})")
    moves = wait(lambda: home.requests("/api/v1/control/queue/move"))
    if not moves or moves[-1].get("issue_identifier") != "TP-979" or moves[-1].get("before") != "TP-977":
        return fail(name, f"the move sent was {moves!r}, not TP-979 before TP-977")
    expected = {"TP-976": "6.1", "TP-979": "6.2", "TP-977": "6.3", "TP-978": "6.4", "TP-980": "6.5"}
    if not landed(home, expected):
        return fail(name, f"after the drop the numbers are {numbers(home)}, not {expected}")

    shown = bring(home, ["MOT-106", "MOT-108", "HUB-213", "TP-1700"])
    if not shown:
        return fail(name, f"MOT-105's sub-rows and the rows below it are not on screen together: {sorted(numbers(home))}")
    drop_on_row(home, name, shown["MOT-106"], shown["TP-1700"])
    moves = wait(lambda: len(home.requests("/api/v1/control/queue/move")) > 1 and home.requests("/api/v1/control/queue/move"))
    if not moves or moves[-1].get("issue_identifier") != "MOT-106" or moves[-1].get("after") != "MOT-108":
        return fail(name, f"the move sent was {moves!r}, not MOT-106 after MOT-108, the last of its epic's")
    expected = {"MOT-105": "8", "MOT-107": "8.1", "MOT-108": "8.2", "MOT-106": "8.3", "HUB-213": "9"}
    result = landed(home, expected)
    home.screenshot("after-drop-outside")
    if not result:
        return fail(name, f"after the drop outside its epic the numbers are {numbers(home)}, not {expected}")
    if name in failures:
        return False
    return ok(name)


def scenario_dependency(home):
    name = "dependency: a drop above a ticket it depends on leaves the queue as it was and says why"
    shown = bring(home, ["TP-977", "TP-978"])
    if not shown:
        return fail(name, f"TP-977 and TP-978 are not on screen together: {sorted(numbers(home))}")
    before = numbers(home)
    drop_on_row(home, name, shown["TP-978"], shown["TP-977"])
    moves = wait(lambda: home.requests("/api/v1/control/queue/move"))
    if not moves or moves[-1].get("issue_identifier") != "TP-978":
        return fail(name, f"the move sent was {moves!r}")
    said = wait(lambda: home.find(DEPENDENCY_REFUSAL), 10)
    home.screenshot("after-drop")
    if not said:
        return fail(name, f"Home does not show the engine's reason {DEPENDENCY_REFUSAL!r}")
    if not landed(home, before):
        return fail(name, f"the queue changed: {before} became {numbers(home)}")
    return ok(name)


def open_upcoming(home, name):
    """Clicks slot 1's epic band, which opens the sub-tickets to come below its card; their rows, or None."""
    band = wait(lambda: home.element("epic-slot-band-1"), 10)
    if band is None:
        fail(name, "slot 1 shows no epic band")
        return None
    reply = home.pointer("click", band["path"], 1)
    if "error" in reply:
        fail(name, f"the click on the band failed: {reply['error']}")
        return None
    shown = wait(lambda: (lambda now: now if all(t in now for t in ("TP-1623", "TP-1624", "TP-1607")) else None)(
        {row["ticket"]: row for row in home.rows()}), 10)
    if not shown:
        fail(name, f"the band opened no sub-tickets to come: {sorted(numbers(home))}")
        return None
    return shown


def scenario_slot_epic(home):
    name = "slot-epic: a sub-ticket dragged in an epic slot card's list lands among its epic's"
    shown = open_upcoming(home, name)
    if not shown:
        return False
    if [shown[t]["number"] for t in ("TP-1623", "TP-1624", "TP-1607")] != ["9", "10", "11"]:
        return fail(name, f"the rows to come are not numbered on from 7 done: {numbers(home)}")
    home.hover(shown["TP-1607"])
    grab = home.grab_point(shown["TP-1607"]).split(",")
    start = (int(grab[0]), int(grab[1]))
    helper = home.drag(start, (start[0], shown["TP-1623"]["frame"]["y"] - 1))
    try:
        if not wait(lambda: home.dragged("TP-1607"), 3):
            fail(name, "mid-drag TP-1607 is not left behind dimmed")
        if home.element("queue-drop-line") is None:
            fail(name, "mid-drag no drop line shows above TP-1623")
        home.screenshot("mid-drag")
    finally:
        home.release(helper)
    moves = wait(lambda: home.requests("/api/v1/control/queue/move"))
    if not moves or moves[-1].get("issue_identifier") != "TP-1607" or moves[-1].get("before") != "TP-1623":
        return fail(name, f"the move sent was {moves!r}, not TP-1607 before TP-1623")
    expected = {"TP-1607": "9", "TP-1623": "10", "TP-1624": "11", "TP-1609": "12"}
    result = landed(home, expected)
    home.screenshot("after-drop")
    if not result:
        return fail(name, f"after the drop the numbers are {numbers(home)}, not {expected}")
    if name in failures:
        return False
    return ok(name)


def scenario_slot_epic_refused(home):
    name = "slot-epic-refused: a drop above a sub-ticket it depends on leaves the card's list as it was and says why"
    shown = open_upcoming(home, name)
    if not shown:
        return False
    before = numbers(home)
    drop_on_row(home, name, shown["TP-1624"], shown["TP-1623"])
    moves = wait(lambda: home.requests("/api/v1/control/queue/move"))
    if not moves or moves[-1].get("issue_identifier") != "TP-1624":
        return fail(name, f"the move sent was {moves!r}")
    said = wait(lambda: home.find(SLOT_REFUSAL), 10)
    home.screenshot("after-drop")
    if not said:
        return fail(name, f"Home does not show the engine's reason {SLOT_REFUSAL!r}")
    if not landed(home, before):
        return fail(name, f"the list changed: {before} became {numbers(home)}")
    return ok(name)


SCENARIOS = {
    "hover": scenario_hover,
    "reorder": scenario_reorder,
    "strip": scenario_strip,
    "card": scenario_card,
    "refused": scenario_refused,
    "filter": scenario_filter,
    "epic": scenario_epic,
    "sub-row": scenario_sub_row,
    "dependency": scenario_dependency,
    "slot-epic": scenario_slot_epic,
    "slot-epic-refused": scenario_slot_epic_refused,
}

# The scenarios that run on the epics fixture; the others run on FIXTURES.
ON_EPICS = {"epic", "sub-row", "dependency"}
# The scenarios that run on the epic slot fixture.
ON_EPIC_SLOT = {"slot-epic", "slot-epic-refused"}


def main():
    app = os.environ.get("SYMPHONY_QA_APP", "").strip()
    if not app:
        sys.exit("FAIL [launch]: SYMPHONY_QA_APP is not set: this test runs on the QA build in the QA VM")
    executable = app_executable(app)
    picked = sys.argv[1:] or list(SCENARIOS)
    unknown = [name for name in picked if name not in SCENARIOS]
    if unknown:
        sys.exit(f"unknown scenario(s): {unknown}; pick from {list(SCENARIOS)}")

    work = tempfile.mkdtemp(prefix="home-drag-test.")
    shots = os.environ.get("HOME_DRAG_TEST_SHOTS") or tempfile.mkdtemp(prefix="home-drag-shots.")
    os.makedirs(shots, exist_ok=True)
    print(f"screenshots: {shots}")
    try:
        driver = os.path.join(work, "symphony-qa-driver")
        compile_swift(work, os.path.join(PRIV, "symphony-qa-driver.swift"), driver, ["-D", "SYMPHONY_QA_SSH"])
        source = os.path.join(work, "drag.swift")
        with open(source, "w") as handle:
            handle.write(DRAG)
        dragger = os.path.join(work, "drag")
        compile_swift(work, source, dragger)

        permissions = json.loads(subprocess.run([driver, "permissions"], capture_output=True, text=True).stdout or "{}")
        if permissions.get("accessibility") is not True:
            sys.exit(f"FAIL [permissions]: this host gives the driver no Accessibility grant: {permissions}")

        for name in picked:
            print(f"== {name}")
            fixtures = EPICS if name in ON_EPICS else EPIC_SLOT if name in ON_EPIC_SLOT else FIXTURES
            home = Home(driver, dragger, executable, shots, name, fixtures)
            try:
                if home.ready():
                    SCENARIOS[name](home)
            except Exception as error:  # noqa: BLE001 - a scenario's crash is its failure, the rest still run
                fail(name, f"{type(error).__name__}: {error}")
            finally:
                home.close()
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print(f"{len(passed)} passed, {len(failures)} failed")
    if failures:
        sys.exit(f"{len(failures)} failure(s)")
    print("home-drag-test: all passed")


if __name__ == "__main__":
    main()
