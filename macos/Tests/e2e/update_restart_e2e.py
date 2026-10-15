#!/usr/bin/env python3
"""End-to-end test of the menu bar app's Update, Restart and rollback.

Builds releases N and N+1 of Symphony.app from this checkout, installs N in a
temporary folder, runs it in scripted QA mode against a fake Linear (the memory
tracker) and a stub agent, and checks nine scenarios:

1. Update N -> N+1 while a run is active: the old Symphony drains and stops, the
   new app starts its Symphony on its own, dispatch resumes, every Symphony BEAM
   runs from inside the running app's bundle, and no BEAM from N is left running.
2. Restart while a run is active, pressed after dispatch was resumed but before
   the app polled again: it pauses dispatch itself, waits for the run, restarts
   and resumes.
3. Restart with a broken symphony.yml: refused with the config error, and the
   running Symphony is left as it was.
4. Rollback to `Symphony (previous).app`: it starts N's BEAM from its own bundle
   and still reads its secrets.
5. update_on_release: Automatically when released, from N with an agent run
   active, with no menu press: once the feed publishes N+1 the app pauses
   dispatch ("updating to vN+1") while the run goes on, records the start
   notification with Cancel Update, waits for the run, relaunches on N+1 and
   resumes dispatch, and N+1 notifies "Symphony updated to vN+1".
6. update_on_release_hand_pause: a pause made by hand before N+1 is published
   stays after the update.
7. update_on_release_cancel: Cancel Update on that update resumes dispatch,
   withdraws the start notification, and three later checks don't start N+1
   again; the menu holds N+1 until Update to vN+1 installs it by hand.
8. Automatically when idle, from N with Symphony running and no agent runs: it
   installs N+1 by itself, which passes its health check, says so in a
   notification, and shows "Updated to vN+1 (K changes)", which opens N+1's notes.
9. Automatically when idle with a symphony.yml whose workspaces.repo doesn't
   exist: N+1 fails its health check and is rolled back; N says so in a
   notification naming N+1 and the failed check, and in a menu line that opens
   N+1's notes, and doesn't install N+1 again.

It never touches the installed app: the app, its settings, secrets, logs,
update downloads, Symphony's state and logs, HOME and the epmd port are all its
own, and the dashboard binds a free port. The live app's
processes, state files and port 4000 are snapshotted before
and after, and any change fails the test.

Usage (from macos/): make e2e, or python3 Tests/e2e/update_restart_e2e.py
See Tests/e2e/README.md for the options.
"""

import argparse
import http.server
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
from datetime import datetime
from pathlib import Path

MACOS = Path(__file__).resolve().parents[2]
REPO = MACOS.parent
BUILD_N = int(os.environ.get("SYMPHONY_E2E_BUILD_N", "90001"))
BUILD_N1 = BUILD_N + 1
STUB_SECONDS = int(os.environ.get("SYMPHONY_E2E_STUB_SECONDS", "15"))
ISSUE = "E2E-1"
PAUSE_TITLE = "Pause Dispatch…"


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


def version(build):
    return f"0.0.1.{build}"


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
# Build: releases N and N+1, signed with one identity, and the update feed.


