#!/usr/bin/env python3
"""Read-only consensus runway preflight.

Consensus runway checks Project's imported truth surface. It does not inspect or
open port-local runtime state.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path
from typing import Any


STAGES = ("corpus", "5k", "10k", "50k", "100k", "tip")
BAD_NATIVE_CRYPTO_VALUES = {"managed", "pure", "fallback", "not_enabled", "unavailable", "none", "false"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project DB path")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--port", help="Port to preflight")
    group.add_argument("--all", action="store_true", help="Preflight all non-reference ports")
    parser.add_argument("--stage", choices=STAGES, default="corpus", help="Runway stage to check")
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


def all_ports(conn: sqlite3.Connection) -> list[str]:
    return [
        row["port"]
        for row in rows(
            conn,
            "select port from docker_contracts where port <> 'reference' order by port",
        )
    ]


def preflight_port(conn: sqlite3.Connection, port: str, stage: str) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []
    row = one(
        conn,
        """
        select *
        from consensus_runway
        where port = ? and stage = ?
        """,
        (port, stage),
    )
    if row is None:
        return {
            "port": port,
            "stage": stage,
            "runway_status": "missing",
            "errors": ["missing consensus_runway row"],
            "warnings": [],
        }

    has_clean_corpus = row["has_clean_script_corpus"] == 1
    if not has_clean_corpus:
        errors.append(
            "missing clean per-port script corpus proof "
            f"(passed={row['script_passed']}, failed={row['script_failed']})"
        )
    native_crypto = str(row.get("script_native_crypto_backend") or "").strip().lower()
    if native_crypto in BAD_NATIVE_CRYPTO_VALUES:
        errors.append(f"script corpus native crypto is non-native/fallback: {native_crypto}")
    elif has_clean_corpus and not native_crypto:
        warnings.append("script corpus artifact does not declare native_crypto_backend")

    if int(row.get("open_blocker_count") or 0) > 0:
        errors.append(f"open blockers at or below stage: {row.get('open_blocker_heights')}")

    if stage != "corpus" and row.get("baseline_5k_status") != "passed":
        errors.append(f"5k baseline is not passed: {row.get('baseline_5k_status') or 'missing'}")

    target_height = int(row.get("target_height") or -1)
    if stage == "10k" and row.get("runway_status") != "passed":
        errors.append(
            "missing comparable 10k benchmark gate proof "
            f"(stage_gate_status={row.get('stage_gate_status') or 'missing'}, "
            f"stage_gate_comparability={row.get('stage_gate_comparability') or 'missing'})"
        )
    if stage in {"10k", "50k", "100k"} and int(row.get("max_validated_height") or -1) < target_height:
        errors.append(
            f"missing {stage} stage proof: max_validated_height={row.get('max_validated_height')} "
            f"target={target_height}"
        )
    if stage == "tip" and row.get("runway_status") != "passed":
        errors.append(
            "missing tip proof "
            f"(sync_status={row.get('sync_status')}, "
            f"validated={row.get('max_validated_height')}, header={row.get('header_height')})"
        )

    if row.get("runway_status") != "passed":
        warnings.append(f"Project runway projection status={row.get('runway_status')}")

    return {
        "port": port,
        "stage": stage,
        "runway_status": row.get("runway_status"),
        "target_height": row.get("target_height"),
        "has_clean_script_corpus": row.get("has_clean_script_corpus"),
        "script_passed": row.get("script_passed"),
        "script_failed": row.get("script_failed"),
        "script_runtime_surface": row.get("script_runtime_surface"),
        "script_native_crypto_backend": row.get("script_native_crypto_backend"),
        "baseline_5k_status": row.get("baseline_5k_status"),
        "stage_gate_status": row.get("stage_gate_status"),
        "stage_gate_comparability": row.get("stage_gate_comparability"),
        "max_validated_height": row.get("max_validated_height"),
        "header_height": row.get("header_height"),
        "sync_status": row.get("sync_status"),
        "open_blocker_count": row.get("open_blocker_count"),
        "open_blocker_heights": row.get("open_blocker_heights"),
        "script_source_artifact_id": row.get("script_source_artifact_id"),
        "baseline_source_artifact_id": row.get("baseline_source_artifact_id"),
        "status_source_artifact_id": row.get("status_source_artifact_id"),
        "errors": errors,
        "warnings": warnings,
    }


def print_text(results: list[dict[str, Any]]) -> None:
    for index, result in enumerate(results):
        if index:
            print()
        print(
            "consensus_runway_preflight "
            f"port={result['port']} "
            f"stage={result['stage']} "
            f"status={result['runway_status']} "
            f"errors={len(result['errors'])} "
            f"warnings={len(result['warnings'])}"
        )
        print(
            "  script_corpus="
            f"{result.get('has_clean_script_corpus')} "
            f"passed={result.get('script_passed')} failed={result.get('script_failed')} "
            f"native_crypto={result.get('script_native_crypto_backend') or ''}"
        )
        print(f"  baseline_5k={result.get('baseline_5k_status') or ''}")
        if result.get("stage") in {"10k", "50k", "100k"}:
            print(
                "  stage_gate="
                f"{result.get('stage_gate_status') or ''} "
                f"comparability={result.get('stage_gate_comparability') or ''}"
            )
        print(
            "  sync="
            f"{result.get('sync_status') or ''} "
            f"validated={result.get('max_validated_height')} header={result.get('header_height')}"
        )
        print(
            "  blockers="
            f"{result.get('open_blocker_count')} "
            f"heights={result.get('open_blocker_heights') or ''}"
        )
        for warning in result["warnings"]:
            print(f"  warning: {warning}")
        for error in result["errors"]:
            print(f"  error: {error}")


def main() -> int:
    args = parse_args()
    conn = connect(args.db)
    ports = all_ports(conn) if args.all else [str(args.port).lower()]
    results = [preflight_port(conn, port, args.stage) for port in ports]
    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        print_text(results)
    has_errors = any(result["errors"] for result in results)
    return 1 if args.strict and has_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
