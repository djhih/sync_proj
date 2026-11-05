"""Plan moves of misplaced entries inside the destination to their correct month.

Timeslot folders belong in the month named by their own name; LRF files belong
in the month written in their name. Entries sitting directly under the root (outside
any YYYYMM directory) are treated as misplaced too.
"""
import os
from typing import Callable, List, Optional, Set, Tuple

from .plan import Action, Kind
from .scan import ScanError, is_lrf_name, list_dir, month_dirs
from .timeslot import is_timeslot_name, month_of_lrf_name, month_of_timeslot

# (path) -> month the entry belongs in, or None if it cannot be decided
MonthRule = Callable[[str], Optional[str]]
Candidate = Callable[[str], bool]


def plan_relocation(folder_dst: Optional[str], lrf_dst: Optional[str]) -> List[Action]:
    actions: List[Action] = []
    if folder_dst:
        actions += _plan_root(folder_dst, _is_timeslot_dir,
                              lambda path: month_of_timeslot(os.path.basename(path)))
    if lrf_dst:
        actions += _plan_root(lrf_dst, _is_lrf_file,
                              lambda path: month_of_lrf_name(os.path.basename(path)))
    return actions


def _is_timeslot_dir(path: str) -> bool:
    return os.path.isdir(path) and is_timeslot_name(os.path.basename(path))


def _is_lrf_file(path: str) -> bool:
    return os.path.isfile(path) and is_lrf_name(os.path.basename(path))


def _plan_root(root: str, is_candidate: Candidate, month_rule: MonthRule) -> List[Action]:
    try:
        containers: List[Tuple[Optional[str], str]] = [(None, root)] + month_dirs(root)
        claimed: Set[str] = set()
        actions: List[Action] = []
        for current_month, container in containers:
            for name in list_dir(container):
                path = os.path.join(container, name)
                if is_candidate(path):
                    action = _plan_entry(root, path, current_month, month_rule, claimed)
                    if action:
                        actions.append(action)
        return actions
    except ScanError as error:
        return [Action(Kind.ERROR, root, reason=str(error))]


def _plan_entry(root: str, path: str, current_month: Optional[str],
                month_rule: MonthRule, claimed: Set[str]) -> Optional[Action]:
    expected = month_rule(path)
    if expected is None:
        return Action(Kind.SKIP, path, reason="cannot decide the correct month")
    if expected == current_month:
        return None

    target = os.path.join(root, expected, os.path.basename(path))
    reason = "belongs in {}, found in {}".format(expected, current_month or "root")
    if os.path.lexists(target) or target in claimed:
        return Action(Kind.SKIP, path, target, "target already exists; " + reason)
    claimed.add(target)
    return Action(Kind.MOVE, path, target, reason)
