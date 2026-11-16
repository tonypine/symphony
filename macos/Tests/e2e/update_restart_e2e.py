#!/usr/bin/env python3
"""End-to-end test of the menu bar app's Update, Restart and rollback.

Builds releases N and N+1 of Symphony.app from this checkout, installs N in a
temporary folder, runs it in scripted QA mode against a fake Linear (the memory
tracker) and a stub agent, and checks the three things only a real install can prove:

1. Update N -> N+1 while an agent run is active: the old Symphony drains and
   stops (the stub run is held until the test has seen the update wait for it),
   N+1 is downloaded, verified, swapped in and relaunched from its own bundle,
   starts its Symphony on its own, dispatch resumes, every Symphony BEAM runs
   from inside the running app's bundle, and no BEAM from N is left running.
2. Automatically when idle, with symphony.yml's workspaces.repo removed just
   after N+1's check passed: N+1 fails its health check and is rolled back; N
   says so in a notification naming N+1 and the failed check, and in a menu line
   that opens N+1's notes, and doesn't install N+1 again.
3. Retry vN+1 when N+1 can't start at all (the relaunch finds its binary not
   executable): the update helper, its start window shortened to a few seconds
   for the test, puts N back, N runs again, says N+1 was rolled back, lists it
   as skipped, and the update log names each step, the launch that failed
   included.

Everything else about Update, Restart and rollback is decided in
SymphonyBarCore and covered by its unit tests (see Tests/e2e/README.md).

It never touches the installed app: the app, its settings, secrets, logs,
update downloads, Symphony's state and logs, HOME and the epmd port are all its
own, and the dashboard binds a free port. The live app's
processes, state files and port 4000 are snapshotted before
and after, and any change fails the test.

Usage (from macos/): make e2e, or python3 Tests/e2e/update_restart_e2e.py
See Tests/e2e/README.md for the options.
"""

import argparse
import json
import os
import plistlib
import pwd
import re
import secrets
import shutil
import signal
import socket
import string
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

MACOS = Path(__file__).resolve().parents[2]
REPO = MACOS.parent
# The release pair's build, signing and update feed are the shared helpers' (test/support/README.md).
sys.path.insert(0, str(REPO / "test" / "support"))

from macos_release import minisign_keys, release_pair, signing  # noqa: E402
from macos_release._run import BuildError  # noqa: E402
from stubs.update_feed import UpdateFeed  # noqa: E402

BUILD_N = int(os.environ.get("SYMPHONY_E2E_BUILD_N", "90001"))
BUILD_N1 = BUILD_N + 1
# The longest a held stub run waits to be released, so a stuck test can't hang CI.
HOLD_LIMIT_SECONDS = 300
ISSUE = "E2E-1"


class Failure(Exception):
    pass


def log(message):
    print(f"[e2e {time.strftime('%H:%M:%S')}] {message}", flush=True)


