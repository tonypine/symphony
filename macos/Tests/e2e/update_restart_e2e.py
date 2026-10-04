#!/usr/bin/env python3
"""End-to-end test of the menu bar app's Update, Restart and rollback.

Builds releases N and N+1 of Symphony.app from this checkout, installs N in a
temporary folder, runs it in scripted QA mode against a fake Linear (the memory
tracker) and a stub agent, and checks four scenarios:

1. Update N -> N+1 while a run is active: the old Symphony drains and stops, the
   new app starts its Symphony on its own, dispatch resumes, only N+1's unpacked
   release is left, and no BEAM from N is left running.
2. Restart while a run is active: it waits for the run, restarts and resumes.
3. Restart with a broken symphony.yml: refused with the config error, and the
   running Symphony is left as it was.
4. Rollback to `Symphony (previous).app`: it starts and still reads its secrets.

It never touches the installed app: the app, its settings, secrets, logs,
update downloads, Symphony's state, logs and unpacked release, HOME and the
epmd port are all its own, and the dashboard binds a free port. The live app's
processes, state files, unpacked releases and port 4000 are snapshotted before
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
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

MACOS = Path(__file__).resolve().parents[2]
REPO = MACOS.parent
BUILD_N = int(os.environ.get("SYMPHONY_E2E_BUILD_N", "90001"))
BUILD_N1 = BUILD_N + 1
STUB_SECONDS = int(os.environ.get("SYMPHONY_E2E_STUB_SECONDS", "15"))
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
    # The installed app (~/Applications or /Applications) and the Symphony it runs from its unpacked release.
    snapshot["apps"] = sorted(pid for pid, cmd in rows if "/Applications/Symphony.app/Contents/MacOS/" in cmd)
    snapshot["beams"] = sorted(pid for pid, cmd in rows if "beam.smp" in cmd and str(support / ".burrito") in cmd)

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

    burrito = support / ".burrito"
    try:
        snapshot["unpacked"] = sorted(
            f"{entry.name} ino={entry.stat().st_ino}" for entry in burrito.iterdir() if entry.is_dir()
        )
    except FileNotFoundError:
        snapshot["unpacked"] = "missing"
    except OSError as error:
        snapshot["unpacked"] = f"unreadable ({error.strerror})"
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
    out.parent.mkdir(parents=True, exist_ok=True)
    prebuilt = os.environ.get(f"SYMPHONY_E2E_SYMPHONY_BIN_{'N1' if build == BUILD_N1 else 'N'}")
    if prebuilt:
        shutil.copy(prebuilt, out)
        log(f"using the prebuilt Symphony binary {prebuilt} as build {build}")
        return
    log(f"building the Symphony binary for build {build} (make package)")
    env = dict(os.environ, SYMPHONY_BUILD_NUMBER=str(build), BURRITO_TARGET="macos_arm64")
    env.pop("SYMPHONY_AGENT_RUNTIME", None)
    run(["make", "package"], cwd=REPO, env=env, capture=False)
    # `make package` renames Burrito's symphony_macos_arm64 to the name release.yml ships.
    built = REPO / "burrito_out" / "symphony-macos-arm64"
    if not built.is_file():
        found = sorted(p.name for p in (REPO / "burrito_out").glob("*")) if (REPO / "burrito_out").is_dir() else []
        raise SystemExit(f"make package didn't produce {built}; burrito_out/ holds {found or 'nothing'}")
    shutil.copy(built, out)


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
        binary = work / "bin" / f"symphony-{number}"
        build_symphony(number, binary)
        build_dir = work / f"build-{number}"
        log(f"bundling Symphony.app {version(number)}")
        run([
            "make", "-C", MACOS, "bundle",
            f"BUILD_DIR={build_dir}",
            f"PREBUILT_EXECUTABLE={executable}",
            f"SYMPHONY_BIN={binary}",
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
    """Serves the update feed: `releases/latest` like GitHub's API, and the release assets."""

    def __init__(self, folder):
        self.folder = folder
        handler = lambda *args, **kwargs: _QuietHandler(*args, directory=str(folder), **kwargs)  # noqa: E731
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        names = [p.name for p in folder.iterdir() if p.is_file()]
        (folder / "releases").mkdir()
        (folder / "releases" / "latest").write_text(json.dumps({
            "tag_name": f"v{version(BUILD_N1)}-e2e",
            "html_url": f"{self.base}/release",
            "body": (folder / "release_notes.md").read_text(),
            "assets": [{"name": name, "browser_download_url": f"{self.base}/{name}"} for name in names],
        }))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def latest_url(self):
        return f"{self.base}/releases/latest"

    def stop(self):
        self.server.shutdown()


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
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
        self.secret = secrets.token_hex(8)
        self.epmd_port = free_port()
        self.app_process = None
        self.launches = 0
        self.command_count = 0
        for folder in (self.qa, self.applications, work / "config", work / "logs", work / "home", work / "repo"):
            folder.mkdir(parents=True, exist_ok=True)
        self._write_fake_linear_and_stub()
        self._write_qa_settings()
        run(["ditto", app_n, self.app])
        self.env = self._app_environment(feed)

    def burrito_folder(self, build):
        matches = sorted((self.qa / "burrito" / ".burrito").glob(f"symphony_erts-*_0.0.1-{build}"))
        return matches[0] if matches else self.qa / "burrito" / ".burrito" / f"symphony_erts-?_0.0.1-{build}"

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
        # The hook runs with Symphony's own environment: the binary and unpacked release that run, and the secret
        # the app passed it.
        (config / "WORKFLOW.md").write_text(
            "---\nhooks:\n  before_run: |\n"
            f"    printf '%s binary=%s root=%s secret=%s\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" "
            f"\"${{__BURRITO_BIN_PATH:-unknown}}\" \"${{RELEASE_ROOT:-unknown}}\" \"${{E2E_SECRET:-unset}}\" "
            f">> '{self.runs_log}'\n"
            "---\nWork on {{ issue.identifier }}.\n"
        )
        stub = self.work / "bin" / "stub-claude"
        stub.write_text(
            "#!/bin/sh\n"
            "# Stub agent: one Claude stream-json turn that takes a while, logged by session.\n"
            "sid=\"e2e-$$\"\n"
            f"log='{self.stub_log}'\n"
            "trap 'echo \"$(date +%s) killed $sid\" >> \"$log\"; exit 143' TERM INT\n"
            "echo \"$(date +%s) start $sid\" >> \"$log\"\n"
            "printf '%s\\n' \"{\\\"type\\\":\\\"system\\\",\\\"subtype\\\":\\\"init\\\",\\\"session_id\\\":\\\"$sid\\\","
            "\\\"cwd\\\":\\\"$PWD\\\",\\\"tools\\\":[],\\\"mcp_servers\\\":[],\\\"model\\\":\\\"stub\\\","
            "\\\"permissionMode\\\":\\\"default\\\",\\\"apiKeySource\\\":\\\"none\\\"}\"\n"
            f"sleep {STUB_SECONDS} &\nwait $!\n"
            "echo \"$(date +%s) end $sid\" >> \"$log\"\n"
            "printf '%s\\n' \"{\\\"type\\\":\\\"result\\\",\\\"subtype\\\":\\\"success\\\",\\\"is_error\\\":false,"
            "\\\"num_turns\\\":1,\\\"result\\\":\\\"Done.\\\",\\\"session_id\\\":\\\"$sid\\\","
            "\\\"usage\\\":{\\\"input_tokens\\\":1,\\\"output_tokens\\\":1}}\"\n"
        )
        stub.chmod(0o755)
        self.config.write_text(
            "issues:\n  provider: memory\n  poll_interval_ms: 1000\n  memory:\n    issues_file: issues.json\n"
            "  states:\n    active: [Todo, In Progress]\n    terminal: [Done]\n"
            "repositories:\n  - key: e2e\n    workflow: WORKFLOW.md\n"
            f"    workspace:\n      strategy: clone\n      repo: {repo}\n"
            f"workspaces:\n  root: {self.work / 'workspaces'}\n"
            f"agent:\n  runtime: claude\n  command: {stub}\n  concurrency:\n    max_total: 1\n"
            "  limits:\n    max_turns: 1\n"
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
            }, file)
        secrets_file = self.qa / "secrets.json"
        secrets_file.write_text(json.dumps({"LINEAR_API_KEY": "e2e-not-a-real-key", "E2E_SECRET": self.secret}))
        secrets_file.chmod(0o600)

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

    def press(self, title, timeout=30):
        """Presses a menu item as a click would, after waiting for it to be enabled."""
        wait_for(f"'{title}' to be enabled (menu: {list(self.menu())})", lambda: self.menu().get(title), timeout)
        self.command_count += 1
        name = f"{self.command_count:04d}"
        commands = self.qa / "commands"
        (commands / f".{name}").write_text(title)
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

        fields = wait_for("a new agent run", started, timeout)
        if os.path.realpath(fields.get("binary", "")) != os.path.realpath(self.app / "Contents" / "Resources" / "symphony"):
            raise Failure(f"the run's Symphony is {fields.get('binary')}, not the installed app's")
        # The unpacked release is named after the build: symphony_erts-<erts>_0.0.1-<build>.
        root = fields.get("root", "")
        if os.path.realpath(Path(root).parent) != os.path.realpath(self.qa / "burrito" / ".burrito") or not root.endswith(
            f"-{build}"
        ):
            raise Failure(f"the run's Symphony runs from {fields.get('root')}, not build {build}'s unpacked release")
        return fields.get("secret")

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
        """The build's Symphony BEAMs, whose unpacked release may be deleted already.

        Only `beam.smp` counts: the release's `epmd -daemon` also runs from the unpacked folder,
        but it is detached and outlives the node by design, so it isn't a running Symphony.
        """
        root = str(self.qa / "burrito" / ".burrito") + "/"
        return [
            pid for pid, cmd in processes()
            if root in cmd and f"_0.0.1-{build}/" in cmd and "/bin/beam.smp" in cmd
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
        epmds = sorted((self.qa / "burrito").glob(".burrito/*/erts-*/bin/epmd"))
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
                {k: status[k] for k in ("pid", "build", "symphony_pid", "alerts", "presses")}))
            lines.append("menu: " + json.dumps([m["title"] for m in status["menu"]]))
        lines.append(f"Symphony state: {json.dumps(self.symphony_state())[:600]}")
        logs = [
            self.qa / "updates" / "update-helper.log",
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

    def __init__(self, instance, pids, old_build=None):
        super().__init__(daemon=True)
        self.instance = instance
        self.pids = dict.fromkeys(pids)
        self.old_build = old_build
        self.violation = None
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
            if self.old_build and self.violation is None:
                folder = self.instance.burrito_folder(self.old_build)
                if not folder.exists():
                    beams = self.instance.beam_pids(self.old_build)
                    if beams:
                        self.violation = (
                            f"TP-339: build {self.old_build}'s unpacked release was deleted while its Symphony "
                            f"(pids {beams}) was still running"
                        )
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
    instance.press("Check for Updates…")
    update_title = f"Update to v{version(BUILD_N1)}"
    wait_for(f"'{update_title}'", lambda: instance.menu().get(update_title), 60)

    # Press while a run is just starting, so the drain has something to wait for.
    sessions = wait_for("a run with time left", lambda: _fresh_session(instance), 60)
    old_app = instance.status()["pid"]
    old_symphony = instance.symphony_pid()
    runs_before = len(instance.runs())
    tracker = Tracker(instance, [old_app, old_symphony], old_build=BUILD_N)
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
    if tracker.violation:
        raise Failure(tracker.violation)
    if not any(line.startswith("Waiting for") for line in tracker.lines):
        raise Failure(f"the update never showed it was waiting for agent runs; lines seen: {sorted(tracker.lines)}")
    check_drained(instance, sessions[0], old_symphony, tracker)

    if alive(old_symphony) or instance.beam_pids(BUILD_N):
        raise Failure(f"build {BUILD_N}'s Symphony is still running: {instance.beam_pids(BUILD_N)}")
    unpacked = sorted(p.name for p in (instance.qa / "burrito" / ".burrito").iterdir() if p.is_dir())
    if unpacked != [instance.burrito_folder(BUILD_N1).name]:
        raise Failure(f"unpacked releases after the update: {unpacked}, expected only build {BUILD_N1}'s")
    if instance.app_build(instance.app) != BUILD_N1 or instance.app_build(instance.previous) != BUILD_N:
        raise Failure("the app folder doesn't hold N+1 as Symphony.app and N as Symphony (previous).app")
    if instance.alerts():
        raise Failure(f"the updated app showed alerts: {instance.alerts()}")
    log("scenario 1 passed")


def _fresh_session(instance):
    """The active sessions, once one has at least half the stub's run time left."""
    sessions = instance.active_sessions()
    if not sessions:
        return None
    started = instance.stub_events(sessions[0]).get("start")
    return sessions if started and time.time() - started < STUB_SECONDS / 2 else None


def scenario_restart(instance):
    log("scenario 2: Restart while a run is active")
    sessions = wait_for("a run with time left", lambda: _fresh_session(instance), 120)
    old_symphony = instance.symphony_pid()
    runs_before = len(instance.runs())
    tracker = Tracker(instance, [old_symphony])
    tracker.start()
    try:
        instance.press("Restart Symphony")
        wait_for(
            "Symphony to restart",
            lambda: (pid := instance.symphony_pid()) and pid != old_symphony and pid,
            180,
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
    status = instance.status()
    app_pid, symphony = status["pid"], status["symphony_pid"]
    instance.press("Quit Symphony")
    wait_for("the app to quit", lambda: not alive(app_pid), 120)
    wait_for("Symphony to stop", lambda: not alive(symphony), 60)
    instance.app.rename(instance.applications / "Symphony (rolled back).app")
    instance.previous.rename(instance.app)
    log("swapped Symphony (previous).app back in")
    status = instance.launch()
    if status["build"] != BUILD_N:
        raise Failure(f"the rolled-back app is build {status['build']}, not {BUILD_N}")
    runs_before = len(instance.runs())
    instance.press("Start Symphony", timeout=60)
    secret = instance.wait_for_new_run(runs_before, BUILD_N, timeout=180)
    if secret != instance.secret:
        raise Failure(f"the rolled-back Symphony didn't get the stored secret (got {secret!r})")
    if instance.alerts():
        raise Failure(f"the rolled-back app showed alerts: {instance.alerts()}")
    log("scenario 4 passed")


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
        for scenario in (scenario_update, scenario_restart, scenario_broken_config, scenario_rollback):
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
    log("FAILED" if failed else "all 4 scenarios passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
