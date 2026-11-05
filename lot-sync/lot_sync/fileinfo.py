"""Comparing a source file with the copy that already sits at the destination."""
from dataclasses import dataclass
from datetime import datetime

MTIME_TOLERANCE_SECONDS = 2  # SMB timestamps can be coarser than the source's


@dataclass(frozen=True)
class FileInfo:
    size: int
    mtime: float


def is_same_file(first: FileInfo, second: FileInfo) -> bool:
    return first.size == second.size and abs(first.mtime - second.mtime) <= MTIME_TOLERANCE_SECONDS


def is_newer(candidate: FileInfo, other: FileInfo) -> bool:
    return candidate.mtime - other.mtime > MTIME_TOLERANCE_SECONDS


def is_replacement(source: FileInfo, destination: FileInfo) -> bool:
    """True if copying `source` over `destination` changes it (rsync -u semantics)."""
    return not is_same_file(source, destination) and not is_newer(destination, source)


def describe_replacement(path: str, old: FileInfo, new: FileInfo) -> str:
    return "{}: {} B @ {} -> {} B @ {}".format(
        path, old.size, _stamp(old.mtime), new.size, _stamp(new.mtime))


def _stamp(mtime: float) -> str:
    return datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
