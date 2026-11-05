from lot_sync.config import LrfLane
from lot_sync.lrf import plan_lrf_sync
from lot_sync.plan import Kind

from helpers import NOW, OLD, write

NAME = "LOTAAAA0001-20260911-172530_pub.lrf"


def lane(tmp_path):
    return LrfLane(str(tmp_path / "src"), str(tmp_path / "dst"))


def plan(tmp_path):
    return plan_lrf_sync(lane(tmp_path), 60, NOW)


def source(tmp_path, where="sendout_20261105", content="x", mtime=OLD, name=NAME):
    return write(str(tmp_path / "src" / where / name), content, mtime)


def destination(tmp_path, month="202609", content="x", mtime=OLD, name=NAME):
    return write(str(tmp_path / "dst" / month / name), content, mtime)


def test_month_is_the_date_in_the_name_not_the_sendout_or_the_mtime(tmp_path):
    source(tmp_path, where="sendout_20261105")  # delivered in November, mtime is today
    [action] = plan(tmp_path)
    assert action.kind is Kind.COPY_FILE
    assert action.dst == str(tmp_path / "dst" / "202609" / NAME)


def test_same_file_already_there_is_up_to_date(tmp_path):
    source(tmp_path)
    destination(tmp_path)
    assert plan(tmp_path)[0].kind is Kind.UP_TO_DATE


def test_newer_source_replaces_the_copy_in_place_and_says_what_it_replaces(tmp_path):
    source(tmp_path, content="new content", mtime=OLD)
    old = destination(tmp_path, month="202608", content="old", mtime=OLD - 1000)
    [action] = plan(tmp_path)
    assert (action.kind, action.dst) == (Kind.COPY_FILE, old)
    assert len(action.notes) == 1 and "3 B" in action.notes[0] and "11 B" in action.notes[0]


def test_older_source_never_replaces_a_newer_destination(tmp_path):
    source(tmp_path, content="older", mtime=OLD - 1000)
    destination(tmp_path, content="newer content", mtime=OLD)
    [action] = plan(tmp_path)
    assert (action.kind, action.reason) == (Kind.SKIP, "destination is newer")


def test_one_name_from_two_sources_syncs_only_the_newest(tmp_path):
    source(tmp_path, where="sendout_1", content="a", mtime=OLD - 500)
    source(tmp_path, where="sendout_2", content="b", mtime=OLD)
    kinds = {a.src.split("/")[-2]: a.kind for a in plan(tmp_path)}
    assert kinds == {"sendout_1": Kind.SKIP, "sendout_2": Kind.COPY_FILE}


def test_name_without_a_date_is_an_error(tmp_path):
    source(tmp_path, name="report.lrf")
    [action] = plan(tmp_path)
    assert action.kind is Kind.ERROR


def test_file_still_being_written_waits(tmp_path):
    source(tmp_path, mtime=NOW - 5)
    assert plan(tmp_path)[0].reason == "still being written"


def test_other_extensions_are_ignored(tmp_path):
    write(str(tmp_path / "src" / "a-20260911-172530.txt"))
    assert plan(tmp_path) == []


def test_planning_creates_no_directories(tmp_path):
    source(tmp_path)
    plan(tmp_path)
    assert not (tmp_path / "dst").exists()
