#!/usr/bin/env python3
"""Validate Mojo diagnostic pure-crypto sole-backend local-reference proof artifacts."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


GATES: dict[str, dict[str, Any]] = {
    "baseline_5k": {
        "target_height": 5000,
        "target_hash": "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2",
        "utxo_count": 4574,
        "fresh_state": True,
    },
    "performance_100k": {
        "target_height": 100000,
        "target_hash": "0000000000524911745ab6eee9348bca9843c2c2b1b27eada246e3dc2f80b6b1",
        "utxo_count": 13154991,
        "fresh_state": True,
    },
    "post_100k_to_tip": {
        "target_height": None,
        "target_hash": None,
        "utxo_count": None,
        "fresh_state": False,
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate", required=True, choices=sorted(GATES))
    parser.add_argument("--artifact", required=True, help="Diagnostic pure proof JSON")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable validation output")
    return parser.parse_args()


def nonnegative_int(value: Any) -> bool:
    return isinstance(value, int) and value >= 0 and not isinstance(value, bool)


def positive_int(value: Any) -> bool:
    return nonnegative_int(value) and value > 0


def validate_target_fields(payload: dict[str, Any], expected: dict[str, Any], errors: list[str]) -> None:
    if expected["fresh_state"]:
        if payload.get("fresh_state") is not True:
            errors.append("fresh_state must be true")
        if payload.get("validated_height") != expected["target_height"]:
            errors.append("validated_height mismatch")
        if payload.get("validated_hash") != expected["target_hash"]:
            errors.append("validated_hash mismatch")
        if payload.get("chainstate_utxo_count") != expected["utxo_count"]:
            errors.append("chainstate_utxo_count mismatch")
        if payload.get("reference_finish_height") != expected["target_height"]:
            errors.append("reference_finish_height mismatch")
        if payload.get("reference_finish_hash") != expected["target_hash"]:
            errors.append("reference_finish_hash mismatch")
        return

    if payload.get("fresh_state") is not False:
        errors.append("fresh_state must be false")
    if payload.get("source_state_gate") != "performance_100k":
        errors.append("source_state_gate must be performance_100k")
    if payload.get("source_state_origin") != "port_durable_state":
        errors.append("source_state_origin must be port_durable_state")
    source_height = payload.get("source_state_height")
    source_hash = payload.get("source_state_hash")
    source_utxos = payload.get("source_state_utxo_count")
    if not nonnegative_int(source_height) or source_height < 100000:
        errors.append("source_state_height must be at least 100000")
    if not isinstance(source_hash, str) or not source_hash:
        errors.append("source_state_hash missing")
    if not positive_int(source_utxos):
        errors.append("source_state_utxo_count must be positive")
    if source_height == 100000:
        if source_hash != GATES["performance_100k"]["target_hash"]:
            errors.append("source 100k hash mismatch")
        if source_utxos != GATES["performance_100k"]["utxo_count"]:
            errors.append("source 100k UTXO mismatch")
    if payload.get("reference_start_height") != source_height:
        errors.append("reference_start_height must match source_state_height")
    if payload.get("reference_start_hash") != source_hash:
        errors.append("reference_start_hash must match source_state_hash")
    finish_height = payload.get("reference_finish_height")
    finish_hash = payload.get("reference_finish_hash")
    if not positive_int(finish_height):
        errors.append("reference_finish_height must be positive")
    if not isinstance(finish_hash, str) or not finish_hash:
        errors.append("reference_finish_hash missing")
    if payload.get("validated_height") != finish_height:
        errors.append("validated_height must match reference_finish_height")
    if payload.get("validated_hash") != finish_hash:
        errors.append("validated_hash must match reference_finish_hash")
    if nonnegative_int(source_height) and nonnegative_int(finish_height) and finish_height <= source_height:
        errors.append("post_100k_to_tip finish height must exceed source height")
    if not positive_int(payload.get("chainstate_utxo_count")):
        errors.append("chainstate_utxo_count must be positive")


def validate(path: Path, gate: str) -> dict[str, Any]:
    errors: list[str] = []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"path": str(path), "gate": gate, "result": "failed", "errors": [f"invalid JSON: {exc}"]}

    if not isinstance(payload, dict):
        return {"path": str(path), "gate": gate, "result": "failed", "errors": ["artifact root must be object"]}

    expected = GATES[gate]
    if payload.get("schema") != "port.local_reference_proof.v1":
        errors.append("schema must be port.local_reference_proof.v1")
    if payload.get("category") != "local_reference_sync":
        errors.append("category must be local_reference_sync")
    if payload.get("benchmark_gate") != gate:
        errors.append("benchmark_gate mismatch")
    if payload.get("benchmark_comparability") != "diagnostic_non_comparable":
        errors.append("benchmark_comparability must be diagnostic_non_comparable")
    if payload.get("port") != "mojo":
        errors.append("port must be mojo")
    if payload.get("result") != "passed" or payload.get("status") != "passed":
        errors.append("pure proof result/status must be passed")
    validate_target_fields(payload, expected, errors)
    if payload.get("native_crypto_available") is not False:
        errors.append("native_crypto_available must be false for pure diagnostic proof")
    if payload.get("native_crypto_backend") != "none":
        errors.append("native_crypto_backend must be none")
    if payload.get("crypto_backend") != "mojo-pure-secp256k1":
        errors.append("crypto_backend must be mojo-pure-secp256k1")
    if payload.get("native_fallback_used") is not False:
        errors.append("native_fallback_used must be false")
    shadow = payload.get("shadow_crypto")
    if shadow is not None:
        if not isinstance(shadow, dict) or shadow.get("enabled") is not False:
            errors.append("pure sole-backend proof must not include enabled shadow_crypto")

    if payload.get("rocksdb_wal_disabled") is not False:
        errors.append("rocksdb_wal_disabled must be false")
    if payload.get("chainstate_backend") != "rocksdb":
        errors.append("chainstate_backend must be rocksdb")

    timing = payload.get("timing_summary")
    if not isinstance(timing, dict):
        errors.append("timing_summary object missing")
    stage_totals = payload.get("stage_totals_ms")
    if not isinstance(stage_totals, dict):
        errors.append("stage_totals_ms object missing")
    telemetry = payload.get("telemetry_summary")
    if not isinstance(telemetry, dict):
        errors.append("telemetry_summary object missing")
    elif telemetry.get("telemetry_quality") != "clean":
        errors.append("telemetry_quality must be clean")

    script_metrics = payload.get("script_metrics")
    if not isinstance(script_metrics, dict):
        errors.append("script_metrics object missing")
        script_metrics = {}
    if payload.get("script_runner_actual_mode") == "parallel":
        if (
            not nonnegative_int(script_metrics.get("script_parallel_batches"))
            or script_metrics.get("script_parallel_batches", 0) <= 0
        ):
            errors.append("parallel pure proof requires positive script_parallel_batches")
        if not nonnegative_int(script_metrics.get("script_jobs")) or script_metrics.get("script_jobs", 0) <= 0:
            errors.append("parallel pure proof requires positive script_jobs")
    if gate in {"performance_100k", "post_100k_to_tip"}:
        if payload.get("script_runner_actual_mode") != "parallel":
            errors.append("long diagnostic pure proof requires script_runner_actual_mode=parallel")
        if not positive_int(script_metrics.get("script_parallel_batches")):
            errors.append("long diagnostic pure proof requires positive script_parallel_batches")
        if not positive_int(script_metrics.get("script_jobs")):
            errors.append("long diagnostic pure proof requires positive script_jobs")

    return {
        "path": str(path),
        "gate": gate,
        "target_height": payload.get("validated_height"),
        "crypto_backend": payload.get("crypto_backend"),
        "runner": payload.get("script_runner_actual_mode"),
        "result": "passed" if not errors else "failed",
        "errors": errors,
    }


def main() -> int:
    args = parse_args()
    result = validate(Path(args.artifact), args.gate)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(
            "pure_crypto_proof_validation "
            f"path={result['path']} gate={result['gate']} result={result['result']} "
            f"height={result['target_height']} backend={result['crypto_backend']} "
            f"runner={result['runner']} errors={len(result['errors'])}"
        )
        for error in result["errors"]:
            print(f"  error: {error}")
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
