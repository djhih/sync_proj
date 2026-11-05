from types import SimpleNamespace

import pytest

from lot_sync.rsync import Rsync, RsyncError


def runner_returning(stdout="", returncode=0, stderr=""):
    calls = []

    def run(command, **_):
        calls.append(command)
        return SimpleNamespace(stdout=stdout, returncode=returncode, stderr=stderr)

    return run, calls


def test_copy_never_replaces_newer_files_and_never_deletes():
    run, calls = runner_returning()
    Rsync(runner=run).copy_tree("/s/lot", "/d/202610/lot")
    assert calls == [["rsync", "-a", "-u", "--no-owner", "--no-group", "/s/lot/", "/d/202610/lot/"]]
    assert "--delete" not in calls[0]


def test_extra_args_go_before_the_paths():
    run, calls = runner_returning()
    Rsync("rsync", ["--timeout=60"], runner=run).copy_tree("/s", "/d")
    assert calls[0][:2] == ["rsync", "--timeout=60"]


def test_failure_carries_exit_code_and_stderr():
    run, _ = runner_returning(returncode=23, stderr="opendir failed: Permission denied")
    with pytest.raises(RsyncError, match="exited 23.*Permission denied"):
        Rsync(runner=run).copy_tree("/s", "/d")


def test_verify_passes_when_nothing_would_transfer():
    run, _ = runner_returning(stdout="cd+++++++++ sub/\n.d..t...... ./\n")
    Rsync(runner=run).verify_tree("/s", "/d")  # directory-only lines are not a mismatch


def test_verify_fails_when_a_file_is_missing_or_differs():
    run, _ = runner_returning(stdout=">f+++++++++ a.bin\n")
    with pytest.raises(RsyncError, match="1 file"):
        Rsync(runner=run).verify_tree("/s", "/d")