class Signing:
    """A code-signing identity: given, or a throwaway self-signed one in a temporary keychain."""

    def __init__(self, work):
        self.work = work
        self.keychain = None
        self.password = None
        self.certificate = None
        self.trusted = False
        self.search_list = None
        self.identity = os.environ.get("SYMPHONY_E2E_SIGNING_IDENTITY")
        if self.identity:
            keychain = os.environ.get("SYMPHONY_E2E_KEYCHAIN")
            self.flags = ["--keychain", keychain] if keychain else []
            log(f"signing with the given identity {self.identity}")
        else:
            self._create()

    def _create(self):
        folder = self.work / "signing"
        folder.mkdir()
        self.password = secrets.token_hex(16)
        name = f"Symphony E2E {secrets.token_hex(4)}"
        config = folder / "cert.cnf"
        config.write_text(
            "[req]\ndistinguished_name = dn\nx509_extensions = ext\nprompt = no\n"
            f"[dn]\nCN = {name}\n"
            "[ext]\nbasicConstraints = critical,CA:false\nkeyUsage = critical,digitalSignature\n"
            "extendedKeyUsage = critical,codeSigning\n"
        )
        key, cert, p12 = folder / "key.pem", folder / "cert.pem", folder / "identity.p12"
        openssl = "/usr/bin/openssl"
        run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
             "-days", "2", "-config", config])
        run([openssl, "pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12,
             "-passout", f"pass:{self.password}", "-name", name])
        self.keychain = folder / "e2e.keychain-db"
        run(["security", "create-keychain", "-p", self.password, self.keychain])
        run(["security", "set-keychain-settings", "-lut", "21600", self.keychain])
        run(["security", "unlock-keychain", "-p", self.password, self.keychain])
        run(["security", "import", p12, "-k", self.keychain, "-f", "pkcs12", "-P", self.password,
             "-T", "/usr/bin/codesign"])
        run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
             "-k", self.password, self.keychain])
        # codesign only finds an identity in a keychain on the search list, even with --keychain.
        output = run(["security", "list-keychains", "-d", "user"]).stdout
        self.search_list = [line.strip().strip('"') for line in output.splitlines() if line.strip()]
        run(["security", "list-keychains", "-d", "user", "-s", self.keychain, *self.search_list])
        self.certificate = cert
        self.identity = self._identity_hash(name)
        self.flags = ["--keychain", str(self.keychain)]
        log(f"created the throwaway signing identity '{name}' ({self.identity}) in {self.keychain}")
        self._check_trust()

    def _identity_hash(self, name):
        """The SHA-1 of the imported identity, which codesign matches without a trusted certificate."""
        output = run(["security", "find-identity", "-p", "codesigning", self.keychain]).stdout
        for line in output.splitlines():
            match = re.match(r'\s*\d+\) ([0-9A-F]{40}) "(.*)"', line)
            if match and match.group(2) == name:
                return match.group(1)
        raise Failure(f"the keychain {self.keychain} has no code-signing identity '{name}':\n{output}")

    def _check_trust(self):
        """`codesign --verify` needs the certificate trusted for code signing, in the build and in the app."""
        probe = self.work / "signing" / "probe"
        shutil.copy("/usr/bin/true", probe)
        run(["codesign", "--force", "--sign", self.identity, *self.flags, probe])
        if run(["codesign", "--verify", "--strict", probe], check=False).returncode == 0:
            return
        if os.environ.get("SYMPHONY_E2E_TRUST_CERT") != "1":
            raise Failure(
                "codesign doesn't trust the throwaway certificate, so the app would refuse the update. Either set "
                "SYMPHONY_E2E_SIGNING_IDENTITY to a trusted code-signing identity (with SYMPHONY_E2E_KEYCHAIN when "
                "it isn't in the search list), or set SYMPHONY_E2E_TRUST_CERT=1 to trust the throwaway certificate "
                "for code signing until the test ends (uses sudo)."
            )
        log("trusting the throwaway certificate for code signing until the test ends")
        run(["sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "codeSign",
             "-k", "/Library/Keychains/System.keychain", self.certificate])
        self.trusted = True
        run(["codesign", "--verify", "--strict", probe])

    def cleanup(self):
        if self.trusted:
            run(["sudo", "-n", "security", "remove-trusted-cert", "-d", self.certificate], check=False)
        if self.search_list is not None:
            run(["security", "list-keychains", "-d", "user", "-s", *self.search_list], check=False)
        if self.keychain:
            run(["security", "delete-keychain", self.keychain], check=False)


def build_symphony(build, out):
    """Copies build `build`'s Symphony release (`make release`, ERTS included) to `out`."""
    out.parent.mkdir(parents=True, exist_ok=True)
    prebuilt = os.environ.get(f"SYMPHONY_E2E_SYMPHONY_RELEASE_{'N1' if build == BUILD_N1 else 'N'}")
    if prebuilt:
        run(["ditto", prebuilt, out])
        log(f"using the prebuilt Symphony release {prebuilt} as build {build}")
        return
    log(f"building the Symphony release for build {build} (make release)")
    env = dict(os.environ, SYMPHONY_BUILD_NUMBER=str(build))
    env.pop("SYMPHONY_AGENT_RUNTIME", None)
    run(["make", "release"], cwd=REPO, env=env, capture=False)
    built = REPO / "_build" / "prod" / "rel" / "symphony"
    if not (built / "releases" / f"0.0.1-{build}").is_dir():
        raise SystemExit(f"make release didn't produce build {build}'s release in {built}")
    run(["ditto", built, out])


def build_app_executable():
    prebuilt = os.environ.get("SYMPHONY_E2E_APP_EXECUTABLE")
    if prebuilt:
        log(f"using the prebuilt app executable {prebuilt}")
        return Path(prebuilt)
    log("building SymphonyBar (swift build -c release)")
    run(["swift", "build", "-c", "release", "--product", "SymphonyBar"], cwd=MACOS, capture=False)
    bin_path = run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=MACOS).stdout.strip()
    return Path(bin_path) / "SymphonyBar"


def build(work):
    """Builds both bundles and the update feed; returns (app N, signing, minisign public key)."""
    signing = Signing(work)
    keys = work / "minisign"
    keys.mkdir()
    run(["minisign", "-G", "-W", "-f", "-p", keys / "minisign.pub", "-s", keys / "minisign.key"])
    public_key = (keys / "minisign.pub").read_text().splitlines()[1].strip()

    executable = build_app_executable()
    apps = {}
    for number in (BUILD_N, BUILD_N1):
        release = work / "releases" / f"symphony-{number}"
        build_symphony(number, release)
        build_dir = work / f"build-{number}"
        log(f"bundling Symphony.app {version(number)}")
        run([
            "make", "-C", MACOS, "bundle",
            f"BUILD_DIR={build_dir}",
            f"PREBUILT_EXECUTABLE={executable}",
            f"SYMPHONY_RELEASE={release}",
            f"SHORT_VERSION={version(number)}",
            f"BUILD_NUMBER={number}",
            f"MINISIGN_PUBLIC_KEY={public_key}",
            f"SIGNING_IDENTITY={signing.identity}",
            f"CODESIGN_FLAGS={' '.join(signing.flags)}",
        ])
        apps[number] = build_dir / "Symphony.app"

    log(f"packaging {version(BUILD_N1)} as a release")
    feed = work / "feed"
    commit = run(["git", "rev-parse", "HEAD"], cwd=REPO).stdout.strip()
    env = dict(os.environ, MINISIGN_SECRET_KEY=(keys / "minisign.key").read_text(), MINISIGN_PUBLIC_KEY=public_key)
    run([
        REPO / "scripts" / "release" / "package.sh",
        "--app", apps[BUILD_N1], "--version", version(BUILD_N1), "--build", BUILD_N1,
        "--commit", commit, "--tag", f"v{version(BUILD_N1)}-e2e", "--signed", "true", "--out", feed,
    ], cwd=REPO, env=env)
    return apps[BUILD_N], signing, feed


