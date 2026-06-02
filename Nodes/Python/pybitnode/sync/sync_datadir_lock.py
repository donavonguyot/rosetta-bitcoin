"""Prevent concurrent pybitnode-sync writers against one datadir (SQLite single-writer rule)."""

from __future__ import annotations

import errno
import fcntl
import logging
import os
from pathlib import Path
from typing import BinaryIO

logger = logging.getLogger(__name__)


class ExclusiveDataDirSyncLock:
    """Non-blocking POSIX flock on `<datadir>/.pybitnode-sync.lock`."""

    def __init__(self, datadir: Path) -> None:
        self.datadir = datadir
        self._fp: BinaryIO | None = None

    def __enter__(self) -> ExclusiveDataDirSyncLock:
        self.datadir.mkdir(parents=True, exist_ok=True)
        lock_path = self.datadir / ".pybitnode-sync.lock"
        fp = open(lock_path, "a+b")  # noqa: SIM115 — short-lived flock holder
        try:
            fcntl.flock(fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            fp.close()
            if getattr(exc, "errno", None) in (
                errno.EACCES,
                errno.EAGAIN,
                errno.EWOULDBLOCK if hasattr(errno, "EWOULDBLOCK") else errno.EAGAIN,
            ):
                logger.error(
                    "duplicate_pybitnode_sync_holder_same_datadir datadir=%s",
                    self.datadir.resolve(),
                )
                raise RuntimeError(
                    "Another pybitnode-sync holds this datadir; exit the other instance first."
                ) from exc
            raise
        fp.seek(0)
        fp.truncate()
        fp.write(f"{os.getpid()}\n".encode())
        fp.flush()
        self._fp = fp
        return self

    def __exit__(self, *_args: object) -> None:
        if self._fp is not None:
            try:
                fcntl.flock(self._fp.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            self._fp.close()
            self._fp = None
