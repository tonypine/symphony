"""Running commands and logging for the release helpers."""

import subprocess
import time


class BuildError(Exception):
    """A step of the release build failed; the message says which and why."""


def log(message):
    print(f"[release-pair {time.strftime('%H:%M:%S')}] {message}", flush=True)


def run(args, cwd=None, env=None, check=True, capture=True):
    """Runs `args`; with `check`, raises BuildError with the output's tail when it exits non-zero."""
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
        raise BuildError(f"{' '.join(str(a) for a in args)} exited {result.returncode}:\n{output}")
    return result
