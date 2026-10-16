"""Which code-signing identity the release pair is signed with, from the environment. Nothing is signed."""

import sys
import tempfile
import unittest
from pathlib import Path

SUPPORT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SUPPORT))

from macos_release import signing  # noqa: E402
from macos_release._run import BuildError  # noqa: E402


class SelectTest(unittest.TestCase):
    def setUp(self):
        self.created = []
        self.folder = Path(tempfile.gettempdir()) / "signing-test-unused"

    def create(self, folder, trust):
        self.created.append((folder, trust))
        return signing.Identity("THROWAWAY", throwaway=True)

    def test_a_given_identity_is_used_without_making_one(self):
        identity = signing.select(self.folder, {signing.IDENTITY_ENV: "QA Test Signing"}, create=self.create)
        self.assertEqual((identity.identity, identity.flags, identity.throwaway), ("QA Test Signing", [], False))
        self.assertEqual(self.created, [])

    def test_a_given_keychain_goes_to_codesign(self):
        env = {signing.IDENTITY_ENV: "QA Test Signing", signing.KEYCHAIN_ENV: "/tmp/qa.keychain-db"}
        identity = signing.select(self.folder, env, create=self.create)
        self.assertEqual(identity.flags, ["--keychain", "/tmp/qa.keychain-db"])

    def test_without_one_a_throwaway_identity_is_made_in_the_folder(self):
        identity = signing.select(self.folder, {}, create=self.create)
        self.assertEqual(identity.identity, "THROWAWAY")
        self.assertEqual(self.created, [(self.folder, False)])

    def test_trust_cert_asks_the_throwaway_identity_to_be_trusted(self):
        signing.select(self.folder, {signing.TRUST_ENV: "1"}, create=self.create)
        signing.select(self.folder, {signing.TRUST_ENV: "yes"}, create=self.create)
        self.assertEqual([trust for _, trust in self.created], [True, False])

    def test_an_empty_identity_counts_as_none(self):
        signing.select(self.folder, {signing.IDENTITY_ENV: "", signing.KEYCHAIN_ENV: "/x"}, create=self.create)
        self.assertEqual(len(self.created), 1)

    def test_a_given_identity_is_a_context_that_cleans_nothing_up(self):
        with signing.Identity("QA") as identity:
            self.assertEqual(identity.identity, "QA")


class Sha1Test(unittest.TestCase):
    def test_a_sha1_is_used_as_given(self):
        identity = signing.Identity("ab" * 20)
        self.assertEqual(identity.sha1(find=self.fail), "AB" * 20)

    def test_a_name_is_looked_up_in_its_keychain(self):
        looked_up = []

        def find(keychain):
            looked_up.append(keychain)
            return [("1" * 40, "Other"), ("2" * 40, "QA Test Signing")]

        identity = signing.Identity("QA Test Signing", keychain="/tmp/qa.keychain-db")
        self.assertEqual(identity.sha1(find=find), "2" * 40)
        self.assertEqual(looked_up, ["/tmp/qa.keychain-db"])

    def test_a_name_found_none_or_twice_is_refused(self):
        identity = signing.Identity("QA Test Signing")
        with self.assertRaisesRegex(BuildError, "0 code-signing identities"):
            identity.sha1(find=lambda _: [])
        twice = [("1" * 40, "QA Test Signing"), ("2" * 40, "QA Test Signing")]
        with self.assertRaisesRegex(BuildError, "2 code-signing identities"):
            identity.sha1(find=lambda _: twice)


if __name__ == "__main__":
    unittest.main()
