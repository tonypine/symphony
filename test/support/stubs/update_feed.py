#!/usr/bin/env python3
"""The update feed stand-in: answers `releases/latest` like GitHub's API and serves the release's assets.

Point the menu bar app at it with SYMPHONY_BAR_UPDATE_URL=http://127.0.0.1:<port>/releases/latest (qa_launch_app's
`update_feed_port` does). Modes, switchable while it runs:

  publish    the feed's release (N+1, or the --fake-release) is the latest
  none       no newer release: the latest is the app's own (N), so the app finds itself up to date
  forbidden  `releases/latest` answers 403, which the app reads as GitHub's rate limit

Usage:
  python3 test/support/stubs/update_feed.py --dir macos/build/release-pair/feed --port 8123 --log feed.log
  python3 test/support/stubs/update_feed.py --fake-release 9.9.9 9999 --port 8123 --log feed.log
  curl -X POST --data none http://127.0.0.1:8123/_feed/mode     # switch mode while it runs

See test/support/README.md.
"""

import argparse
import json
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from stubs._server import StubHandler, StubServer, serve_cli  # noqa: E402

MODES = ("publish", "none", "forbidden")
MODE_ROUTE = "/_feed/mode"
LATEST_ROUTE = "/releases/latest"
# What GitHub's API says when an unauthenticated client is over its rate limit.
FORBIDDEN_BODY = {
    "message": "API rate limit exceeded (the update feed stand-in's forbidden mode)",
    "documentation_url": "https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting",
}


class FeedError(Exception):
    pass


def zip_name(version):
    return f"Symphony-{version}.zip"


def read_manifest_current(folder):
    """(version, build) of release N from the manifest.json next to a release-pair's feed folder, else None."""
    manifest = Path(folder).parent / "manifest.json"
    try:
        n = json.loads(manifest.read_text())["n"]
        return n["version"], int(n["build"])
    except (FileNotFoundError, KeyError, TypeError, ValueError):
        return None


class Release:
    """One release as the feed answers it: GitHub's `releases/latest` JSON, and the assets it serves under `prefix`.

    `files` maps an asset name to a file on disk, `generated` to bytes served from memory. A name the release lists
    in neither is listed but not served (404), like the app of a release with no build.
    """

    def __init__(self, tag, prefix, body, names, files=None, generated=None):
        self.tag = tag
        self.prefix = prefix
        self.body = body
        self.names = sorted(names)
        self.files = files or {}
        self.generated = generated or {}

    def payload(self, base):
        return {
            "tag_name": self.tag,
            "html_url": f"{base}{self.prefix}release",
            "body": self.body,
            "assets": [{"name": name, "browser_download_url": f"{base}{self.prefix}{name}"} for name in self.names],
        }


def folder_release(folder):
    """The release the feed folder holds (`make -C macos release-pair`'s feed/): every file in it, served from disk."""
    folder = Path(folder)
    info = json.loads((folder / "version.json").read_text())
    files = {path.name: path for path in folder.iterdir() if path.is_file() and not path.name.startswith(".")}
    notes = folder / "release_notes.md"
    return Release(
        tag=f"v{info['version']}",
        prefix="/",
        body=notes.read_text() if notes.exists() else "",
        names=files,
        files=files,
    ), info


def current_release(current, published_info):
    """N as the latest release, so the app finds itself up to date. Its version.json names N's build, and the
    release lists the app's names without the files: a check never downloads them."""
    version, build = current
    name = zip_name(version)
    info = dict(published_info or {}, version=version, build=build, zip=name)
    info["minisig"] = f"{name}.minisig" if info.get("minisig") else None
    names = ["version.json", name, f"{name}.sha256"] + ([info["minisig"]] if info["minisig"] else [])
    return Release(
        tag=f"v{version}",
        prefix="/n/",
        body=f"Release {version}.\n",
        names=names,
        generated={"version.json": (json.dumps(info, indent=2) + "\n").encode()},
    )


def fake_release(version, build):
    """A made-up release with no build, for checks of what the app shows: its app and checksum are 404s."""
    name = zip_name(version)
    info = {
        "version": version,
        "build": build,
        "sha256": "0" * 64,
        "commit": "0" * 40,
        "published_at": "2000-01-01T00:00:00Z",
        "signed": False,
        "zip": name,
        "minisig": None,
        "changes": 1,
    }
    return Release(
        tag=f"v{version}",
        prefix="/fake/",
        body="1 change:\n\n- A made-up release with no build, served by the update feed stand-in.\n",
        names=["version.json", name, f"{name}.sha256"],
        generated={"version.json": (json.dumps(info, indent=2) + "\n").encode()},
    )


