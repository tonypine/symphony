"""The release pair's layout step and options, on made-up inputs: nothing is built or signed."""

import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SUPPORT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SUPPORT))

from macos_release import minisign_keys, release_pair  # noqa: E402
from macos_release._run import BuildError  # noqa: E402

BUILD_N, BUILD_N1 = 90001, 90002
COMMIT = "0123456789abcdef0123456789abcdef01234567"
SHA1 = "A" * 40
ZIP = "Symphony-0.0.1.90002.zip"


def made_up_inputs(scratch, root):
    """What the build hands the layout step: app N, N+1 as package.sh packages it, and the minisign keys."""
    app = scratch / "build-90001" / "Symphony.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Info.plist").write_text("<plist>90001</plist>\n")
    (app / "Contents" / "MacOS" / "SymphonyBar").write_bytes(b"\xcf\xfa\xed\xfe app")
    packaged = scratch / "package"
    packaged.mkdir()
    (packaged / ZIP).write_bytes(b"zip of 90002")
    (packaged / f"{ZIP}.sha256").write_text(f"{'b' * 64}  {ZIP}\n")
    (packaged / f"{ZIP}.minisig").write_text("untrusted comment: signature\nRWsig\n")
    (packaged / "release_notes.md").write_text("2 changes:\n\n- a\n- b\n")
    (packaged / "version.json").write_text(json.dumps({
        "version": "0.0.1.90002", "build": BUILD_N1, "sha256": "b" * 64, "commit": COMMIT,
        "published_at": "2026-10-16T09:41:07Z", "signed": True, "zip": ZIP, "minisig": f"{ZIP}.minisig",
        "changes": 2,
    }, indent=2) + "\n")
    keys = minisign_keys.KeyPair(release_pair.Layout(root).minisign)
    keys.folder.mkdir(parents=True, exist_ok=True)
    keys.public_file.write_text("untrusted comment: minisign public key\nRWTESTPUBLICKEY\n")
    keys.secret_file.write_text("untrusted comment: minisign secret key\nRWTESTSECRETKEY\n")
    return app, packaged, keys


def lay_out(root, scratch):
    app, packaged, keys = made_up_inputs(scratch, root)
    return release_pair.lay_out(
        root, app_n=app, packaged=packaged, commit=COMMIT, published_at=release_pair.utc(1_760_000_000),
        build_n=BUILD_N, build_n1=BUILD_N1, identity_sha1=SHA1, keys=keys,
    )


def snapshot(root):
    """Every file under `root`: its path relative to `root` and its bytes."""
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in sorted(root.rglob("*")) if path.is_file()
    }


class LayoutTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = self.tmp / "release-pair"

    def test_writes_the_documented_layout_and_the_manifest_names_every_file(self):
        manifest = lay_out(self.root, self.tmp / "scratch")
        self.assertEqual(json.loads((self.root / "manifest.json").read_text()), manifest)
        self.assertEqual(manifest, {
            "commit": COMMIT,
            "signing_identity": SHA1,
            "minisign": {
                "public_key": "RWTESTPUBLICKEY",
                "public_key_file": "minisign/minisign.pub",
                "secret_key_file": "minisign/minisign.key",
            },
            "n": {"version": "0.0.1.90001", "build": BUILD_N, "app": "N/Symphony.app"},
            "n1": {
                "version": "0.0.1.90002",
                "build": BUILD_N1,
                "tag": "v0.0.1.90002-release-pair",
                "feed": "feed",
                "zip": f"feed/{ZIP}",
                "sha256": f"feed/{ZIP}.sha256",
                "minisig": f"feed/{ZIP}.minisig",
                "version_json": "feed/version.json",
                "release_notes": "feed/release_notes.md",
            },
        })
        self.assertTrue((self.root / "N" / "Symphony.app" / "Contents" / "Info.plist").is_file())

        named = {"manifest.json", manifest["n"]["app"], *manifest["minisign"].values(),
                 *(manifest["n1"][key] for key in ("zip", "sha256", "minisig", "version_json", "release_notes"))}
        for path in snapshot(self.root):
            self.assertTrue(path in named or path.startswith(manifest["n"]["app"] + "/"),
                            f"manifest.json doesn't name {path}")
        for path in named - {"RWTESTPUBLICKEY"}:
            self.assertTrue((self.root / path).exists(), f"manifest.json names {path}, which doesn't exist")

    def test_version_json_carries_the_given_publication_time(self):
        lay_out(self.root, self.tmp / "scratch")
        info = json.loads((self.root / "feed" / "version.json").read_text())
        self.assertEqual(info["published_at"], "2025-10-09T08:53:20Z")
        self.assertEqual((info["version"], info["build"], info["zip"]), ("0.0.1.90002", BUILD_N1, ZIP))

    def test_the_same_inputs_give_the_same_paths_version_json_and_manifest(self):
        lay_out(self.root, self.tmp / "first")
        first = snapshot(self.root)
        # A second run over the first one's output, and one into another folder.
        lay_out(self.root, self.tmp / "second")
        self.assertEqual(snapshot(self.root), first)
        other = self.tmp / "elsewhere" / "release-pair"
        lay_out(other, self.tmp / "third")
        self.assertEqual(snapshot(other), first)

    def test_a_second_run_leaves_nothing_of_the_first_in_n_and_feed(self):
        lay_out(self.root, self.tmp / "first")
        (self.root / "feed" / "stale.zip").write_text("old")
        (self.root / "N" / "Old.app").mkdir()
        lay_out(self.root, self.tmp / "second")
        self.assertFalse((self.root / "feed" / "stale.zip").exists())
        self.assertFalse((self.root / "N" / "Old.app").exists())

    def test_refuses_a_package_with_a_missing_asset_or_another_build(self):
        app, packaged, keys = made_up_inputs(self.tmp / "scratch", self.root)
        options = dict(app_n=app, packaged=packaged, commit=COMMIT, published_at="x", build_n=BUILD_N,
                       build_n1=BUILD_N1, identity_sha1=SHA1, keys=keys)
        (packaged / f"{ZIP}.minisig").unlink()
        with self.assertRaisesRegex(BuildError, "minisig"):
            release_pair.lay_out(self.root, **options)
        (packaged / f"{ZIP}.minisig").write_text("sig\n")
        (packaged / "version.json").write_text(json.dumps({"version": "0.0.1.90005", "build": 90005}))
        with self.assertRaisesRegex(BuildError, "names 0.0.1.90005 build 90005, not 0.0.1.90002 build 90002"):
            release_pair.lay_out(self.root, **options)

    def test_keys_outside_the_folder_are_named_by_their_full_path(self):
        app, packaged, _ = made_up_inputs(self.tmp / "scratch", self.root)
        keys = minisign_keys.KeyPair(self.tmp / "keys")
        keys.folder.mkdir()
        keys.public_file.write_text("comment\nRWOTHER\n")
        keys.secret_file.write_text("secret\n")
        manifest = release_pair.lay_out(self.root, app_n=app, packaged=packaged, commit=COMMIT, published_at="x",
                                        build_n=BUILD_N, build_n1=BUILD_N1, identity_sha1=SHA1, keys=keys)
        self.assertEqual(manifest["minisign"]["public_key_file"], str(keys.public_file))
        self.assertEqual(manifest["minisign"]["public_key"], "RWOTHER")


class OptionsTest(unittest.TestCase):
    def test_build_numbers_default_to_90001_and_90002(self):
        args = release_pair.parse_args([], env={})
        self.assertEqual((args.build_n, args.build_n1, args.out), (90001, 90002, release_pair.DEFAULT_OUT))
        self.assertEqual(release_pair.DEFAULT_OUT, SUPPORT.parents[1] / "macos" / "build" / "release-pair")

    def test_build_numbers_are_overridable(self):
        self.assertEqual(release_pair.parse_args(["--build-n", "5"], env={}).build_n1, 6)
        args = release_pair.parse_args(["--build-n", "5", "--build-n1", "9"], env={})
        self.assertEqual((args.build_n, args.build_n1), (5, 9))
        self.assertEqual(release_pair.parse_args([], env={"SYMPHONY_E2E_BUILD_N": "70001"}).build_n1, 70002)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            release_pair.parse_args(["--build-n", "5", "--build-n1", "5"], env={})

    def test_build_refuses_n1_at_or_below_n(self):
        with self.assertRaisesRegex(BuildError, "must be above"):
            release_pair.build(Path(tempfile.gettempdir()) / "unused", identity=None, keys=None, build_n=5,
                               build_n1=4, env={})

    def test_versions_and_tag(self):
        self.assertEqual(release_pair.version(90001), "0.0.1.90001")
        self.assertEqual(release_pair.tag(90002), "v0.0.1.90002-release-pair")

    def test_the_minisign_public_key_is_the_second_line(self):
        with tempfile.TemporaryDirectory() as folder:
            keys = minisign_keys.KeyPair(folder)
            self.assertFalse(keys.exists())
            keys.public_file.write_text("untrusted comment: x\n")
            keys.secret_file.write_text("s\n")
            self.assertTrue(keys.exists())
            with self.assertRaises(BuildError):
                keys.public_key
            # An existing pair is used as it is, without minisign.
            self.assertEqual(minisign_keys.existing_or_generate(folder).secret_key, "s\n")


if __name__ == "__main__":
    unittest.main()
