from __future__ import annotations

import json

import pytest

from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode import healthcheck


def test_docker_health_document_exposes_tracker_metrics(tmp_path):
    db = tmp_path / "hc-chainstate"
    settings = Settings(chain="testnet4", db_path=str(db))
    tracker = ProjectTracker(settings.resolved_db_path())

    tracker.set_validated_tip(11, "aa" * 32, chain="testnet4")
    tracker.record_block(1, "bb" * 32, file_name="blk.dat", file_offset=0, size=100)
    tracker.add_utxo(b"\x01" * 32, 0, height=1, value=1000, script_pubkey=b"\x51", coinbase=False)

    tracker.record_peer_connected("198.51.100.2", 48333)

    tracker.set_meta("mempool_tx_count", "3")
    tracker.set_meta("mempool_size_bytes", "2048")
    tracker.record_header(
        height=42,
        block_hash="cc" * 32,
        prev_hash="dd" * 32,
        timestamp=1,
    )
    tracker.upsert_sync_state("testnet4", best_height=100, sync_status="connected")

    doc = healthcheck.docker_health_document(settings, tracker)
    tracker.close()

    assert doc["validated_height"] == 11
    assert doc["header_height"] == 42
    assert doc["block_count"] >= 1
    assert doc["utxo_count"] >= 1
    assert doc["mempool_tx_count"] == 3
    assert doc["mempool_size"] == 3
    assert doc["mempool_size_bytes"] == 2048
    assert doc["peer_count"] >= 1
    assert doc["sync_progress_pct"] == 11.0
    assert isinstance(doc["metrics"], dict)
    assert doc["metrics"] == {"blocks_validated_total": 0, "txs_relayed_total": 0}
    assert doc["last_error"] is None
    healthcheck.validate_healthcheck_payload(doc)


def test_validate_healthcheck_payload_rejects_bad_metrics_value():
    base = {
        "ok": True,
        "healthy": True,
        "sync_status": "running",
        "chain": "testnet4",
        "validated_height": 0,
        "header_height": 0,
        "block_count": 0,
        "utxo_count": 0,
        "peer_count": 0,
        "peer_records_total": 0,
        "mempool_tx_count": 0,
        "mempool_size": 0,
        "mempool_size_bytes": 0,
        "metrics": {"blocks_validated_total": -1, "txs_relayed_total": 0},
        "summary": {},
    }
    with pytest.raises(ValueError, match="non-negative"):
        healthcheck.validate_healthcheck_payload(base)


def test_validate_healthcheck_payload_accepts_future_metric_counter():
    base = {
        "ok": True,
        "healthy": True,
        "sync_status": "running",
        "chain": "testnet4",
        "validated_height": 0,
        "header_height": 0,
        "block_count": 0,
        "utxo_count": 0,
        "peer_count": 0,
        "peer_records_total": 0,
        "mempool_tx_count": 0,
        "mempool_size": 0,
        "mempool_size_bytes": 0,
        "metrics": {"blocks_validated_total": 0, "txs_relayed_total": 0, "future_total": 1},
        "summary": {},
    }
    healthcheck.validate_healthcheck_payload(base)


def test_validate_healthcheck_payload_ignores_unknown_top_level_keys():
    base = {
        "ok": True,
        "healthy": True,
        "sync_status": "running",
        "chain": "testnet4",
        "validated_height": 0,
        "header_height": 0,
        "block_count": 0,
        "utxo_count": 0,
        "peer_count": 0,
        "peer_records_total": 0,
        "mempool_tx_count": 0,
        "mempool_size": 0,
        "mempool_size_bytes": 0,
        "metrics": {"blocks_validated_total": 0, "txs_relayed_total": 0},
        "summary": {},
        "future_field": {"any": "thing"},
    }
    healthcheck.validate_healthcheck_payload(base)


def test_healthcheck_main_writes_json_and_ok(tmp_path, monkeypatch, capsys):
    db = tmp_path / "hm-chainstate"
    monkeypatch.setenv("DB_PATH", str(db))
    monkeypatch.setenv("CHAIN", "testnet4")

    tracker = ProjectTracker(str(db))
    tracker.upsert_sync_state("testnet4", sync_status="headers_current")
    tracker.close()

    healthcheck.main()
    out = capsys.readouterr().out.strip().splitlines()
    payload = json.loads(out[0])
    assert payload["sync_status"] == "headers_current"
    assert payload["ok"] is True
    assert payload.get("metrics") == {"blocks_validated_total": 0, "txs_relayed_total": 0}


def test_healthcheck_main_fails_when_sync_error(tmp_path, monkeypatch, capsys):
    db = tmp_path / "bad-chainstate"
    monkeypatch.setenv("DB_PATH", str(db))
    monkeypatch.setenv("CHAIN", "testnet4")

    tracker = ProjectTracker(str(db))
    tracker.upsert_sync_state("testnet4", sync_status="error")
    tracker.close()

    with pytest.raises(SystemExit) as ei:
        healthcheck.main()
    assert ei.value.code == 1
    decoded = json.loads(capsys.readouterr().out.strip().splitlines()[0])
    assert decoded["sync_status"] == "error"
    assert decoded["ok"] is False
    assert decoded.get("last_error") is None


def test_healthcheck_last_error_when_meta_set(tmp_path):
    db = tmp_path / "le-chainstate"
    settings = Settings(chain="testnet4", db_path=str(db))
    tracker = ProjectTracker(settings.resolved_db_path())
    tracker.upsert_sync_state("testnet4", sync_status="running", best_height=1)
    tracker.set_meta("last_error", "connection reset")
    doc = healthcheck.docker_health_document(settings, tracker)
    tracker.close()

    assert doc["last_error"] == "connection reset"
    healthcheck.validate_healthcheck_payload(doc)


def test_sync_progress_pct_none_when_no_peer_tip(tmp_path):
    db = tmp_path / "np-chainstate"
    settings = Settings(chain="testnet4", db_path=str(db))
    tracker = ProjectTracker(settings.resolved_db_path())
    tracker.set_validated_tip(5, "aa" * 32, chain="testnet4")
    tracker.upsert_sync_state(
        "testnet4",
        sync_status="headers_current",
        best_height=0,
    )

    doc = healthcheck.docker_health_document(settings, tracker)
    tracker.close()

    assert doc["sync_progress_pct"] is None
    healthcheck.validate_healthcheck_payload(doc)
