#!/usr/bin/env python3
"""Validate Mojo diagnostic local-reference shadow crypto proof artifacts."""

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
    },
    "shakedown_50k": {
        "target_height": 50000,
        "target_hash": "00000000e2c8c94ba126169a88997233f07a9769e2b009fb10cad0e893eff2cb",
        "utxo_count": 568855,
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate", required=True, choices=sorted(GATES))
    parser.add_argument("--artifact", required=True, help="Diagnostic shadow proof JSON")
    parser.add_argument(
        "--require-zero-unsupported",
        action="store_true",
        help="Require full pure-shadow live coverage with unsupported_script_inputs=0",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable validation output")
    return parser.parse_args()


def nonnegative_int(value: Any) -> bool:
    return isinstance(value, int) and value >= 0 and not isinstance(value, bool)


def validate(path: Path, gate: str, *, require_zero_unsupported: bool = False) -> dict[str, Any]:
    errors: list[str] = []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"path": str(path), "gate": gate, "result": "failed", "errors": [f"invalid JSON: {exc}"]}

    expected = GATES[gate]
    if not isinstance(payload, dict):
        return {"path": str(path), "gate": gate, "result": "failed", "errors": ["artifact root must be object"]}

    if payload.get("schema") != "port.local_reference_proof.v1":
        errors.append("schema must be port.local_reference_proof.v1")
    if payload.get("category") != "local_reference_sync":
        errors.append("category must be local_reference_sync")
    if payload.get("port") != "mojo":
        errors.append("port must be mojo")
    if payload.get("benchmark_gate") != gate:
        errors.append("benchmark_gate mismatch")
    if payload.get("benchmark_comparability") != "diagnostic_non_comparable":
        errors.append("benchmark_comparability must be diagnostic_non_comparable")
    if payload.get("native_crypto_backend") != "libsecp256k1":
        errors.append("native_crypto_backend must remain libsecp256k1")
    if payload.get("result") != "passed" or payload.get("status") != "passed":
        errors.append("native proof result/status must be passed")
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

    shadow = payload.get("shadow_crypto")
    if not isinstance(shadow, dict):
        errors.append("shadow_crypto object missing")
        shadow = {}
    if shadow.get("enabled") is not True:
        errors.append("shadow_crypto.enabled must be true")
    if shadow.get("backend") != "mojo-pure-secp256k1":
        errors.append("shadow backend mismatch")
    if shadow.get("diagnostic_only") is not True:
        errors.append("shadow_crypto.diagnostic_only must be true")
    if shadow.get("native_fallback_used") is not False:
        errors.append("native fallback must be false")

    runner_mode = shadow.get("runner_mode")
    runner_actual_mode = shadow.get("runner_actual_mode")
    script_jobs = shadow.get("script_jobs")
    parallel_batches = shadow.get("parallel_batches")
    thread_count = shadow.get("thread_count")
    if runner_mode not in {"sequential", "parallel"}:
        errors.append("shadow runner_mode must be sequential or parallel")
    if runner_actual_mode not in {"sequential", "parallel"}:
        errors.append("shadow runner_actual_mode must be sequential or parallel")
    for field, value in (
        ("script_jobs", script_jobs),
        ("parallel_batches", parallel_batches),
        ("thread_count", thread_count),
    ):
        if not nonnegative_int(value):
            errors.append(f"shadow {field} must be a nonnegative integer")
    if runner_mode == "parallel" or runner_actual_mode == "parallel":
        if runner_actual_mode != "parallel":
            errors.append("shadow parallel claim requires runner_actual_mode=parallel")
        if not nonnegative_int(script_jobs) or script_jobs <= 0:
            errors.append("shadow parallel claim requires positive script_jobs")
        if not nonnegative_int(parallel_batches) or parallel_batches <= 0:
            errors.append("shadow parallel claim requires positive parallel_batches")
        if not nonnegative_int(thread_count):
            errors.append("shadow parallel claim requires thread_count")

    attempted = shadow.get("attempted_script_inputs")
    supported = shadow.get("supported_script_inputs")
    unsupported = shadow.get("unsupported_script_inputs")
    agreed = shadow.get("agreed_script_inputs")
    disagreed = shadow.get("disagreed_script_inputs")
    for field, value in (
        ("attempted_script_inputs", attempted),
        ("supported_script_inputs", supported),
        ("unsupported_script_inputs", unsupported),
        ("agreed_script_inputs", agreed),
        ("disagreed_script_inputs", disagreed),
    ):
        if not nonnegative_int(value):
            errors.append(f"{field} must be a nonnegative integer")

    if nonnegative_int(attempted) and nonnegative_int(supported) and nonnegative_int(unsupported):
        if attempted != supported + unsupported:
            errors.append("attempted must equal supported + unsupported")
        if attempted <= 0:
            errors.append("shadow attempted_script_inputs must be greater than zero")
        if require_zero_unsupported and unsupported != 0:
            errors.append("unsupported_script_inputs must be zero")
    if nonnegative_int(supported) and nonnegative_int(agreed) and nonnegative_int(disagreed):
        if supported != agreed + disagreed:
            errors.append("supported must equal agreed + disagreed")
        if supported <= 0:
            errors.append("shadow supported_script_inputs must be greater than zero")
    if disagreed != 0:
        errors.append("shadow disagreements must be zero")
    if shadow.get("first_disagreement") is not None:
        errors.append("first_disagreement must be null for a clean diagnostic proof")

    unsupported_by_reason = shadow.get("unsupported_by_reason")
    if not isinstance(unsupported_by_reason, dict):
        errors.append("unsupported_by_reason object missing")
        unsupported_by_reason = {}
    reason_total = 0
    for field in ("p2sh", "segwit_v0", "legacy_other", "other"):
        value = unsupported_by_reason.get(field)
        if not nonnegative_int(value):
            errors.append(f"unsupported_by_reason.{field} must be nonnegative integer")
        else:
            reason_total += int(value)
    if nonnegative_int(unsupported) and reason_total != unsupported:
        errors.append("unsupported_by_reason total mismatch")

    timing = shadow.get("timing_ms")
    if not isinstance(timing, dict):
        errors.append("shadow timing_ms object missing")
        timing = {}
    for field in (
        "total",
        "p2pkh_ecdsa",
        "p2sh",
        "segwit_v0",
        "legacy_other",
        "other",
        "taproot_schnorr",
        "taproot_tweak",
    ):
        if not nonnegative_int(timing.get(field)):
            errors.append(f"timing_ms.{field} must be nonnegative integer")

    return {
        "path": str(path),
        "gate": gate,
        "target_height": payload.get("validated_height"),
        "shadow_attempted": shadow.get("attempted_script_inputs"),
        "shadow_supported": shadow.get("supported_script_inputs"),
        "shadow_unsupported": shadow.get("unsupported_script_inputs"),
        "shadow_disagreed": shadow.get("disagreed_script_inputs"),
        "result": "passed" if not errors else "failed",
        "errors": errors,
    }


def main() -> int:
    args = parse_args()
    result = validate(Path(args.artifact), args.gate, require_zero_unsupported=args.require_zero_unsupported)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(
            "shadow_crypto_proof_validation "
            f"path={result['path']} gate={result['gate']} result={result['result']} "
            f"height={result['target_height']} supported={result['shadow_supported']} "
            f"unsupported={result['shadow_unsupported']} disagreements={result['shadow_disagreed']} "
            f"errors={len(result['errors'])}"
        )
        for error in result["errors"]:
            print(f"  error: {error}")
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
