#!/usr/bin/env python3
"""Draws the design references of the design sheet in a headless Chromium.

`make design-sheet` runs it between the two passes of the snapshot program: the first writes
`<sheet>/shots.json`, this draws each shot's reference (a prototype's window, or the page of one of
the catalog's Window stories) into `<sheet>/reference/<id>.png` at twice its size in points and
records the size it drew in `<sheet>/references.json`, and the second draws the native page at that
same size beside it.

It talks to Chromium over its DevTools pipe (`--remote-debugging-pipe`: JSON messages ending in a
NUL, read from fd 3 and written to fd 4), so it needs nothing beyond the standard library. Chromium
runs in one process: an agent's sandbox refuses the Mach port its child processes check in with.

    python3 -I capture.py <sheet dir>

`CHROME` names the browser; without it, the first of Playwright's headless shell and Google Chrome
that is installed.

`DESIGN_SHEET_REFERENCE_CACHE` names a folder that keeps the drawn references between runs (a CI
runner that keeps its disk sets it). The references depend only on the shots asked for, the design
files and this script, so a set drawn once is filed there under a key made from those and copied
back while none of them changes, with no browser started. Drawing them is most of the sheet's time.
"""

import base64
import fcntl
import glob
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

TIMEOUT = 60
SETTLE = 0.4


def find_chrome():
    if os.environ.get("CHROME"):
        return os.environ["CHROME"]
    home = os.path.expanduser("~")
    candidates = sorted(
        glob.glob(os.path.join(home, "Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell")),
        reverse=True,
    )
    candidates += [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ]
    for path in candidates:
        if os.access(path, os.X_OK):
            return path
    sys.exit("design sheet: no Chromium found; set CHROME to a Chromium or Google Chrome executable")


class Browser:
    """A headless Chromium on its DevTools pipe."""

    def __init__(self, binary, profile):
        to_chrome_r, self.to_chrome = os.pipe()
        self.from_chrome, from_chrome_w = os.pipe()
        args = [
            binary, "--remote-debugging-pipe", "--single-process", "--no-sandbox", "--no-zygote",
            "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-crash-reporter",
            "--disable-extensions", "--hide-scrollbars", "--mute-audio", "--font-render-hinting=none",
            "--user-data-dir=" + profile, "about:blank",
        ]
        if not binary.endswith("chrome-headless-shell"):
            args.insert(1, "--headless")

        def wire():
            # Out of the way first, so neither end is closed by the other's dup2 onto 3 or 4.
            read_end = fcntl.fcntl(to_chrome_r, fcntl.F_DUPFD, 10)
            write_end = fcntl.fcntl(from_chrome_w, fcntl.F_DUPFD, 10)
            os.dup2(read_end, 3)
            os.dup2(write_end, 4)

        env = dict(os.environ, HOME=profile)
        self.process = subprocess.Popen(args, pass_fds=(3, 4), preexec_fn=wire, env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.close(to_chrome_r)
        os.close(from_chrome_w)
        self.buffer = b""
        self.next_id = 0
        self.events = []

    def _read(self):
        while b"\0" not in self.buffer:
            chunk = os.read(self.from_chrome, 1 << 20)
            if not chunk:
                raise RuntimeError("Chromium closed its pipe")
            self.buffer += chunk
        message, self.buffer = self.buffer.split(b"\0", 1)
        return json.loads(message)

    def send(self, method, params=None, session=None):
        self.next_id += 1
        message = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        os.write(self.to_chrome, json.dumps(message).encode() + b"\0")
        while True:
            reply = self._read()
            if reply.get("id") == self.next_id:
                if "error" in reply:
                    raise RuntimeError("%s: %s" % (method, reply["error"].get("message")))
                return reply.get("result", {})
            self.events.append(reply)

    def wait_for(self, method, session):
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            for i, event in enumerate(self.events):
                if event.get("method") == method and event.get("sessionId") == session:
                    del self.events[i]
                    return event
            self.events.append(self._read())
        raise RuntimeError("no %s within %d s" % (method, TIMEOUT))

    def close(self):
        try:
            self.send("Browser.close")
        except (RuntimeError, OSError):
            pass
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


# Waits for the fonts, for every animation that ends (a live dot or a progress bar repeats forever, so those are
# left running) and for two frames, five seconds at most, then answers the element's box.
SETTLED_BOX = """
(async (selector) => {
  const ends = (a) => { const t = a.effect && a.effect.getComputedTiming(); return t && Number.isFinite(t.endTime); };
  const settled = Promise.all([document.fonts.ready].concat(
    document.getAnimations().filter(ends).map((a) => a.finished.catch(() => null))));
  await Promise.race([settled, new Promise((done) => setTimeout(done, 5000))]);
  await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
  const el = document.querySelector(selector);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return { x: r.left + window.scrollX, y: r.top + window.scrollY, width: r.width, height: r.height };
})(%s)
"""


def shoot(browser, shot, out):
    target = browser.send("Target.createTarget", {"url": "about:blank"})["targetId"]
    session = browser.send("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
    try:
        browser.send("Page.enable", session=session)
        browser.send("Emulation.setDeviceMetricsOverride", {
            "width": int(shot["width"]) + 1200, "height": int(shot["height"]) + 1000,
            "deviceScaleFactor": 2, "mobile": False,
        }, session=session)
        browser.send("Emulation.setEmulatedMedia", {"features": [
            {"name": "prefers-color-scheme", "value": shot["theme"]},
            {"name": "prefers-reduced-motion", "value": "reduce"},
        ]}, session=session)
        browser.send("Page.navigate", {"url": shot["url"]}, session=session)
        browser.wait_for("Page.loadEventFired", session)
        time.sleep(SETTLE)
        box = browser.send("Runtime.evaluate", {
            "expression": SETTLED_BOX % json.dumps(shot["selector"]), "awaitPromise": True, "returnByValue": True,
        }, session=session).get("result", {}).get("value")
        if not box or box["width"] < 1 or box["height"] < 1:
            raise RuntimeError("%s has no %s" % (shot["url"], shot["selector"]))
        image = browser.send("Page.captureScreenshot", {
            "format": "png", "captureBeyondViewport": True, "clip": dict(box, scale=1),
        }, session=session)["data"]
        with open(out, "wb") as f:
            f.write(base64.b64decode(image))
        return {"width": round(box["width"]), "height": round(box["height"])}
    finally:
        browser.send("Target.closeTarget", {"targetId": target})


DESIGN = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "docs", "design"))
KEPT_SETS = 3


