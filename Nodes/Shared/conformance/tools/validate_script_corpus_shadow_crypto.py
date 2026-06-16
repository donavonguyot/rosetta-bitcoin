#!/usr/bin/env python3
"""Validate a diagnostic script-corpus shadow crypto artifact."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REQUIRED_SCHEMA = "port.script_corpus_shadow_crypto.v1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", nargs="+", help="Shadow crypto result JSON files")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable validation output")
    parser.add_argument(
        "--require-shadow-timing",
        action="store_true",
        help="Require diagnostic timing fields for attempted pure-shadow rows",
    )
    parser.add_argument(
        "--max-shadow-row-ms",
        type=int,
        default=None,
        help="Reject artifacts with any attempted pure-shadow row above this duration",
    )
    return parser.parse_args()


def text(value: Any) -> str:
    return "" if value is None else str(value)


def nonnegative_int(value: Any) -> bool:
    return isinstance(value, int) and value >= 0 and not isinstance(value, bool)


def validate(
    path: Path,
    *,
    require_shadow_timing: bool = False,
    max_shadow_row_ms: int | None = None,
) -> dict[str, Any]:
    errors: list[str] = []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"path": str(path), "result": "failed", "errors": [f"invalid JSON: {exc}"]}

    if not isinstance(payload, dict):
        return {"path": str(path), "result": "failed", "errors": ["artifact root must be an object"]}

    if payload.get("schema") != REQUIRED_SCHEMA:
        errors.append("schema check failed")
    if payload.get("category") != "script_corpus_shadow_crypto":
        errors.append("category check failed")
    if text(payload.get("native_crypto_backend")).lower() != "libsecp256k1":
        errors.append("native_crypto_backend must remain libsecp256k1")
    if not text(payload.get("shadow_crypto_backend")).strip():
        errors.append("shadow_crypto_backend missing")
    if payload.get("fixture_count") != 45:
        errors.append("fixture_count must be 45")
    if payload.get("native_passed") != 45 or payload.get("native_failed") != 0:
        errors.append("native corpus lane must pass 45/45")
    if payload.get("result") not in {"diagnostic", "passed", "failed"}:
        errors.append("result must be diagnostic, passed, or failed")

    rows = payload.get("results")
    if not isinstance(rows, list):
        errors.append("results must be a list")
        rows = []
    if len(rows) != payload.get("fixture_count"):
        errors.append("results length must match fixture_count")

    supported = 0
    agreed = 0
    disagreements = 0
    supported_timing_total = 0
    max_row_ms = 0
    attempted_timing_total = 0
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            errors.append(f"results[{index}] is not an object")
            continue
        if not text(row.get("fixture_id")).strip():
            errors.append(f"results[{index}] missing fixture_id")
        if row.get("native_result") not in {"passed", "failed"}:
            errors.append(f"results[{index}] native_result invalid")
        if row.get("shadow_result") not in {"passed", "failed", "unsupported", "malformed", "consensus_invalid"}:
            errors.append(f"results[{index}] shadow_result invalid")
        if "shadow_supported" not in row:
            errors.append(f"results[{index}] missing shadow_supported")
        if "shadow_agreed" not in row:
            errors.append(f"results[{index}] missing shadow_agreed")
        if row.get("shadow_used_native_fallback") is not False:
            errors.append(f"results[{index}] used native fallback")
        if row.get("shadow_result") == "passed" and not row.get("shadow_supported"):
            errors.append(f"results[{index}] pure pass without support marker")
        if row.get("shadow_supported") is True:
            supported += 1
            if require_shadow_timing and not nonnegative_int(row.get("shadow_duration_ms")):
                errors.append(f"results[{index}] supported row missing shadow_duration_ms")
        if row.get("shadow_agreed") is True:
            agreed += 1
        if row.get("shadow_supported") is True and row.get("shadow_agreed") is not True:
            disagreements += 1
        if "shadow_duration_ms" in row:
            if not nonnegative_int(row.get("shadow_duration_ms")):
                errors.append(f"results[{index}] invalid shadow_duration_ms")
            else:
                duration = int(row["shadow_duration_ms"])
                attempted_timing_total += duration
                if row.get("shadow_supported") is True:
                    supported_timing_total += duration
                max_row_ms = max(max_row_ms, duration)
                if max_shadow_row_ms is not None and duration > max_shadow_row_ms:
                    errors.append(f"results[{index}] shadow_duration_ms exceeds {max_shadow_row_ms}")

    if payload.get("shadow_supported") != supported:
        errors.append("shadow_supported count mismatch")
    if supported <= 0:
        errors.append("shadow_supported must be greater than zero")
    if payload.get("shadow_agreed") != agreed:
        errors.append("shadow_agreed count mismatch")
    if payload.get("disagreements") != disagreements:
        errors.append("disagreements count mismatch")
    if disagreements != 0:
        errors.append("shadow crypto disagreements must be zero")
    if payload.get("shadow_unsupported") != payload.get("fixture_count", 0) - supported:
        errors.append("shadow_unsupported count mismatch")

    if require_shadow_timing:
        for field in ("shadow_eval_ms", "shadow_supported_eval_ms", "shadow_max_row_ms"):
            if not nonnegative_int(payload.get(field)):
                errors.append(f"{field} missing or invalid")
        if nonnegative_int(payload.get("shadow_eval_ms")) and payload.get("shadow_eval_ms") != attempted_timing_total:
            errors.append("shadow_eval_ms does not match row durations")
        if (
            nonnegative_int(payload.get("shadow_supported_eval_ms"))
            and payload.get("shadow_supported_eval_ms") != supported_timing_total
        ):
            errors.append("shadow_supported_eval_ms does not match supported row durations")
        if nonnegative_int(payload.get("shadow_max_row_ms")) and payload.get("shadow_max_row_ms") != max_row_ms:
            errors.append("shadow_max_row_ms does not match row maximum")

    return {
        "path": str(path),
        "schema": payload.get("schema", ""),
        "port": payload.get("port", ""),
        "fixture_count": payload.get("fixture_count", 0),
        "shadow_supported": payload.get("shadow_supported", 0),
        "disagreements": payload.get("disagreements", 0),
        "shadow_max_row_ms": payload.get("shadow_max_row_ms", 0),
        "result": "passed" if not errors else "failed",
        "errors": errors,
    }


def main() -> int:
    args = parse_args()
    results = [
        validate(
            Path(path),
            require_shadow_timing=args.require_shadow_timing,
            max_shadow_row_ms=args.max_shadow_row_ms,
        )
        for path in args.artifacts
    ]
    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        for result in results:
            print(
                "script_corpus_shadow_crypto_validation "
                f"path={result['path']} result={result['result']} "
                f"supported={result['shadow_supported']} disagreements={result['disagreements']} "
                f"max_row_ms={result['shadow_max_row_ms']} "
                f"errors={len(result['errors'])}"
            )
            for error in result["errors"]:
                print(f"  error: {error}")
    return 1 if any(result["errors"] for result in results) else 0


if __name__ == "__main__":
    sys.exit(main())
