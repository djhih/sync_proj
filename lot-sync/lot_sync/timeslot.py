"""Month rules: which YYYYMM directory a lot folder or an LRF file belongs in.

Only the date written in the name counts. The sendout_YYYYMMDD folder it was
delivered in, and the time of copying, are irrelevant.
"""
import re
from datetime import datetime
from typing import Optional

_TIMESLOT_SUFFIX = re.compile(r"(\d{8})-\d{6}$")
# e.g. LOTAAAA0001-20260911-172530.lrf, ..._filtered.lrf, ..._pub.lrf
_LRF_NAME = re.compile(r"(\d{8})-\d{6}(?:_[A-Za-z0-9]+)*\.lrf$", re.IGNORECASE)
_MONTH_DIR = re.compile(r"^\d{6}$")


def is_timeslot_name(name: str) -> bool:
    """True for names ending in YYYYMMDD-HHMMSS, e.g. 'LOTC-20261103-112600'."""
    return _TIMESLOT_SUFFIX.search(name) is not None


def is_month_dir_name(name: str) -> bool:
    return _MONTH_DIR.match(name) is not None


def month_of_timeslot(name: str) -> Optional[str]:
    """'YYYYMM' of a lot folder name, or None if it holds no real date."""
    return _month_of_match(_TIMESLOT_SUFFIX.search(name))


def month_of_lrf_name(name: str) -> Optional[str]:
    """'YYYYMM' of an LRF file name, or None if it holds no real date."""
    return _month_of_match(_LRF_NAME.search(name))


def _month_of_match(match: Optional["re.Match"]) -> Optional[str]:
    if match is None:
        return None
    try:
        return datetime.strptime(match.group(1), "%Y%m%d").strftime("%Y%m")
    except ValueError:
        return None
