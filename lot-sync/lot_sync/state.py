"""Remembers which lot folders were copied completely, and which problems were reported."""
import json
import logging
import os
from dataclasses import asdict, dataclass
from typing import Dict, Optional, Set

from .scan import TreeSignature


@dataclass(frozen=True)
class Completed:
    source: str  # the one source folder this lot-id was synced from
    signature: TreeSignature


class SyncState:
    """`done` is keyed by destination path, i.e. by lot-id: a lot-id has exactly one owner.

    `reported` holds the problems already written to the error log; they are not
    written again until they have gone away and come back.
    """

    def __init__(self, path: str, done: Dict[str, Completed], reported: Set[str]):
        self._path = path
        self._done = done
        self.reported = reported

    @classmethod
    def empty(cls, path: str) -> "SyncState":
        return cls(path, {}, set())

    @classmethod
    def load(cls, path: str) -> "SyncState":
        try:
            with open(path) as handle:
                raw = json.load(handle)
            done = {
                destination: Completed(value["source"], TreeSignature(
                    value["files"], value["bytes"], value["newest_mtime"]))
                for destination, value in raw["done"].items()}
            return cls(path, done, set(raw["reported"]))
        except FileNotFoundError:
            return cls.empty(path)
        except (ValueError, TypeError, KeyError, OSError) as error:
            # Safe to start empty: copying again is idempotent, only slower.
            logging.warning("STATE UNREADABLE | %s: %s; starting empty", path, error)
            return cls.empty(path)

    def record_for(self, destination: str) -> Optional[Completed]:
        return self._done.get(destination)

    def mark_done(self, destination: str, source: str, signature: TreeSignature) -> None:
        self._done[destination] = Completed(source, signature)

    def save(self) -> None:
        os.makedirs(os.path.dirname(self._path) or ".", exist_ok=True)
        temporary = self._path + ".tmp"
        with open(temporary, "w") as handle:
            json.dump({
                "done": {destination: dict(source=done.source, **asdict(done.signature))
                         for destination, done in self._done.items()},
                "reported": sorted(self.reported)}, handle)
        os.replace(temporary, self._path)
