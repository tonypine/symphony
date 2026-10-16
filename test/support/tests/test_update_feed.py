"""The update feed stand-in: its modes, the mode switch, its log lines, its CLI."""

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

SUPPORT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SUPPORT))

from stubs import update_feed  # noqa: E402
from stubs.update_feed import FeedError, UpdateFeed  # noqa: E402

N, N1 = ("0.0.1.90001", 90001), ("0.0.1.90002", 90002)
ZIP = "Symphony-0.0.1.90002.zip"


def write_pair(root):
    """A release pair's feed/ and manifest.json, with made-up bytes in place of the built app."""
    feed = root / "feed"
    feed.mkdir(parents=True)
    (feed / ZIP).write_bytes(b"zip bytes")
    (feed / f"{ZIP}.sha256").write_text(f"{'a' * 64}  {ZIP}\n")
    (feed / f"{ZIP}.minisig").write_text("untrusted comment: test\nRWfake\n")
    (feed / "release_notes.md").write_text("3 changes:\n\n- one\n- two\n- three\n")
    (feed / "version.json").write_text(json.dumps({
        "version": N1[0], "build": N1[1], "sha256": "a" * 64, "zip": ZIP, "minisig": f"{ZIP}.minisig",
        "changes": 3, "signed": True,
    }))
    (root / "manifest.json").write_text(json.dumps({"n": {"version": N[0], "build": N[1]}}))
    return feed


def get(url, data=None):
    """(status, body bytes) for a GET, or a POST with `data`."""
    request = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def get_json(url):
    status, body = get(url)
    return status, json.loads(body)


class FeedTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)]))
        self.folder = write_pair(self.tmp)
        self.log = self.tmp / "feed.log"

    def start(self, **options):
        options.setdefault("log", self.log)
        feed = UpdateFeed(**options).start()
        self.addCleanup(feed.stop)
        return feed

    def latest(self, feed):
        return get_json(feed.latest_url)


class ModesTest(FeedTestCase):
    def test_publish_offers_the_feed_folders_release_and_serves_its_assets(self):
        feed = self.start(folder=self.folder)
        status, release = self.latest(feed)
        self.assertEqual(status, 200)
        self.assertEqual(release["tag_name"], f"v{N1[0]}")
        self.assertEqual(release["body"], "3 changes:\n\n- one\n- two\n- three\n")
        assets = {a["name"]: a["browser_download_url"] for a in release["assets"]}
        self.assertEqual(sorted(assets), sorted([ZIP, f"{ZIP}.sha256", f"{ZIP}.minisig", "version.json",
                                                 "release_notes.md"]))
        self.assertEqual(get(assets[ZIP]), (200, b"zip bytes"))
        status, info = get_json(assets["version.json"])
        self.assertEqual((status, info["build"], info["zip"]), (200, N1[1], ZIP))

    def test_none_serves_the_apps_own_release_from_the_manifest(self):
        feed = self.start(folder=self.folder, mode="none")
        status, release = self.latest(feed)
        self.assertEqual((status, release["tag_name"]), (200, f"v{N[0]}"))
        assets = {a["name"]: a["browser_download_url"] for a in release["assets"]}
        status, info = get_json(assets["version.json"])
        self.assertEqual((status, info["version"], info["build"]), (200, N[0], N[1]))
        self.assertEqual(info["zip"], "Symphony-0.0.1.90001.zip")
        self.assertEqual(info["minisig"], "Symphony-0.0.1.90001.zip.minisig")
        # A check never downloads N's app, so the feed lists it without serving it.
        self.assertEqual(get(assets[info["zip"]])[0], 404)

    def test_none_takes_the_current_release_given(self):
        feed = self.start(folder=self.folder, current=("0.0.1.5", 5), mode="none")
        self.assertEqual(self.latest(feed)[1]["tag_name"], "v0.0.1.5")

    def test_forbidden_answers_403_like_githubs_rate_limit(self):
        feed = self.start(folder=self.folder, mode="forbidden")
        status, body = self.latest(feed)
        self.assertEqual(status, 403)
        self.assertIn("rate limit", body["message"])

    def test_fake_release_offers_a_made_up_release_with_no_build(self):
        feed = self.start(fake=("9.9.9", 9999))
        status, release = self.latest(feed)
        self.assertEqual((status, release["tag_name"]), (200, "v9.9.9"))
        assets = {a["name"]: a["browser_download_url"] for a in release["assets"]}
        status, info = get_json(assets["version.json"])
        self.assertEqual((status, info["version"], info["build"], info["zip"]), (200, "9.9.9", 9999,
                                                                                  "Symphony-9.9.9.zip"))
        self.assertEqual(get(assets["Symphony-9.9.9.zip"])[0], 404)
        self.assertEqual(get(assets["Symphony-9.9.9.zip.sha256"])[0], 404)

    def test_fake_release_with_a_folder_replaces_the_published_one(self):
        feed = self.start(folder=self.folder, fake=("9.9.9", 9999))
        self.assertEqual(self.latest(feed)[1]["tag_name"], "v9.9.9")
        feed.set_mode("none")
        self.assertEqual(self.latest(feed)[1]["tag_name"], f"v{N[0]}")

    def test_none_without_the_apps_release_is_refused(self):
        with self.assertRaises(FeedError):
            UpdateFeed(fake=("9.9.9", 9999), mode="none")
        feed = self.start(fake=("9.9.9", 9999))
        status, _ = get(f"{feed.url}/_feed/mode", data=b"none")
        self.assertEqual((status, feed.mode), (400, "publish"))

    def test_needs_a_folder_or_a_fake_release(self):
        with self.assertRaises(FeedError):
            UpdateFeed()

    def test_serves_only_the_releases_assets(self):
        feed = self.start(folder=self.folder)
        for route in ("/manifest.json", "/../manifest.json", "/%2e%2e/manifest.json", "/feed.log", "/n/x"):
            self.assertEqual(get(feed.url + route)[0], 404, route)

    def test_answers_are_the_same_for_the_same_folder(self):
        first = self.start(folder=self.folder)
        second = self.start(folder=self.folder)
        for mode in ("publish", "none"):
            first.set_mode(mode)
            second.set_mode(mode)
            a, b = self.latest(first)[1], self.latest(second)[1]
            self.assertEqual(json.dumps(a).replace(first.url, "BASE"), json.dumps(b).replace(second.url, "BASE"))