def references_key(shots):
    """What a drawn set depends on: the shots, every design file's content and this script."""
    digest = hashlib.sha256(json.dumps(shots, sort_keys=True).encode())
    paths = [__file__]
    for folder, folders, files in os.walk(DESIGN):
        folders.sort()
        paths += [os.path.join(folder, name) for name in sorted(files)]
    for path in paths:
        digest.update(os.path.relpath(path, DESIGN).encode())
        with open(path, "rb") as f:
            digest.update(hashlib.sha256(f.read()).digest())
    return digest.hexdigest()[:32]


def reuse(cache, key, shots, sheet):
    """Copies the set filed under `key` into the sheet; False when there is none, or it misses a shot."""
    kept = os.path.join(cache, key)
    try:
        with open(os.path.join(kept, "references.json")) as f:
            drawn = json.load(f)
    except (OSError, ValueError):
        return False
    if any(shot["id"] not in drawn or not os.path.isfile(os.path.join(kept, shot["id"] + ".png")) for shot in shots):
        return False
    for shot in shots:
        shutil.copyfile(os.path.join(kept, shot["id"] + ".png"), os.path.join(sheet, "reference", shot["id"] + ".png"))
    shutil.copyfile(os.path.join(kept, "references.json"), os.path.join(sheet, "references.json"))
    os.utime(kept)
    return True


def keep(cache, key, shots, sheet):
    """Files the sheet's drawn set under `key`, and drops all but the newest sets."""
    os.makedirs(cache, exist_ok=True)
    staged = tempfile.mkdtemp(prefix=".keep-", dir=cache)
    for shot in shots:
        shutil.copyfile(os.path.join(sheet, "reference", shot["id"] + ".png"), os.path.join(staged, shot["id"] + ".png"))
    shutil.copyfile(os.path.join(sheet, "references.json"), os.path.join(staged, "references.json"))
    shutil.rmtree(os.path.join(cache, key), ignore_errors=True)
    os.rename(staged, os.path.join(cache, key))
    sets = sorted((entry for entry in os.scandir(cache) if entry.is_dir()), key=lambda entry: entry.stat().st_mtime, reverse=True)
    for old in sets[KEPT_SETS:]:
        shutil.rmtree(old.path, ignore_errors=True)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: capture.py <sheet dir>")
    sheet = os.path.abspath(sys.argv[1])
    with open(os.path.join(sheet, "shots.json")) as f:
        shots = json.load(f)
    os.makedirs(os.path.join(sheet, "reference"), exist_ok=True)
    cache = os.environ.get("DESIGN_SHEET_REFERENCE_CACHE")
    key = references_key(shots) if cache else None
    if cache and reuse(cache, key, shots, sheet):
        print("reused the %d references drawn before for these design files (%s)" % (len(shots), key))
        return
    drawn = {}
    with tempfile.TemporaryDirectory(prefix="design-sheet-chrome-") as profile:
        browser = Browser(find_chrome(), profile)
        try:
            for shot in shots:
                out = os.path.join(sheet, "reference", shot["id"] + ".png")
                drawn[shot["id"]] = shoot(browser, shot, out)
                print("drew %s (%d × %d pt)" % (out, drawn[shot["id"]]["width"], drawn[shot["id"]]["height"]))
        finally:
            browser.close()
    with open(os.path.join(sheet, "references.json"), "w") as f:
        json.dump(drawn, f, indent=2, sort_keys=True)
    if cache:
        keep(cache, key, shots, sheet)


if __name__ == "__main__":
    main()
