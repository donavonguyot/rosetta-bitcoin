#!/usr/bin/env python3
"""Validate Shared replay telemetry v1 artifacts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REQUIRED_FIELDS = (
    "schema_version",
    "artifact_kind",
    "run_id",
    "implementation",
    "port",
    "runtime_surface",
    "replay_mode",
    "chain",
    "target_height",
    "validated_height",
    "result",
    "stage_totals_ms",
)

VALID_RESULTS = {"passed", "failed", "blocked", "unknown"}


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} did not contain a JSON object")
    return data


def validate(data: dict[str, Any], path: Path) -> list[str]:
    errors: list[str] = []

    for field in REQUIRED_FIELDS:
        if field not in data or data[field] in ("", None):
            errors.append(f"{path}: missing required field {field}")

    if data.get("schema_version") != 1:
        errors.append(f"{path}: schema_version must be 1")
    if data.get("artifact_kind") != "shared.replay_telemetry":
        errors.append(f"{path}: artifact_kind must be shared.replay_telemetry")
    if data.get("result") not in VALID_RESULTS:
        errors.append(f"{path}: result must be one of {sorted(VALID_RESULTS)}")

    for field in ("target_height", "validated_height", "stored_block_height", "header_height", "elapsed_ms"):
        if field in data and data[field] is not None:
            if not isinstance(data[field], int) or data[field] < 0:
                errors.append(f"{path}: {field} must be a non-negative integer")

    stages = data.get("stage_totals_ms")
    if not isinstance(stages, dict):
        errors.append(f"{path}: stage_totals_ms must be an object")
    else:
        for name, value in stages.items():
            if not isinstance(name, str) or not name:
                errors.append(f"{path}: stage name must be a non-empty string")
            if not isinstance(value, int) or value < 0:
                errors.append(f"{path}: stage {name} must be a non-negative integer")

    for field in ("slow_blocks", "progress_samples", "resource_samples"):
        if field in data and not isinstance(data[field], list):
            errors.append(f"{path}: {field} must be an array")

    if (
        isinstance(data.get("target_height"), int)
        and isinstance(data.get("validated_height"), int)
        and data.get("result") == "passed"
        and data["validated_height"] < data["target_height"]
    ):
        errors.append(f"{path}: passed artifact validated below target_height")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", nargs="+", help="canonical replay telemetry JSON artifacts")
    parser.add_argument("--json", action="store_true", help="emit machine-readable summary")
    args = parser.parse_args()

    results = []
    all_errors: list[str] = []
    for value in args.artifacts:
        path = Path(value)
        errors = validate(load_json(path), path)
        all_errors.extend(errors)
        results.append({"path": str(path), "errors": errors, "result": "passed" if not errors else "failed"})

    summary = {"artifact_count": len(results), "error_count": len(all_errors), "results": results}
    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(f"replay_telemetry_validation artifacts={len(results)} errors={len(all_errors)}")
        for error in all_errors:
            print(f"error: {error}")
    return 0 if not all_errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
