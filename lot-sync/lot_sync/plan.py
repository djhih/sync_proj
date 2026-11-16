"""A plan is a list of Actions. Planning is read-only; executing is separate."""
from dataclasses import dataclass
from enum import Enum
from typing import Optional, Tuple

from .scan import TreeSignature

UNDATED_LRF = "cannot derive a date from the file name"
MISSING_DESTINATION = "destination root does not exist; is the share mounted?"
# ERROR reasons that describe the data, not a failure to read or write it. They wait
# for a person and do not make a pass count as failed (see cli.exit_code).
DATA_PROBLEMS = frozenset({UNDATED_LRF})


class Kind(Enum):
    COPY_TREE = "COPY_TREE"
    COPY_FILE = "COPY_FILE"
    MOVE = "MOVE"
    SKIP = "SKIP"
    UP_TO_DATE = "UP_TO_DATE"
    DUPLICATE = "DUPLICATE"  # same lot-id from two sources: alert a human, copy nothing
    ERROR = "ERROR"


@dataclass(frozen=True)
class Action:
    kind: Kind
    src: str
    dst: Optional[str] = None
    reason: str = ""
    signature: Optional[TreeSignature] = None  # COPY_TREE: what was measured when planned
    notes: Tuple[str, ...] = ()  # destination files this action will overwrite

    def problem_key(self) -> str:
        """Identifies a problem across passes, so it is reported once, not every pass."""
        return "{}|{}|{}".format(self.kind.value, self.src, self.reason)

    def describe(self) -> str:
        target = " -> {}".format(self.dst) if self.dst else ""
        note = "  ({})".format(self.reason) if self.reason else ""
        return "{:<10} {}{}{}".format(self.kind.value, self.src, target, note)
