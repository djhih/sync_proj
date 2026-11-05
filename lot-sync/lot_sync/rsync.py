"""Thin wrapper around the rsync CLI; all other modules stay engine-agnostic."""
import subprocess
from typing import Callable, List, Sequence

_STDERR_TAIL_CHARS = 500
# -u: never replace a destination file that is newer than the source. Never --delete.
_BASE_FLAGS = ["-a", "-u", "--no-owner", "--no-group"]


class RsyncError(Exception):
    pass


class Rsync:
    def __init__(self, binary: str = "rsync", extra_args: Sequence[str] = (),
                 runner: Callable = subprocess.run):
        self._binary = binary
        self._extra_args = list(extra_args)
        self._runner = runner

    def copy_tree(self, src: str, dst: str) -> None:
        """Copy new and changed files into `dst`; never deletes anything."""
        self._run(_BASE_FLAGS + [_as_dir(src), _as_dir(dst)])

    def verify_tree(self, src: str, dst: str) -> None:
        """Fail if a dry run would still transfer any file (missing or size differs)."""
        output = self._run(["-rn", "-u", "--size-only", "--itemize-changes",
                            _as_dir(src), _as_dir(dst)])
        pending = [line for line in output.splitlines() if line.startswith(">f")]
        if pending:
            raise RsyncError("verify: {} file(s) differ, first: {}".format(
                len(pending), pending[0]))

    def _run(self, args: List[str]) -> str:
        command = [self._binary] + self._extra_args + args
        result = self._runner(command, capture_output=True, text=True)
        if result.returncode != 0:
            tail = (result.stderr or "").strip()[-_STDERR_TAIL_CHARS:]
            raise RsyncError("rsync exited {}: {}".format(result.returncode, tail))
        return result.stdout or ""


def _as_dir(path: str) -> str:
    """rsync copies the *contents* of a source only when it ends with a slash."""
    return path.rstrip("/") + "/"
