import logging
import os

from lot_sync.config import FolderLane
from lot_sync.executor import Executor
from lot_sync.folders import plan_folder_sync
from lot_sync.state import SyncState

from helpers import NOW, OLD, FakeRsync, write


def setup(tmp_path):
    write(str(tmp_path / "src" / "20260815-101010" / "a.bin"))
    state = SyncState.empty(str(tmp_path / "state.json"))
    lane = FolderLane(str(tmp_path / "src"), str(tmp_path / "dst"))
    return state, plan_folder_sync(lane, state, 60, NOW)


def test_copy_lands_in_the_right_month_and_is_remembered(tmp_path):
    state, plan = setup(tmp_path)
    report = Executor(False, FakeRsync(), state).run(plan)

    assert report.ok
    assert (tmp_path / "dst" / "202608" / "20260815-101010" / "a.bin").exists()
    assert not list((tmp_path / "dst" / "202608").glob(".*partial"))
    record = SyncState.load(str(tmp_path / "state.json")).record_for(plan[0].dst)
    assert (record.source, record.signature) == (plan[0].src, plan[0].signature)


def test_failed_copy_is_not_remembered_and_leaves_no_final_folder(tmp_path):
    state, plan = setup(tmp_path)
    report = Executor(False, FakeRsync(fail_copy=True), state).run(plan)

    assert report.failed == 1
    assert not os.path.exists(plan[0].dst)
    assert state.record_for(plan[0].dst) is None


def test_dry_run_touches_nothing(tmp_path):
    state, plan = setup(tmp_path)
    rsync = FakeRsync()
    report = Executor(True, rsync, state).run(plan)

    assert report.applied == 1 and rsync.copies == []
    assert not (tmp_path / "dst").exists()
    assert not (tmp_path / "state.json").exists()


def test_existing_destination_is_topped_up_in_place(tmp_path):
    state, plan = setup(tmp_path)
    os.makedirs(plan[0].dst)  # e.g. an empty folder left by the old program
    rsync = FakeRsync()
    Executor(False, rsync, state).run(plan)

    assert rsync.copies == [(plan[0].src, plan[0].dst)]
    assert os.path.exists(os.path.join(plan[0].dst, "a.bin"))


def test_duplicate_is_reported_and_makes_the_run_not_ok(tmp_path):
    write(str(tmp_path / "src" / "sendout_1" / "20261030-120000" / "a.bin"))
    write(str(tmp_path / "src" / "sendout_2" / "20261030-120000" / "a.bin"))
    state = SyncState.empty(str(tmp_path / "state.json"))
    lane = FolderLane(str(tmp_path / "src"), str(tmp_path / "dst"))
    rsync = FakeRsync()

    report = Executor(False, rsync, state).run(plan_folder_sync(lane, state, 60, NOW))

    assert report.duplicates == 2 and not report.ok
    assert rsync.copies == [] and not (tmp_path / "dst").exists()


def errors(caplog):
    return [r for r in caplog.records if r.levelno >= logging.ERROR]


def test_overwrites_are_logged_before_and_in_dry_run(tmp_path, caplog):
    caplog.set_level(logging.INFO)
    state, plan = setup(tmp_path)
    write(str(tmp_path / "dst" / "202608" / "20260815-101010" / "a.bin"), "stale!", mtime=OLD - 1000)
    plan = plan_folder_sync(FolderLane(str(tmp_path / "src"), str(tmp_path / "dst")), state, 60, NOW)

    Executor(True, FakeRsync(), state).run(plan)
    assert any("DRY-RUN REPLACE" in r.getMessage() for r in caplog.records)

    caplog.clear()
    Executor(False, FakeRsync(), state).run(plan)
    assert any("REPLACING" in r.getMessage() and "a.bin" in r.getMessage() for r in caplog.records)


def test_a_problem_is_logged_once_until_it_goes_away(tmp_path, caplog):
    write(str(tmp_path / "src" / "sendout_1" / "20261030-120000" / "a.bin"))
    write(str(tmp_path / "src" / "sendout_2" / "20261030-120000" / "a.bin"))
    state = SyncState.empty(str(tmp_path / "state.json"))
    lane = FolderLane(str(tmp_path / "src"), str(tmp_path / "dst"))
    duplicates = plan_folder_sync(lane, state, 60, NOW)
    executor = Executor(False, FakeRsync(), state)

    executor.run(duplicates)
    assert len(errors(caplog)) == 2          # one per source folder, first time

    caplog.clear()
    report = executor.run(duplicates)
    assert errors(caplog) == [] and report.duplicates == 2   # still counted, not repeated

    executor.run([])                          # the problem went away ...
    caplog.clear()
    executor.run(duplicates)                  # ... and came back
    assert len(errors(caplog)) == 2


def test_reported_problems_survive_a_restart(tmp_path):
    write(str(tmp_path / "src" / "sendout_1" / "20261030-120000" / "a.bin"))
    write(str(tmp_path / "src" / "sendout_2" / "20261030-120000" / "a.bin"))
    state = SyncState.empty(str(tmp_path / "state.json"))
    lane = FolderLane(str(tmp_path / "src"), str(tmp_path / "dst"))
    Executor(False, FakeRsync(), state).run(plan_folder_sync(lane, state, 60, NOW))

    assert len(SyncState.load(str(tmp_path / "state.json")).reported) == 2


def test_dry_run_shows_every_problem_and_remembers_nothing(tmp_path, caplog):
    write(str(tmp_path / "src" / "sendout_1" / "20261030-120000" / "a.bin"))
    write(str(tmp_path / "src" / "sendout_2" / "20261030-120000" / "a.bin"))
    state = SyncState.empty(str(tmp_path / "state.json"))
    lane = FolderLane(str(tmp_path / "src"), str(tmp_path / "dst"))
    plan = plan_folder_sync(lane, state, 60, NOW)

    Executor(True, FakeRsync(), state).run(plan)
    Executor(True, FakeRsync(), state).run(plan)
    assert len(errors(caplog)) == 4 and not (tmp_path / "state.json").exists()


def test_lrf_replacement_overwrites_the_file(tmp_path):
    from lot_sync.config import LrfLane
    from lot_sync.lrf import plan_lrf_sync
    name = "A-20260911-172530.lrf"
    write(str(tmp_path / "src" / name), "new content", mtime=OLD)
    old = write(str(tmp_path / "dst" / "202609" / name), "old", mtime=OLD - 1000)

    report = Executor(False).run(plan_lrf_sync(LrfLane(str(tmp_path / "src"), str(tmp_path / "dst")), 60, NOW))

    assert report.ok and open(old).read() == "new content"
    assert not list((tmp_path / "dst" / "202609").glob(".*partial"))
