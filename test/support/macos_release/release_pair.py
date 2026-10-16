#!/usr/bin/env python3
"""Builds a signed Symphony.app release N and its update N+1 from this checkout, at fixed paths.

  <out>/N/Symphony.app      release N, signed, with the pair's minisign public key in its Info.plist
  <out>/feed/               N+1 as released: Symphony-<v>.zip, .sha256, .minisig, version.json, release_notes.md
  <out>/minisign/           the throwaway minisign key pair N+1 is signed with
  <out>/manifest.json       the paths (relative to <out>), versions, build numbers, the signing identity's SHA-1
                            and the minisign public key

<out> is macos/build/release-pair by default. Usage (from the repo root):

  python3 test/support/macos_release/release_pair.py [--out DIR] [--build-n 90001] [--build-n1 90002]

or `make -C macos release-pair`. Serve the feed with test/support/stubs/update_feed.py. See test/support/README.md.
"""

import argparse
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from macos_release import minisign_keys, signing  # noqa: E402
from macos_release._run import BuildError, log, run  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
MACOS = REPO / "macos"
DEFAULT_OUT = MACOS / "build" / "release-pair"
DEFAULT_BUILD_N = 90001
TOOLS = ("swift", "codesign", "ditto", "plutil", "minisign", "git", "make", "jq", "security")

# Prebuilt inputs, so a test can skip the slow builds (they must match the build numbers).
RELEASE_ENV = {"n": "SYMPHONY_E2E_SYMPHONY_RELEASE_N", "n1": "SYMPHONY_E2E_SYMPHONY_RELEASE_N1"}
EXECUTABLE_ENV = "SYMPHONY_E2E_APP_EXECUTABLE"


def version(build):
    return f"0.0.1.{build}"


def tag(build):
    """N+1's tag, which no real release has: the notes then list the commits since the latest real v* tag."""
    return f"v{version(build)}-release-pair"


class Layout:
    """The fixed paths under a release pair's folder."""

    def __init__(self, root):
        self.root = Path(root)
        self.app_n = self.root / "N" / "Symphony.app"
        self.feed = self.root / "feed"
        self.minisign = self.root / "minisign"
        self.manifest = self.root / "manifest.json"
        # Intermediate builds, removed once the pair is laid out.
        self.work = self.root / "work"

    def feed_names(self, build_n1):
        zip_name = f"Symphony-{version(build_n1)}.zip"
        return {
            "zip": zip_name,
            "sha256": f"{zip_name}.sha256",
            "minisig": f"{zip_name}.minisig",
            "version_json": "version.json",
            "release_notes": "release_notes.md",
        }

    def relative(self, path):
        path = Path(path)
        try:
            return path.resolve().relative_to(self.root.resolve()).as_posix()
        except ValueError:
            return str(path)


def utc(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def lay_out(root, *, app_n, packaged, commit, published_at, build_n, build_n1, identity_sha1, keys):
    """Moves app N and N+1's packaged assets to the fixed paths under `root` and writes manifest.json.

    `published_at` replaces the packaging time in version.json, so the same commit gives the same file. Returns the
    manifest.
    """
    layout = Layout(root)
    names = layout.feed_names(build_n1)
    packaged = Path(packaged)
    missing = [name for name in names.values() if not (packaged / name).is_file()]
    if missing:
        raise BuildError(f"the packaged release in {packaged} has no {', '.join(missing)}")
    info = json.loads((packaged / "version.json").read_text())
    if info.get("version") != version(build_n1) or info.get("build") != build_n1:
        raise BuildError(f"version.json names {info.get('version')} build {info.get('build')}, "
                         f"not {version(build_n1)} build {build_n1}")

    shutil.rmtree(layout.app_n.parent, ignore_errors=True)
    shutil.rmtree(layout.feed, ignore_errors=True)
    if layout.manifest.exists():
        layout.manifest.unlink()
    layout.app_n.parent.mkdir(parents=True)
    shutil.move(str(app_n), str(layout.app_n))
    layout.feed.mkdir(parents=True)
    for name in names.values():
        shutil.move(str(packaged / name), str(layout.feed / name))
    info["published_at"] = published_at
    (layout.feed / "version.json").write_text(json.dumps(info, indent=2) + "\n")

    manifest = {
        "commit": commit,
        "signing_identity": identity_sha1,
        "minisign": {
            "public_key": keys.public_key,
            "public_key_file": layout.relative(keys.public_file),
            "secret_key_file": layout.relative(keys.secret_file),
        },
        "n": {
            "version": version(build_n),
            "build": build_n,
            "app": layout.relative(layout.app_n),
        },
        "n1": dict(
            {"version": version(build_n1), "build": build_n1, "tag": tag(build_n1),
             "feed": layout.relative(layout.feed)},
            **{key: layout.relative(layout.feed / name) for key, name in names.items()},
        ),
    }
    layout.manifest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def build_app_executable(env):
    prebuilt = env.get(EXECUTABLE_ENV)
    if prebuilt:
        log(f"using the prebuilt app executable {prebuilt}")
        return Path(prebuilt)
    log("building SymphonyBar (swift build -c release)")
    run(["swift", "build", "-c", "release", "--product", "SymphonyBar"], cwd=MACOS, capture=False)
    bin_path = run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=MACOS).stdout.strip()
    return Path(bin_path) / "SymphonyBar"


