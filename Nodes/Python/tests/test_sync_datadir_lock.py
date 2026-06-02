from __future__ import annotations

import pytest

from pybitnode.sync.sync_datadir_lock import ExclusiveDataDirSyncLock


def test_exclusive_datadir_sync_lock_conflicts_between_handles(tmp_path):
    d = tmp_path / "d"
    with ExclusiveDataDirSyncLock(d):
        with pytest.raises(RuntimeError, match="Another pybitnode-sync holds this datadir"):
            with ExclusiveDataDirSyncLock(d):
                pass
