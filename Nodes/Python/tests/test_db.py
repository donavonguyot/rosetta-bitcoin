from __future__ import annotations

import sqlite_utils

from pybitnode.chain.genesis import TESTNET4_GENESIS
from pybitnode.chain.params import TESTNET4
from pybitnode.db.schema import SCHEMA_VERSION, init_schema
from pybitnode.db.tracker import ProjectTracker
from pybitnode.messages.headers import HeadersMessage
from pybitnode.sync.headers import ensure_genesis, genesis_locator, next_locator, persist_headers, repair_sync_state


def test_schema_initialization(tmp_path):
    db_path = tmp_path / "test.db"
    db = sqlite_utils.Database(str(db_path))
    init_schema(db)
    assert db["meta"].count >= 1
    rows = list(db["meta"].rows_where("key = ?", ["schema_version"]))
    assert rows[0]["value"] == str(SCHEMA_VERSION)
    assert db["project_phases"].count == 6
    db.close()


def test_tracker_project_phases_and_events(tmp_path):
    tracker = ProjectTracker(tmp_path / "tracker.db")
    tracker.update_phase("phase0", status="completed", notes="wire tests pass")
    tracker.log_event("test", "hello", details={"x": 1})
    tracker.upsert_sync_state("testnet4", best_height=10, sync_status="connected")
    tracker.record_peer_connected("127.0.0.1", 48333, user_agent="/pybitnode:0.1.0/")

    summary = tracker.summary("testnet4")
    assert summary["sync"]["best_height"] == 10
    assert summary["peer_count"] == 1
    assert any(p["phase"] == "phase0" and p["status"] == "completed" for p in summary["phases"])
    assert summary["recent_events"]
    tracker.close()


def test_tracker_headers_ignore_duplicates(tmp_path):
    tracker = ProjectTracker(tmp_path / "headers.db")
    tracker.record_header(0, "abc", "def", 123)
    tracker.record_header(0, "abc", "def", 123)
    assert tracker.header_count() == 1
    tracker.close()


def test_genesis_locator_uses_internal_hash():
    locator = genesis_locator(TESTNET4)
    assert locator == [TESTNET4_GENESIS.block_hash()]


def test_next_locator_includes_genesis_at_height_zero(tmp_path):
    tracker = ProjectTracker(tmp_path / "locator.db")
    ensure_genesis(tracker, TESTNET4)
    locator = next_locator(tracker, TESTNET4)
    assert TESTNET4_GENESIS.block_hash() in locator
    tracker.close()


def test_repair_sync_state_from_headers(tmp_path):
    tracker = ProjectTracker(tmp_path / "repair.db")
    ensure_genesis(tracker, TESTNET4)
    tracker.upsert_sync_state("testnet4", best_height=0, sync_status="error")
    tracker.record_header(1, "abc123", TESTNET4.genesis_hash, 123)
    repair_sync_state(tracker, TESTNET4)
    state = tracker.get_sync_state("testnet4")
    assert state["best_height"] == 1
    assert state["best_hash"] == "abc123"
    tracker.close()


def test_persist_headers_with_empty_message(tmp_path):
    tracker = ProjectTracker(tmp_path / "sync.db")
    height, best_hash, stored = persist_headers(tracker, TESTNET4, HeadersMessage(headers=()))
    assert stored == 0
    assert height == 0
    assert best_hash == TESTNET4.genesis_hash
    assert tracker.header_count() == 1
    tracker.close()
