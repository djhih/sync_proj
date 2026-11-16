import pytest

from lot_sync.cli import build_parser, sync_config_from


def config_of(*argv):
    parser = build_parser()
    return sync_config_from(parser.parse_args(["sync", "--dry-run", *argv]), parser)


LRF = ("--lrf-src", "/src", "--lrf-dst", "/dst")


def test_fallback_dirs_reach_the_lrf_lane_in_order():
    config = config_of(*LRF, "--lrf-fallback-dir", "b", "--lrf-fallback-dir", "a")
    assert config.lrf_lane.fallback_dirs == ("b", "a")


def test_no_fallback_dirs_by_default():
    assert config_of(*LRF).lrf_lane.fallback_dirs == ()


def test_fallback_dir_without_an_lrf_lane_is_refused():
    with pytest.raises(SystemExit):
        config_of("--folder-src", "/src", "--folder-dst", "/dst", "--lrf-fallback-dir", "a")


@pytest.mark.parametrize("bad", ["a/b", "", ".", ".."])
def test_fallback_dir_must_be_a_plain_directory_name(bad):
    with pytest.raises(SystemExit):
        config_of(*LRF, "--lrf-fallback-dir", bad)


def run_main(tmp_path, *argv):
    from lot_sync.cli import main
    return main(["sync", "--dry-run", "--state-file", str(tmp_path / "state.json"), *argv])


def test_exit_status_is_0_when_nothing_is_waiting(tmp_path):
    from helpers import destination_root, write
    write(str(tmp_path / "src" / "20261030-120000" / "a.bin"))
    assert run_main(tmp_path, "--folder-src", str(tmp_path / "src"),
                    "--folder-dst", destination_root(tmp_path)) == 0


def test_exit_status_3_means_finished_but_a_person_is_needed(tmp_path):
    from helpers import destination_root, write
    write(str(tmp_path / "src" / "s1" / "20261030-120000" / "a.bin"))
    write(str(tmp_path / "src" / "s2" / "20261030-120000" / "a.bin"))   # duplicate lot-id
    write(str(tmp_path / "src" / "summary.lrf"))                         # undated .lrf
    dst = destination_root(tmp_path)
    assert run_main(tmp_path, "--folder-src", str(tmp_path / "src"), "--folder-dst", dst,
                    "--lrf-src", str(tmp_path / "src"), "--lrf-dst", dst) == 3


def test_exit_status_4_means_something_could_not_be_read_or_written(tmp_path):
    from helpers import write
    write(str(tmp_path / "src" / "20261030-120000" / "a.bin"))
    assert run_main(tmp_path, "--folder-src", str(tmp_path / "src"),
                    "--folder-dst", str(tmp_path / "unmounted")) == 4