def run(args, cwd=None, env=None, check=True, capture=True):
    result = subprocess.run(
        [str(a) for a in args],
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    if check and result.returncode != 0:
        output = (result.stdout or "")[-4000:]
        raise Failure(f"{' '.join(str(a) for a in args)} exited {result.returncode}:\n{output}")
    return result


version = release_pair.version


def wait_for(description, condition, timeout, interval=0.25):
    deadline = time.monotonic() + timeout
    while True:
        value = condition()
        if value:
            return value
        if time.monotonic() > deadline:
            raise Failure(f"timed out after {timeout}s waiting for {description}")
        time.sleep(interval)


def processes():
    """Every process as (pid, command line)."""
    output = run(["ps", "-axww", "-o", "pid=,command="]).stdout
    rows = []
    for line in output.splitlines():
        pid, _, command = line.strip().partition(" ")
        if pid.isdigit():
            rows.append((int(pid), command.strip()))
    return rows


def alive(pid):
    if not pid:
        return False
    # An app this script started stays a zombie, which signal 0 still finds, until it is reaped.
    try:
        if os.waitpid(pid, os.WNOHANG)[0] == pid:
            return False
    except ChildProcessError:
        pass
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


# ---------------------------------------------------------------------------
# The live app: snapshotted before and after, must not change.


def live_snapshot(work):
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    support = home / "Library" / "Application Support"
    snapshot = {}

    rows = [(pid, cmd) for pid, cmd in processes() if str(work) not in cmd]
    # The installed app (~/Applications or /Applications) and the Symphony it runs from the release in its bundle.
    snapshot["apps"] = sorted(pid for pid, cmd in rows if "/Applications/Symphony.app/Contents/MacOS/" in cmd)
    snapshot["beams"] = sorted(
        pid for pid, cmd in rows
        if "beam.smp" in cmd
        and "/Applications/Symphony.app/Contents/Resources/symphony-release/" in cmd
    )

    listeners = run(["lsof", "-nP", "-iTCP:4000", "-sTCP:LISTEN", "-t"], check=False).stdout.split()
    snapshot["port_4000"] = sorted(int(pid) for pid in listeners if pid.isdigit())

    # Fingerprinted from their metadata only: the live secrets are never read.
    for root in (support / "symphony", support / "symphony" / "release"):
        for name in ("control_url", "control_token", "erlang_cookie", "secrets.json"):
            path = root / name
            try:
                info = path.stat()
                fingerprint = f"ino={info.st_ino} size={info.st_size} mtime={info.st_mtime_ns}"
            except FileNotFoundError:
                fingerprint = "missing"
            except OSError as error:
                fingerprint = f"unreadable ({error.strerror})"
            snapshot[f"state {path}"] = fingerprint

    return snapshot


def compare_live(before, after):
    changes = [
        f"{key}: {before.get(key)!r} -> {after.get(key)!r}"
        for key in sorted(set(before) | set(after))
        if before.get(key) != after.get(key)
    ]
    if changes:
        raise Failure("the live app changed during the test:\n  " + "\n  ".join(changes))


# ---------------------------------------------------------------------------
# The isolated instance: fake Linear, stub agent, QA root, app folder.


class Instance:
    def __init__(self, work, app_n, feed):
        self.work = work
        self.qa = work / "qa"
        self.applications = work / "Applications"
        self.app = self.applications / "Symphony.app"
        self.previous = self.applications / "Symphony (previous).app"
        self.config = work / "config" / "symphony.yml"
        self.stub_log = work / "logs" / "stub.log"
        self.runs_log = work / "logs" / "runs.log"
        # While this file exists, each stub run waits for the test to remove it; without it, a run ends at once.
        self.run_hold = work / "config" / "hold-runs"
        self.secret = secrets.token_hex(8)
        # N+1's notes as the feed serves them: the notes window shows them.
        self.release_notes = (feed.folder / "release_notes.md").read_text()
        self.epmd_port = free_port()
        self.feed = feed
        self.app_process = None
        self.launches = 0
        self.command_count = 0
        for folder in (self.qa, self.applications, work / "bin", work / "config", work / "logs", work / "home", work / "repo"):
            folder.mkdir(parents=True, exist_ok=True)
        self._write_fake_linear_and_stub()
        self._write_qa_settings()
        run(["ditto", app_n, self.app])
        self.env = self._app_environment(feed)

    def check_runs_from_bundle(self, app, build):
        """Every Symphony BEAM of this instance is build `build`'s and runs from `app`'s bundled release."""
        release = os.path.realpath(app / "Contents" / "Resources" / "symphony-release") + "/"
        beams = [(pid, cmd) for pid, cmd in processes() if str(self.work) in cmd and "/bin/beam.smp" in cmd]
        if not beams:
            raise Failure(f"no Symphony BEAM is running (expected build {build}'s from {release})")
        outside = [(pid, cmd[:200]) for pid, cmd in beams if not cmd.startswith(release)]
        if outside:
            raise Failure(f"Symphony BEAMs running from outside {release}: {outside}")
        others = [pid for pid, _ in beams if pid not in self.beam_pids(build)]
        if others:
            raise Failure(f"Symphony BEAMs {others} are not build {build}'s")

    def _write_fake_linear_and_stub(self):
        config = self.config.parent
        repo = self.work / "repo"
        run(["git", "init", "-q", "-b", "main", repo])
        run(["git", "-C", repo, "-c", "user.email=e2e@example.com", "-c", "user.name=e2e",
             "commit", "-q", "--allow-empty", "-m", "init"])
        (config / "issues.json").write_text(json.dumps([{
            "id": "e2e-issue-1", "identifier": ISSUE, "title": "Stub run",
            "description": "End-to-end test issue", "state": "Todo",
        }]))
        # The hook logs the release its Symphony runs and that release's version, read from the command line of
        # the BEAM it descends from (Symphony clears the launcher's variables before it runs a hook), and the
        # secret the app passed Symphony.
        hook = self.work / "bin" / "runs-hook"
        hook.write_text(
            "#!/bin/sh\n"
            "pid=$PPID\n"
            "beam=''\n"
            "for _ in 1 2 3 4 5 6 7 8; do\n"
            "  [ -n \"$pid\" ] && [ \"$pid\" -gt 1 ] || break\n"
            "  command=\"$(ps -ww -o command= -p \"$pid\")\"\n"
            "  case \"$command\" in */bin/beam.smp*) beam=\"$command\"; break ;; esac\n"
            "  pid=\"$(ps -o ppid= -p \"$pid\" | tr -d ' ')\"\n"
            "done\n"
            "root=\"$(printf '%s\\n' \"$beam\" | sed -n 's|.* -root \\([^ ]*\\).*|\\1|p')\"\n"
            "vsn=\"$(printf '%s\\n' \"$beam\" | sed -n 's|.* -boot [^ ]*/releases/\\([^/ ]*\\)/start.*|\\1|p')\"\n"
            "printf '%s root=%s vsn=%s secret=%s\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" "
            "\"${root:-unknown}\" \"${vsn:-unknown}\" \"${E2E_SECRET:-unset}\" "
            f">> '{self.runs_log}'\n"
        )
        hook.chmod(0o755)
        (config / "WORKFLOW.md").write_text(
            f"---\nhooks:\n  before_run: |\n    '{hook}'\n"
            "---\nWork on {{ issue.identifier }}.\n"
        )
        stub = self.work / "bin" / "stub-claude"
        stub.write_text(
            "#!/bin/sh\n"
            "# Stub agent: one Claude stream-json turn, held while the test's hold file exists, logged by session.\n"
            "sid=\"e2e-$$\"\n"
            f"log='{self.stub_log}'\n"
            f"hold='{self.run_hold}'\n"
            f"deadline=$(( $(date +%s) + {HOLD_LIMIT_SECONDS} ))\n"
            "trap 'echo \"$(date +%s) killed $sid\" >> \"$log\"; exit 143' TERM INT\n"
            "echo \"$(date +%s) start $sid\" >> \"$log\"\n"
            "printf '%s\\n' \"{\\\"type\\\":\\\"system\\\",\\\"subtype\\\":\\\"init\\\",\\\"session_id\\\":\\\"$sid\\\","
            "\\\"cwd\\\":\\\"$PWD\\\",\\\"tools\\\":[],\\\"mcp_servers\\\":[],\\\"model\\\":\\\"stub\\\","
            "\\\"permissionMode\\\":\\\"default\\\",\\\"apiKeySource\\\":\\\"none\\\"}\"\n"
            "while [ -e \"$hold\" ]; do\n"
            "  if [ \"$(date +%s)\" -ge \"$deadline\" ]; then echo \"$(date +%s) expired $sid\" >> \"$log\"; exit 1; fi\n"
            "  sleep 0.2 &\n  wait $!\n"
            "done\n"
            "echo \"$(date +%s) end $sid\" >> \"$log\"\n"
            "printf '%s\\n' \"{\\\"type\\\":\\\"result\\\",\\\"subtype\\\":\\\"success\\\",\\\"is_error\\\":false,"
            "\\\"num_turns\\\":1,\\\"result\\\":\\\"Done.\\\",\\\"session_id\\\":\\\"$sid\\\","
            "\\\"usage\\\":{\\\"input_tokens\\\":1,\\\"output_tokens\\\":1}}\"\n"
        )
        stub.chmod(0o755)
        self.write_config("clone", repo)

    def write_config(self, strategy, repo):
        """Writes symphony.yml with the e2e repo's workspace `strategy` and `repo`."""
        self.config.write_text(
            "issues:\n  provider: memory\n  poll_interval_ms: 1000\n  memory:\n    issues_file: issues.json\n"
            "  states:\n    active: [Todo, In Progress]\n    terminal: [Done]\n"
            "repositories:\n  - key: e2e\n    workflow: WORKFLOW.md\n"
            f"    workspace:\n      strategy: {strategy}\n      repo: {repo}\n"
            f"workspaces:\n  root: {self.work / 'workspaces'}\n"
            f"agent:\n  runtime: claude\n  command: {self.work / 'bin' / 'stub-claude'}\n  concurrency:\n    max_total: 1\n"
            "  limits:\n    max_turns: 1\n"
            # E2E-1 is dispatched again and again across the scenarios without a state move or a PR head, which
            # the dispatch-loop guard would hold on a Blocked hold after 4 runs in 10 minutes. These limits keep
            # the guard on but out of reach of one test run: 50 runs within one second.
            "watchdog:\n  dispatch_loop_runs: 50\n  dispatch_loop_window_ms: 1000\n"
            "  dispatch_loop_long_runs: 50\n  dispatch_loop_long_window_ms: 1000\n"
            # A free port, so the live Symphony's 4000 is never taken.
            "dashboard:\n  port: 0\n"
        )

    def _write_qa_settings(self):
        with open(self.qa / "settings.plist", "wb") as file:
            plistlib.dump({
                "configPath": str(self.config),
                "developmentMode": False,
                "startOnLaunch": False,
                "restartTimeoutMinutes": 10,
                "stopTimeoutSeconds": 30,
                # Scenario 1 installs with Update to vX; the default, Automatically when released, would install by
                # itself at the launch check. Scenario 2 chooses Automatically when idle.
                "updateMode": "manual",
            }, file)
        secrets_file = self.qa / "secrets.json"
        secrets_file.write_text(json.dumps({"LINEAR_API_KEY": "e2e-not-a-real-key", "E2E_SECRET": self.secret}))
        secrets_file.chmod(0o600)

    def hold_runs(self):
        """Makes the stub's runs wait, from now on, until `release_runs`."""
        self.run_hold.touch()

    def release_runs(self):
        """Ends the held stub runs, and lets the next ones end at once."""
        self.run_hold.unlink(missing_ok=True)

    def update_settings(self, **values):
        """Changes the app's settings, as Settings… would, while the app isn't running."""
        path = self.qa / "settings.plist"
        with open(path, "rb") as file:
            settings = plistlib.load(file)
        settings.update(values)
        with open(path, "wb") as file:
            plistlib.dump(settings, file)

    def set_issue_state(self, state):
        """Moves the fake Linear's issue to `state`; outside the active states Symphony dispatches nothing."""
        issues_file = self.config.parent / "issues.json"
        issues = json.loads(issues_file.read_text())
        for issue in issues:
            issue["state"] = state
        issues_file.write_text(json.dumps(issues))

    def _app_environment(self, feed):
        user = pwd.getpwuid(os.getuid()).pw_name
        env = {
            "HOME": str(self.work / "home"),
            "USER": user,
            "LOGNAME": user,
            "SHELL": "/bin/sh",
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "SYMPHONY_BAR_QA_ROOT": str(self.qa),
            "SYMPHONY_BAR_QA_SCRIPTED": "1",
            "SYMPHONY_BAR_UPDATE_URL": feed.latest_url,
            # Symphony's release node name is fixed, so it gets its own epmd.
            "ERL_EPMD_PORT": str(self.epmd_port),
        }
        if os.environ.get("SYMPHONY_MCP_SOCKET_ROOT"):
            env["SYMPHONY_MCP_SOCKET_ROOT"] = os.environ["SYMPHONY_MCP_SOCKET_ROOT"]
        return env

    # -- the app ------------------------------------------------------------

    def launch(self):
        self.launches += 1
        out = open(self.work / "logs" / f"app-{self.launches}.log", "w")
        status = self.qa / "status.json"
        if status.exists():
            status.unlink()
        self.app_process = subprocess.Popen(
            [self.app / "Contents" / "MacOS" / "SymphonyBar"],
            env=self.env, stdout=out, stderr=subprocess.STDOUT, start_new_session=True,
        )
        return wait_for("the app to write status.json", lambda: self.status(), 60)

    def status(self):
        try:
            return json.loads((self.qa / "status.json").read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def menu(self):
        status = self.status() or {}
        return {item["title"]: item["enabled"] for item in status.get("menu", [])}

    def press(self, title, timeout=30, answer=None):
        """Presses a menu item as a click would, after waiting for it to be enabled. `answer` answers the prompt the
        press shows, such as Pause Dispatch…'s reason."""
        wait_for(f"'{title}' to be enabled (menu: {list(self.menu())})", lambda: self.menu().get(title), timeout)
        self.command_count += 1
        name = f"{self.command_count:04d}"
        commands = self.qa / "commands"
        (commands / f".{name}").write_text(title if answer is None else f"{title}\n{answer}")
        (commands / f".{name}").rename(commands / name)

        def handled():
            status = self.status() or {}
            return next((p for p in status.get("presses", []) if p["command"] == name), None)

        press = wait_for(f"the app to handle '{title}'", handled, 15)
        if press["result"] != "pressed":
            raise Failure(f"'{title}' was {press['result']}")
        log(f"pressed '{title}'")

    def alerts(self):
        return (self.status() or {}).get("alerts", [])

    def wait_for_handoff(self, app_pid):
        """Waits for the app this script launched to quit for the update helper.

        Polling `alive` reaps it: until then it is a zombie, which the helper takes for a running app and waits on.
        """
        wait_for("the app to hand the update over and quit", lambda: not alive(app_pid), 180)
        self.app_process = None

    def quit(self):
        """Chooses Quit Symphony and waits for the app and its Symphony to exit."""
        status = self.status()
        app_pid, symphony = status["pid"], status["symphony_pid"]
        self.press("Quit Symphony")
        wait_for("the app to quit", lambda: not alive(app_pid), 120)
        wait_for("Symphony to stop", lambda: not alive(symphony), 60)
        self.app_process = None

    # -- Symphony -----------------------------------------------------------

    def symphony_state(self):
        try:
            base = (self.qa / "state" / "control_url").read_text().strip()
            with urllib.request.urlopen(f"{base}/api/v1/state", timeout=2) as response:
                return json.loads(response.read())
        except (OSError, ValueError):
            return None

    def symphony_pid(self):
        return (self.status() or {}).get("symphony_pid")

    def active_sessions(self):
        state = self.symphony_state() or {}
        return [run_["session_id"] for run_ in state.get("running", []) if run_.get("session_id")]

    def wait_for_active_run(self, timeout=120):
        return wait_for("an active agent run", lambda: self.active_sessions(), timeout)

    def stub_events(self, session):
        """{'start'|'end'|'killed': epoch seconds} for one stub session."""
        events = {}
        for line in self._read(self.stub_log).splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[2] == session:
                events[parts[1]] = int(parts[0])
        return events

    def runs(self):
        """The before_run hook's fields for every run, oldest first."""
        return [
            dict(part.split("=", 1) for part in line.split()[1:] if "=" in part)
            for line in self._read(self.runs_log).splitlines()
        ]

    def wait_for_new_run(self, after, build, timeout=120):
        """Waits for a run started after the first `after` runs, by the given build's Symphony; returns its secret."""
        def started():
            runs = self.runs()[after:]
            return runs[-1] if runs else None

        try:
            fields = wait_for("a new agent run", started, timeout)
        except Failure as failure:
            held = self.hold_note()
            raise Failure(f"{failure}; {held}" if held else str(failure)) from None
        release = self.app / "Contents" / "Resources" / "symphony-release"
        if os.path.realpath(fields.get("root", "")) != os.path.realpath(release):
            raise Failure(f"the run's Symphony runs from {fields.get('root')}, not the installed app's {release}")
        if fields.get("vsn") != f"0.0.1-{build}":
            raise Failure(f"the run's Symphony is release {fields.get('vsn')}, not build {build}'s")
        return fields.get("secret")

    def hold_note(self):
        """Why Symphony isn't dispatching E2E-1, when its state says so: a hold, such as the dispatch-loop guard's."""
        state = self.symphony_state() or {}
        notes = [
            f"Symphony skips {ISSUE} ({entry.get('reason')})"
            for entry in state.get("dispatch_skipped", []) if entry.get("issue_identifier") == ISSUE
        ] + [
            f"{ISSUE} waits on a person: {entry.get('headline')}"
            for entry in state.get("waiting_on_you", []) if entry.get("issue_identifier") == ISSUE
        ]
        return "; ".join(notes)

    @staticmethod
    def app_build(app):
        with open(app / "Contents" / "Info.plist", "rb") as file:
            return int(plistlib.load(file)["CFBundleVersion"])

    @staticmethod
    def _read(path):
        try:
            return path.read_text()
        except FileNotFoundError:
            return ""

    def beam_pids(self, build):
        """The build's Symphony BEAMs, told apart by the boot script of their release version.

        Only `beam.smp` counts: the release's `epmd -daemon` also runs from the bundle, but it is
        detached and outlives the node by design, so it isn't a running Symphony.
        """
        return [
            pid for pid, cmd in processes()
            if str(self.applications) in cmd and "/bin/beam.smp" in cmd and f"/releases/0.0.1-{build}/start" in cmd
        ]

    # -- teardown -----------------------------------------------------------

    def stop(self):
        if self.app_process and self.app_process.poll() is None:
            self.app_process.terminate()
            try:
                self.app_process.wait(60)
            except subprocess.TimeoutExpired:
                self.app_process.kill()
        status = self.status() or {}
        for pid in (status.get("pid"), status.get("symphony_pid")):
            if alive(pid):
                os.kill(pid, signal.SIGTERM)
        wait_for_quiet = time.monotonic() + 30
        while time.monotonic() < wait_for_quiet and any("beam.smp" in cmd for _, cmd in self.leftovers()):
            time.sleep(0.5)
        epmds = sorted(self.applications.glob("*.app/Contents/Resources/symphony-release/erts-*/bin/epmd"))
        if epmds:
            run([epmds[0], "-kill"], env=dict(os.environ, ERL_EPMD_PORT=str(self.epmd_port)), check=False)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and self.leftovers():
            time.sleep(0.5)
        for pid, _ in self.leftovers():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def leftovers(self):
        return [(pid, cmd) for pid, cmd in processes() if str(self.work) in cmd and pid != os.getpid()]

    def diagnostics(self):
        lines = ["--- diagnostics ---"]
        status = self.status()
        if status:
            lines.append("status.json: " + json.dumps(
                {k: status.get(k) for k in ("pid", "build", "symphony_pid", "alerts", "presses", "withdrawn")}))
            lines.append("menu: " + json.dumps([m["title"] for m in status["menu"]]))
        lines.append(f"Symphony state: {json.dumps(self.symphony_state())[:600]}")
        lines.append(f"update checks the feed answered: {self.feed.latest_requests}")
        logs = [
            self.qa / "logs" / "update.log",
            self.qa / "logs" / "menubar-child.log",
            self.stub_log,
            self.runs_log,
            *sorted((self.work / "logs").glob("app-*.log")),
        ]
        for path in logs:
            text = self._read(path)
            if text:
                lines.append(f"--- {path.name} (tail) ---")
                lines.extend(text.splitlines()[-25:])
        lines.append(f"processes under {self.work}:")
        lines.extend(f"  {pid} {cmd[:200]}" for pid, cmd in self.leftovers())
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Scenarios.


class Tracker(threading.Thread):
    """Watches processes and folders during an update or restart, every 100ms."""

    def __init__(self, instance, pids):
        super().__init__(daemon=True)
        self.instance = instance
        self.pids = dict.fromkeys(pids)
        self.lines = set()
        self.running = True

    def run(self):
        while self.running:
            now = time.time()
            for pid, gone in self.pids.items():
                if gone is None and not alive(pid):
                    self.pids[pid] = now
            for item in (self.instance.status() or {}).get("menu", []):
                self.lines.add(item["title"])
            time.sleep(0.1)

    def gone_at(self, pid):
        return self.pids.get(pid)

    def stop(self):
        self.running = False
        self.join(2)


def check_drained(instance, session, symphony_pid, tracker):
    events = instance.stub_events(session)
    if "killed" in events or "end" not in events:
        raise Failure(f"the run {session} that was active didn't finish on its own: {events}")
    stopped = tracker.gone_at(symphony_pid)
    if stopped is None or events["end"] > stopped + 1:
        raise Failure(f"Symphony {symphony_pid} stopped (at {stopped}) before the run {session} ended ({events['end']})")
    log(f"the active run {session} finished before Symphony {symphony_pid} stopped")


def scenario_update(instance):
    log("scenario 1: Update N -> N+1 while a run is active")
    # The run is held until the test has seen the update wait for it.
    instance.hold_runs()
    instance.press("Start Symphony", timeout=60)
    sessions = instance.wait_for_active_run()
    instance.wait_for_new_run(0, BUILD_N)
    instance.check_runs_from_bundle(instance.app, BUILD_N)
    # A settings file from before a rename: N+1's start rewrites it. Added while N runs, which keeps its last good
    # config, so this checks the new build's migration.
    good_config = instance.config.read_text()
    instance.config.write_text(good_config + "pre_push_review:\n  enabled: false\n")
    instance.press("Check for Updates…")
    update_title = f"Update to v{version(BUILD_N1)}"
    wait_for(f"'{update_title}'", lambda: instance.menu().get(update_title), 60)

    old_app = instance.status()["pid"]
    old_symphony = instance.symphony_pid()
    runs_before = len(instance.runs())
    tracker = Tracker(instance, [old_app, old_symphony])
    tracker.start()
    try:
        instance.press(update_title)
        wait_for(
            "the update to show it waits for the agent run",
            lambda: any(line.startswith("Waiting for") for line in tracker.lines),
            120,
        )
        # Downloaded, verified and draining: the run goes on, under the old Symphony, until the test lets it end.
        events = instance.stub_events(sessions[0])
        if events.keys() & {"end", "killed", "expired"} or not alive(old_symphony) or not alive(old_app):
            raise Failure(f"the update didn't wait for the run {sessions[0]}: {events}, "
                          f"Symphony {old_symphony} alive {alive(old_symphony)}, app {old_app} alive {alive(old_app)}")
        log(f"the update waits for the run {sessions[0]}; releasing it")
        instance.release_runs()
        wait_for("the old app to quit", lambda: tracker.gone_at(old_app), 180)
        new = wait_for(
            f"build {BUILD_N1} to relaunch",
            lambda: (s := instance.status()) and s["pid"] != old_app and s["build"] == BUILD_N1 and s,
            120,
        )
        log(f"build {BUILD_N1} relaunched as pid {new['pid']}")
        instance.app_process = None
        wait_for("the new app to start Symphony", lambda: instance.symphony_pid(), 120)
        secret = instance.wait_for_new_run(runs_before, BUILD_N1, timeout=180)
        wait_for("dispatch to be resumed", lambda: (s := instance.symphony_state()) and not s["pause"]["paused"], 60)
    finally:
        tracker.stop()
    check_drained(instance, sessions[0], old_symphony, tracker)
    if secret != instance.secret:
        raise Failure(f"N+1's Symphony didn't give its run the secret stored in Settings (got {secret!r})")

    if alive(old_symphony) or instance.beam_pids(BUILD_N):
        raise Failure(f"build {BUILD_N}'s Symphony is still running: {instance.beam_pids(BUILD_N)}")
    instance.check_runs_from_bundle(instance.app, BUILD_N1)
    if instance.app_build(instance.app) != BUILD_N1 or instance.app_build(instance.previous) != BUILD_N:
        raise Failure("the app folder doesn't hold N+1 as Symphony.app and N as Symphony (previous).app")
    if instance.alerts():
        raise Failure(f"the updated app showed alerts: {instance.alerts()}")
    migrated = instance.config.read_text()
    backup = instance.config.with_name(f"{instance.config.name}.before-v{version(BUILD_N1)}")
    if "pre_push_review:\n" in migrated or "\ncode_review:\n  enabled: false\n" not in migrated or "(TP-1203)" not in migrated:
        raise Failure(f"N+1 didn't migrate symphony.yml: {migrated}")
    if not backup.exists() or "\npre_push_review:\n" not in backup.read_text():
        raise Failure(f"N+1 left no backup of symphony.yml at {backup}")
    log("N+1 renamed the settings key, with a note and a backup")
    # The rest of the run starts from the file as it was.
    instance.config.write_text(good_config)
    backup.unlink()
    # The release the old build installed, carried across the relaunch: the line opens its notes.
    updated_line = f"Updated to v{version(BUILD_N1)}"
    # The line replaces "Checking v...", which stays until the new build's health check has finished.
    wait_for(
        f"the menu's '{updated_line}' line",
        lambda: any(title.startswith(updated_line) and enabled for title, enabled in instance.menu().items()),
        120,
    )
    log("scenario 1 passed")


def change_count(notes):
    """'12 changes' or '1 change' from the notes' first line, as the app reads it; None when it names no count."""
    first = next((line for line in notes.splitlines() if line.strip()), "")
    words = first.strip().split(" ", 2)
    if len(words) < 2 or not words[0].isdigit() or words[1].strip(string.punctuation) not in ("change", "changes"):
        return None
    count = int(words[0])
    return "1 change" if count == 1 else f"{count} changes"


def new_alert(instance, title, timeout):
    """Waits for the alert or notification titled `title` and returns it."""
    return wait_for(
        f"'{title}' (alerts: {[a['title'] for a in instance.alerts()]})",
        lambda: next((a for a in instance.alerts() if a["title"] == title), None),
        timeout,
    )


def check_notes(instance, line, build, message=None):
    """Chooses the menu line `line` and checks it opens build's release notes, with `message` above them."""
    before = len(instance.alerts())
    instance.press(line)
    window = wait_for(f"the notes '{line}' opens", lambda: instance.alerts()[before:][:1], 15)[0]
    expected = {
        "title": f"Symphony {version(build)}",
        "message": "\n\n".join(text for text in (message, instance.release_notes) if text),
    }
    if window != expected:
        raise Failure(f"'{line}' opened {json.dumps(window)[:600]}, not {json.dumps(expected)[:600]}")
    log(f"'{line}' opened the notes of {version(build)}")


def scenario_automatic_rollback(instance):
    log("scenario 2: N+1 passes its check, then fails its health check (workspaces.repo is gone) and is rolled back to N")
    instance.quit()
    shutil.rmtree(instance.app)
    instance.previous.rename(instance.app)
    # So the one found afterwards is the rollback's.
    rolled_back = instance.applications / "Symphony (rolled back).app"
    shutil.rmtree(rolled_back, ignore_errors=True)
    # N+1's check before the install must pass, so the repo exists until the hand-over.
    repo = instance.work / "vanishing-repo"
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    instance.write_config("worktree", repo)
    # Automatically when idle, with Symphony stopped and nothing to dispatch: N installs N+1 with no press.
    instance.set_issue_state("Backlog")
    instance.update_settings(updateMode="whenIdle", startOnLaunch=False)
    update_log = instance.qa / "logs" / "update.log"
    log_before = len(instance._read(update_log).splitlines()) if update_log.exists() else 0
    log(f"installed N again; symphony.yml's workspaces.repo is {repo}")
    first = instance.launch()
    if first["build"] != BUILD_N:
        raise Failure(f"the app is build {first['build']}, not {BUILD_N}")

    # N installs N+1 by itself. The repo goes once N+1's check has passed, before the relaunched N+1 checks again;
    # that check fails, and the helper puts N back and opens it.
    wait_for(
        "N+1 to pass its check before the install",
        lambda: any("downloaded and verified" in line for line in instance._read(update_log).splitlines()[log_before:]),
        180,
    )
    shutil.rmtree(repo)
    instance.wait_for_handoff(first["pid"])
    v, v1 = version(BUILD_N), version(BUILD_N1)
    title = f"Symphony rolled back to v{v}"
    restored = wait_for(
        f"build {BUILD_N} to be put back and say '{title}'",
        lambda: (s := instance.status()) and s["pid"] != first["pid"] and s["build"] == BUILD_N
        and any(a["title"] == title for a in s["alerts"]) and s,
        300,
    )
    instance.app_process = None
    log(f"build {BUILD_N} was put back as pid {restored['pid']}")
    if instance.app_build(instance.app) != BUILD_N or instance.app_build(rolled_back) != BUILD_N1:
        raise Failure("the app folder doesn't hold N as Symphony.app and N+1 as Symphony (rolled back).app")

    line = next((t for t, enabled in instance.menu().items() if t.startswith(f"v{v1} was rolled back: ") and enabled),
                None)
    if not line:
        raise Failure(f"the restored app's menu has no enabled 'v{v1} was rolled back: …' line: {instance.menu()}")
    reason = line.removeprefix(f"v{v1} was rolled back: ")
    if not reason.startswith("symphony check failed: ") or "workspaces.repo does not exist" not in reason:
        raise Failure(f"the rollback's reason isn't the failed config check: {reason!r}")
    notice = new_alert(instance, title, 0)
    body = (f"v{v1} failed its health check ({reason}). It won't be installed by itself again; "
            f"choose Retry v{v1} in the menu to install it.")
    if notice["message"] != body:
        raise Failure(f"the rollback notification says {notice['message']!r}, not {body!r}")
    log(f"notified: {notice['title']}: {notice['message']}")
    if instance.alerts() != [notice]:
        raise Failure(f"the restored app showed other alerts: {instance.alerts()}")

    check_notes(
        instance, line, BUILD_N1,
        message=f"{line}. To roll back by hand, or to keep the app from installing a version again, "
        "choose Open Rollback Steps.",
    )
    # Pinned: the restored app's update check finds N+1 rolled back, offers Retry, and doesn't install it again.
    changes = change_count(instance.release_notes)
    pinned = f"Update rolled back: v{v1}" + (f" ({changes})" if changes else "")
    wait_for(f"'{pinned}' (menu: {list(instance.menu())})", lambda: pinned in instance.menu(), 60)
    if f"Retry v{v1}" not in instance.menu():
        raise Failure(f"the restored app's menu has no 'Retry v{v1}': {instance.menu()}")
    status = instance.status()
    if status["pid"] != restored["pid"] or status["build"] != BUILD_N:
        raise Failure(f"the restored app didn't stay: now pid {status['pid']}, build {status['build']}")
    # The next scenario's install checks symphony.yml again: it needs a repo that exists.
    instance.write_config("clone", instance.work / "repo")
    log("scenario 2 passed")


# The bound the update helper gives a relaunched app to start, shortened for scenario 3 from the product's 30 seconds
# (UpdateLaunch.timeout) through the helper's SYMPHONY_UPDATE_LAUNCH_SECONDS, which QA mode passes on; and how long
# the test waits for the previous app to run again after an update whose app can't start.
LAUNCH_SECONDS_KEY = "SYMPHONY_UPDATE_LAUNCH_SECONDS"
LAUNCH_SECONDS = 5
RESTORED_WITHIN = LAUNCH_SECONDS + 30


def scenario_unlaunchable_update(instance):
    log(f"scenario 3: N+1 can't start at all; the helper puts N back after {LAUNCH_SECONDS}s and N runs, N+1 skipped")
    instance.quit()
    v, v1 = version(BUILD_N), version(BUILD_N1)
    rolled_back = instance.applications / "Symphony (rolled back).app"
    shutil.rmtree(rolled_back, ignore_errors=True)
    # The relaunch the helper runs instead of its own: the first time, it makes the new app unlaunchable, as a binary
    # that lost its executable bit would be, and tries to run it; the restored app it runs as the helper would.
    relaunch = instance.work / "bin" / "unlaunchable-relaunch"
    broken = instance.work / "bin" / "unlaunchable-relaunch.done"
    relaunch.write_text(
        "#!/bin/sh\n"
        f"if [ ! -e '{broken}' ]; then\n"
        f"  touch '{broken}'\n"
        "  chmod a-x \"$1/Contents/MacOS/SymphonyBar\"\n"
        "fi\n"
        f"\"$1/Contents/MacOS/SymphonyBar\" >> '{instance.work / 'logs' / 'relaunched.log'}' 2>&1 &\n"
    )
    relaunch.chmod(0o755)
    instance.env["SYMPHONY_UPDATE_OPEN"] = str(relaunch)
    instance.env[LAUNCH_SECONDS_KEY] = str(LAUNCH_SECONDS)
    update_log = instance.qa / "logs" / "update.log"
    log_before = len(instance._read(update_log).splitlines()) if update_log.exists() else 0
    first = instance.launch()
    if first["build"] != BUILD_N:
        raise Failure(f"the app is build {first['build']}, not {BUILD_N}")

    # Scenario 2 pinned N+1; Retry installs it by hand.
    instance.press(f"Retry v{v1}", timeout=60)
    instance.wait_for_handoff(first["pid"])
    handed_over = time.monotonic()
    title = f"Symphony rolled back to v{v}"
    restored = wait_for(
        f"build {BUILD_N} to be put back and running, saying '{title}'",
        lambda: (s := instance.status()) and s["pid"] != first["pid"] and s["build"] == BUILD_N
        and any(a["title"] == title for a in s["alerts"]) and s,
        RESTORED_WITHIN,
    )
    took = time.monotonic() - handed_over
    log(f"build {BUILD_N} was put back as pid {restored['pid']} {took:.0f}s after the hand-over")
    if not alive(restored["pid"]):
        raise Failure(f"the restored app {restored['pid']} isn't running")
    if instance.app_build(instance.app) != BUILD_N or instance.app_build(rolled_back) != BUILD_N1:
        raise Failure("the app folder doesn't hold N as Symphony.app and N+1 as Symphony (rolled back).app")
    if os.access(rolled_back / "Contents" / "MacOS" / "SymphonyBar", os.X_OK):
        raise Failure("N+1's binary is still executable: the scenario didn't make it unlaunchable")

    reason_start = f"the app didn't start within {LAUNCH_SECONDS} seconds of the update; see "
    line = wait_for(
        f"an enabled 'v{v1} was rolled back: …' line (menu: {list(instance.menu())})",
        lambda: next((t for t, enabled in instance.menu().items()
                      if t.startswith(f"v{v1} was rolled back: {reason_start}") and enabled), None),
        30,
    )
    if not line.endswith("/logs/update.log"):
        raise Failure(f"the rollback's reason doesn't name the update log: {line!r}")
    # Skipped: the restored app pinned N+1, offers Retry and doesn't install it again.
    changes = change_count(instance.release_notes)
    pinned = f"Update rolled back: v{v1}" + (f" ({changes})" if changes else "")
    wait_for(f"'{pinned}' (menu: {list(instance.menu())})", lambda: pinned in instance.menu(), 60)
    if f"Retry v{v1}" not in instance.menu():
        raise Failure(f"the restored app's menu has no 'Retry v{v1}': {instance.menu()}")

    steps = instance._read(update_log).splitlines()[log_before:]
    expected = (
        f"[build {BUILD_N}] downloading v{v1}",
        f"[build {BUILD_N}] v{v1} downloaded and verified",
        f"[build {BUILD_N}] handing v{v1} over to the update helper",
        "[helper] updated; the replaced app is at",
        f"didn't start within {LAUNCH_SECONDS}s; putting",
        "[helper] rolled back: the new app is at",
        f"[build {BUILD_N}] put back after v{v1} didn't start",
    )
    position = 0
    for step in expected:
        found = next((i for i, text in enumerate(steps[position:], position) if step in text), None)
        if found is None:
            raise Failure(f"the update log has no line with {step!r} after line {position}:\n" + "\n".join(steps))
        position = found + 1
    if not all(re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \[", text) for text in steps):
        raise Failure("an update log line has no timestamp:\n" + "\n".join(steps))
    log(f"the update log names every step ({len(steps)} lines)")

    status = instance.status()
    if status["pid"] != restored["pid"] or status["build"] != BUILD_N:
        raise Failure(f"the restored app didn't stay: now pid {status['pid']}, build {status['build']}")
    log("scenario 3 passed")


SCENARIOS = (
    scenario_update,
    scenario_automatic_rollback,
    scenario_unlaunchable_update,
)


# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--keep", action="store_true", help="keep the work folder")
    args = parser.parse_args()

    if sys.platform != "darwin" or os.uname().machine != "arm64":
        print("The end-to-end test runs on Apple silicon Macs only.", file=sys.stderr)
        return 2
    missing = [tool for tool in (*release_pair.TOOLS, "lsof") if not shutil.which(tool)]
    if missing:
        print(f"Missing tools: {', '.join(missing)}", file=sys.stderr)
        return 2

    work_root = os.environ.get("SYMPHONY_E2E_WORK_ROOT")
    if work_root:
        os.makedirs(work_root, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="symphony-e2e.", dir=work_root)).resolve()
    log(f"work folder: {work}")
    before = live_snapshot(work)
    log(f"live app before: {json.dumps(before)}")
    identity = feed = instance = None
    failed = True
    try:
        identity = signing.select(work / "signing")
        pair = release_pair.Layout(work / "release-pair")
        keys = minisign_keys.generate(pair.minisign)
        release_pair.build(pair.root, identity, keys, BUILD_N, BUILD_N1)
        (work / "logs").mkdir()
        feed = UpdateFeed(pair.feed, current=(version(BUILD_N), BUILD_N), log=work / "logs" / "feed.log").start()
        log(f"the update feed {feed.latest_url} publishes v{version(BUILD_N1)} (requests in logs/feed.log)")
        instance = Instance(work, pair.app_n, feed)
        log(f"launching build {BUILD_N} from {instance.app} (QA root {instance.qa}, epmd port {instance.epmd_port})")
        instance.launch()
        for scenario in SCENARIOS:
            scenario(instance)
        failed = False
    except (Failure, BuildError) as error:
        log(f"FAILED: {error}")
        if instance:
            print(instance.diagnostics(), flush=True)
    finally:
        if instance:
            instance.stop()
            leftovers = instance.leftovers()
            if leftovers:
                log(f"FAILED: processes left running: {leftovers}")
                failed = True
        if feed:
            feed.stop()
        if identity:
            identity.cleanup()
        after = live_snapshot(work)
        try:
            compare_live(before, after)
            log("the live app is unchanged")
        except Failure as error:
            log(f"FAILED: {error}")
            failed = True
        if failed or args.keep:
            log(f"kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)
    log("FAILED" if failed else f"all {len(SCENARIOS)} scenarios passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
