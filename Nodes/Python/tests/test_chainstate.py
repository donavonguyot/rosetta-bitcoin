from __future__ import annotations

import pytest

from pybitnode.chain.genesis import TESTNET4_GENESIS
from pybitnode.chain.params import TESTNET4
from pybitnode.chainstate.tracker import SCHEMA_VERSION, ProjectTracker
from pybitnode.config import Settings
from pybitnode.messages.headers import HeadersMessage
from pybitnode.sync.headers import ensure_genesis, genesis_locator, next_locator, persist_headers, repair_sync_state


def test_chainstate_initialization(tmp_path):
    tracker = ProjectTracker(tmp_path / "chainstate-rocksdb")
    assert tracker.get_meta("schema_version") == str(SCHEMA_VERSION)
    assert len(tracker.list_phases()) == 6
    assert tracker.get_meta("backend_name") == "rocksdb"
    tracker.close()


def test_native_tracker_creates_no_sqlite_artifacts(tmp_path):
    state_path = tmp_path / "chainstate-rocksdb"
    tracker = ProjectTracker(state_path)
    tracker.set_validated_tip(1, "ab" * 32)
    tracker.close()
    forbidden = [
        path
        for path in tmp_path.rglob("*")
        if path.suffix in {".db", ".sqlite", ".sqlite3"}
        or path.name.endswith((".db-wal", ".db-shm", ".db-journal"))
    ]
    assert forbidden == []


def test_legacy_db_env_is_rejected(monkeypatch):
    monkeypatch.setenv("DB_PATH", "/tmp/pybitnode.db")
    monkeypatch.delenv("STATE_PATH", raising=False)
    with pytest.raises(RuntimeError, match="DB_PATH is retired"):
        Settings.from_env()


def test_tracker_project_phases_and_events(tmp_path):
    tracker = ProjectTracker(tmp_path / "chainstate-rocksdb")
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
    tracker = ProjectTracker(tmp_path / "chainstate-rocksdb")
    tracker.record_header(0, "abc", "def", 123)
    tracker.record_header(0, "abc", "def", 123)
    assert tracker.header_count() == 1
    tracker.close()


def test_genesis_locator_uses_internal_hash():
    locator = genesis_locator(TESTNET4)
    assert locator == [TESTNET4_GENESIS.block_hash()]


def test_next_locator_includes_genesis_at_height_zero(tmp_path):
    tracker = ProjectTracker(tmp_path / "chainstate-rocksdb")
    ensure_genesis(tracker, TESTNET4)
    locator = next_locator(tracker, TESTNET4)
    assert TESTNET4_GENESIS.block_hash() in locator
    tracker.close()


def test_repair_sync_state_from_headers(tmp_path):
    tracker = ProjectTracker(tmp_path / "chainstate-rocksdb")
    ensure_genesis(tracker, TESTNET4)
    tracker.upsert_sync_state("testnet4", best_height=0, sync_status="error")
    tracker.record_header(1, "abc123", TESTNET4.genesis_hash, 123)
    repair_sync_state(tracker, TESTNET4)
    state = tracker.get_sync_state("testnet4")
    assert state["best_height"] == 1
    assert state["best_hash"] == "abc123"
    tracker.close()


def test_persist_headers_with_empty_message(tmp_path):
    tracker = ProjectTracker(tmp_path / "chainstate-rocksdb")
    height, best_hash, stored = persist_headers(tracker, TESTNET4, HeadersMessage(headers=()))
    assert stored == 0
    assert height == 0
    assert best_hash == TESTNET4.genesis_hash
    assert tracker.header_count() == 1
    tracker.close()
