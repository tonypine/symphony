"""The throwaway minisign key pair the release pair's update is signed with: never Symphony's release key."""

from pathlib import Path

from macos_release._run import BuildError, run

PUBLIC = "minisign.pub"
SECRET = "minisign.key"


class KeyPair:
    def __init__(self, folder):
        self.folder = Path(folder)
        self.public_file = self.folder / PUBLIC
        self.secret_file = self.folder / SECRET

    @property
    def public_key(self):
        """The key line of minisign.pub, which the app's Info.plist carries."""
        lines = self.public_file.read_text().splitlines()
        if len(lines) < 2 or not lines[1].strip():
            raise BuildError(f"{self.public_file} has no key line")
        return lines[1].strip()

    @property
    def secret_key(self):
        return self.secret_file.read_text()

    def exists(self):
        return self.public_file.is_file() and self.secret_file.is_file()


def generate(folder):
    """A new password-less key pair in `folder`."""
    keys = KeyPair(folder)
    keys.folder.mkdir(parents=True, exist_ok=True)
    run(["minisign", "-G", "-W", "-f", "-p", keys.public_file, "-s", keys.secret_file])
    return keys


def existing_or_generate(folder):
    """The key pair in `folder` when there is one, else a new one there."""
    keys = KeyPair(folder)
    return keys if keys.exists() else generate(folder)
