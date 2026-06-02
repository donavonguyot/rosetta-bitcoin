from __future__ import annotations

import json
import sys

from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.metrics import META_LAST_ERROR, snapshot_counters


def _sync_progress_pct(validated_height: int, peer_tip_height: int) -> float | None:
    """Validated height as share of peer tip (sync_state.best_height), capped at 100%."""
    if peer_tip_height <= 0:
        return None
    if validated_height <= 0:
        return 0.0
    return round(min(100.0, 100.0 * validated_height / peer_tip_height), 2)


def _last_error_value(tracker: ProjectTracker) -> str | None:
    raw = tracker.get_meta(META_LAST_ERROR)
    if raw is None or raw.strip() == "":
        return None
    return raw


def validate_healthcheck_payload(doc: dict) -> None:
    """
    Ensure healthcheck JSON matches the shape expected by Docker / scrapers.

    Unknown top-level keys are ignored so metrics can add fields without
    breaking checks. Documented fields are validated when present.
    """
    required_top = (
        "ok",
        "healthy",
        "sync_status",
        "chain",
        "validated_height",
        "header_height",
        "block_count",
        "utxo_count",
        "peer_count",
        "peer_records_total",
        "mempool_tx_count",
        "mempool_size",
        "mempool_size_bytes",
        "metrics",
        "summary",
    )
    missing = [k for k in required_top if k not in doc]
    if missing:
        raise ValueError(f"healthcheck payload missing keys: {missing}")

    if not isinstance(doc["ok"], bool) or not isinstance(doc["healthy"], bool):
        raise ValueError("ok and healthy must be bool")
    if doc["ok"] != doc["healthy"]:
        raise ValueError("healthy must match ok")

    if not isinstance(doc["sync_status"], str):
        raise ValueError("sync_status must be str")
    if not isinstance(doc["chain"], str):
        raise ValueError("chain must be str")

    int_fields = (
        "validated_height",
        "header_height",
        "block_count",
        "utxo_count",
        "peer_count",
        "peer_records_total",
        "mempool_tx_count",
        "mempool_size",
        "mempool_size_bytes",
    )
    for key in int_fields:
        val = doc[key]
        if not isinstance(val, int):
            raise ValueError(f"{key} must be int")

    sp = doc.get("sync_progress_pct")
    if sp is not None and not isinstance(sp, (int, float)):
        raise ValueError("sync_progress_pct must be a number or null")

    le = doc.get("last_error")
    if le is not None and not isinstance(le, str):
        raise ValueError("last_error must be str or null")

    metrics = doc["metrics"]
    if not isinstance(metrics, dict):
        raise ValueError("metrics must be a dict")
    for name, val in metrics.items():
        if not isinstance(name, str):
            raise ValueError("metrics keys must be str")
        if not isinstance(val, int) or val < 0:
            raise ValueError(f"metrics.{name} must be a non-negative int")

    if not isinstance(doc["summary"], dict):
        raise ValueError("summary must be a dict")


def docker_health_document(settings: Settings, tracker: ProjectTracker) -> dict:
    """
    Produce a compact JSON document for container healthchecks and metrics scrapers.

    Exit status is still authoritative for Docker (see ``main``); this payload is additive.
    """
    summary = tracker.summary(settings.chain)
    sync = summary.get("sync", {}) if isinstance(summary.get("sync"), dict) else {}
    sync_status = sync.get("sync_status", "unknown")
    mempool_count_raw = tracker.get_meta("mempool_tx_count") or "0"
    mempool_bytes_raw = tracker.get_meta("mempool_size_bytes") or "0"
    mempool_tx_count = int(mempool_count_raw)

    peer_tip = sync.get("best_height")
    try:
        peer_tip_height = int(peer_tip) if peer_tip is not None else 0
    except (TypeError, ValueError):
        peer_tip_height = 0

    validated_height = int(summary.get("validated_height", 0) or 0)
    peer_connected = summary.get("connected_peers")
    metrics = snapshot_counters(tracker)

    ok = sync_status != "error"
    doc: dict = {
        "ok": ok,
        "healthy": ok,
        "sync_status": sync_status,
        "chain": settings.chain,
        "validated_height": validated_height,
        "header_height": tracker.max_header_height(),
        "block_count": summary.get("block_count", 0),
        "utxo_count": summary.get("utxo_count", 0),
        "peer_count": peer_connected if peer_connected is not None else 0,
        "peer_records_total": summary.get("peer_count", 0),
        "mempool_tx_count": mempool_tx_count,
        "mempool_size": mempool_tx_count,
        "mempool_size_bytes": int(mempool_bytes_raw),
        "sync_progress_pct": _sync_progress_pct(validated_height, peer_tip_height),
        "last_error": _last_error_value(tracker),
        "metrics": metrics,
        "summary": summary,
    }
    return doc


def main() -> None:
    settings = Settings.from_env()
    tracker = ProjectTracker(settings.resolved_state_path())
    try:
        payload = docker_health_document(settings, tracker)
        try:
            validate_healthcheck_payload(payload)
        except ValueError as exc:
            print(json.dumps(payload, default=str))
            print(f"healthcheck: payload validation failed: {exc}", file=sys.stderr)
            raise SystemExit(1) from exc
        print(json.dumps(payload, default=str))
        if payload.get("sync_status") == "error":
            raise SystemExit(1)
    finally:
        tracker.close()


if __name__ == "__main__":
    main()
