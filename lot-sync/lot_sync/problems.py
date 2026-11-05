"""Error-log discipline: each problem is written once, not on every pass."""
import logging
from typing import Set


class ProblemLog:
    def __init__(self, already_reported: Set[str], repeat_all: bool = False):
        self._already_reported = already_reported
        self._repeat_all = repeat_all
        self.current: Set[str] = set()

    def report(self, key: str, message: str) -> None:
        """Log `message` as an error unless this problem was already reported."""
        self.current.add(key)
        if self._repeat_all or key not in self._already_reported:
            logging.error("%s", message)
