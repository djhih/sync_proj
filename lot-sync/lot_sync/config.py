from dataclasses import dataclass
from typing import Optional, Tuple

DEFAULT_STATE_FILE = "/var/lib/lot-sync/state.json"


@dataclass(frozen=True)
class FolderLane:
    src_root: str
    dst_root: str


@dataclass(frozen=True)
class LrfLane:
    src_root: str
    dst_root: str
    fallback_dirs: Tuple[str, ...] = ()  # sources under these names lose to a same-named file elsewhere


@dataclass(frozen=True)
class SyncConfig:
    folder_lane: Optional[FolderLane]
    lrf_lane: Optional[LrfLane]
    state_file: str = DEFAULT_STATE_FILE
    stable_seconds: int = 60
    verify: bool = True
    dry_run: bool = False
    rsync_binary: str = "rsync"
    rsync_args: Tuple[str, ...] = ()