class UpdateFeed:
    """The feed server. `folder` is a release's assets (a release-pair's feed/), `fake` a (version, build) to offer
    instead, `current` the (version, build) the `none` mode serves (default: the release-pair's N, from the
    manifest.json next to `folder`)."""

    def __init__(self, folder=None, *, fake=None, current=None, mode="publish", port=0, log=None):
        if folder is None and fake is None:
            raise FeedError("give the feed a folder or a fake release")
        self.folder = Path(folder) if folder is not None else None
        published_info = None
        if fake is not None:
            self.published = fake_release(*fake)
        else:
            self.published, published_info = folder_release(self.folder)
        if current is None and self.folder is not None:
            current = read_manifest_current(self.folder)
        self.current = current_release(current, published_info) if current else None
        self._lock = threading.Lock()
        self._mode = None
        self.latest_requests = 0
        self.set_mode(mode)
        self.server = StubServer(_handler(self), port=port, log_path=log)

    # -- the API tests use --------------------------------------------------

    @property
    def mode(self):
        return self._mode

    def set_mode(self, mode):
        if mode not in MODES:
            raise FeedError(f"unknown mode {mode!r}; the modes are {', '.join(MODES)}")
        if mode == "none" and self.current is None:
            raise FeedError("the none mode needs the app's own release: pass --current VERSION BUILD")
        with self._lock:
            self._mode = mode

    @property
    def url(self):
        return self.server.url

    @property
    def latest_url(self):
        return f"{self.url}{LATEST_ROUTE}"

    @property
    def port(self):
        return self.server.port

    @property
    def requests(self):
        """Every request the feed answered, as logged (empty without a log file)."""
        return self.server.request_log.entries()

    def start(self):
        self.server.start()
        return self

    def stop(self):
        self.server.stop()

    # -- answers -------------------------------------------------------------

    def latest(self):
        """(status, body) for `releases/latest` in the current mode."""
        with self._lock:
            self.latest_requests += 1
            mode = self._mode
        if mode == "forbidden":
            return 403, FORBIDDEN_BODY
        release = self.published if mode == "publish" else self.current
        return 200, release.payload(self.url)

    def asset(self, route):
        """(status, bytes or None, path or None) for an asset route."""
        for release in (self.published, self.current):
            if release is None or not route.startswith(release.prefix):
                continue
            name = route[len(release.prefix):]
            if name == "release":
                return 200, f"<html><body>Release {release.tag}</body></html>\n".encode(), None
            if name in release.generated:
                return 200, release.generated[name], None
            if name in release.files:
                return 200, None, release.files[name]
        return 404, None, None


def _handler(feed):
    class Handler(StubHandler):
        def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's name
            route = self.route
            if route == LATEST_ROUTE:
                status, body = feed.latest()
                return self.respond(status, body)
            if route == MODE_ROUTE:
                return self.respond(200, feed.mode + "\n", content_type="text/plain")
            status, body, path = feed.asset(route)
            if path is not None:
                with open(path, "rb") as file:
                    return self.respond(200, content_type="application/octet-stream", file=file,
                                        length=path.stat().st_size)
            if status == 200:
                html = body.startswith(b"<html>")
                return self.respond(200, body, content_type="text/html" if html else "application/json")
            return self.respond(404, {"message": "Not Found"})

        do_HEAD = do_GET  # noqa: N815

        def do_POST(self):  # noqa: N802
            body = self.request_body().decode(errors="replace").strip()
            if self.route != MODE_ROUTE:
                return self.respond(404, {"message": "Not Found"}, sent=body)
            try:
                feed.set_mode(body)
            except FeedError as error:
                return self.respond(400, str(error) + "\n", content_type="text/plain", sent=body)
            return self.respond(200, feed.mode + "\n", content_type="text/plain", sent=body)

    return Handler


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dir", type=Path, help="the release's assets: version.json, the zip, .sha256, .minisig, "
                        "release_notes.md (a release-pair's feed/)")
    parser.add_argument("--fake-release", nargs=2, metavar=("VERSION", "BUILD"),
                        help="offer a made-up newer release with no build instead, for checks of the app's UI")
    parser.add_argument("--current", nargs=2, metavar=("VERSION", "BUILD"),
                        help="the app's own release, which the none mode serves (default: N from the "
                        "manifest.json next to --dir)")
    parser.add_argument("--mode", choices=MODES, default="publish", help="the starting mode (default publish)")
    parser.add_argument("--port", type=int, default=0, help="the port on 127.0.0.1 (default: a free one)")
    parser.add_argument("--log", type=Path, help="append one JSON line per request to this file")
    args = parser.parse_args(argv)
    if args.dir is None and args.fake_release is None:
        parser.error("give --dir, --fake-release or both")
    for name in ("fake_release", "current"):
        value = getattr(args, name)
        if value is not None:
            if not value[1].isdigit():
                parser.error(f"--{name.replace('_', '-')}'s BUILD must be a number, got {value[1]}")
            setattr(args, name, (value[0], int(value[1])))
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        feed = UpdateFeed(args.dir, fake=args.fake_release, current=args.current, mode=args.mode,
                          port=args.port, log=args.log)
    except (FeedError, OSError, ValueError, KeyError) as error:
        print(f"update_feed: {error}", file=sys.stderr)
        return 2
    serve_cli(feed.server, f"update feed on {feed.latest_url} (mode {feed.mode}, log {args.log or 'none'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
