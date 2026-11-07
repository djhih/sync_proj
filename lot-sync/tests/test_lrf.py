from lot_sync.config import LrfLane
from lot_sync.lrf import plan_lrf_sync
from lot_sync.plan import Kind

from helpers import NOW, OLD, write

NAME = "LOTAAAA0001-20260911-172530_pub.lrf"


def lane(tmp_path, fallback=()):
    return LrfLane(str(tmp_path / "src"), str(tmp_path / "dst"), tuple(fallback))


def plan(tmp_path, fallback=()):
    return plan_lrf_sync(lane(tmp_path, fallback), 60, NOW)


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


def by_source(actions):
    return {a.src: a for a in actions}


def test_newer_file_in_a_fallback_directory_never_displaces_the_original(tmp_path):
    original = source(tmp_path, where="sendout_1", content="original, longer", mtime=OLD - 500)
    derived = source(tmp_path, where="sendout_2/derived", content="cut", mtime=OLD)
    actions = by_source(plan(tmp_path, fallback=["derived"]))
    assert actions[original].kind is Kind.COPY_FILE
    assert (actions[derived].kind, actions[derived].reason) == (
        Kind.SKIP, "same name exists outside a fallback directory")


def test_fallback_file_cannot_replace_the_original_already_at_the_destination(tmp_path):
    original = source(tmp_path, where="sendout_1", content="original, longer", mtime=OLD - 500)
    source(tmp_path, where="sendout_2/derived", content="cut", mtime=OLD)
    destination(tmp_path, content="original, longer", mtime=OLD - 500)
    actions = plan(tmp_path, fallback=["derived"])
    assert [a.kind for a in actions if a.kind is Kind.COPY_FILE] == []
    assert by_source(actions)[original].kind is Kind.UP_TO_DATE


def test_without_the_option_the_newest_wins_as_before(tmp_path):
    source(tmp_path, where="sendout_1", content="original, longer", mtime=OLD - 500)
    derived = source(tmp_path, where="sendout_2/derived", content="cut", mtime=OLD)
    assert by_source(plan(tmp_path))[derived].kind is Kind.COPY_FILE


def test_file_found_only_in_a_fallback_directory_is_still_synced(tmp_path):
    only = source(tmp_path, where="sendout_1/a/derived/b")  # any depth below the name
    [action] = plan(tmp_path, fallback=["derived"])
    assert (action.src, action.kind) == (only, Kind.COPY_FILE)


def test_between_fallback_copies_the_newest_still_wins(tmp_path):
    source(tmp_path, where="sendout_1/derived", content="a", mtime=OLD - 500)
    newer = source(tmp_path, where="sendout_2/derived", content="b", mtime=OLD)
    kinds = {a.src: a.kind for a in plan(tmp_path, fallback=["derived"])}
    assert kinds[newer] is Kind.COPY_FILE and list(kinds.values()).count(Kind.SKIP) == 1


def test_fallback_matches_whole_directory_names_only(tmp_path):
    source(tmp_path, where="sendout_1", content="a", mtime=OLD - 500)
    newer = source(tmp_path, where="sendout_2/derived_old", content="b", mtime=OLD)
    assert by_source(plan(tmp_path, fallback=["derived"]))[newer].kind is Kind.COPY_FILE


def test_the_source_root_itself_is_not_a_fallback_directory(tmp_path):
    root = tmp_path / "derived"
    path = write(str(root / "sendout_1" / NAME))
    lane_ = LrfLane(str(root), str(tmp_path / "dst"), ("derived",))
    original = write(str(root / "sendout_0" / NAME), "longer", OLD - 500)
    kinds = {a.src: a.kind for a in plan_lrf_sync(lane_, 60, NOW)}
    assert kinds == {path: Kind.COPY_FILE, original: Kind.SKIP}