class SwitchAndLogTest(FeedTestCase):
    def test_mode_switches_while_it_runs_and_every_request_is_one_log_line(self):
        feed = self.start(folder=self.folder)
        self.assertEqual(self.latest(feed)[1]["tag_name"], f"v{N1[0]}")
        self.assertEqual(get(f"{feed.url}/_feed/mode", data=b"none"), (200, b"none\n"))
        self.assertEqual(self.latest(feed)[1]["tag_name"], f"v{N[0]}")
        feed.set_mode("forbidden")
        self.assertEqual(self.latest(feed)[0], 403)
        self.assertEqual(get(f"{feed.url}/_feed/mode"), (200, b"forbidden\n"))
        self.assertEqual(get(f"{feed.url}/_feed/mode", data=b"bogus")[0], 400)
        self.assertEqual(feed.mode, "forbidden")
        self.assertEqual(feed.latest_requests, 3)

        lines = self.log.read_text().splitlines()
        entries = [json.loads(line) for line in lines]
        self.assertEqual(
            [(e["method"], e["path"], e["status"], e.get("body")) for e in entries],
            [
                ("GET", "/releases/latest", 200, None),
                ("POST", "/_feed/mode", 200, "none"),
                ("GET", "/releases/latest", 200, None),
                ("GET", "/releases/latest", 403, None),
                ("GET", "/_feed/mode", 200, None),
                ("POST", "/_feed/mode", 400, "bogus"),
            ],
        )
        self.assertEqual(feed.requests, entries)
        for entry in entries:
            self.assertRegex(entry["time"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")

    def test_binds_127_0_0_1_only(self):
        feed = self.start(folder=self.folder)
        self.assertEqual(feed.server.server_address[0], "127.0.0.1")
        self.assertTrue(feed.url.startswith("http://127.0.0.1:"))


class CommandLineTest(FeedTestCase):
    def test_serves_switches_and_logs_from_the_command_line(self):
        script = SUPPORT / "stubs" / "update_feed.py"
        process = subprocess.Popen(
            [sys.executable, str(script), "--dir", str(self.folder), "--log", str(self.log)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.wait, 10)
        self.addCleanup(process.terminate)
        banner = process.stdout.readline()
        self.assertIn("update feed on http://127.0.0.1:", banner)
        latest = banner.split(" on ", 1)[1].split()[0]
        self.assertTrue(latest.endswith("/releases/latest"))
        base = latest[: -len("/releases/latest")]
        self.assertEqual(get_json(latest)[1]["tag_name"], f"v{N1[0]}")
        self.assertEqual(get(f"{base}/_feed/mode", data=b"forbidden")[0], 200)
        self.assertEqual(get(latest)[0], 403)
        process.terminate()
        self.assertEqual(process.wait(10), 0)
        self.assertEqual(len(self.log.read_text().splitlines()), 3)

    def test_parse_args(self):
        args = update_feed.parse_args(["--fake-release", "9.9.9", "9999", "--port", "8123", "--mode", "forbidden"])
        self.assertEqual((args.fake_release, args.port, args.mode, args.dir), (("9.9.9", 9999), 8123, "forbidden",
                                                                              None))
        for argv in ([], ["--fake-release", "9.9.9", "nine"]):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                update_feed.parse_args(argv)

    def test_exits_2_on_a_folder_without_a_release(self):
        empty = self.tmp / "empty"
        empty.mkdir()
        result = subprocess.run([sys.executable, str(SUPPORT / "stubs" / "update_feed.py"), "--dir", str(empty)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 2)
        self.assertIn("version.json", result.stderr)


if __name__ == "__main__":
    unittest.main()
