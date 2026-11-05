import os
import shutil
import time
from datetime import datetime

NOW = time.time()
OLD = NOW - 3600  # comfortably past the stable window


def write(path, content="x", mtime=OLD):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(content)
    os.utime(path, (mtime, mtime))
    return path


def timestamp_of(year, month, day):
    return datetime(year, month, day, 12, 0).timestamp()


class FakeRsync:
    """Stands in for Rsync: copies with shutil, can be told to fail."""

    def __init__(self, fail_copy=False):
        self.fail_copy = fail_copy
        self.copies = []

    def copy_tree(self, src, dst):
        from lot_sync.rsync import RsyncError
        if self.fail_copy:
            raise RsyncError("copy exited 1: boom")
        self.copies.append((src, dst))
        shutil.copytree(src, dst, dirs_exist_ok=True)

    def verify_tree(self, src, dst):
        pass
