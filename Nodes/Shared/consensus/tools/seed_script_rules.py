#!/usr/bin/env python3
"""Seed the script-rule ledger from the Shared script fixture manifest."""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any


def repo_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / "Nodes" / "Shared").exists() and (parent / "Project").exists():
            return parent
    raise SystemExit("could not locate repository root")


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def slug(value: Any) -> str:
    text = str(value or "unknown").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "_", text).strip("_")
    return text or "unknown"


def discover_script_evidence(root: Path, results_dir: Path) -> dict[str, list[dict[str, Any]]]:
    evidence: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for path in sorted(results_dir.resolve().glob("*script_corpus*.json")):
        try:
            data = load_json(path)
        except Exception:
            continue
        implementation = str(data.get("implementation") or path.name.split("_", 1)[0])
        port = slug(implementation.replace("Node", ""))
        results = data.get("results")
        if not isinstance(results, list):
            continue
        by_fixture = {str(item.get("fixture_id")): item for item in results if isinstance(item, dict) and item.get("fixture_id")}
        for fixture_id, item in by_fixture.items():
            evidence[fixture_id].append(
                {
                    "port": port,
                    "implementation": implementation,
                    "runtime_surface": data.get("runtime_surface"),
                    "verifier": data.get("verifier"),
                    "artifact": str(path.relative_to(root.resolve())),
                    "result": str(item.get("result") or data.get("result") or "unknown"),
                    "corpus_result": str(data.get("result") or "unknown"),
                    "fixture_count": 1,
                }
            )
    return evidence


def rule_from_fixture(entry: dict[str, Any], evidence_by_fixture: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
    fixture_id = str(entry["fixture_id"])
    height = entry.get("height")
    template = str(entry.get("template") or "unknown")
    groups = [str(value) for value in entry.get("groups", []) if value]
    required_rules = [str(value) for value in entry.get("required_rules", []) if value]
    tags = sorted(set(groups + [template, str(entry.get("missing_rule") or "")] + required_rules) - {""})
    evidence = evidence_by_fixture.get(fixture_id, [])
    status = "proved" if any(item.get("result") == "passed" for item in evidence) else "fixture_backed"
    raw_blocker = entry.get("java_blocker") or {}
    blocker = raw_blocker if isinstance(raw_blocker, dict) else {}

    return {
        "schema_version": 1,
        "rule_id": f"script.{slug(fixture_id)}",
        "category": "script",
        "title": f"Script fixture {fixture_id}",
        "chain": str(entry.get("chain") or "testnet4"),
        "status": status,
        "fixture_ids": [fixture_id],
        "required_rules": required_rules,
        "tags": tags,
        "first_observed": {
            "height": height,
            "block_hash": entry.get("block_hash"),
            "txid": entry.get("txid"),
            "input_index": entry.get("input_index"),
            "template": template,
            "spent_script_pubkey": entry.get("spent_script_pubkey"),
        },
        "blocker": {
            "height": blocker.get("height") or height,
            "missing_rule": entry.get("missing_rule"),
            "failure": blocker.get("failure") or (raw_blocker if isinstance(raw_blocker, str) else ""),
        },
        "evidence": evidence,
        "notes": "Seeded from Shared script corpus manifest; port evidence must point at script-corpus result artifacts.",
    }


def main() -> int:
    root = repo_root()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=str(root / "Nodes/Shared/conformance/fixtures/scripts/manifest.json"))
    parser.add_argument("--results-dir", default=str(root / "Nodes/Shared/conformance/results"))
    parser.add_argument("--output", default=str(root / "Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json"))
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    results_dir = Path(args.results_dir)
    manifest = load_json(manifest_path)
    fixtures = manifest.get("fixtures", [])
    if not isinstance(fixtures, list):
        raise SystemExit("manifest fixtures must be a list")

    evidence = discover_script_evidence(root, results_dir)
    rules = [rule_from_fixture(entry, evidence) for entry in fixtures]
    output = {
        "schema_version": 1,
        "artifact_kind": "shared.consensus_knowledge_ledger",
        "chain": "testnet4",
        "source_manifest": str(manifest_path.resolve().relative_to(root)),
        "rule_count": len(rules),
        "rules": rules,
    }
    write_json(Path(args.output), output)
    print(json.dumps({"result": "passed", "rules": len(rules), "output": args.output}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
