#!/usr/bin/env python3
"""Validate a port-owned script-corpus result artifact."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REQUIRED_SCHEMA = "port.script_corpus_result.v1"
BAD_NATIVE = {"", "managed", "pure", "pure_ts", "pure_java", "pure_csharp", "not_enabled", "unavailable", "none"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", nargs="+", help="Script corpus result JSON files")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable validation output")
    return parser.parse_args()


def text(value: Any) -> str:
    return "" if value is None else str(value)


def verifier_name(payload: dict[str, Any]) -> str:
    verifier = payload.get("verifier")
    if isinstance(verifier, dict):
        return text(verifier.get("engine"))
    return text(verifier)


def native_backend(payload: dict[str, Any]) -> str:
    verifier = payload.get("verifier")
    if isinstance(verifier, dict):
        return text(payload.get("native_crypto_backend") or verifier.get("crypto_backend"))
    return text(payload.get("native_crypto_backend"))


def validate(path: Path) -> dict[str, Any]:
    errors: list[str] = []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"path": str(path), "result": "failed", "errors": [f"invalid JSON: {exc}"]}
    if not isinstance(payload, dict):
        return {"path": str(path), "result": "failed", "errors": ["artifact root must be an object"]}

    checks = {
        "schema": payload.get("schema") == REQUIRED_SCHEMA,
        "category": payload.get("category") == "script_corpus",
        "result": payload.get("result") == "passed",
        "implementation": bool(text(payload.get("implementation")).strip()),
        "port": bool(text(payload.get("port")).strip()),
        "runtime_surface": bool(text(payload.get("runtime_surface")).strip()),
        "verifier": bool(verifier_name(payload).strip()),
        "native_crypto_backend": native_backend(payload).strip().lower() not in BAD_NATIVE,
        "fixture_count": payload.get("fixture_count") == 45,
        "passed": payload.get("passed") == 45,
        "failed": payload.get("failed") == 0,
        "results": isinstance(payload.get("results"), list) and len(payload.get("results", [])) == 45,
    }
    for name, ok in checks.items():
        if not ok:
            errors.append(f"{name} check failed")
    for index, row in enumerate(payload.get("results") if isinstance(payload.get("results"), list) else []):
        if not isinstance(row, dict):
            errors.append(f"results[{index}] is not an object")
            continue
        if not text(row.get("fixture_id")).strip():
            errors.append(f"results[{index}] missing fixture_id")
        if row.get("result") != "passed":
            errors.append(f"results[{index}] result is {row.get('result')!r}")
    return {
        "path": str(path),
        "schema": payload.get("schema", ""),
        "port": payload.get("port", ""),
        "fixture_count": payload.get("fixture_count", 0),
        "passed": payload.get("passed", 0),
        "failed": payload.get("failed", 0),
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
                "script_corpus_result_validation "
                f"path={result['path']} result={result['result']} errors={len(result['errors'])}"
            )
            for error in result["errors"]:
                print(f"  error: {error}")
    return 1 if any(result["errors"] for result in results) else 0


if __name__ == "__main__":
    sys.exit(main())
