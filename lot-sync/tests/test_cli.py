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