def build_symphony(build, out, prebuilt, env):
    """Copies build `build`'s Symphony release (`make release`, ERTS included) to `out`."""
    out.parent.mkdir(parents=True, exist_ok=True)
    if prebuilt:
        run(["ditto", prebuilt, out])
        log(f"using the prebuilt Symphony release {prebuilt} as build {build}")
        return
    log(f"building the Symphony release for build {build} (make release)")
    release_env = dict(env, SYMPHONY_BUILD_NUMBER=str(build))
    release_env.pop("SYMPHONY_AGENT_RUNTIME", None)
    run(["make", "release"], cwd=REPO, env=release_env, capture=False)
    built = REPO / "_build" / "prod" / "rel" / "symphony"
    if not (built / "releases" / f"0.0.1-{build}").is_dir():
        raise BuildError(f"make release didn't produce build {build}'s release in {built}")
    run(["ditto", built, out])


def build(root, identity, keys, build_n=DEFAULT_BUILD_N, build_n1=None, env=None):
    """Builds and signs N and N+1 with `identity`, packages N+1 signed with `keys`, and lays them out under `root`.

    Returns the manifest.
    """
    env = dict(os.environ if env is None else env)
    build_n1 = build_n + 1 if build_n1 is None else build_n1
    if build_n1 <= build_n:
        raise BuildError(f"N+1's build number ({build_n1}) must be above N's ({build_n})")
    layout = Layout(root)
    shutil.rmtree(layout.work, ignore_errors=True)
    layout.work.mkdir(parents=True)

    executable = build_app_executable(env)
    apps = {}
    for key, number in (("n", build_n), ("n1", build_n1)):
        release = layout.work / "releases" / f"symphony-{number}"
        build_symphony(number, release, env.get(RELEASE_ENV[key]), env)
        build_dir = layout.work / f"build-{number}"
        log(f"bundling Symphony.app {version(number)}")
        run([
            "make", "-C", MACOS, "bundle",
            f"BUILD_DIR={build_dir}",
            f"PREBUILT_EXECUTABLE={executable}",
            f"SYMPHONY_RELEASE={release}",
            f"SHORT_VERSION={version(number)}",
            f"BUILD_NUMBER={number}",
            f"MINISIGN_PUBLIC_KEY={keys.public_key}",
            f"SIGNING_IDENTITY={identity.identity}",
            f"CODESIGN_FLAGS={' '.join(identity.flags)}",
        ])
        apps[key] = build_dir / "Symphony.app"

    log(f"packaging {version(build_n1)} as a release")
    packaged = layout.work / "package"
    commit = run(["git", "rev-parse", "HEAD"], cwd=REPO).stdout.strip()
    committed = int(run(["git", "show", "-s", "--format=%ct", commit], cwd=REPO).stdout.strip())
    package_env = dict(env, MINISIGN_SECRET_KEY=keys.secret_key, MINISIGN_PUBLIC_KEY=keys.public_key)
    package_env.pop("MINISIGN_PASSWORD", None)
    run([
        REPO / "scripts" / "release" / "package.sh",
        "--app", apps["n1"], "--version", version(build_n1), "--build", build_n1,
        "--commit", commit, "--tag", tag(build_n1), "--signed", "true", "--out", packaged,
    ], cwd=REPO, env=package_env)

    manifest = lay_out(
        root, app_n=apps["n"], packaged=packaged, commit=commit, published_at=utc(committed),
        build_n=build_n, build_n1=build_n1, identity_sha1=identity.sha1(), keys=keys,
    )
    shutil.rmtree(layout.work, ignore_errors=True)
    log(f"release pair in {layout.root}: N {version(build_n)}, N+1 {version(build_n1)} (manifest.json)")
    return manifest


def parse_args(argv, env=None):
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"the pair's folder (default {DEFAULT_OUT})")
    parser.add_argument("--build-n", type=int, default=int(env.get("SYMPHONY_E2E_BUILD_N") or DEFAULT_BUILD_N),
                        help=f"release N's build number (default {DEFAULT_BUILD_N})")
    parser.add_argument("--build-n1", type=int, help="release N+1's build number (default N's plus one)")
    parser.add_argument("--minisign-dir", type=Path,
                        help="use the minisign key pair in this folder (made there when it has none) instead of a "
                        "new one in <out>/minisign each run")
    args = parser.parse_args(argv)
    if args.build_n1 is None:
        args.build_n1 = args.build_n + 1
    if args.build_n1 <= args.build_n:
        parser.error(f"--build-n1 ({args.build_n1}) must be above --build-n ({args.build_n})")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    missing = [tool for tool in TOOLS if not shutil.which(tool)]
    if sys.platform != "darwin" or missing:
        print(f"release_pair: needs macOS with {', '.join(TOOLS)}; missing: {', '.join(missing) or 'macOS'}",
              file=sys.stderr)
        return 2
    out = args.out.resolve()
    try:
        if args.minisign_dir:
            keys = minisign_keys.existing_or_generate(args.minisign_dir.resolve())
        else:
            keys = minisign_keys.generate(Layout(out).minisign)
        with tempfile.TemporaryDirectory(prefix="release-pair-signing.") as scratch:
            with signing.select(Path(scratch) / "signing") as identity:
                build(out, identity, keys, args.build_n, args.build_n1)
                if identity.throwaway:
                    log("the throwaway signing identity is removed now: N accepts N+1 only while its certificate "
                        f"is trusted, so give {signing.IDENTITY_ENV} a persistent test identity to install it")
    except BuildError as error:
        print(f"release_pair: {error}", file=sys.stderr)
        return 1
    print(Layout(out).manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
