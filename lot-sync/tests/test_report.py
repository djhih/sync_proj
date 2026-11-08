"""tools/report.py must understand the log lines the Executor really writes."""
import csv
import logging
import os
import sys
from contextlib import contextmanager

from lot_sync.cli import LOG_FORMAT
from lot_sync.config import FolderLane, LrfLane
from lot_sync.executor import Executor
from lot_sync.folders import plan_folder_sync
from lot_sync.lrf import plan_lrf_sync
from lot_sync.relocate import plan_relocation
from lot_sync.state import SyncState

from helpers import NOW, OLD, FakeRsync, write

sys.path.insert(0, os.path.join(os.path.dirname(__file__), os.pardir, "tools"))
import report  # noqa: E402


@contextmanager
def logged_to(path):
    """Write INFO and above to `path` in the format the CLI uses."""
    handler = logging.FileHandler(path)
    handler.setFormatter(logging.Formatter(LOG_FORMAT))
    root = logging.getLogger()
    level = root.level
    root.addHandler(handler)
    root.setLevel(logging.INFO)
    try:
        yield
    finally:
        root.removeHandler(handler)
        root.setLevel(level)
        handler.close()


def results(rows):
    return sorted(row[1] for row in rows)


def sync_sources(tmp_path):
    src, dst = tmp_path / "src", tmp_path / "dst"
    write(str(src / "s1" / "20260815-101010" / "a.bin"))                          # new lot
    write(str(src / "s1" / "20260816-101010" / "a.bin"), "longer", mtime=NOW - 600)
    write(str(dst / "202608" / "20260816-101010" / "a.bin"), "x", mtime=OLD)     # older copy
    write(str(src / "s1" / "20260817-101010" / "a.bin"))                          # same lot-id twice
    write(str(src / "s2" / "20260817-101010" / "a.bin"))
    write(str(src / "s1" / "X-20260901-101010.lrf"), "newer", mtime=NOW - 600)
    write(str(dst / "202609" / "X-20260901-101010.lrf"), "old", mtime=OLD)
    write(str(src / "s1" / "summary.lrf"))                                        # no date
    write(str(src / "s1" / "20260818-101010" / "a.bin"), mtime=NOW)              # still being written
    state = SyncState.empty(str(tmp_path / "state.json"))
    plan = (plan_folder_sync(FolderLane(str(src), str(dst)), state, 60, NOW)
            + plan_lrf_sync(LrfLane(str(src), str(dst)), 60, NOW))
    return src, dst, state, plan


def test_a_real_sync_run_becomes_one_row_per_outcome(tmp_path):
    src, dst, state, plan = sync_sources(tmp_path)
    log = str(tmp_path / "run.log")
    with logged_to(log):
        Executor(False, FakeRsync(), state).run(plan)

    rows = report.parse(log)
    assert results(rows) == ["duplicate", "duplicate", "error", "overwrote", "overwrote",
                             "updated", "updated", "updated"]
    by_result = {row[1]: row for row in rows}
    assert by_result["overwrote"][3] == str(src / "s1" / "X-20260901-101010.lrf")
    assert by_result["overwrote"][4] == str(dst / "202609" / "X-20260901-101010.lrf")
    assert " B @ " in by_result["overwrote"][5]
    assert by_result["duplicate"][5].startswith("lot-id also found at: ")
    assert by_result["error"][3:] == [str(src / "s1" / "summary.lrf"), "",
                                      "cannot derive a date from the file name"]


def test_failed_and_interrupted_actions_are_listed(tmp_path):
    write(str(tmp_path / "src" / "20260815-101010" / "a.bin"))
    state = SyncState.empty(str(tmp_path / "state.json"))
    plan = plan_folder_sync(FolderLane(str(tmp_path / "src"), str(tmp_path / "dst")), state, 60, NOW)
    log = str(tmp_path / "run.log")
    with logged_to(log):
        Executor(False, FakeRsync(fail_copy=True), state).run(plan)
    with open(log, "a") as handle:  # a run killed right after starting an action
        handle.write("2026-11-08 03:00:00,000 | INFO | START | COPY_TREE  /s/20260819-101010"
                     " -> /d/202608/20260819-101010\n")

    rows = report.parse(log)
    assert results(rows) == ["failed", "unfinished"]
    failed = [row for row in rows if row[1] == "failed"][0]
    assert failed[2:5] == ["COPY_TREE", plan[0].src, plan[0].dst]
    assert "boom" in failed[5]


def test_a_dry_run_lists_what_would_happen_and_what_is_skipped(tmp_path):
    _, _, state, plan = sync_sources(tmp_path)
    log = str(tmp_path / "dry.log")
    with logged_to(log):
        Executor(True, None, state).run(plan)

    rows = report.parse(log)
    assert results(rows) == ["duplicate", "duplicate", "error", "skipped", "would-overwrite",
                             "would-overwrite", "would-update", "would-update", "would-update"]
    skipped = [row for row in rows if row[1] == "skipped"][0]
    assert skipped[5] == "still being written"


def test_a_relocation_gives_old_and_new_paths_for_an_undo_list(tmp_path):
    root = tmp_path / "dst"
    write(str(root / "202609" / "X-20260815-101010.lrf"))
    log = str(tmp_path / "relocate.log")
    with logged_to(log):
        Executor(False).run(plan_relocation(None, str(root)))

    [row] = report.parse(log)
    assert row[1:] == ["updated", "MOVE", str(root / "202609" / "X-20260815-101010.lrf"),
                       str(root / "202608" / "X-20260815-101010.lrf"),
                       "belongs in 202608, found in 202609"]


def test_the_tsv_marks_empty_fields_and_has_a_header(tmp_path):
    _, _, state, plan = sync_sources(tmp_path)
    log, out = str(tmp_path / "run.log"), str(tmp_path / "out.tsv")
    with logged_to(log):
        Executor(False, FakeRsync(), state).run(plan)
    report.main(log, out)

    with open(out) as handle:
        table = list(csv.reader(handle, delimiter="\t"))
    assert table[0] == ["time", "result", "kind", "src", "dst", "reason"]
    assert all(len(row) == 6 and "" not in row for row in table)
