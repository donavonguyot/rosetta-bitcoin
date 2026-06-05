#!/usr/bin/env python3
"""Read-only 5k baseline preflight.

The 5k baseline is stricter than a benchmark target pass. It combines Project's
official comparable 5k Docker/local-reference P2P lane with RocksDB, native
crypto, script corpus, UTXO accounting, timing, and command-surface evidence.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]

PASSABLE_DOCKER_STATUSES = {
    "contract_passed",
    "proof_partial",
    "supervisor_partial",
}

REQUIRED_COMMANDS = ("docker_warm", "docker_proof_local")
REQUIRED_TIMING_BUCKETS = (
    "utxo_load",
    "script_verify",
    "utxo_apply",
    "commit",
    "block_connect_store_commit",
)
BAD_NATIVE_CRYPTO_VALUES = {"", "managed", "pure", "not_enabled", "unavailable", "none", "false"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project DB path")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--port", help="Port to preflight")
    group.add_argument("--all", action="store_true", help="Preflight all non-reference ports")
    parser.add_argument("--strict", action="store_true", help="Exit nonzero when any port has errors")
    parser.add_argument("--json", action="store_true", help="Emit JSON")
    return parser.parse_args()


def connect(db_path: str) -> sqlite3.Connection:
    db = Path(db_path)
    if not db.exists():
        raise SystemExit(f"Project DB not found: {db}")
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    return conn


def rows(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    return [dict(row) for row in conn.execute(sql, params).fetchall()]


def one(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...]) -> dict[str, Any] | None:
    row = conn.execute(sql, params).fetchone()
    return dict(row) if row else None


def as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


def all_ports(conn: sqlite3.Connection) -> list[str]:
    return [
        row["port"]
        for row in rows(
            conn,
            "select port from docker_contracts where port <> 'reference' order by port",
        )
    ]


def artifact_payload(conn: sqlite3.Connection, artifact_id: str | None) -> dict[str, Any]:
    if not artifact_id:
        return {}
    row = one(conn, "select raw_json from artifacts where artifact_id = ?", (artifact_id,))
    if not row or not row["raw_json"]:
        return {}
    try:
        parsed = json.loads(row["raw_json"])
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def timing_keys(value: Any) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, nested in value.items():
            if key in REQUIRED_TIMING_BUCKETS:
                found.add(key)
            found.update(timing_keys(nested))
    elif isinstance(value, list):
        for nested in value:
            found.update(timing_keys(nested))
    return found


def command_errors(conn: sqlite3.Connection, port: str) -> list[str]:
    errors: list[str] = []
    for command_key in REQUIRED_COMMANDS:
        command = one(
            conn,
            """
            select supported, command
            from port_command_surface
            where port = ? and command_key = ?
            """,
            (port, command_key),
        )
        if command is None:
            errors.append(f"missing command {command_key}")
            continue
        if not as_bool(command["supported"]):
            errors.append(f"command {command_key} is not supported")
        if not str(command["command"]).strip():
            errors.append(f"command {command_key} has no command text")
    return errors


def preflight_port(conn: sqlite3.Connection, port: str) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    baseline = one(conn, "select * from port_baseline_5k where port = ?", (port,))
    contract = one(conn, "select * from docker_contracts where port = ?", (port,))
    if baseline is None:
        errors.append("missing port_baseline_5k row")
        baseline = {"port": port}
    if contract is None:
        errors.append("missing docker_contracts row")
        contract = {}

    docker_status = str(contract.get("status", ""))
    if docker_status and docker_status not in PASSABLE_DOCKER_STATUSES:
        errors.append(f"docker status {docker_status!r} is not baseline-ready")
    errors.extend(command_errors(conn, port))

    if baseline.get("comparability_status") != "comparable":
        errors.append(
            "official 5k gate is not comparable"
            + (f": {baseline.get('comparability_status')}" if baseline.get("comparability_status") else "")
        )
    if int(baseline.get("validated_height") or -1) < 5000:
        errors.append(f"validated_height is {baseline.get('validated_height')}; expected >= 5000")
    if str(baseline.get("chainstate_backend") or "").lower() != "rocksdb":
        errors.append(f"chainstate_backend is {baseline.get('chainstate_backend')!r}; expected rocksdb")

    native_crypto = str(baseline.get("native_crypto_backend") or "").strip()
    if native_crypto.lower() in BAD_NATIVE_CRYPTO_VALUES:
        errors.append("native_crypto_backend is missing or not native")

    if baseline.get("script_corpus_status") != "passed":
        errors.append(
            "script corpus is not a clean pass "
            f"(status={baseline.get('script_corpus_status')}, "
            f"passed={baseline.get('script_passed')}, failed={baseline.get('script_failed')})"
        )

    fixed_fields = {
        "runtime_surface": "docker",
        "peer_mode": "local_reference",
        "byte_source": "local_reference_p2p",
        "proof_mode": "p2p_sync",
        "prefetch_depth": 4,
        "script_runner_mode": "parallel",
        "rocksdb_wal_disabled": 0,
        "fresh_state": 1,
        "utxo_accounting_policy": "core_spendable_v1",
        "chainstate_utxo_count": 4574,
    }
    for key, expected in fixed_fields.items():
        actual = baseline.get(key)
        if isinstance(expected, int):
            try:
                mismatch = int(actual) != expected
            except (TypeError, ValueError):
                mismatch = True
        else:
            mismatch = str(actual or "") != expected
        if mismatch:
            errors.append(f"{key} is {actual!r}; expected {expected!r}")

    payload = artifact_payload(conn, baseline.get("source_artifact_id"))
    artifact_timing = timing_keys(payload)
    imported_timing = set(
        row["stage"]
        for row in rows(
            conn,
            """
            select distinct ts.stage
            from timing_samples ts
            where ts.source_artifact_id = ?
            """,
            (baseline.get("source_artifact_id"),),
        )
    )
    timing = artifact_timing | imported_timing
    missing_timing = [stage for stage in REQUIRED_TIMING_BUCKETS if stage not in timing]
    if missing_timing:
        errors.append("missing required timing buckets: " + ", ".join(missing_timing))

    if baseline.get("baseline_status") != "passed":
        warnings.append(f"Project baseline projection status={baseline.get('baseline_status')}")
    if baseline.get("comparability_notes"):
        warnings.append(f"comparability_notes={baseline.get('comparability_notes')}")

    return {
        "port": port,
        "baseline_status": baseline.get("baseline_status", "missing"),
        "docker_status": docker_status,
        "validated_height": baseline.get("validated_height", -1),
        "chainstate_backend": baseline.get("chainstate_backend", ""),
        "native_crypto_backend": native_crypto,
        "script_corpus_status": baseline.get("script_corpus_status", "missing"),
        "script_passed": baseline.get("script_passed", 0),
        "script_failed": baseline.get("script_failed", 0),
        "timing_buckets": sorted(timing),
        "missing_timing_buckets": missing_timing,
        "source_artifact_id": baseline.get("source_artifact_id"),
        "errors": errors,
        "warnings": warnings,
    }


def print_text(results: list[dict[str, Any]]) -> None:
    for index, result in enumerate(results):
        if index:
            print()
        print(
            "port_baseline_preflight "
            f"port={result['port']} "
            f"status={result['baseline_status']} "
            f"errors={len(result['errors'])} "
            f"warnings={len(result['warnings'])}"
        )
        print(f"  docker_status={result['docker_status']}")
        print(f"  validated_height={result['validated_height']}")
        print(f"  chainstate_backend={result['chainstate_backend']}")
        print(f"  native_crypto_backend={result['native_crypto_backend']}")
        print(
            "  script_corpus="
            f"{result['script_corpus_status']} "
            f"passed={result['script_passed']} failed={result['script_failed']}"
        )
        print("  timing_buckets=" + ",".join(result["timing_buckets"]))
        for warning in result["warnings"]:
            print(f"  warning: {warning}")
        for error in result["errors"]:
            print(f"  error: {error}")


def main() -> int:
    args = parse_args()
    conn = connect(args.db)
    ports = all_ports(conn) if args.all else [str(args.port).lower()]
    results = [preflight_port(conn, port) for port in ports]
    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        print_text(results)
    has_errors = any(result["errors"] for result in results)
    return 1 if args.strict and has_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
