#!/usr/bin/env python3
"""Validate Mojo diagnostic must-reject script corpus artifacts."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REQUIRED_SCHEMA = "port.script_corpus_reject_result.v1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", nargs="+", help="Reject corpus artifact JSON files")
    parser.add_argument(
        "--expect-red",
        action="store_true",
        help="Expect a controlled fault to make at least one reject row accept",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable validation output")
    return parser.parse_args()


def nonnegative_int(value: Any) -> bool:
    return isinstance(value, int) and value >= 0 and not isinstance(value, bool)


def text(value: Any) -> str:
    return "" if value is None else str(value)


def validate(path: Path, *, expect_red: bool = False) -> dict[str, Any]:
    errors: list[str] = []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"path": str(path), "result": "failed", "errors": [f"invalid JSON: {exc}"]}

    if not isinstance(payload, dict):
        return {"path": str(path), "result": "failed", "errors": ["artifact root must be object"]}

    if payload.get("schema") != REQUIRED_SCHEMA:
        errors.append("schema must be port.script_corpus_reject_result.v1")
    if payload.get("category") != "script_corpus_reject":
        errors.append("category must be script_corpus_reject")
    if payload.get("port") != "mojo":
        errors.append("port must be mojo")
    if payload.get("diagnostic_only") is not True:
        errors.append("diagnostic_only must be true")
    if payload.get("native_fallback_used") is not False:
        errors.append("native_fallback_used must be false")
    if payload.get("crypto_backend") not in {"libsecp256k1", "mojo-pure-secp256k1"}:
        errors.append("crypto_backend must be libsecp256k1 or mojo-pure-secp256k1")
    if payload.get("crypto_backend") == "mojo-pure-secp256k1" and payload.get("native_crypto_backend") != "none":
        errors.append("pure reject artifact must report native_crypto_backend=none")

    rows = payload.get("results")
    if not isinstance(rows, list):
        errors.append("results must be a list")
        rows = []

    fixture_count = payload.get("fixture_count")
    rejected = payload.get("rejected")
    accepted = payload.get("accepted")
    for field, value in (("fixture_count", fixture_count), ("rejected", rejected), ("accepted", accepted)):
        if not nonnegative_int(value):
            errors.append(f"{field} must be a nonnegative integer")
    if nonnegative_int(fixture_count) and fixture_count <= 0:
        errors.append("fixture_count must be greater than zero")
    if nonnegative_int(fixture_count) and len(rows) != fixture_count:
        errors.append("results length must match fixture_count")

    row_rejected = 0
    row_accepted = 0
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            errors.append(f"results[{index}] must be an object")
            continue
        for field in ("case_id", "source_fixture", "family", "mutation"):
            if not text(row.get(field)).strip():
                errors.append(f"results[{index}] missing {field}")
        if row.get("expected") != "reject":
            errors.append(f"results[{index}] expected must be reject")
        if row.get("actual") not in {"rejected", "accepted"}:
            errors.append(f"results[{index}] actual must be rejected or accepted")
        if row.get("rejected") is True:
            row_rejected += 1
        if row.get("accepted") is True:
            row_accepted += 1
        if row.get("rejected") is row.get("accepted"):
            errors.append(f"results[{index}] rejected/accepted booleans must be opposites")

    if nonnegative_int(rejected) and rejected != row_rejected:
        errors.append("rejected count mismatch")
    if nonnegative_int(accepted) and accepted != row_accepted:
        errors.append("accepted count mismatch")

    if expect_red:
        if payload.get("faults_enabled") is not True:
            errors.append("red validation requires faults_enabled=true")
        if not text(payload.get("fault_mode")).strip():
            errors.append("red validation requires fault_mode")
        if row_accepted <= 0:
            errors.append("red validation requires at least one accepted reject row")
        if payload.get("result") != "failed":
            errors.append("red validation requires artifact result=failed")
    else:
        if payload.get("faults_enabled") is not False:
            errors.append("normal reject validation requires faults_enabled=false")
        if row_accepted != 0:
            errors.append("all reject rows must fail closed")
        if payload.get("result") != "passed":
            errors.append("normal reject validation requires artifact result=passed")

    return {
        "path": str(path),
        "result": "passed" if not errors else "failed",
        "crypto_backend": payload.get("crypto_backend"),
        "fixture_count": fixture_count,
        "rejected": rejected,
        "accepted": accepted,
        "errors": errors,
    }


def main() -> int:
    args = parse_args()
    results = [validate(Path(path), expect_red=args.expect_red) for path in args.artifacts]
    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        for result in results:
            print(
                "script_corpus_reject_validation "
                f"path={result['path']} result={result['result']} backend={result['crypto_backend']} "
                f"fixtures={result['fixture_count']} rejected={result['rejected']} "
                f"accepted={result['accepted']} errors={len(result['errors'])}"
            )
            for error in result["errors"]:
                print(f"  error: {error}")
    return 1 if any(result["errors"] for result in results) else 0


if __name__ == "__main__":
    sys.exit(main())
