#!/usr/bin/env python3
"""Validate Shared consensus knowledge ledger v1 files."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


VALID_STATUSES = {"candidate", "fixture_backed", "blocker_backed", "proved"}
REQUIRED_FIELDS = (
    "schema_version",
    "rule_id",
    "category",
    "title",
    "chain",
    "status",
    "fixture_ids",
    "required_rules",
    "tags",
    "evidence",
)


def repo_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / "Nodes" / "Shared").exists() and (parent / "Project").exists():
            return parent
    raise SystemExit("could not locate repository root")


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def manifest_fixture_ids(root: Path) -> set[str]:
    manifest = load_json(root / "Nodes/Shared/conformance/fixtures/scripts/manifest.json")
    return {str(entry.get("fixture_id")) for entry in manifest.get("fixtures", []) if entry.get("fixture_id")}


def iter_rules(data: Any) -> list[dict[str, Any]]:
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("rules"), list):
        return data["rules"]
    raise ValueError("ledger must be a JSON array or object with rules array")


def validate_rule(rule: dict[str, Any], known_fixtures: set[str], root: Path) -> list[str]:
    rule_id = str(rule.get("rule_id", "<missing>"))
    errors: list[str] = []
    for field in REQUIRED_FIELDS:
        if field not in rule or rule[field] in ("", None):
            errors.append(f"{rule_id}: missing required field {field}")
    if rule.get("schema_version") != 1:
        errors.append(f"{rule_id}: schema_version must be 1")
    if rule.get("status") not in VALID_STATUSES:
        errors.append(f"{rule_id}: invalid status {rule.get('status')}")
    fixture_ids = rule.get("fixture_ids")
    if not isinstance(fixture_ids, list) or not fixture_ids:
        errors.append(f"{rule_id}: fixture_ids must be a non-empty array")
    else:
        missing = sorted(set(map(str, fixture_ids)) - known_fixtures)
        for fixture_id in missing:
            errors.append(f"{rule_id}: unknown fixture_id {fixture_id}")
    for field in ("required_rules", "tags", "evidence"):
        if field in rule and not isinstance(rule[field], list):
            errors.append(f"{rule_id}: {field} must be an array")
    for item in rule.get("evidence", []):
        if not isinstance(item, dict):
            errors.append(f"{rule_id}: evidence entry must be an object")
            continue
        for field in ("port", "artifact", "result"):
            if not item.get(field):
                errors.append(f"{rule_id}: evidence entry missing {field}")
        artifact = item.get("artifact")
        if artifact and not (root / artifact).exists():
            errors.append(f"{rule_id}: evidence artifact does not exist: {artifact}")
    return errors


def main() -> int:
    root = repo_root()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ledgers", nargs="+", help="consensus ledger JSON files")
    parser.add_argument("--json", action="store_true", help="emit machine-readable summary")
    args = parser.parse_args()

    known_fixtures = manifest_fixture_ids(root)
    results = []
    all_errors: list[str] = []
    for value in args.ledgers:
        path = Path(value)
        rules = iter_rules(load_json(path))
        errors: list[str] = []
        seen: set[str] = set()
        for rule in rules:
            if not isinstance(rule, dict):
                errors.append(f"{path}: rule entry must be an object")
                continue
            rule_id = str(rule.get("rule_id", ""))
            if rule_id in seen:
                errors.append(f"{path}: duplicate rule_id {rule_id}")
            seen.add(rule_id)
            errors.extend(validate_rule(rule, known_fixtures, root))
        all_errors.extend(errors)
        results.append({"path": str(path), "rule_count": len(rules), "errors": errors, "result": "passed" if not errors else "failed"})

    summary = {"ledger_count": len(results), "error_count": len(all_errors), "results": results}
    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(f"consensus_ledger_validation ledgers={len(results)} errors={len(all_errors)}")
        for error in all_errors:
            print(f"error: {error}")
    return 0 if not all_errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
