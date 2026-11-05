"""Read-only filesystem scanning. Unreadable trees raise instead of looking empty."""
import os
from dataclasses import dataclass
from typing import Dict, Iterator, List, Tuple

from .fileinfo import FileInfo
from .timeslot import is_month_dir_name, is_timeslot_name

LRF_SUFFIX = ".lrf"


class ScanError(Exception):
    """A directory could not be listed; the result would be incomplete."""


@dataclass(frozen=True)
class TreeSignature:
    files: int
    bytes: int
    newest_mtime: float


def is_lrf_name(name: str) -> bool:
    return name.lower().endswith(LRF_SUFFIX)


def _raise_scan_error(error: OSError) -> None:
    raise ScanError(str(error)) from error


def _walk(root: str) -> Iterator[Tuple[str, List[str], List[str]]]:
    return os.walk(root, onerror=_raise_scan_error)


def list_dir(path: str) -> List[str]:
    try:
        return sorted(os.listdir(path))
    except OSError as error:
        raise ScanError(str(error)) from error


def find_timeslot_dirs(root: str) -> List[str]:
    """Timeslot folders under `root`; a match is not searched any deeper."""
    found = []
    for current, dirnames, _ in _walk(root):
        for name in list(dirnames):
            if is_timeslot_name(name):
                found.append(os.path.join(current, name))
                dirnames.remove(name)
    return sorted(found)


def find_lrf_files(root: str) -> List[str]:
    found = []
    for current, _, filenames in _walk(root):
        found.extend(os.path.join(current, n) for n in filenames if is_lrf_name(n))
    return sorted(found)


def month_dirs(root: str) -> List[Tuple[str, str]]:
    """(month, path) for every YYYYMM directory directly under `root`."""
    return [
        (name, os.path.join(root, name))
        for name in list_dir(root)
        if is_month_dir_name(name) and os.path.isdir(os.path.join(root, name))
    ]


def _iter_file_stats(root: str) -> Iterator[Tuple[str, os.stat_result]]:
    for current, _, filenames in _walk(root):
        for name in filenames:
            path = os.path.join(current, name)
            try:
                info = os.lstat(path)
            except FileNotFoundError:  # removed while scanning
                continue
            yield path, info


def measure_tree(root: str) -> TreeSignature:
    files = total = 0
    newest = 0.0
    for _, info in _iter_file_stats(root):
        files += 1
        total += info.st_size
        newest = max(newest, info.st_mtime)
    return TreeSignature(files, total, newest)


def file_infos(root: str) -> Dict[str, FileInfo]:
    """Relative path -> size and mtime for every file under `root`."""
    return {os.path.relpath(path, root): FileInfo(info.st_size, info.st_mtime)
            for path, info in _iter_file_stats(root)}
