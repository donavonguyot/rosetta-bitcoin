#!/usr/bin/env python3
"""Read-only post-100k source-state checks for Project operator surfaces."""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
EXPECTED_100K_HASH = "0000000000524911745ab6eee9348bca9843c2c2b1b27eada246e3dc2f80b6b1"
EXPECTED_100K_UTXO_COUNT = 13154991
READY_STATUS = "ready"
NOT_READY_STATUSES = {
    "state_missing",
    "below_100k",
    "hash_mismatch",
    "utxo_mismatch",
    "status_unparseable",
    "command_missing",
}


def as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


def one(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...]) -> dict[str, Any] | None:
    row = conn.execute(sql, params).fetchone()
    return dict(row) if row else None


def command_surface_row(conn: sqlite3.Connection, port: str, command_key: str) -> dict[str, Any] | None:
    return one(
        conn,
        """
        SELECT supported, command
        FROM port_command_surface
        WHERE port = ? AND command_key = ?
        """,
        (port, command_key),
    )


def extract_json_object(text: str) -> dict[str, Any] | None:
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        parsed = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def reference_finish_truth() -> dict[str, Any]:
    completed = subprocess.run(
        [sys.executable, "Project/scripts/reference_tip.py", "--check-local-reference", "--json"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        return {"ok": False, "error": (completed.stdout + completed.stderr).strip()}
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        return {"ok": False, "error": f"reference_tip output is not JSON: {exc}"}
    return payload if isinstance(payload, dict) else {"ok": False, "error": "reference_tip output must be a JSON object"}


def blank_result(source_state_volume: str, reference_finish: dict[str, Any] | None) -> dict[str, Any]:
    return {
        "status": "command_missing",
        "reason": "",
        "command_key": "docker_status_100k",
        "command": "",
        "source_state_volume": source_state_volume,
        "height": -1,
        "hash": "",
        "utxo_count": -1,
        "reference_finish": reference_finish or {},
    }


def classify_source_payload(
    payload: dict[str, Any],
    result: dict[str, Any],
) -> dict[str, Any]:
    try:
        height = int(payload.get("validated_height") or -1)
    except (TypeError, ValueError):
        height = -1
    state_hash = str(payload.get("validated_hash") or "")
    try:
        utxos = int(payload.get("chainstate_utxo_count") or payload.get("utxo_count") or -1)
    except (TypeError, ValueError):
        utxos = -1
    result.update(
        {
            "height": height,
            "hash": state_hash,
            "utxo_count": utxos,
            "sync_status": payload.get("sync_status", ""),
            "current_blocker": payload.get("current_blocker"),
        }
    )
    if height < 0 or not state_hash or utxos < 0:
        result["status"] = "state_missing"
        result["reason"] = "source status lacks height/hash/UTXO truth"
    elif height < 100000:
        result["status"] = "below_100k"
        result["reason"] = f"source state height={height}; expected >=100000"
    elif height == 100000 and state_hash != EXPECTED_100K_HASH:
        result["status"] = "hash_mismatch"
        result["reason"] = f"source state hash mismatch at 100000: {state_hash}"
    elif height == 100000 and utxos != EXPECTED_100K_UTXO_COUNT:
        result["status"] = "utxo_mismatch"
        result["reason"] = f"source state UTXO count={utxos}; expected {EXPECTED_100K_UTXO_COUNT}"
    else:
        result["status"] = READY_STATUS
        result["reason"] = f"source state height={height} hash={state_hash} utxos={utxos}"
    return result


def classify_source_state(
    conn: sqlite3.Connection,
    port: str,
    source_state_volume: str,
    reference_finish: dict[str, Any] | None = None,
    *,
    log_path: Path | None = None,
) -> dict[str, Any]:
    result = blank_result(source_state_volume, reference_finish)
    if not source_state_volume:
        result["status"] = "state_missing"
        result["reason"] = "missing volumes.proof_100k"
        return result
    command = command_surface_row(conn, port, "docker_status_100k")
    if not command or not as_bool(command.get("supported")) or not str(command.get("command") or "").strip():
        result["reason"] = "missing supported docker_status_100k command"
        return result

    command_text = str(command["command"]).strip()
    result["command"] = command_text
    completed = subprocess.run(command_text, cwd=ROOT, shell=True, capture_output=True, text=True)
    output = completed.stdout + completed.stderr
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(output, encoding="utf-8")
    result["exit_code"] = completed.returncode
    result["output_excerpt"] = output[-2000:]
    if completed.returncode != 0:
        result["status"] = "state_missing"
        result["reason"] = "docker_status_100k failed; durable state may be missing"
        return result
    payload = extract_json_object(output)
    if payload is None:
        result["status"] = "status_unparseable"
        result["reason"] = "docker_status_100k output did not contain a JSON object"
        return result
    return classify_source_payload(payload, result)


def source_state_ready(result: dict[str, Any]) -> bool:
    return result.get("status") == READY_STATUS
