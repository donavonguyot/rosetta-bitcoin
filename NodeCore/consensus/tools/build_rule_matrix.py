#!/usr/bin/env python3
"""Build a readable consensus-rule matrix from a ledger file."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def rules_from(data: Any) -> list[dict[str, Any]]:
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("rules"), list):
        return data["rules"]
    raise ValueError("expected JSON array or object with rules array")


def summarize_evidence(rule: dict[str, Any]) -> str:
    counts = Counter()
    for item in rule.get("evidence", []):
        port = item.get("port")
        result = item.get("result")
        if port and result == "passed":
            counts[str(port)] += 1
    if not counts:
        return "-"
    return ", ".join(f"{port}:{count}" for port, count in sorted(counts.items()))


def cell(value: Any) -> str:
    return str(value or "").replace("|", "\\|").replace("\n", " ")


def row(rule: dict[str, Any]) -> str:
    observed = rule.get("first_observed", {}) if isinstance(rule.get("first_observed"), dict) else {}
    tags = ", ".join(cell(value) for value in rule.get("tags", [])[:5])
    if len(rule.get("tags", [])) > 5:
        tags += ", ..."
    return (
        f"| `{cell(rule.get('rule_id'))}` "
        f"| {cell(observed.get('height', ''))} "
        f"| {cell(', '.join(rule.get('fixture_ids', [])))} "
        f"| {tags} "
        f"| {cell(rule.get('status'))} "
        f"| {cell(summarize_evidence(rule))} |"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rules", required=True, help="ledger JSON file")
    parser.add_argument("--output", required=True, help="matrix Markdown output path")
    args = parser.parse_args()

    rules_path = Path(args.rules)
    rules = rules_from(load_json(rules_path))
    lines = [
        "# Consensus Rule Matrix",
        "",
        "Generated from `NodeCore/consensus/rules/testnet4_script_rules_v1.json`.",
        "",
        "| Rule | Height | Fixtures | Tags | Status | Passed Evidence |",
        "|------|--------|----------|------|--------|-----------------|",
    ]
    lines.extend(row(rule) for rule in rules)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({"result": "passed", "rules": len(rules), "output": str(output)}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
