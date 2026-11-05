import os

from lot_sync.executor import Executor
from lot_sync.plan import Kind
from lot_sync.relocate import plan_relocation

from helpers import write


def test_folder_in_the_wrong_month_is_moved(tmp_path):
    root = tmp_path / "dst"
    write(str(root / "202609" / "20260815-101010" / "a.bin"))
    [action] = plan_relocation(str(root), None)
    assert action.kind is Kind.MOVE
    assert action.dst == str(root / "202608" / "20260815-101010")


def test_folder_in_the_right_month_is_left_alone(tmp_path):
    root = tmp_path / "dst"
    write(str(root / "202608" / "20260815-101010" / "a.bin"))
    assert plan_relocation(str(root), None) == []


def test_loose_folder_under_the_root_is_moved_into_its_month(tmp_path):
    root = tmp_path / "dst"
    write(str(root / "20260815-101010" / "a.bin"))
    [action] = plan_relocation(str(root), None)
    assert action.dst == str(root / "202608" / "20260815-101010")


def test_lrf_is_moved_by_the_date_in_its_name(tmp_path):
    root = tmp_path / "lrf"
    write(str(root / "202609" / "A-20260815-101010_pub.lrf"))
    [action] = plan_relocation(None, str(root))
    assert action.dst == str(root / "202608" / "A-20260815-101010_pub.lrf")


def test_existing_target_is_never_overwritten(tmp_path):
    root = tmp_path / "lrf"
    write(str(root / "202609" / "A-20260815-101010.lrf"), "misplaced")
    write(str(root / "202608" / "A-20260815-101010.lrf"), "already there")
    [action] = plan_relocation(None, str(root))
    assert action.kind is Kind.SKIP


def test_dry_run_changes_nothing_and_apply_moves(tmp_path):
    root = tmp_path / "dst"
    source = root / "202609" / "20260815-101010"
    write(str(source / "a.bin"))
    plan = plan_relocation(str(root), None)

    assert Executor(dry_run=True).run(plan).applied == 1
    assert source.exists()

    assert Executor(dry_run=False).run(plan).ok
    assert not source.exists()
    assert os.path.exists(root / "202608" / "20260815-101010" / "a.bin")
