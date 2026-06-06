#!/usr/bin/env python3
"""Read-only benchmark gate preflight.

This checks whether Project mission control knows enough about a port to start
an official benchmark gate run without creating ambiguous evidence. It does not
open or mutate any port datadir.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any


PASSABLE_DOCKER_STATUSES = {
    "contract_passed",
    "proof_partial",
    "supervisor_partial",
}

GATE_ALIASES = {
    "supporting_5k": "baseline_5k",
    "supporting_50k": "shakedown_50k",
    "primary_100k": "performance_100k",
}

REQUIRED_ARTIFACT_FIELDS = (
    "implementation",
    "runtime_surface",
    "benchmark_contract_version",
    "benchmark_lane",
    "benchmark_kind",
    "target_height",
    "target_label",
    "header_target_height",
    "byte_source",
    "reference_start_height",
    "reference_start_hash",
    "reference_finish_height",
    "reference_finish_hash",
    "validated_height",
    "validated_hash",
    "blocks_fetched",
    "blocks_connected",
    "current_blocker",
    "binary_gate_status",
    "chainstate_backend",
    "chainstate_utxo_count",
    "utxo_accounting_policy",
    "native_crypto_backend",
    "proof_mode",
    "peer_mode",
    "peer",
    "script_runner_mode",
    "rocksdb_wal_disabled",
    "prefetch_depth",
    "resume_supported",
    "fresh_state",
    "result",
    "failures",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project DB path")
    parser.add_argument("--gate", default="baseline_5k", help="Benchmark gate id")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--port", help="Port to preflight")
    group.add_argument("--all", action="store_true", help="Preflight all non-reference ports")
    parser.add_argument("--json", action="store_true", help="Emit JSON")
    return parser.parse_args()


def connect(db_path: str) -> sqlite3.Connection:
    db = Path(db_path)
    if not db.exists():
        raise SystemExit(f"Project DB not found: {db}")
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    return conn


def one(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...]) -> dict[str, Any] | None:
    row = conn.execute(sql, params).fetchone()
    return dict(row) if row else None


def all_rows(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    return [dict(row) for row in conn.execute(sql, params).fetchall()]


def as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


def is_falseish(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, bool):
        return not value
    if isinstance(value, int):
        return value == 0
    if isinstance(value, str):
        return value.strip().lower() in {"", "0", "false", "no", "off", "null"}
    return False


def load_json_object(raw: str, label: str, errors: list[str]) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        errors.append(f"{label} is not valid JSON: {exc}")
        return {}
    if not isinstance(parsed, dict):
        errors.append(f"{label} must be a JSON object")
        return {}
    return parsed


def benchmark_ports(conn: sqlite3.Connection) -> list[str]:
    rows = all_rows(
        conn,
        """
        SELECT port
        FROM docker_contracts
        WHERE port <> 'reference'
        ORDER BY port
        """,
    )
    return [row["port"] for row in rows]


def required_metadata(gate: dict[str, Any]) -> dict[str, Any]:
    return {
        "benchmark_contract_version": 1,
        "benchmark_kind": gate["benchmark_kind"],
        "benchmark_lane": gate["official_lane"],
        "target_height": gate["target_height"],
        "target_label": gate["target_label"],
        "header_target_height": gate["official_header_target_height"],
        "runtime_surface": gate["preferred_runtime_surface"],
        "peer_mode": gate["official_peer_mode"],
        "byte_source": gate["official_byte_source"],
        "proof_mode": gate["official_proof_mode"],
        "prefetch_depth": gate["official_prefetch_depth"],
        "script_runner_mode": gate["official_script_runner_mode"],
        "utxo_accounting_policy": gate["official_utxo_accounting_policy"],
        "chainstate_utxo_count": gate["official_chainstate_utxo_count"],
        "rocksdb_wal_disabled": False,
        "fresh_state": bool(gate["fresh_state_required"]),
        "resume_supported": bool(gate["resume_supported_required"]),
        "binary_gate_status": gate["binary_gate_status"],
        "result_name_pattern": gate["result_name_pattern"],
    }


def preflight_port(conn: sqlite3.Connection, gate: dict[str, Any], port: str) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    contract = one(
        conn,
        """
        SELECT *
        FROM docker_contracts
        WHERE port = ?
        """,
        (port,),
    )
    if contract is None:
        errors.append("missing docker_contracts row")
        return {
            "gate": gate["gate_id"],
            "port": port,
            "gate_status": "unknown",
            "errors": errors,
            "warnings": warnings,
            "required_metadata": required_metadata(gate),
        }

    command_key = gate["preferred_command_key"]
    command = one(
        conn,
        """
        SELECT *
        FROM port_command_surface
        WHERE port = ? AND command_key = ?
        """,
        (port, command_key),
    )
    gate_row = one(
        conn,
        """
        SELECT *
        FROM benchmark_gate_matrix
        WHERE gate_id = ? AND port = ?
        """,
        (gate["gate_id"], port),
    )

    if (
        gate_row is not None
        and gate_row.get("lifecycle_status") in {"baseline_retired", "active_development"}
        and gate["gate_id"] != "baseline_5k"
        and gate_row.get("comparability_status") in {"retired", "active_development", "missing"}
    ):
        return {
            "gate": gate["gate_id"],
            "port": port,
            "lifecycle_status": gate_row.get("lifecycle_status"),
            "benchmark_scope": gate_row.get("benchmark_scope"),
            "retired_at_gate": gate_row.get("retired_at_gate"),
            "gate_status": gate_row.get("gate_status"),
            "comparability_status": gate_row.get("comparability_status"),
            "validated_height": gate_row.get("validated_height"),
            "errors": [],
            "warnings": [],
            "required_metadata": required_metadata(gate),
            "required_artifact_fields": REQUIRED_ARTIFACT_FIELDS,
        }

    docker_status = contract["status"]
    if docker_status not in PASSABLE_DOCKER_STATUSES:
        errors.append(
            f"docker status {docker_status!r} is not benchmark-ready "
            f"(expected one of {sorted(PASSABLE_DOCKER_STATUSES)})"
        )

    if command is None:
        errors.append(f"missing preferred command {command_key!r}")
    else:
        if not as_bool(command["supported"]):
            errors.append(f"preferred command {command_key!r} is not supported")
        if not str(command["command"]).strip():
            errors.append(f"preferred command {command_key!r} has no command text")
        command_text = str(command["command"]).strip().lower()
        if any(marker in command_text for marker in ("rpc-replay", "replay-local", "storage-proof")):
            errors.append(
                f"preferred command {command_key!r} looks like replay/storage proof, "
                f"but official {gate['target_label']} requires local Reference P2P"
            )

    if gate["preferred_runtime_surface"] != "docker":
        errors.append(
            f"gate preferred_runtime_surface={gate['preferred_runtime_surface']!r}; expected 'docker'"
        )

    peer_modes = load_json_object(contract["peer_modes_json"], "peer_modes_json", errors)
    local_reference = peer_modes.get("local_reference")
    if gate["local_reference_required"]:
        if not isinstance(local_reference, dict):
            errors.append("local_reference peer mode is missing")
        elif not as_bool(local_reference.get("supported")):
            errors.append("local_reference peer mode is not supported")
        else:
            if not str(local_reference.get("command") or "").strip():
                errors.append("local_reference peer mode has no command")
            peer = str(local_reference.get("peer") or "").strip()
            if not peer:
                errors.append("local_reference peer mode has no peer/source description")
            elif peer == "host.docker.internal:48333":
                errors.append(
                    "local_reference peer must use Docker DNS bitcoin-core-testnet4:48333, "
                    "not host.docker.internal:48333"
                )
            elif "should be" in peer.lower() or "currently" in peer.lower():
                warnings.append(f"local_reference peer/source needs cleanup: {peer}")

    if gate["durable_required"]:
        if not str(contract["proof_volume"]).strip():
            errors.append("durable benchmark requires a proof_volume")

    if gate["wal_disabled_required"] != 0:
        errors.append("gate requires WAL disabled; official benchmark gates must keep WAL enabled")

    imported_row_claims_official_lane = bool(
        gate_row
        and (
            gate_row.get("comparability_status") == "comparable"
            or gate_row.get("evidence_lane") == gate["official_lane"]
        )
    )

    imported_wal = gate_row["rocksdb_wal_disabled"] if gate_row else ""
    if not is_falseish(imported_wal):
        message = (
            "latest imported gate evidence has rocksdb_wal_disabled="
            f"{imported_wal!r}; official runs require false"
        )
        if imported_row_claims_official_lane:
            errors.append(message)
        else:
            warnings.append(message)

    if gate_row and gate_row["utxo_accounting_policy"] and gate_row["utxo_accounting_policy"] != gate["official_utxo_accounting_policy"]:
        message = (
            "latest imported gate evidence has utxo_accounting_policy="
            f"{gate_row['utxo_accounting_policy']!r}; expected {gate['official_utxo_accounting_policy']!r}"
        )
        if imported_row_claims_official_lane:
            errors.append(message)
        else:
            warnings.append(message)

    if (
        gate_row
        and int(gate["official_chainstate_utxo_count"]) >= 0
        and int(gate_row["chainstate_utxo_count"]) >= 0
        and int(gate_row["chainstate_utxo_count"]) != int(gate["official_chainstate_utxo_count"])
    ):
        message = (
            "latest imported gate evidence has chainstate_utxo_count="
            f"{gate_row['chainstate_utxo_count']}; expected {gate['official_chainstate_utxo_count']}"
        )
        if imported_row_claims_official_lane:
            errors.append(message)
        else:
            warnings.append(message)

    if gate_row and gate_row.get("comparability_status") not in (None, "", "missing", "comparable"):
        warnings.append(
            "latest imported gate evidence is "
            f"{gate_row['comparability_status']} ({gate_row.get('evidence_lane', '')}); "
            f"notes={gate_row.get('comparability_notes', '') or 'none'}"
        )

    if gate_row and gate_row["runtime_surface"] and gate_row["runtime_surface"] != "docker":
        warnings.append(
            f"latest imported gate evidence runtime_surface={gate_row['runtime_surface']!r}; "
            "next official run should report docker"
        )

    if gate_row and gate_row["peer_mode"] and gate_row["peer_mode"] != gate["official_peer_mode"]:
        warnings.append(
            f"latest imported gate evidence peer_mode={gate_row['peer_mode']!r}; "
            "next official run should report local_reference"
        )

    return {
        "gate": gate["gate_id"],
        "port": port,
        "lifecycle_status": gate_row.get("lifecycle_status") if gate_row else "",
        "benchmark_scope": gate_row.get("benchmark_scope") if gate_row else "",
        "retired_at_gate": gate_row.get("retired_at_gate") if gate_row else "",
        "node_id": contract["node_id"],
        "docker_status": docker_status,
        "gate_status": gate_row["gate_status"] if gate_row else "unknown",
        "comparability_status": gate_row["comparability_status"] if gate_row else "unknown",
        "evidence_lane": gate_row["evidence_lane"] if gate_row else "",
        "comparability_notes": gate_row["comparability_notes"] if gate_row else "",
        "validated_height": gate_row["validated_height"] if gate_row else -1,
        "utxo_accounting_policy": gate_row["utxo_accounting_policy"] if gate_row else "",
        "chainstate_utxo_count": gate_row["chainstate_utxo_count"] if gate_row else -1,
        "command_key": command_key,
        "command": command["command"] if command else "",
        "proof_volume": contract["proof_volume"],
        "supervisor_volume": contract["supervisor_volume"],
        "local_reference": local_reference if isinstance(local_reference, dict) else {},
        "required_metadata": required_metadata(gate),
        "required_artifact_fields": list(REQUIRED_ARTIFACT_FIELDS),
        "errors": errors,
        "warnings": warnings,
    }


def print_text(results: list[dict[str, Any]]) -> None:
    for index, result in enumerate(results):
        if index:
            print()
        print(
            "benchmark_preflight "
            f"gate={result['gate']} "
            f"port={result['port']} "
            f"lifecycle={result.get('lifecycle_status') or ''} "
            f"gate_status={result['gate_status']} "
            f"comparability={result.get('comparability_status', 'unknown')} "
            f"errors={len(result['errors'])} "
            f"warnings={len(result['warnings'])}"
        )
        if result.get("node_id"):
            print(f"  node_id={result['node_id']}")
        if result.get("docker_status"):
            print(f"  docker_status={result['docker_status']}")
        if "validated_height" in result:
            print(f"  latest_gate_validated_height={result['validated_height']}")
        if result.get("utxo_accounting_policy"):
            print(f"  latest_utxo_accounting_policy={result['utxo_accounting_policy']}")
        if "chainstate_utxo_count" in result:
            print(f"  latest_chainstate_utxo_count={result['chainstate_utxo_count']}")
        if result.get("evidence_lane"):
            print(f"  latest_evidence_lane={result['evidence_lane']}")
        if result.get("comparability_notes"):
            print(f"  comparability_notes={result['comparability_notes']}")
        if result.get("command_key"):
            print(f"  command_key={result['command_key']}")
        if result.get("command"):
            print(f"  command={result['command']}")
        if result.get("proof_volume"):
            print(f"  proof_volume={result['proof_volume']}")
        if result.get("supervisor_volume"):
            print(f"  supervisor_volume={result['supervisor_volume']}")
        local_reference = result.get("local_reference") or {}
        if local_reference:
            print(f"  local_reference_supported={local_reference.get('supported')}")
            if local_reference.get("peer"):
                print(f"  local_reference_peer={local_reference.get('peer')}")
        print("  required_metadata:")
        for key, value in result["required_metadata"].items():
            print(f"    {key}={json.dumps(value, sort_keys=True)}")
        print("  required_artifact_fields:")
        print("    " + ", ".join(result["required_artifact_fields"]))
        for warning in result["warnings"]:
            print(f"  warning: {warning}")
        for error in result["errors"]:
            print(f"  error: {error}")


def main() -> int:
    args = parse_args()
    gate_id = GATE_ALIASES.get(args.gate, args.gate)
    conn = connect(args.db)
    gate = one(
        conn,
        """
        SELECT *
        FROM benchmark_gates
        WHERE gate_id = ?
        """,
        (gate_id,),
    )
    if gate is None:
        raise SystemExit(f"missing benchmark gate: {args.gate}")

    ports = benchmark_ports(conn) if args.all else [args.port]
    results = [preflight_port(conn, gate, port) for port in ports]
    error_count = sum(len(result["errors"]) for result in results)
    warning_count = sum(len(result["warnings"]) for result in results)

    if args.json:
        print(
            json.dumps(
                {
                    "gate": args.gate,
                    "canonical_gate": gate_id,
                    "error_count": error_count,
                    "warning_count": warning_count,
                    "results": results,
                },
                indent=2,
                sort_keys=True,
            )
        )
    else:
        print_text(results)
        print()
        print(
            f"benchmark_preflight_summary gate={gate_id} "
            f"ports={len(results)} errors={error_count} warnings={warning_count}"
        )

    return 1 if error_count else 0


if __name__ == "__main__":
    sys.exit(main())
