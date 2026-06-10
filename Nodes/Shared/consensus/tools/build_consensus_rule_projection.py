#!/usr/bin/env python3
"""Build a fixture-backed consensus rule projection from Shared sources."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


SCHEMA = "shared.consensus_rule_projection.v1"
AUTHORITY = "projection_only"
SOURCE_OF_TRUTH = ["rule_ledger", "script_fixture_manifest"]
DOES_NOT_PROVE = ["port_pass", "live_sync", "benchmark_readiness", "full_node_validity"]
VALID_RULE_STATUSES = {"candidate", "fixture_backed", "blocker_backed", "proved"}


def repo_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / "Nodes" / "Shared").exists() and (parent / "Project").exists():
            return parent
    raise SystemExit("could not locate repository root")


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def rules_from(data: Any) -> list[dict[str, Any]]:
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("rules"), list):
        return data["rules"]
    raise ValueError("rule ledger must be a JSON array or object with rules array")


def fixtures_from(data: Any) -> list[dict[str, Any]]:
    if isinstance(data, dict) and isinstance(data.get("fixtures"), list):
        return data["fixtures"]
    raise ValueError("fixture manifest must be an object with fixtures array")


def sort_key(rule: dict[str, Any]) -> tuple[int, str]:
    observed = rule.get("first_observed")
    if isinstance(observed, dict):
        height = observed.get("height")
    else:
        height = None
    if not isinstance(height, int):
        blocker = rule.get("blocker")
        height = blocker.get("height") if isinstance(blocker, dict) else None
    return (height if isinstance(height, int) else 10**12, str(rule.get("rule_id", "")))


def required_fixture_files(fixture: dict[str, Any]) -> list[dict[str, Any]]:
    files: list[dict[str, Any]] = []
    for item in fixture.get("source_files", []):
        if not isinstance(item, dict):
            continue
        files.append(
            {
                "category": item.get("category", ""),
                "path": item.get("path", ""),
                "sha256": item.get("sha256", ""),
                "size_bytes": item.get("size_bytes", 0),
            }
        )
    return sorted(files, key=lambda item: (str(item.get("category", "")), str(item.get("path", ""))))


def fixture_projection(fixture: dict[str, Any]) -> dict[str, Any]:
    return {
        "fixture_id": fixture.get("fixture_id", ""),
        "height": fixture.get("height"),
        "txid": fixture.get("txid", ""),
        "input_index": fixture.get("input_index"),
        "expected_result": fixture.get("expected_result", ""),
        "groups": fixture.get("groups", []),
        "template": fixture.get("template", ""),
        "missing_rule": fixture.get("missing_rule", ""),
        "portability_status": fixture.get("portability_status", ""),
        "required_rules": fixture.get("required_rules", []),
        "files": fixture.get("files", {}),
        "required_fixture_files": required_fixture_files(fixture),
    }


def evidence_summary(rule: dict[str, Any]) -> dict[str, Any]:
    counts = Counter()
    ports: set[str] = set()
    artifacts: list[dict[str, Any]] = []
    for item in rule.get("evidence", []):
        if not isinstance(item, dict):
            continue
        result = str(item.get("result", ""))
        if result:
            counts[result] += 1
        port = str(item.get("port", ""))
        if port and result == "passed":
            ports.add(port)
        artifacts.append(
            {
                "port": port,
                "result": result,
                "artifact": item.get("artifact", ""),
                "runtime_surface": item.get("runtime_surface", ""),
                "implementation": item.get("implementation", ""),
            }
        )
    return {
        "result_counts": dict(sorted(counts.items())),
        "passed_ports": sorted(ports),
        "artifacts": sorted(artifacts, key=lambda item: (str(item.get("port", "")), str(item.get("artifact", "")))),
    }


def build_projection(rules: list[dict[str, Any]], fixtures: list[dict[str, Any]]) -> dict[str, Any]:
    fixtures_by_id = {str(item.get("fixture_id")): item for item in fixtures if item.get("fixture_id")}
    projected_rules: list[dict[str, Any]] = []
    for rule in sorted(rules, key=sort_key):
        fixture_ids = [str(value) for value in rule.get("fixture_ids", [])]
        projected_rules.append(
            {
                "rule_id": rule.get("rule_id", ""),
                "category": rule.get("category", ""),
                "chain": rule.get("chain", ""),
                "status": rule.get("status", ""),
                "title": rule.get("title", ""),
                "first_observed": rule.get("first_observed", {}),
                "fixture_ids": fixture_ids,
                "required_rules": rule.get("required_rules", []),
                "tags": rule.get("tags", []),
                "evidence_summary": evidence_summary(rule),
                "fixtures": [fixture_projection(fixtures_by_id[fixture_id]) for fixture_id in fixture_ids if fixture_id in fixtures_by_id],
                "authority": AUTHORITY,
                "source_of_truth": SOURCE_OF_TRUTH,
                "does_not_prove": DOES_NOT_PROVE,
            }
        )

    covered_fixtures = sorted({fixture_id for rule in projected_rules for fixture_id in rule.get("fixture_ids", [])})
    return {
        "schema": SCHEMA,
        "authority": AUTHORITY,
        "source_of_truth": SOURCE_OF_TRUTH,
        "does_not_prove": DOES_NOT_PROVE,
        "domain": "script",
        "chain": "testnet4",
        "rule_count": len(projected_rules),
        "fixture_count": len(covered_fixtures),
        "inputs": {
            "rule_ledger": "Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json",
            "script_fixture_manifest": "Nodes/Shared/conformance/fixtures/scripts/manifest.json",
        },
        "rules": projected_rules,
    }


def validate_projection(projection: dict[str, Any], rules: list[dict[str, Any]], fixtures: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    rule_ids = {str(rule.get("rule_id")) for rule in rules if rule.get("rule_id")}
    fixture_ids = {str(fixture.get("fixture_id")) for fixture in fixtures if fixture.get("fixture_id")}
    projected_rules = projection.get("rules", [])
    if projection.get("schema") != SCHEMA:
        errors.append(f"projection schema must be {SCHEMA}")
    if projection.get("authority") != AUTHORITY:
        errors.append(f"projection authority must be {AUTHORITY}")
    if projection.get("source_of_truth") != SOURCE_OF_TRUTH:
        errors.append("projection source_of_truth changed")
    if projection.get("does_not_prove") != DOES_NOT_PROVE:
        errors.append("projection does_not_prove changed")
    if not isinstance(projected_rules, list):
        return errors + ["projection rules must be an array"]

    projected_rule_ids = [str(rule.get("rule_id")) for rule in projected_rules]
    sorted_rule_ids = [str(rule.get("rule_id")) for rule in sorted(rules, key=sort_key)]
    if projected_rule_ids != sorted_rule_ids:
        errors.append("projection rules must be ordered by observed height, then rule_id")
    missing_rules = sorted(rule_ids - set(projected_rule_ids))
    extra_rules = sorted(set(projected_rule_ids) - rule_ids)
    for rule_id in missing_rules:
        errors.append(f"missing projected rule {rule_id}")
    for rule_id in extra_rules:
        errors.append(f"unknown projected rule {rule_id}")
    if len(projected_rule_ids) != len(set(projected_rule_ids)):
        errors.append("projection contains duplicate rule_id values")

    covered_fixtures: set[str] = set()
    ledger_statuses = {str(rule.get("rule_id")): rule.get("status") for rule in rules}
    for rule in projected_rules:
        rule_id = str(rule.get("rule_id", ""))
        if rule.get("status") != ledger_statuses.get(rule_id):
            errors.append(f"{rule_id}: projected status must match ledger status")
        if rule.get("status") not in VALID_RULE_STATUSES:
            errors.append(f"{rule_id}: invalid projected status {rule.get('status')}")
        for fixture_id in rule.get("fixture_ids", []):
            fixture_id = str(fixture_id)
            covered_fixtures.add(fixture_id)
            if fixture_id not in fixture_ids:
                errors.append(f"{rule_id}: unknown projected fixture {fixture_id}")
        if len(rule.get("fixtures", [])) != len(rule.get("fixture_ids", [])):
            errors.append(f"{rule_id}: fixture projection count does not match fixture_ids")
        if rule.get("authority") != AUTHORITY:
            errors.append(f"{rule_id}: rule authority must be {AUTHORITY}")

    missing_fixtures = sorted(fixture_ids - covered_fixtures)
    extra_fixtures = sorted(covered_fixtures - fixture_ids)
    for fixture_id in missing_fixtures:
        errors.append(f"fixture not covered by projection {fixture_id}")
    for fixture_id in extra_fixtures:
        errors.append(f"unknown fixture covered by projection {fixture_id}")
    if projection.get("rule_count") != len(rule_ids):
        errors.append("projection rule_count does not match ledger")
    if projection.get("fixture_count") != len(fixture_ids):
        errors.append("projection fixture_count does not match manifest")
    return errors


def main() -> int:
    root = repo_root()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rules", default="Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json", help="rule ledger JSON")
    parser.add_argument("--manifest", default="Nodes/Shared/conformance/fixtures/scripts/manifest.json", help="script fixture manifest JSON")
    parser.add_argument("--output", help="projection JSON output path")
    parser.add_argument("--self-test", action="store_true", help="build and validate without writing")
    args = parser.parse_args()

    rules = rules_from(load_json(root / args.rules))
    fixtures = fixtures_from(load_json(root / args.manifest))
    projection = build_projection(rules, fixtures)
    errors = validate_projection(projection, rules, fixtures)
    if errors:
        for error in errors:
            print(f"error: {error}")
        return 1

    summary = {
        "result": "passed",
        "schema": SCHEMA,
        "rules": projection["rule_count"],
        "fixtures": projection["fixture_count"],
        "authority": AUTHORITY,
    }
    if args.self_test:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0
    if not args.output:
        raise SystemExit("--output is required unless --self-test is used")
    output = root / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(projection, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    summary["output"] = args.output
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
