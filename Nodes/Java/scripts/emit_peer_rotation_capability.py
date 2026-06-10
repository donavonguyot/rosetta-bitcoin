#!/usr/bin/env python3
"""Emit Java peer-rotation capability evidence from a bounded rotation probe result."""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]


def rel(path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(ROOT).as_posix()
    except ValueError:
        return resolved.as_posix()


def utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def contract(status: str, evidence_path: str, notes: str) -> dict[str, Any]:
    return {
        "port": "java",
        "contract_id": "java.full_node_peer_rotation_reconnect",
        "capability": "full_node_peer_rotation_reconnect",
        "status": status,
        "scope": "docker_public_peer",
        "backend": "rocksdb+libsecp256k1-acinq",
        "evidence_kind": "peer_rotation_probe",
        "evidence_path": evidence_path,
        "command_key": "docker_probe_external",
        "suite_id": "",
        "suite_version": "",
        "suite_hash": "",
        "provenance": ["proof_derived"],
        "does_not_prove": (
            "Manual two-peer outbound rotation does not prove inbound serving, mempool relay, "
            "DNS seed selection, reorg recovery, restart soak, bad-peer safety, or resource-bound safety."
        ),
        "blocking_for": ["validator_follower", "full_node"],
        "notes": notes,
    }


def notes_for(probe: dict[str, Any]) -> str:
    keys = [
        "selected_peers",
        "disconnect_error_count",
        "reconnect_count",
        "successful_peer_count",
        "start_header_height",
        "end_header_height",
        "start_validated_height",
        "end_validated_height",
        "blocks_downloaded",
        "blocks_connected",
        "final_status",
    ]
    facts = {key: probe.get(key) for key in keys if key in probe}
    attempts = probe.get("attempted_peers")
    if isinstance(attempts, list):
        facts["attempted_peer_count"] = len(attempts)
        facts["attempted_peers"] = [row.get("peer") for row in attempts if isinstance(row, dict)]
        facts["peer_advertised_start_heights"] = [
            row.get("peer_advertised_start_height") for row in attempts if isinstance(row, dict)
        ]
        facts["local_advertised_start_heights"] = [
            row.get("local_advertised_start_height") for row in attempts if isinstance(row, dict)
        ]
    return json.dumps(facts, sort_keys=True, separators=(",", ":"))


def payload(probe_result: Path, result_path: Path) -> dict[str, Any]:
    probe = json.loads(probe_result.read_text(encoding="utf-8"))
    if probe.get("schema") != "java.public_peer_rotation_probe.v1":
        raise SystemExit(f"{probe_result}: expected java.public_peer_rotation_probe.v1")
    result = str(probe.get("result") or "").strip()
    if result not in {"pass", "fail"}:
        raise SystemExit(f"{probe_result}: result must be pass or fail")
    return {
        "schema": "port.test_capability_contract.v1",
        "category": "test_capability_contracts",
        "port": "java",
        "captured_at": str(probe.get("captured_at") or utc_now()),
        "contracts": [
            contract(
                status=result,
                evidence_path=rel(result_path),
                notes=notes_for(probe),
            )
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe-result", required=True)
    parser.add_argument("--result-path", required=True)
    args = parser.parse_args()

    probe_result = Path(args.probe_result)
    result_path = Path(args.result_path)
    result_path.parent.mkdir(parents=True, exist_ok=True)
    data = payload(probe_result, result_path)
    result_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(result_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