class Feed:
    """Serves the update feed: `releases/latest` like GitHub's API, and the release assets.

    It publishes N+1 from the start. `serve_n` makes N the latest release, so the app finds itself up to date, until
    `publish_n1` publishes N+1 again.
    """

    def __init__(self, folder):
        self.folder = folder
        handler = lambda *args, **kwargs: _QuietHandler(*args, directory=str(folder), **kwargs)  # noqa: E731
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.server.latest_requests = 0
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        names = [p.name for p in folder.iterdir() if p.is_file()]
        self.release_n1 = {
            "tag_name": f"v{version(BUILD_N1)}-e2e",
            "html_url": f"{self.base}/release",
            "body": (folder / "release_notes.md").read_text(),
            "assets": [{"name": name, "browser_download_url": f"{self.base}/{name}"} for name in names],
        }
        self.release_n = self._release_n(json.loads((folder / "version.json").read_text()))
        (folder / "releases").mkdir()
        self.publish_n1()
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def _release_n(self, info_n1):
        """N as the latest release: its version.json names N's build. A check never downloads its app, so the
        release lists the app's names without the files. A failed check would wait 6 hours for the next one."""
        n = version(BUILD_N)
        zip_name = f"Symphony-{n}.zip"
        info = dict(info_n1, version=n, build=BUILD_N, zip=zip_name,
                    minisig=f"{zip_name}.minisig" if info_n1.get("minisig") else None)
        (self.folder / "n").mkdir()
        (self.folder / "n" / "version.json").write_text(json.dumps(info))
        names = ["version.json", zip_name, f"{zip_name}.sha256"] + ([info["minisig"]] if info["minisig"] else [])
        return {
            "tag_name": f"v{n}-e2e",
            "html_url": f"{self.base}/release-n",
            "body": f"Release {n}.\n",
            "assets": [{"name": name, "browser_download_url": f"{self.base}/n/{name}"} for name in names],
        }

    def _serve(self, release):
        latest = self.folder / "releases" / "latest"
        partial = latest.with_name(".latest")
        partial.write_text(json.dumps(release))
        partial.rename(latest)

    def serve_n(self):
        self._serve(self.release_n)
        log(f"the feed serves v{version(BUILD_N)} only")

    def publish_n1(self):
        self._serve(self.release_n1)

    @property
    def latest_requests(self):
        """How many update checks asked for the latest release so far."""
        return self.server.latest_requests

    @property
    def latest_url(self):
        return f"{self.base}/releases/latest"

    def stop(self):
        self.server.shutdown()


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] == "/releases/latest":
            self.server.latest_requests += 1
        super().do_GET()

    def log_message(self, *args):
        pass


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
        # How long the stub's runs take, when a scenario changes it.
        self.stub_seconds_file = work / "config" / "stub-seconds"
        self.stub_seconds = STUB_SECONDS
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
            "# Stub agent: one Claude stream-json turn that takes a while, logged by session.\n"
            "sid=\"e2e-$$\"\n"
            f"log='{self.stub_log}'\n"
            f"seconds=\"$(cat '{self.stub_seconds_file}' 2>/dev/null || echo {STUB_SECONDS})\"\n"
            "trap 'echo \"$(date +%s) killed $sid\" >> \"$log\"; exit 143' TERM INT\n"
            "echo \"$(date +%s) start $sid\" >> \"$log\"\n"
            "printf '%s\\n' \"{\\\"type\\\":\\\"system\\\",\\\"subtype\\\":\\\"init\\\",\\\"session_id\\\":\\\"$sid\\\","
            "\\\"cwd\\\":\\\"$PWD\\\",\\\"tools\\\":[],\\\"mcp_servers\\\":[],\\\"model\\\":\\\"stub\\\","
            "\\\"permissionMode\\\":\\\"default\\\",\\\"apiKeySource\\\":\\\"none\\\"}\"\n"
            "sleep \"$seconds\" &\nwait $!\n"
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
                # itself at the launch check.
                "updateMode": "manual",
            }, file)
        secrets_file = self.qa / "secrets.json"
        secrets_file.write_text(json.dumps({"LINEAR_API_KEY": "e2e-not-a-real-key", "E2E_SECRET": self.secret}))
        secrets_file.chmod(0o600)

    def set_stub_seconds(self, seconds):
        """Makes the stub's next runs take `seconds`."""
        self.stub_seconds = seconds
        self.stub_seconds_file.write_text(f"{seconds}\n")

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

    def withdrawn(self):
        """The titles of the recorded notifications the app withdrew."""
        return (self.status() or {}).get("withdrawn", [])

    def pause(self):
        """Symphony's pause: `paused` and `reason`; empty while it doesn't answer."""
        return (self.symphony_state() or {}).get("pause") or {}

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

    def control(self, action):
        """Sends `pause` or `resume` to Symphony's control API itself, as the dashboard or another client would."""
        state = self.qa / "state"
        request = urllib.request.Request(
            f"{(state / 'control_url').read_text().strip()}/api/v1/control/{action}",
            data=b"{}",
            method="POST",
            headers={
                "Authorization": f"Bearer {(state / 'control_token').read_text().strip()}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(request, timeout=10):
            pass
        log(f"sent {action} to Symphony's control API")

    def pause_requests(self, since):
        """The `POST /api/v1/control/pause` lines Symphony logged at or after `since` (epoch seconds).

        The log is written late (synced every few seconds), so a line's own time tells which pause it was.
        """
        found = []
        for path in (self.qa / "symphony-logs").glob("symphony.log*"):
            if not re.fullmatch(r"symphony\.log(\.\d+)?", path.name):
                continue  # the wrap log's .idx and .siz files
            for line in path.read_text(errors="replace").splitlines():
                if "POST /api/v1/control/pause" not in line:
                    continue
                try:
                    logged = datetime.fromisoformat(line.split(" ", 1)[0].replace("Z", "+00:00")).timestamp()
                except ValueError:
                    continue
                if logged >= since:
                    found.append(line)
        return found

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
            self.qa / "updates" / "update-helper.log",
            self.qa / "updates" / "rollback-helper.log",
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
    instance.press("Start Symphony", timeout=60)
    instance.wait_for_active_run()
    instance.wait_for_new_run(0, BUILD_N)
    instance.check_runs_from_bundle(instance.app, BUILD_N)
    instance.press("Check for Updates…")
    update_title = f"Update to v{version(BUILD_N1)}"
    wait_for(f"'{update_title}'", lambda: instance.menu().get(update_title), 60)

    # Press while a run is just starting, so the drain has something to wait for.
    sessions = wait_for("a run with time left", lambda: _fresh_session(instance), 60)
    old_app = instance.status()["pid"]
    old_symphony = instance.symphony_pid()
    runs_before = len(instance.runs())
    tracker = Tracker(instance, [old_app, old_symphony])
    tracker.start()
    try:
        instance.press(update_title)
        wait_for("the old app to quit", lambda: tracker.gone_at(old_app), 180)
        new = wait_for(
            f"build {BUILD_N1} to relaunch",
            lambda: (s := instance.status()) and s["pid"] != old_app and s["build"] == BUILD_N1 and s,
            120,
        )
        log(f"build {BUILD_N1} relaunched as pid {new['pid']}")
        instance.app_process = None
        wait_for("the new app to start Symphony", lambda: instance.symphony_pid(), 120)
        instance.wait_for_new_run(runs_before, BUILD_N1, timeout=180)
        wait_for("dispatch to be resumed", lambda: (s := instance.symphony_state()) and not s["pause"]["paused"], 60)
    finally:
        tracker.stop()
    if not any(line.startswith("Waiting for") for line in tracker.lines):
        raise Failure(f"the update never showed it was waiting for agent runs; lines seen: {sorted(tracker.lines)}")
    check_drained(instance, sessions[0], old_symphony, tracker)

    if alive(old_symphony) or instance.beam_pids(BUILD_N):
        raise Failure(f"build {BUILD_N}'s Symphony is still running: {instance.beam_pids(BUILD_N)}")
    instance.check_runs_from_bundle(instance.app, BUILD_N1)
    if instance.app_build(instance.app) != BUILD_N1 or instance.app_build(instance.previous) != BUILD_N:
        raise Failure("the app folder doesn't hold N+1 as Symphony.app and N as Symphony (previous).app")
    if instance.alerts():
        raise Failure(f"the updated app showed alerts: {instance.alerts()}")
    # The release the old build installed, carried across the relaunch: the line opens its notes.
    updated_line = f"Updated to v{version(BUILD_N1)}"
    if not any(title.startswith(updated_line) and enabled for title, enabled in instance.menu().items()):
        raise Failure(f"the updated app's menu has no enabled '{updated_line}' line: {instance.menu()}")
    log("scenario 1 passed")


def _fresh_session(instance):
    """The active sessions, once one has at least half the stub's run time left."""
    sessions = instance.active_sessions()
    if not sessions:
        return None
    started = instance.stub_events(sessions[0]).get("start")
    return sessions if started and time.time() - started < instance.stub_seconds / 2 else None


def scenario_restart(instance):
    log("scenario 2: Restart while a run is active, right after dispatch was resumed")
    sessions = wait_for("a run with time left", lambda: _fresh_session(instance), 120)
    old_symphony = instance.symphony_pid()
    runs_before = len(instance.runs())
    # TP-435: the app's last poll shows dispatch paused, but it is resumed before Restart is pressed, so the restart
    # can't count on that pause. Pause from the menu (the app polls right after), resume behind its back, and press
    # Restart before its next poll, 5s later.
    instance.press(PAUSE_TITLE)
    wait_for("the menu to show dispatch paused", lambda: instance.menu().get("Resume Dispatch"), 10)
    instance.control("resume")
    pressed = time.time()
    tracker = Tracker(instance, [old_symphony])
    tracker.start()
    try:
        instance.press("Restart Symphony")
        wait_for(
            "Symphony to restart",
            lambda: (pid := instance.symphony_pid()) and pid != old_symphony and pid,
            180,
        )
        wait_for(
            "the restart's own POST /api/v1/control/pause in Symphony's log",
            lambda: instance.pause_requests(since=pressed),
            30,
        )
        instance.wait_for_new_run(runs_before, BUILD_N1)
        wait_for("dispatch to be resumed", lambda: (s := instance.symphony_state()) and not s["pause"]["paused"], 60)
    finally:
        tracker.stop()
    if not any(line.startswith("Waiting for") for line in tracker.lines):
        raise Failure(f"the restart never showed it was waiting for agent runs; lines seen: {sorted(tracker.lines)}")
    check_drained(instance, sessions[0], old_symphony, tracker)
    log("scenario 2 passed")


def scenario_broken_config(instance):
    log("scenario 3: Restart with a broken symphony.yml")
    symphony = wait_for("Symphony", lambda: instance.symphony_pid(), 60)
    alerts_before = len(instance.alerts())
    good = instance.config.read_text()
    instance.config.write_text(good + "issues: [\n")
    try:
        instance.press("Restart Symphony")
        alert = wait_for(
            "the restart to be refused",
            lambda: (alerts := instance.alerts()[alerts_before:]) and alerts[0],
            120,
        )
    finally:
        instance.config.write_text(good)
    log(f"refused: {alert['title']}: {alert['message'][:200]}")
    if alert["title"] != "Symphony wasn't restarted" or "symphony.yml" not in alert["message"]:
        raise Failure(f"unexpected alert: {alert}")
    if instance.symphony_pid() != symphony or not alive(symphony):
        raise Failure(f"Symphony {symphony} didn't keep running: now {instance.symphony_pid()}")
    runs_before = len(instance.runs())
    instance.wait_for_new_run(runs_before, BUILD_N1)
    state = instance.symphony_state()
    if not state or state["pause"]["paused"]:
        raise Failure(f"dispatch didn't stay on: {state and state['pause']}")
    log("scenario 3 passed")


def scenario_rollback(instance):
    log("scenario 4: Rollback to Symphony (previous).app")
    instance.quit()
    instance.app.rename(instance.applications / "Symphony (rolled back).app")
    instance.previous.rename(instance.app)
    log("swapped Symphony (previous).app back in")
    status = instance.launch()
    if status["build"] != BUILD_N:
        raise Failure(f"the rolled-back app is build {status['build']}, not {BUILD_N}")
    runs_before = len(instance.runs())
    instance.press("Start Symphony", timeout=60)
    secret = instance.wait_for_new_run(runs_before, BUILD_N, timeout=180)
    instance.check_runs_from_bundle(instance.app, BUILD_N)
    if secret != instance.secret:
        raise Failure(f"the rolled-back Symphony didn't get the stored secret (got {secret!r})")
    if instance.alerts():
        raise Failure(f"the rolled-back app showed alerts: {instance.alerts()}")
    log("scenario 4 passed")


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


# Automatically when released (TP-970's journeys J3 and J4).

CHECK_INTERVAL_KEY = "SYMPHONY_BAR_UPDATE_CHECK_INTERVAL"
# Seconds between update checks in Automatically when released: the scenarios publish N+1 and wait for a check.
CHECK_INTERVAL = 2
# How long each stub run takes in those scenarios, so the run active when N+1 is published outlasts the download and
# verification and is still going when the app pauses dispatch.
ON_RELEASE_STUB_SECONDS = 45
START_TITLE = f"Updating Symphony to v{version(BUILD_N1)}"
# The update item's title while an update is under way, and the line under a release Cancel Update holds (S2e).
UPDATING_TITLE = "Updating Symphony…"
CANCELLED_LINE = "You cancelled this update. It waits for you; a newer release installs by itself."


def put_n_back(instance):
    """Makes N `Symphony.app` again, N+1 thrown away, while the app isn't running."""
    if instance.app_build(instance.app) == BUILD_N:
        return
    shutil.rmtree(instance.app)
    instance.previous.rename(instance.app)
    log(f"put build {BUILD_N} back as Symphony.app")


def start_on_release(instance):
    """Quits, puts N back and launches it in Automatically when released, checking every CHECK_INTERVAL seconds, with
    Start at launch on and the feed serving N only. Returns N's status once its Symphony runs."""
    instance.quit()
    put_n_back(instance)
    instance.set_issue_state("Todo")
    instance.set_stub_seconds(ON_RELEASE_STUB_SECONDS)
    instance.feed.serve_n()
    instance.update_settings(updateMode="onRelease", startOnLaunch=True)
    instance.env[CHECK_INTERVAL_KEY] = str(CHECK_INTERVAL)
    log(f"Automatically when released, a check every {CHECK_INTERVAL}s, Start at launch on")
    status = instance.launch()
    if status["build"] != BUILD_N:
        raise Failure(f"the app is build {status['build']}, not {BUILD_N}")
    wait_for("the app to start Symphony", lambda: instance.symphony_pid(), 120)
    return status


def publish(instance):
    instance.feed.publish_n1()
    log(f"published v{version(BUILD_N1)} in the feed")


def recent_session(instance):
    """The active sessions, once one started in the last 5 seconds: it has nearly all its run time left."""
    sessions = instance.active_sessions()
    started = sessions and instance.stub_events(sessions[0]).get("start")
    return sessions if started and time.time() - started < 5 else None


def wait_for_update_pause(instance, timeout=90):
    """Waits for the app to pause dispatch for N+1 by itself, with the update's reason."""
    reason = f"updating to v{version(BUILD_N1)}"
    pause = wait_for(
        f"dispatch to be paused with the reason '{reason}' (pause: {instance.pause()})",
        lambda: (p := instance.pause()).get("paused") and p.get("reason") == reason and p,
        timeout,
    )
    log(f"dispatch paused by the app: '{pause['reason']}'")
    return pause


def check_start_notification(instance):
    """The app recorded "Updating Symphony to vN+1" for one active run, with its Cancel Update action."""
    notice = new_alert(instance, START_TITLE, 30)
    body = ("Dispatch is paused until 1 agent run finishes. Symphony then updates and resumes dispatch."
            " · Cancel Update")
    if notice["message"] != body:
        raise Failure(f"the start notification says {notice['message']!r}, not {body!r}")
    log(f"recorded the start notification: {notice['title']}: {notice['message']}")


def check_run_going(instance, session, symphony):
    """The run `session` wasn't stopped, and the Symphony running it still runs."""
    events = instance.stub_events(session)
    if "killed" in events:
        raise Failure(f"the run {session} was stopped: {events}")
    if instance.symphony_pid() != symphony or not alive(symphony):
        raise Failure(f"Symphony {symphony} didn't keep running: now {instance.symphony_pid()}")


def wait_for_relaunch(instance, old_app, timeout=240):
    """Waits for N+1 to relaunch in place of the app `old_app` and start its Symphony; returns its status."""
    new = wait_for(
        f"build {BUILD_N1} to relaunch",
        lambda: (s := instance.status()) and s["pid"] != old_app and s["build"] == BUILD_N1 and s,
        timeout,
    )
    instance.app_process = None
    log(f"the app relaunched on build {BUILD_N1} as pid {new['pid']}")
    wait_for("the new app to start Symphony", lambda: instance.symphony_pid(), 120)
    return new


def check_updated_folder(instance):
    if instance.beam_pids(BUILD_N):
        raise Failure(f"build {BUILD_N}'s Symphony is still running: {instance.beam_pids(BUILD_N)}")
    instance.check_runs_from_bundle(instance.app, BUILD_N1)
    if instance.app_build(instance.app) != BUILD_N1 or instance.app_build(instance.previous) != BUILD_N:
        raise Failure("the app folder doesn't hold N+1 as Symphony.app and N as Symphony (previous).app")


def scenario_update_on_release(instance):
    v, v1 = version(BUILD_N), version(BUILD_N1)
    log(f"scenario 5 update_on_release: v{v} -> v{v1} by itself while a run is active, with no menu action")
    first = start_on_release(instance)
    sessions = wait_for("a run that just started", lambda: recent_session(instance), 120)
    old_app, old_symphony = first["pid"], instance.symphony_pid()
    runs_before = len(instance.runs())
    presses_before = instance.command_count
    tracker = Tracker(instance, [old_app, old_symphony])
    tracker.start()
    try:
        publish(instance)
        wait_for_update_pause(instance)
        # The run active when the release came out goes on: dispatch is paused, not the run.
        if sessions[0] not in instance.active_sessions():
            raise Failure(f"the run {sessions[0]} isn't active once dispatch paused: {instance.active_sessions()}")
        check_run_going(instance, sessions[0], old_symphony)
        log(f"the run {sessions[0]} keeps going")
        check_start_notification(instance)
        wait_for(
            f"the active run {sessions[0]} to finish",
            lambda: instance.stub_events(sessions[0]).keys() & {"end", "killed"},
            ON_RELEASE_STUB_SECONDS + 30,
        )
        if "killed" in instance.stub_events(sessions[0]):
            raise Failure(f"the run {sessions[0]} was stopped: {instance.stub_events(sessions[0])}")
        log(f"the active run {sessions[0]} finished")
        wait_for("the old app to quit", lambda: tracker.gone_at(old_app), 180)
        wait_for_relaunch(instance, old_app)
        instance.wait_for_new_run(runs_before, BUILD_N1, timeout=180)
        wait_for("dispatch to be resumed", lambda: (p := instance.pause()) and not p["paused"], 60)
        log("dispatch resumed")
    finally:
        tracker.stop()
    if not any(line.startswith("Waiting for") for line in tracker.lines):
        raise Failure(f"the update never showed it was waiting for agent runs; lines seen: {sorted(tracker.lines)}")
    check_drained(instance, sessions[0], old_symphony, tracker)
    check_updated_folder(instance)
    if instance.command_count != presses_before:
        raise Failure("the test pressed a menu item during the update")
    log("no menu item was pressed")

    # The relaunched app says the update was automatic.
    changes = change_count(instance.release_notes)
    notice = new_alert(instance, f"Symphony updated to v{v1}", 240)
    body = (f"{changes}. " if changes else "") + f"Choose Updated to v{v1} in the menu for the release notes."
    if notice["message"] != body:
        raise Failure(f"the update notification says {notice['message']!r}, not {body!r}")
    log(f"notified: {notice['title']}: {notice['message']}")
    if instance.alerts() != [notice]:
        raise Failure(f"the updated app showed other alerts: {instance.alerts()}")
    log("scenario 5 update_on_release: PASS")


def scenario_update_on_release_hand_pause(instance):
    log("scenario 6 update_on_release_hand_pause: a pause made by hand before the release stays after the update")
    first = start_on_release(instance)
    reason = "e2e: paused by hand before the release"
    instance.press(PAUSE_TITLE, answer=reason)
    wait_for(f"dispatch to be paused with '{reason}'", lambda: instance.pause().get("reason") == reason, 30)
    # The app knows it is paused, so the update's drain leaves the pause as it is instead of making its own.
    wait_for("the menu to show dispatch paused", lambda: instance.menu().get("Resume Dispatch"), 15)
    log(f"dispatch paused by hand: '{reason}'")
    publish(instance)
    wait_for("the app to install N+1 by itself and quit", lambda: not alive(first["pid"]), 240)
    instance.app_process = None
    wait_for_relaunch(instance, first["pid"])
    new_alert(instance, f"Symphony updated to v{version(BUILD_N1)}", 240)
    check_updated_folder(instance)
    # The new app has seen Symphony answer, and leaves the pause it didn't make: a few polls later it still holds.
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        pause = instance.pause()
        if not pause.get("paused") or pause.get("reason") != reason:
            raise Failure(f"the hand pause didn't stay after the update: {pause}")
        time.sleep(0.5)
    log(f"dispatch is still paused by hand after the update: '{reason}'")
    instance.press("Resume Dispatch")
    wait_for("dispatch to be resumed", lambda: (p := instance.pause()) and not p["paused"], 30)
    log("scenario 6 update_on_release_hand_pause: PASS")


def scenario_update_on_release_cancel(instance):
    v1 = version(BUILD_N1)
    log(f"scenario 7 update_on_release_cancel: Cancel Update holds v{v1}, which waits for Update to v{v1}")
    first = start_on_release(instance)
    sessions = wait_for("a run that just started", lambda: recent_session(instance), 120)
    symphony = instance.symphony_pid()
    publish(instance)
    wait_for_update_pause(instance)
    check_start_notification(instance)

    # The menu's Cancel Update does what the notification's does (UpdateCancel); scripted QA presses the menu's.
    instance.press("Cancel Update")
    wait_for("dispatch to be resumed", lambda: (p := instance.pause()) and not p["paused"], 30)
    log("dispatch resumed")
    check_run_going(instance, sessions[0], symphony)
    log(f"the run {sessions[0]} keeps going")
    wait_for(f"the start notification to be withdrawn (withdrawn: {instance.withdrawn()})",
             lambda: instance.withdrawn() == [START_TITLE], 15)
    log("the start notification was withdrawn")

    # Each check finds N+1 again; none may start it. A 4th request means the 3rd check's result was acted on.
    checks = instance.feed.latest_requests
    deadline = time.monotonic() + 4 * CHECK_INTERVAL + 60
    while instance.feed.latest_requests < checks + 4:
        status = instance.status() or {}
        menu = {item["title"] for item in status.get("menu", [])}
        started = [a for a in status.get("alerts", []) if a["title"] == START_TITLE]
        if status.get("pid") != first["pid"]:
            raise Failure(f"the app quit after Cancel Update: now pid {status.get('pid')}")
        if menu & {UPDATING_TITLE, "Cancel Update"} or len(started) > 1 or instance.pause().get("paused"):
            raise Failure(f"a later check started v{v1} again: menu {sorted(menu)}, start notifications {started}, "
                          f"pause {instance.pause()}")
        if time.monotonic() > deadline:
            raise Failure(f"the app checked only {instance.feed.latest_requests - checks} times since Cancel Update")
        time.sleep(0.25)
    log(f"three checks found v{v1} and started no update")

    wait_for(
        f"the held release in the menu (menu: {instance.menu()})",
        lambda: (menu := instance.menu()) and CANCELLED_LINE in menu
        and menu.get(f"Update to v{v1}") and menu.get("Skip This Version"),
        15,
    )
    log(f"the menu holds v{v1}: '{CANCELLED_LINE}', Update to v{v1}, Skip This Version")

    # Update to vN+1 by hand: it waits for the run under way, then relaunches on N+1.
    sessions = wait_for("a run with time left", lambda: _fresh_session(instance), 120)
    runs_before = len(instance.runs())
    tracker = Tracker(instance, [first["pid"], symphony])
    tracker.start()
    try:
        instance.press(f"Update to v{v1}")
        wait_for("the old app to quit", lambda: tracker.gone_at(first["pid"]), 180)
        wait_for_relaunch(instance, first["pid"])
        instance.wait_for_new_run(runs_before, BUILD_N1, timeout=180)
        wait_for("dispatch to be resumed", lambda: (p := instance.pause()) and not p["paused"], 60)
        log("dispatch resumed")
    finally:
        tracker.stop()
    check_drained(instance, sessions[0], symphony, tracker)
    check_updated_folder(instance)
    log("scenario 7 update_on_release_cancel: PASS")


def scenario_automatic_update(instance):
    log("scenario 8: Automatically when idle installs N+1 by itself, notifies, and the menu line opens its notes")
    instance.quit()
    # Scenario 7 left N+1 as Symphony.app. The checks follow the settings again, and the feed still publishes N+1.
    put_n_back(instance)
    instance.env.pop(CHECK_INTERVAL_KEY, None)
    instance.set_stub_seconds(STUB_SECONDS)
    # Symphony runs with no agent runs: the issue leaves the active states, so nothing is dispatched.
    instance.set_issue_state("Backlog")
    instance.update_settings(updateMode="whenIdle", startOnLaunch=True)
    log("Automatically when idle and Start at launch on, nothing to dispatch")
    first = instance.launch()
    if first["build"] != BUILD_N:
        raise Failure(f"the app is build {first['build']}, not {BUILD_N}")

    # No press: the app starts Symphony, sees it idle and installs N+1, which checks its health and starts Symphony.
    instance.wait_for_handoff(first["pid"])
    new = wait_for(
        f"build {BUILD_N1} to install itself and relaunch",
        lambda: (s := instance.status()) and s["pid"] != first["pid"] and s["build"] == BUILD_N1 and s,
        300,
    )
    instance.app_process = None
    log(f"build {BUILD_N1} relaunched as pid {new['pid']}")
    v1 = version(BUILD_N1)
    changes = change_count(instance.release_notes)
    notice = new_alert(instance, f"Symphony updated to v{v1}", 240)
    body = (f"{changes}. " if changes else "") + f"Choose Updated to v{v1} in the menu for the release notes."
    if notice["message"] != body:
        raise Failure(f"the update notification says {notice['message']!r}, not {body!r}")
    log(f"notified: {notice['title']}: {notice['message']}")
    if instance.alerts() != [notice]:
        raise Failure(f"the updated app showed other alerts: {instance.alerts()}")

    wait_for("the updated app to run Symphony", lambda: instance.symphony_pid(), 60)
    instance.check_runs_from_bundle(instance.app, BUILD_N1)
    wait_for("dispatch to be resumed", lambda: (s := instance.symphony_state()) and not s["pause"]["paused"], 60)
    if instance.app_build(instance.app) != BUILD_N1 or instance.app_build(instance.previous) != BUILD_N:
        raise Failure("the app folder doesn't hold N+1 as Symphony.app and N as Symphony (previous).app")

    line = f"Updated to v{v1}" + (f" ({changes})" if changes else "")
    wait_for(f"the enabled '{line}' line (menu: {list(instance.menu())})", lambda: instance.menu().get(line), 30)
    check_notes(instance, line, BUILD_N1)
    log("scenario 8 passed")


def scenario_automatic_rollback(instance):
    log("scenario 9: N+1 fails its health check (workspaces.repo doesn't exist) and is rolled back to N")
    instance.quit()
    shutil.rmtree(instance.app)
    instance.previous.rename(instance.app)
    # Scenario 4's, so the one found afterwards is the rollback's.
    rolled_back = instance.applications / "Symphony (rolled back).app"
    shutil.rmtree(rolled_back, ignore_errors=True)
    missing = instance.work / "missing-repo"
    instance.write_config("worktree", missing)
    instance.update_settings(startOnLaunch=False)
    log(f"installed N again; symphony.yml's workspaces.repo is {missing}, which doesn't exist")
    first = instance.launch()
    if first["build"] != BUILD_N:
        raise Failure(f"the app is build {first['build']}, not {BUILD_N}")

    # N installs N+1 by itself; N+1's symphony check fails, and the helper puts N back and opens it.
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
    log("scenario 9 passed")


SCENARIOS = (
    scenario_update,
    scenario_restart,
    scenario_broken_config,
    scenario_rollback,
    scenario_update_on_release,
    scenario_update_on_release_hand_pause,
    scenario_update_on_release_cancel,
    scenario_automatic_update,
    scenario_automatic_rollback,
)


# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--keep", action="store_true", help="keep the work folder")
    args = parser.parse_args()

    if sys.platform != "darwin" or os.uname().machine != "arm64":
        print("The end-to-end test runs on Apple silicon Macs only.", file=sys.stderr)
        return 2
    missing = [tool for tool in ("swift", "codesign", "ditto", "plutil", "minisign", "lsof", "git", "make")
               if not shutil.which(tool)]
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
    signing = feed = instance = None
    failed = True
    try:
        app_n, signing, feed_folder = build(work)
        feed = Feed(feed_folder)
        instance = Instance(work, app_n, feed)
        log(f"launching build {BUILD_N} from {instance.app} (QA root {instance.qa}, epmd port {instance.epmd_port})")
        instance.launch()
        for scenario in SCENARIOS:
            scenario(instance)
        failed = False
    except Failure as error:
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
        if signing:
            signing.cleanup()
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
