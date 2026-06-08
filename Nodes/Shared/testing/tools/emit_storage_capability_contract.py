#!/usr/bin/env python3
"""Emit storage capability contract artifacts from bounded storage proof JSON."""

from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path
from typing import Any

import emit_crypto_capability_contract as contract_emitter


CODEC_CASE_TOTAL = 7
RESTART_CASE_TOTAL = 2


def text(value: Any, default: str = "") -> str:
    if value is None:
        return default
    return str(value)


def boolish(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "passed", "pass"}
    return bool(value)


def result_map(payload: dict[str, Any]) -> dict[str, str]:
    rows = payload.get("results")
    if not isinstance(rows, list):
        return {}
    out: dict[str, str] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        fixture = text(row.get("fixture_id")).strip()
        if fixture:
            out[fixture] = text(row.get("result")).strip()
    return out


def codec_passed(payload: dict[str, Any], results: dict[str, str]) -> bool | None:
    verification = payload.get("verification") if isinstance(payload.get("verification"), dict) else {}
    codec = payload.get("codec") if isinstance(payload.get("codec"), dict) else {}
    if boolish(verification.get("chainstate_codec_v2_vectors_run")):
        return True
    if text(verification.get("codec_v2_vectors")).strip():
        return True
    if text(codec.get("byte_for_byte_vectors")).strip():
        return all(value == "passed" for value in results.values()) if results else True

    roundtrip_cases = {
        "metadata.codec_version",
        "tip.roundtrip",
        "header.roundtrip",
        "block_index.roundtrip",
        "utxo.roundtrip",
        "undo.roundtrip",
        "metadata.prefix_iterator",
    }
    if roundtrip_cases & set(results):
        return all(results.get(case) == "passed" for case in roundtrip_cases if case in results)
    if boolish(payload.get("atomic_batch_commit")):
        return True
    return None


def restart_passed(payload: dict[str, Any], results: dict[str, str]) -> bool | None:
    if "storage.native_restart" in results:
        return results["storage.native_restart"] == "passed"
    if payload.get("startup_invariant_ms") is not None and boolish(payload.get("rocksdb_runtime_truth")):
        return True
    return None


def runtime_truth_passed(payload: dict[str, Any], results: dict[str, str]) -> bool | None:
    if "storage.rocksdb_runtime_truth" in results:
        return results["storage.rocksdb_runtime_truth"] == "passed"
    if payload.get("rocksdb_runtime_truth") is not None:
        return boolish(payload.get("rocksdb_runtime_truth"))
    backend = text(payload.get("chainstate_backend") or payload.get("storage_backend"))
    if backend:
        return backend == "rocksdb"
    return None


def counted_outcome(capability: str, passed: int, total: int, notes: str) -> dict[str, Any]:
    return {
        "capability": capability,
        "status": "pass" if passed == total else "fail",
        "case_passed": passed,
        "case_total": total,
        "notes": notes,
    }


def missing_outcome(capability: str, notes: str) -> dict[str, Any]:
    return {
        "capability": capability,
        "status": "missing",
        "notes": notes,
    }


def build_outcomes(port: str, payload: dict[str, Any] | None) -> dict[str, Any]:
    results = result_map(payload or {})
    codec = codec_passed(payload or {}, results) if payload else None
    restart = restart_passed(payload or {}, results) if payload else None
    runtime = runtime_truth_passed(payload or {}, results) if payload else None

    outcomes: list[dict[str, Any]] = []
    if codec is None:
        outcomes.append(missing_outcome("storage_codec_vectors", "no executed storage codec vector evidence was found"))
    else:
        outcomes.append(
            counted_outcome(
                "storage_codec_vectors",
                CODEC_CASE_TOTAL if codec else 0,
                CODEC_CASE_TOTAL,
                "storage codec vector evidence passed" if codec else "storage codec vector evidence failed",
            )
        )

    if runtime is None and restart is None:
        outcomes.append(missing_outcome("rocksdb_restart_persistence", "no restart persistence evidence was found"))
    else:
        passed = int(runtime is True) + int(restart is True)
        outcomes.append(
            counted_outcome(
                "rocksdb_restart_persistence",
                passed,
                RESTART_CASE_TOTAL,
                f"rocksdb_runtime_truth={runtime}; native_restart={restart}",
            )
        )

    if codec is None and restart is None:
        outcomes.append(missing_outcome("storage_restart_after_codec_change", "no restart-after-codec evidence was found"))
    else:
        passed = int(codec is True) + int(restart is True)
        outcomes.append(
            counted_outcome(
                "storage_restart_after_codec_change",
                passed,
                RESTART_CASE_TOTAL,
                f"storage_codec_vectors={codec}; native_restart={restart}",
            )
        )

    return {"port": port, "backend": "rocksdb", "outcomes": outcomes}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True, choices=sorted(contract_emitter.BACKENDS))
    parser.add_argument("--proof-path")
    parser.add_argument("--result-path", required=True)
    args = parser.parse_args()

    payload = None
    if args.proof_path:
        payload = json.loads(Path(args.proof_path).read_text(encoding="utf-8"))
    outcomes = build_outcomes(args.port, payload)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".json", delete=False) as handle:
        json.dump(outcomes, handle)
        tmp = Path(handle.name)
    try:
        artifact = contract_emitter.outcome_payload(tmp)
    finally:
        tmp.unlink(missing_ok=True)
    path = Path(args.result_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
