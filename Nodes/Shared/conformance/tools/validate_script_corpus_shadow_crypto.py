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
    return parser.parse_args()


def text(value: Any) -> str:
    return "" if value is None else str(value)


def validate(path: Path) -> dict[str, Any]:
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
        if row.get("shadow_agreed") is True:
            agreed += 1
        if row.get("shadow_supported") is True and row.get("shadow_agreed") is not True:
            disagreements += 1

    if payload.get("shadow_supported") != supported:
        errors.append("shadow_supported count mismatch")
    if payload.get("shadow_agreed") != agreed:
        errors.append("shadow_agreed count mismatch")
    if payload.get("disagreements") != disagreements:
        errors.append("disagreements count mismatch")
    if payload.get("shadow_unsupported") != payload.get("fixture_count", 0) - supported:
        errors.append("shadow_unsupported count mismatch")

    return {
        "path": str(path),
        "schema": payload.get("schema", ""),
        "port": payload.get("port", ""),
        "fixture_count": payload.get("fixture_count", 0),
        "shadow_supported": payload.get("shadow_supported", 0),
        "disagreements": payload.get("disagreements", 0),
        "result": "passed" if not errors else "failed",
        "errors": errors,
    }


def main() -> int:
    args = parse_args()
    results = [validate(Path(path)) for path in args.artifacts]
    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        for result in results:
            print(
                "script_corpus_shadow_crypto_validation "
                f"path={result['path']} result={result['result']} "
                f"supported={result['shadow_supported']} disagreements={result['disagreements']} "
                f"errors={len(result['errors'])}"
            )
            for error in result["errors"]:
                print(f"  error: {error}")
    return 1 if any(result["errors"] for result in results) else 0


if __name__ == "__main__":
    sys.exit(main())
