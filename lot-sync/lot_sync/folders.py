"""Plan the sync of lot folders: <src>/**/<lot-id> -> <dst>/YYYYMM/<lot-id>.

A lot-id is a folder named ...YYYYMMDD-HHMMSS. Wherever it sits under the
source (any number of PE layers, any sendout_* date), only its own name is used:
the month comes from the lot-id and no parent path is carried over.

A lot-id must be unique. If the same one shows up twice, or shows up from a
different source than the one already synced, nothing is copied and a
DUPLICATE action is planned so that a person can look into it.

What already sits at the destination (left by the old program, or copied from
an earlier version of this source) is brought up to date: differing files are
replaced by the source's newer ones, and every replacement is listed in the action.
Files only the destination has are left alone.
"""
import os
from collections import defaultdict
from typing import Dict, List, Optional, Tuple

from .config import FolderLane
from .plan import Action, Kind
from .fileinfo import describe_replacement, is_replacement
from .scan import ScanError, file_infos, find_timeslot_dirs, measure_tree
from .state import SyncState
from .timeslot import month_of_timeslot


def plan_folder_sync(lane: FolderLane, state: SyncState,
                     stable_seconds: int, now: float) -> List[Action]:
    try:
        sources = find_timeslot_dirs(lane.src_root)
    except ScanError as error:
        return [Action(Kind.ERROR, lane.src_root, reason=str(error))]

    destinations = {src: _destination_of(lane, src) for src in sources}
    claimants: Dict[str, List[str]] = defaultdict(list)
    for src, destination in destinations.items():
        if destination:
            claimants[destination].append(src)

    return [
        _plan_one(src, destinations[src], _others(claimants, destinations[src], src),
                  state, stable_seconds, now)
        for src in sources
    ]


def _destination_of(lane: FolderLane, src: str) -> Optional[str]:
    lot_id = os.path.basename(src)
    month = month_of_timeslot(lot_id)
    return os.path.join(lane.dst_root, month, lot_id) if month else None


def _others(claimants: Dict[str, List[str]], destination: Optional[str], src: str) -> List[str]:
    return [other for other in claimants.get(destination, ()) if other != src]


def _plan_one(src: str, destination: Optional[str], other_sources: List[str],
              state: SyncState, stable_seconds: int, now: float) -> Action:
    if destination is None:
        return Action(Kind.SKIP, src, reason="cannot derive a month from the folder name")
    if other_sources:
        return Action(Kind.DUPLICATE, src, destination,
                      "lot-id also found at: " + ", ".join(other_sources))

    record = state.record_for(destination)
    if record and record.source != src:
        return Action(Kind.DUPLICATE, src, destination,
                      "lot-id already synced from: " + record.source)

    try:
        signature = measure_tree(src)
    except ScanError as error:
        return Action(Kind.ERROR, src, destination, str(error))

    if signature.files == 0:
        return Action(Kind.SKIP, src, destination, "no files yet")
    if now - signature.newest_mtime < stable_seconds:
        return Action(Kind.SKIP, src, destination, "still being written")
    if record and record.signature == signature:
        return Action(Kind.UP_TO_DATE, src, destination)
    return _plan_copy(src, destination, signature)


def _plan_copy(src: str, destination: str, signature) -> Action:
    try:
        notes = _replacements(src, destination)
    except ScanError as error:
        return Action(Kind.ERROR, src, destination, str(error))
    return Action(Kind.COPY_TREE, src, destination, signature=signature, notes=notes)


def _replacements(src: str, destination: str) -> Tuple[str, ...]:
    """The destination files that copying `src` will overwrite."""
    if not os.path.isdir(destination):
        return ()
    wanted = file_infos(src)
    present = file_infos(destination)
    return tuple(
        describe_replacement(os.path.join(destination, path), present[path], wanted[path])
        for path in sorted(present)
        if path in wanted and is_replacement(wanted[path], present[path])
    )
