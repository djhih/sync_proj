import os

from lot_sync.config import FolderLane
from lot_sync.folders import plan_folder_sync
from lot_sync.plan import Kind
from lot_sync.scan import measure_tree
from lot_sync.state import SyncState

from helpers import NOW, OLD, write


def lane(tmp_path):
    return FolderLane(str(tmp_path / "src"), str(tmp_path / "dst"))


def plan(tmp_path, state=None):
    state = state or SyncState.empty(str(tmp_path / "state.json"))
    return plan_folder_sync(lane(tmp_path), state, 60, NOW)


def make_folder(tmp_path, relative, **kwargs):
    return write(str(tmp_path / "src" / relative / "a.bin"), **kwargs)


def test_destination_month_follows_the_folder_name(tmp_path):
    make_folder(tmp_path, "sendout_20260901/DB/log/20260831-235959")
    [action] = plan(tmp_path)
    assert action.kind is Kind.COPY_TREE
    assert action.dst == str(tmp_path / "dst" / "202608" / "20260831-235959")


def test_empty_folder_is_not_copied(tmp_path):
    os.makedirs(tmp_path / "src" / "20261103-112600")
    [action] = plan(tmp_path)
    assert (action.kind, action.reason) == (Kind.SKIP, "no files yet")


def test_folder_still_being_written_waits(tmp_path):
    make_folder(tmp_path, "20261103-112600", mtime=NOW - 5)
    [action] = plan(tmp_path)
    assert (action.kind, action.reason) == (Kind.SKIP, "still being written")


def test_completed_folder_is_up_to_date_until_it_changes(tmp_path):
    source = tmp_path / "src" / "20261103-112600"
    make_folder(tmp_path, "20261103-112600")
    state = SyncState.empty(str(tmp_path / "state.json"))
    destination = str(tmp_path / "dst" / "202611" / "20261103-112600")
    state.mark_done(destination, str(source), measure_tree(str(source)))
    assert plan(tmp_path, state)[0].kind is Kind.UP_TO_DATE

    write(str(source / "late.bin"))  # a file arrives after the copy
    assert plan(tmp_path, state)[0].kind is Kind.COPY_TREE


def test_parent_layers_and_sendout_date_are_not_carried_over(tmp_path):
    make_folder(tmp_path, "sendout_20261103/PE-test/EXP1/20261030-120000")
    [action] = plan(tmp_path)
    assert action.dst == str(tmp_path / "dst" / "202610" / "20261030-120000")


def test_same_lot_id_from_two_sendouts_is_an_alert_and_copies_neither(tmp_path):
    make_folder(tmp_path, "sendout_20261103/20261030-120000")
    make_folder(tmp_path, "sendout_20261104/20261030-120000")
    actions = plan(tmp_path)
    assert {a.kind for a in actions} == {Kind.DUPLICATE}
    assert all("also found at" in a.reason for a in actions)


def synced_lot(tmp_path):
    first = make_folder(tmp_path, "sendout_20261103/20261030-120000")
    source = os.path.dirname(first)
    state = SyncState.empty(str(tmp_path / "state.json"))
    destination = str(tmp_path / "dst" / "202610" / "20261030-120000")
    state.mark_done(destination, source, measure_tree(source))
    return state, source


def test_later_copy_of_a_synced_lot_flags_both_sources(tmp_path):
    state, source = synced_lot(tmp_path)
    make_folder(tmp_path, "sendout_20261104/20261030-120000")
    assert {a.kind for a in plan(tmp_path, state)} == {Kind.DUPLICATE}


def test_later_copy_is_an_alert_even_after_the_original_source_is_gone(tmp_path):
    state, source = synced_lot(tmp_path)
    os.rename(source, str(tmp_path / "gone"))
    make_folder(tmp_path, "sendout_20261104/20261030-120000")
    [action] = plan(tmp_path, state)
    assert action.kind is Kind.DUPLICATE and "already synced from" in action.reason


def test_destination_left_by_the_old_program_is_adopted_when_consistent(tmp_path):
    make_folder(tmp_path, "sendout_1/20261030-120000")
    write(str(tmp_path / "dst" / "202610" / "20261030-120000" / "a.bin"))  # same file
    assert plan(tmp_path)[0].kind is Kind.COPY_TREE


def test_empty_destination_left_by_the_old_program_is_filled(tmp_path):
    make_folder(tmp_path, "sendout_1/20261030-120000")
    os.makedirs(tmp_path / "dst" / "202610" / "20261030-120000")
    assert plan(tmp_path)[0].kind is Kind.COPY_TREE


def test_older_destination_content_is_overwritten_and_listed(tmp_path):
    make_folder(tmp_path, "sendout_1/20261030-120000", content="new content")
    kept = write(str(tmp_path / "dst" / "202610" / "20261030-120000" / "a.bin"),
                 "old", mtime=OLD - 1000)
    write(str(tmp_path / "dst" / "202610" / "20261030-120000" / "only-here.bin"))
    [action] = plan(tmp_path)
    assert action.kind is Kind.COPY_TREE
    assert len(action.notes) == 1 and kept in action.notes[0]


def test_newer_destination_file_is_not_listed_as_replaced(tmp_path):
    make_folder(tmp_path, "sendout_1/20261030-120000", content="older", mtime=OLD - 1000)
    write(str(tmp_path / "dst" / "202610" / "20261030-120000" / "a.bin"), "newer content", mtime=OLD)
    [action] = plan(tmp_path)
    assert action.kind is Kind.COPY_TREE and action.notes == ()


def test_identical_destination_has_nothing_to_replace(tmp_path):
    make_folder(tmp_path, "sendout_1/20261030-120000")
    write(str(tmp_path / "dst" / "202610" / "20261030-120000" / "a.bin"))
    assert plan(tmp_path)[0].notes == ()
