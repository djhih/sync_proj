"""Plan the sync of LRF files: <src>/**/*.lrf -> <dst>/YYYYMM/<name>.

The month is the date inside the file name (LOTAAAA0001-20260911-172530_pub.lrf
-> 202609), never the sendout folder it came in or the time of copying.

One name is one file: a newer source replaces the copy already at the destination
(in place, wherever it sits); an older source is left alone.
"""
import os
from dataclasses import dataclass
from typing import Dict, List, Tuple

from .config import LrfLane
from .fileinfo import FileInfo, describe_replacement, is_newer, is_same_file
from .plan import Action, Kind
from .scan import ScanError, find_lrf_files, is_lrf_name, list_dir, month_dirs
from .timeslot import month_of_lrf_name


@dataclass(frozen=True)
class Existing:
    path: str
    info: FileInfo


def plan_lrf_sync(lane: LrfLane, stable_seconds: int, now: float) -> List[Action]:
    try:
        sources = find_lrf_files(lane.src_root)
        existing = index_destination(lane.dst_root)
        newest = _newest_source_by_name(sources)
    except (ScanError, OSError) as error:
        return [Action(Kind.ERROR, lane.src_root, reason=str(error))]
    return [_plan_one(path, lane, existing, newest, stable_seconds, now) for path in sources]


def index_destination(dst_root: str) -> Dict[str, Existing]:
    """The newest copy of every LRF name found in any YYYYMM directory."""
    index: Dict[str, Existing] = {}
    if not os.path.isdir(dst_root):
        return index
    for _, month_path in month_dirs(dst_root):
        for name in list_dir(month_path):
            if not is_lrf_name(name):
                continue
            path = os.path.join(month_path, name)
            stat = os.stat(path)
            info = FileInfo(stat.st_size, stat.st_mtime)
            known = index.get(name)
            if known is None or info.mtime > known.info.mtime:
                index[name] = Existing(path, info)
    return index


def _newest_source_by_name(paths: List[str]) -> Dict[str, str]:
    """When one name is offered by several sources, only the newest one is synced."""
    best: Dict[str, Tuple[float, str]] = {}
    for path in paths:
        try:
            mtime = os.stat(path).st_mtime
        except FileNotFoundError:  # removed while scanning
            continue
        name = os.path.basename(path)
        if name not in best or mtime > best[name][0]:
            best[name] = (mtime, path)
    return {name: path for name, (_, path) in best.items()}


def _plan_one(path: str, lane: LrfLane, existing: Dict[str, Existing],
              newest: Dict[str, str], stable_seconds: int, now: float) -> Action:
    name = os.path.basename(path)
    month = month_of_lrf_name(name)
    if month is None:
        return Action(Kind.ERROR, path, reason="cannot derive a date from the file name")

    try:
        stat = os.stat(path)
    except FileNotFoundError:
        return Action(Kind.SKIP, path, reason="removed while planning")
    except OSError as error:
        return Action(Kind.ERROR, path, reason=str(error))

    source = FileInfo(stat.st_size, stat.st_mtime)
    if now - source.mtime < stable_seconds:
        return Action(Kind.SKIP, path, reason="still being written")
    if newest.get(name) != path:
        return Action(Kind.SKIP, path, reason="a newer source with the same name exists")

    current = existing.get(name)
    if current is None:
        return Action(Kind.COPY_FILE, path, os.path.join(lane.dst_root, month, name))
    if is_same_file(source, current.info):
        return Action(Kind.UP_TO_DATE, path)
    if is_newer(current.info, source):
        return Action(Kind.SKIP, path, current.path, "destination is newer")
    return Action(Kind.COPY_FILE, path, current.path,
                  notes=(describe_replacement(current.path, current.info, source),))
