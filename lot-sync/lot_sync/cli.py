"""Command line: `sync` (one pass or daemon) and `relocate` (fix misplaced entries)."""
import argparse
import logging
import shutil
import signal
import threading
import time
from typing import Callable, List, Optional

from .config import DEFAULT_STATE_FILE, FolderLane, LrfLane, SyncConfig
from .executor import Executor, Report
from .folders import plan_folder_sync
from .lrf import plan_lrf_sync
from .rsync import Rsync
from .relocate import plan_relocation
from .state import SyncState

LOG_FORMAT = "%(asctime)s | %(levelname)s | %(message)s"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="lot-sync",
        description="Sync timeslot folders and LRF files into the OutDir share.")
    parser.add_argument("--log-file", help="also write the log to this file")
    parser.add_argument("--error-log-file",
                        help="write errors here too; each problem once, until it goes away")
    parser.add_argument("--verbose", action="store_true", help="log every skipped item")
    commands = parser.add_subparsers(dest="command", required=True)

    sync = commands.add_parser("sync", help="copy new data (one pass or forever)")
    sync.add_argument("--folder-src", help="root holding YYYYMMDD-HHMMSS folders")
    sync.add_argument("--folder-dst", help="destination root for those folders")
    sync.add_argument("--lrf-src", help="root holding .lrf files")
    sync.add_argument("--lrf-dst", help="destination root for .lrf files")
    sync.add_argument("--state-file", default=DEFAULT_STATE_FILE)
    sync.add_argument("--stable-seconds", type=int, default=60,
                      help="ignore data modified within this many seconds (default 60)")
    sync.add_argument("--interval", type=int, default=300,
                      help="seconds between passes when running forever (default 300)")
    sync.add_argument("--once", action="store_true", help="run a single pass and exit")
    sync.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    sync.add_argument("--no-verify", action="store_true", help="skip the rsync verification afterwards")
    sync.add_argument("--rsync", default="rsync", help="rsync binary (default: rsync)")
    sync.add_argument("--rsync-arg", action="append", default=[],
                      help="extra argument passed to every rsync call (repeatable)")

    relocate = commands.add_parser(
        "relocate", help="move entries found in the wrong YYYYMM directory")
    relocate.add_argument("--folder-dst", help="destination root of timeslot folders")
    relocate.add_argument("--lrf-dst", help="destination root of .lrf files")
    mode = relocate.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="list the moves, change nothing")
    mode.add_argument("--apply", action="store_true", help="really move")
    return parser


def configure_logging(log_file: Optional[str], error_log_file: Optional[str],
                      verbose: bool) -> None:
    handlers: List[logging.Handler] = [logging.StreamHandler()]
    if log_file:
        handlers.append(logging.FileHandler(log_file))
    if error_log_file:
        error_handler = logging.FileHandler(error_log_file)
        error_handler.setLevel(logging.ERROR)
        handlers.append(error_handler)
    logging.basicConfig(level=logging.DEBUG if verbose else logging.INFO,
                        format=LOG_FORMAT, handlers=handlers)


def sync_config_from(args: argparse.Namespace, parser: argparse.ArgumentParser) -> SyncConfig:
    folder_lane = _lane(parser, FolderLane, args.folder_src, args.folder_dst)
    lrf_lane = _lane(parser, LrfLane, args.lrf_src, args.lrf_dst)
    if folder_lane is None and lrf_lane is None:
        parser.error("give --folder-src/--folder-dst and/or --lrf-src/--lrf-dst")
    if folder_lane and not args.dry_run and shutil.which(args.rsync) is None:
        parser.error("rsync not found: {}".format(args.rsync))
    return SyncConfig(
        folder_lane=folder_lane, lrf_lane=lrf_lane, state_file=args.state_file,
        stable_seconds=args.stable_seconds, verify=not args.no_verify,
        dry_run=args.dry_run, rsync_binary=args.rsync,
        rsync_args=tuple(args.rsync_arg))


def _lane(parser: argparse.ArgumentParser, lane_type, *paths: Optional[str]):
    if not any(paths):
        return None
    if not all(paths):
        parser.error("incomplete options for {}".format(lane_type.__name__))
    return lane_type(*paths)


def run_sync_pass(config: SyncConfig, state: SyncState, rsync: Rsync) -> Report:
    now = time.time()
    actions = []
    if config.folder_lane:
        actions += plan_folder_sync(config.folder_lane, state, config.stable_seconds, now)
    if config.lrf_lane:
        actions += plan_lrf_sync(config.lrf_lane, config.stable_seconds, now)
    executor = Executor(config.dry_run, rsync, state, config.verify)
    report = executor.run(actions)
    logging.info("PASS | %s", report.summary(config.dry_run))
    return report


def run_sync(config: SyncConfig, once: bool, interval: int) -> int:
    state = SyncState.load(config.state_file)
    rsync = Rsync(config.rsync_binary, config.rsync_args)
    if once or config.dry_run:
        return 0 if run_sync_pass(config, state, rsync).ok else 1
    _repeat(lambda: run_sync_pass(config, state, rsync), interval)
    return 0


def _repeat(action: Callable[[], object], interval: int) -> None:
    stop = threading.Event()
    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, lambda *_: stop.set())
    while not stop.is_set():
        action()
        stop.wait(interval)


def run_relocate(args: argparse.Namespace, parser: argparse.ArgumentParser) -> int:
    if not args.folder_dst and not args.lrf_dst:
        parser.error("give --folder-dst and/or --lrf-dst")
    report = Executor(dry_run=args.dry_run).run(
        plan_relocation(args.folder_dst, args.lrf_dst))
    logging.info("RELOCATE | %s", report.summary(args.dry_run))
    return 0 if report.ok else 1


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    configure_logging(args.log_file, args.error_log_file, args.verbose)
    if args.command == "relocate":
        return run_relocate(args, parser)
    return run_sync(sync_config_from(args, parser), args.once, args.interval)
