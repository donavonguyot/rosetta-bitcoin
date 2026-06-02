from __future__ import annotations

from pybitnode.messages.inventory import InvMessage, InventoryVector, has_block_inventory
from pybitnode.sync.headers import headers_sync_done, mark_headers_current


def test_has_block_inventory_detects_block_types():
    block_inv = InvMessage(
        inventory=[InventoryVector(type=InventoryVector.MSG_WITNESS_BLOCK, hash=b"\x01" * 32)]
    )
    tx_inv = InvMessage(
        inventory=[InventoryVector(type=InventoryVector.MSG_WITNESS_TX, hash=b"\x02" * 32)]
    )
    assert has_block_inventory(block_inv) is True
    assert has_block_inventory(tx_inv) is False


def test_headers_sync_done_on_empty_batch():
    assert headers_sync_done(best_height=100, peer_height=200, batch_count=0) is True


def test_headers_sync_done_at_peer_height():
    assert headers_sync_done(best_height=200, peer_height=200, batch_count=2000) is True
    assert headers_sync_done(best_height=199, peer_height=200, batch_count=2000) is False


def test_mark_headers_current_updates_sync_state(tmp_path):
    from pybitnode.chain.params import TESTNET4
    from pybitnode.db.tracker import ProjectTracker
    from pybitnode.sync.headers import ensure_genesis

    tracker = ProjectTracker(tmp_path / "current.db")
    ensure_genesis(tracker, TESTNET4)
    tracker.upsert_sync_state("testnet4", best_height=0, sync_status="headers_syncing")
    mark_headers_current(tracker, TESTNET4)
    state = tracker.get_sync_state("testnet4")
    assert state["sync_status"] == "headers_current"
    tracker.close()
