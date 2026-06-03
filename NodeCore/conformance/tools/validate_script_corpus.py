#!/usr/bin/env python3
"""Validate the NodeCore script fixture corpus manifest."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


REQUIRED_FIELDS = (
    "fixture_id",
    "category",
    "chain",
    "height",
    "block_hash",
    "txid",
    "input_index",
    "expected_result",
    "source_port",
    "source_files",
    "portability_status",
)


def repo_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / "NodeCore").exists() and (parent / "Nodes").exists():
            return parent
    raise SystemExit("could not locate repository root")


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} did not contain a JSON object")
    return data


def has_any(files: dict[str, list[str]], *categories: str) -> bool:
    return any(files.get(category) for category in categories)


def validate_entry(entry: dict[str, Any], corpus_dir: Path) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []
    fixture_id = str(entry.get("fixture_id", ""))
    files = entry.get("files", {})
    if not isinstance(files, dict):
        errors.append("files must be an object")
        files = {}

    for field in REQUIRED_FIELDS:
        if field not in entry or entry[field] in ("", None, []):
            errors.append(f"missing required field: {field}")

    if entry.get("category") != "script":
        errors.append("category must be script")
    if entry.get("expected_result") != "valid":
        errors.append("expected_result must be valid for Java-cleared script corpus")
    if entry.get("portability_status") not in {
        "raw_imported",
        "normalized",
        "loader_verified",
        "cross_port_ready",
        "absorbed",
    }:
        errors.append("portability_status is not recognized")

    seen_paths: set[str] = set()
    for source in entry.get("source_files", []):
        if not isinstance(source, dict):
            errors.append("source_files entry must be an object")
            continue
        rel = source.get("path")
        if not rel:
            errors.append("source_files entry missing path")
            continue
        seen_paths.add(rel)
        target = corpus_dir / rel
        if not target.exists():
            errors.append(f"referenced file is missing: {rel}")
        elif source.get("size_bytes") != target.stat().st_size:
            errors.append(f"size mismatch for referenced file: {rel}")

    for category, values in files.items():
        if not isinstance(values, list):
            errors.append(f"files.{category} must be a list")
            continue
        for rel in values:
            if rel not in seen_paths:
                errors.append(f"files.{category} references file absent from source_files: {rel}")

    if not has_any(files, "meta"):
        errors.append("missing meta file")
    if not has_any(files, "tx"):
        errors.append("missing spending transaction file")
    if not has_any(files, "block"):
        warnings.append("missing block file")
    if not has_any(files, "prevouts", "prev_spk"):
        warnings.append("missing prevout data file")
    if not has_any(files, "scriptsig", "witness", "witness_script", "redeem_script", "tapscript", "control_block"):
        warnings.append("missing explicit spend-path data file")

    return {
        "fixture_id": fixture_id,
        "height": entry.get("height"),
        "template": entry.get("template", ""),
        "portability_status": entry.get("portability_status", ""),
        "structural_status": "complete" if not errors and not warnings else "incomplete",
        "errors": errors,
        "warnings": warnings,
    }


def main() -> int:
    root = repo_root()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        default=str(root / "NodeCore/conformance/fixtures/scripts/manifest.json"),
    )
    parser.add_argument("--summary-path", default="")
    args = parser.parse_args()

    manifest_path = Path(args.manifest).resolve()
    corpus_dir = manifest_path.parent
    manifest = load_json(manifest_path)
    fixtures = manifest.get("fixtures", [])
    if not isinstance(fixtures, list):
        raise SystemExit("manifest fixtures must be a list")

    entries = [validate_entry(entry, corpus_dir) for entry in fixtures]
    counts = Counter(entry["structural_status"] for entry in entries)
    by_template = Counter(str(entry.get("template", "") or "unknown").lower() for entry in fixtures)
    summary = {
        "schema": "nodecore.script_fixtures.validation.v1",
        "manifest": str(manifest_path.relative_to(root)),
        "fixture_count": len(entries),
        "complete_count": counts.get("complete", 0),
        "incomplete_count": counts.get("incomplete", 0),
        "templates": dict(sorted(by_template.items())),
        "fixtures": entries,
        "result": "passed" if all(not entry["errors"] for entry in entries) else "failed",
    }

    if args.summary_path:
        out = Path(args.summary_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({key: summary[key] for key in ("fixture_count", "complete_count", "incomplete_count", "result")}, indent=2))
    return 0 if summary["result"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
