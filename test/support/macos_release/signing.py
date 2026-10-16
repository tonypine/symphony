"""The code-signing identity both releases are signed with: given, or a throwaway self-signed one.

Only test identities: the given one comes from the environment, and the throwaway one lives in a temporary keychain
for one build or test run. Never the release key or Symphony's signing certificate.

  SYMPHONY_E2E_SIGNING_IDENTITY  sign with this identity (a name or its SHA-1) instead of a throwaway one
  SYMPHONY_E2E_KEYCHAIN          the keychain that holds it, when it isn't in the search list
  SYMPHONY_E2E_TRUST_CERT=1      trust the throwaway certificate for code signing until cleanup (uses sudo)
"""

import os
import re
import secrets
import shutil
from pathlib import Path

from macos_release._run import BuildError, log, run

IDENTITY_ENV = "SYMPHONY_E2E_SIGNING_IDENTITY"
KEYCHAIN_ENV = "SYMPHONY_E2E_KEYCHAIN"
TRUST_ENV = "SYMPHONY_E2E_TRUST_CERT"
SHA1 = re.compile(r"[0-9A-Fa-f]{40}")
OPENSSL = "/usr/bin/openssl"


def find_identities(keychain=None):
    """(SHA-1, name) of every code-signing identity in `keychain`, or in the search list."""
    output = run(["security", "find-identity", "-p", "codesigning", *([keychain] if keychain else [])]).stdout
    found = []
    for line in output.splitlines():
        match = re.match(r'\s*\d+\) ([0-9A-F]{40}) "(.*)"', line)
        if match:
            found.append((match.group(1), match.group(2)))
    return found


class Identity:
    """A code-signing identity: `identity` for codesign's --sign, `flags` its other options (such as --keychain)."""

    def __init__(self, identity, keychain=None, throwaway=False):
        self.identity = identity
        self.keychain = keychain
        self.throwaway = throwaway

    @property
    def flags(self):
        return ["--keychain", str(self.keychain)] if self.keychain else []

    def sha1(self, find=find_identities):
        """The identity's SHA-1, which the release-pair's manifest records."""
        if SHA1.fullmatch(self.identity):
            return self.identity.upper()
        matches = sorted({sha for sha, name in find(self.keychain) if name == self.identity})
        if len(matches) != 1:
            where = self.keychain or "the keychain search list"
            raise BuildError(f"{len(matches)} code-signing identities named '{self.identity}' in {where}; "
                             f"give {IDENTITY_ENV} as a SHA-1")
        return matches[0]

    def cleanup(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.cleanup()
        return False


def given_identity(env):
    """The identity the environment names, else None."""
    name = env.get(IDENTITY_ENV)
    if not name:
        return None
    return Identity(name, keychain=env.get(KEYCHAIN_ENV) or None)


def trust_requested(env):
    return env.get(TRUST_ENV) == "1"


def select(folder, env=None, create=None):
    """The identity the environment names, else a throwaway one made in `folder` (`create(folder, trust=...)`)."""
    env = os.environ if env is None else env
    identity = given_identity(env)
    if identity:
        log(f"signing with the given identity {identity.identity}")
        return identity
    return (create or ThrowawayIdentity.create)(Path(folder), trust=trust_requested(env))


class ThrowawayIdentity(Identity):
    """A self-signed code-signing identity in a temporary keychain, on the user's search list until `cleanup`."""

    def __init__(self, folder, identity, keychain, certificate, search_list):
        super().__init__(identity, keychain=keychain, throwaway=True)
        self.folder = folder
        self.certificate = certificate
        self.search_list = search_list
        self.trusted = False

    @classmethod
    def create(cls, folder, trust=False):
        folder.mkdir(parents=True)
        password = secrets.token_hex(16)
        name = f"Symphony E2E {secrets.token_hex(4)}"
        config = folder / "cert.cnf"
        config.write_text(
            "[req]\ndistinguished_name = dn\nx509_extensions = ext\nprompt = no\n"
            f"[dn]\nCN = {name}\n"
            "[ext]\nbasicConstraints = critical,CA:false\nkeyUsage = critical,digitalSignature\n"
            "extendedKeyUsage = critical,codeSigning\n"
        )
        key, cert, p12 = folder / "key.pem", folder / "cert.pem", folder / "identity.p12"
        run([OPENSSL, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
             "-days", "2", "-config", config])
        run([OPENSSL, "pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12,
             "-passout", f"pass:{password}", "-name", name])
        keychain = folder / "e2e.keychain-db"
        run(["security", "create-keychain", "-p", password, keychain])
        run(["security", "set-keychain-settings", "-lut", "21600", keychain])
        run(["security", "unlock-keychain", "-p", password, keychain])
        run(["security", "import", p12, "-k", keychain, "-f", "pkcs12", "-P", password, "-T", "/usr/bin/codesign"])
        run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password,
             keychain])
        # codesign only finds an identity in a keychain on the search list, even with --keychain.
        output = run(["security", "list-keychains", "-d", "user"]).stdout
        search_list = [line.strip().strip('"') for line in output.splitlines() if line.strip()]
        run(["security", "list-keychains", "-d", "user", "-s", keychain, *search_list])
        sha = next((sha for sha, found in find_identities(keychain) if found == name), None)
        identity = cls(folder, sha, keychain, cert, search_list)
        if sha is None:
            identity.cleanup()
            raise BuildError(f"the keychain {keychain} has no code-signing identity '{name}'")
        log(f"created the throwaway signing identity '{name}' ({sha}) in {keychain}")
        try:
            identity._check_trust(trust)
        except BaseException:
            identity.cleanup()
            raise
        return identity

    def _check_trust(self, trust):
        """`codesign --verify` needs the certificate trusted for code signing, in the build and in the app."""
        probe = self.folder / "probe"
        shutil.copy("/usr/bin/true", probe)
        run(["codesign", "--force", "--sign", self.identity, *self.flags, probe])
        if run(["codesign", "--verify", "--strict", probe], check=False).returncode == 0:
            return
        if not trust:
            raise BuildError(
                "codesign doesn't trust the throwaway certificate, so the app would refuse the update. Either set "
                f"{IDENTITY_ENV} to a trusted code-signing identity (with {KEYCHAIN_ENV} when it isn't in the "
                f"search list), or set {TRUST_ENV}=1 to trust the throwaway certificate for code signing until "
                "the build or test ends (uses sudo)."
            )
        log("trusting the throwaway certificate for code signing until cleanup")
        run(["sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "codeSign",
             "-k", "/Library/Keychains/System.keychain", self.certificate])
        self.trusted = True
        run(["codesign", "--verify", "--strict", probe])

    def cleanup(self):
        """Untrusts the certificate, takes the keychain off the search list and deletes it."""
        if self.trusted:
            run(["sudo", "-n", "security", "remove-trusted-cert", "-d", self.certificate], check=False)
            self.trusted = False
        if self.search_list is not None:
            run(["security", "list-keychains", "-d", "user", "-s", *self.search_list], check=False)
            self.search_list = None
        if self.keychain and Path(self.keychain).exists():
            run(["security", "delete-keychain", self.keychain], check=False)
