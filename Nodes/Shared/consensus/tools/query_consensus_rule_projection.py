#!/usr/bin/env python3
"""Query the generated consensus rule projection."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


DEFAULT_PROJECTION = "Nodes/Shared/consensus/generated/consensus_rule_projection.json"
AUTHORITY = "projection_only"
DOES_NOT_PROVE = ["port_pass", "live_sync", "benchmark_readiness", "full_node_validity"]
HISTORICAL_PROVENANCE = "fixture origin and rule discovery context, not port proof"
SHA256_HEX_RE = re.compile(r"[0-9a-f]{64}")
RULE_OPCODE_LABELS = {
    "altstack",
    "cltv",
    "csv",
    "hash",
    "locktime",
    "multisig",
    "relative_locktime",
    "sighash",
    "signature",
}


# Semantic navigation bundles. These are query-time aids only; they are not
# projection metadata, evidence gates, or readiness profiles.
DOMAINS = {
    "p2tr": {
        "description": "Taproot script and key-path fixture obligations",
        "tags": {"p2tr", "P2TR script-path", "p2tr script-path", "tapscript"},
    },
    "tapscript": {
        "description": "Taproot script-path and tapscript obligations",
        "tags": {"tapscript", "P2TR script-path", "p2tr script-path"},
    },
    "p2wsh": {
        "description": "Native and nested P2WSH fixture obligations",
        "tags": {"p2wsh", "P2WSH"},
    },
    "p2sh": {
        "description": "P2SH and P2SH-wrapped script obligations",
        "tags": {"p2sh", "P2SH"},
    },
    "p2pkh": {
        "description": "P2PKH spend-path obligations",
        "tags": {"p2pkh", "P2PKH"},
    },
    "locktime": {
        "description": "Absolute locktime and CLTV obligations",
        "tags": {"locktime", "cltv", "op_checklocktimeverify"},
    },
    "relative-locktime": {
        "description": "Relative locktime and CSV obligations",
        "tags": {"relative_locktime", "csv", "op_checksequenceverify"},
    },
    "sighash": {
        "description": "Signature hash edge-case obligations",
        "tags": {"sighash"},
    },
    "hash": {
        "description": "Hash opcode obligations",
        "tags": {"hash", "op_hash160", "op_hash256", "op_sha1", "op_ripemd160"},
    },
    "stack": {
        "description": "Stack manipulation obligations",
        "tags": {
            "stack",
            "op_2drop",
            "op_2dup",
            "op_2over",
            "op_2swap",
            "op_3dup",
            "op_depth",
            "op_drop",
            "op_dup",
            "op_fromaltstack",
            "op_ifdup",
            "op_nip",
            "op_over",
            "op_pick",
            "op_roll",
            "op_rot",
            "op_swap",
            "op_toaltstack",
            "op_tuck",
        },
    },
    "arithmetic": {
        "description": "Arithmetic, numeric comparison, and boolean numeric obligations",
        "tags": {
            "op_0notequal",
            "op_1sub",
            "op_abs",
            "op_add",
            "op_booland",
            "op_boolor",
            "op_max",
            "op_min",
            "op_not",
            "op_numequal",
            "op_numequalverify",
            "op_numnotequal",
            "op_sub",
            "op_within",
        },
    },
    "conditionals": {
        "description": "Conditional execution and verification obligations",
        "tags": {"op_if", "op_notif", "op_else", "op_endif", "op_verify"},
    },
    "altstack": {
        "description": "Alternate stack obligations",
        "tags": {"altstack", "op_toaltstack", "op_fromaltstack"},
    },
    "multisig": {
        "description": "Multisig script obligations",
        "tags": {"multisig", "op_checkmultisig"},
    },
    "signature": {
        "description": "Signature verification obligations",
        "tags": {"op_checksig", "op_checksigverify", "op_checkmultisig", "multisig"},
    },
}


# Projection Loading


def repo_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / "Nodes" / "Shared").exists() and (parent / "Project").exists():
            return parent
    raise SystemExit("could not locate repository root")


def load_projection(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or not isinstance(data.get("rules"), list):
        raise ValueError("projection must be an object with a rules array")
    if data.get("authority") != AUTHORITY:
        raise ValueError(f"projection authority must be {AUTHORITY}")
    if data.get("does_not_prove") != DOES_NOT_PROVE:
        raise ValueError("projection does_not_prove boundary changed")
    return data


# Selectors And Filters


def rule_height(rule: dict[str, Any]) -> int | None:
    observed = rule.get("first_observed")
    if isinstance(observed, dict) and isinstance(observed.get("height"), int):
        return observed["height"]
    for fixture in rule.get("fixtures", []):
        if isinstance(fixture, dict) and isinstance(fixture.get("height"), int):
            return fixture["height"]
    return None


def fixture_ids(rule: dict[str, Any]) -> set[str]:
    values = {str(value) for value in rule.get("fixture_ids", [])}
    for fixture in rule.get("fixtures", []):
        if isinstance(fixture, dict) and fixture.get("fixture_id"):
            values.add(str(fixture["fixture_id"]))
    return values


def tag_values(rule: dict[str, Any]) -> set[str]:
    values = {str(value) for value in rule.get("tags", [])}
    for fixture in rule.get("fixtures", []):
        if not isinstance(fixture, dict):
            continue
        values.update(str(value) for value in fixture.get("groups", []))
        values.update(str(value) for value in fixture.get("required_rules", []))
    return values


def filter_rules(
    rules: list[dict[str, Any]],
    *,
    rule_id: str | None = None,
    fixture_id: str | None = None,
    tag: str | None = None,
    domain: str | None = None,
    height: int | None = None,
) -> list[dict[str, Any]]:
    domain_tags = domain_tag_values(domain) if domain else set()
    matches: list[dict[str, Any]] = []
    for rule in rules:
        values = tag_values(rule)
        if rule_id and rule.get("rule_id") != rule_id:
            continue
        if fixture_id and fixture_id not in fixture_ids(rule):
            continue
        if tag and tag not in values:
            continue
        if domain and not values.intersection(domain_tags):
            continue
        if height is not None and rule_height(rule) != height:
            continue
        matches.append(rule)
    return matches


# Domain Listing


def all_tags(rules: list[dict[str, Any]]) -> list[str]:
    values: set[str] = set()
    for rule in rules:
        values.update(tag_values(rule))
    return sorted(values)


def domain_tag_values(domain: str) -> set[str]:
    if domain not in DOMAINS:
        known = ", ".join(sorted(DOMAINS))
        raise ValueError(f"unknown domain {domain!r}; use --list-domains (known: {known})")
    return set(DOMAINS[domain]["tags"])


def domain_rows(rules: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for name in sorted(DOMAINS):
        tags = sorted(domain_tag_values(name))
        rows.append(
            {
                "domain": name,
                "description": DOMAINS[name]["description"],
                "tags": tags,
                "matches": len(filter_rules(rules, domain=name)),
            }
        )
    return rows


def matched_domain_tags(domain: str | None) -> set[str]:
    return domain_tag_values(domain) if domain else set()


# Renderers


def evidence_line(rule: dict[str, Any]) -> str:
    summary = rule.get("evidence_summary", {})
    counts = summary.get("result_counts", {}) if isinstance(summary, dict) else {}
    if not isinstance(counts, dict) or not counts:
        return "evidence artifacts: none"
    parts = [f"{key}={counts[key]}" for key in sorted(counts)]
    return "evidence artifacts: " + ", ".join(parts)


def format_files(fixture: dict[str, Any]) -> str:
    files = fixture.get("required_fixture_files", [])
    if not isinstance(files, list) or not files:
        return "-"
    parts: list[str] = []
    for item in files:
        if not isinstance(item, dict):
            continue
        category = item.get("category") or "file"
        path = item.get("path") or ""
        if path:
            parts.append(f"{category}:{path}")
    return ", ".join(parts) if parts else "-"


def format_file_items(files: list[dict[str, Any]]) -> str:
    if not files:
        return "-"
    parts: list[str] = []
    for item in files:
        if not isinstance(item, dict):
            continue
        category = item.get("category") or "file"
        path = item.get("path") or ""
        if path:
            parts.append(f"{category}:{path}")
    return ", ".join(parts) if parts else "-"


def format_markdown_file_items(files: list[dict[str, Any]]) -> str:
    if not files:
        return "-"
    by_category: dict[str, list[str]] = {}
    for item in files:
        if not isinstance(item, dict):
            continue
        category = str(item.get("category") or "file")
        path = str(item.get("path") or "")
        if path:
            by_category.setdefault(category, []).append(path)
    parts: list[str] = []
    for category in sorted(by_category):
        paths = sorted(by_category[category])
        if category == "witness" and len(paths) > 1:
            parts.append(f"{category}: {len(paths)} files")
        elif len(paths) == 1:
            parts.append(f"{category}:{paths[0]}")
        else:
            parts.append(f"{category}: {len(paths)} files, first={paths[0]}")
    return ", ".join(parts) if parts else "-"


def text_summary(projection: dict[str, Any], rules: list[dict[str, Any]]) -> str:
    lines = [
        f"authority={projection.get('authority')}",
        "does_not_prove=" + ",".join(projection.get("does_not_prove", [])),
        f"matches={len(rules)}",
    ]
    for rule in rules:
        lines.append("")
        lines.append(f"rule: {rule.get('rule_id')}")
        lines.append(f"title: {rule.get('title', '')}")
        lines.append(f"status: {rule.get('status', '')}")
        lines.append(f"height: {rule_height(rule) if rule_height(rule) is not None else ''}")
        tags = ", ".join(rule.get("tags", [])) or "-"
        required = ", ".join(rule.get("required_rules", [])) or "-"
        lines.append(f"tags: {tags}")
        lines.append(f"required_rules: {required}")
        lines.append(evidence_line(rule))
        for fixture in rule.get("fixtures", []):
            if not isinstance(fixture, dict):
                continue
            groups = ", ".join(fixture.get("groups", [])) or "-"
            missing_rule = fixture.get("missing_rule") or "-"
            template = fixture.get("template") or "-"
            lines.append(f"fixture: {fixture.get('fixture_id', '')}")
            lines.append(
                "  "
                + f"height={fixture.get('height', '')} "
                + f"txid={fixture.get('txid', '')} "
                + f"input_index={fixture.get('input_index', '')} "
                + f"expected={fixture.get('expected_result', '')}"
            )
            lines.append(f"  groups: {groups}")
            lines.append(f"  template: {template}")
            lines.append(f"  missing_rule: {missing_rule}")
            lines.append(f"  files: {format_files(fixture)}")
    return "\n".join(lines)


def json_output(projection: dict[str, Any], rules: list[dict[str, Any]]) -> str:
    payload = {
        "schema": projection.get("schema"),
        "authority": projection.get("authority"),
        "does_not_prove": projection.get("does_not_prove"),
        "matches": len(rules),
        "rules": rules,
    }
    return json.dumps(payload, indent=2, sort_keys=True)


def domains_output(projection: dict[str, Any], rules: list[dict[str, Any]], as_json: bool) -> str:
    rows = domain_rows(rules)
    if as_json:
        return json.dumps(
            {
                "authority": projection.get("authority"),
                "does_not_prove": projection.get("does_not_prove"),
                "domains": rows,
            },
            indent=2,
            sort_keys=True,
        )
    lines = [
        f"authority={projection.get('authority')}",
        "does_not_prove=" + ",".join(projection.get("does_not_prove", [])),
    ]
    for row in rows:
        lines.append(
            f"{row['domain']}: matches={row['matches']} description={row['description']} tags={','.join(row['tags'])}"
        )
    return "\n".join(lines)


def markdown_cell(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def domains_markdown_output(projection: dict[str, Any], rules: list[dict[str, Any]]) -> str:
    lines = [
        "# Consensus Domain Index",
        "",
        "## Boundary",
        f"- authority: {projection.get('authority')}",
        "- does_not_prove: " + ", ".join(projection.get("does_not_prove", [])),
        "",
        "## Domains",
        "",
        "| Domain | Rules | Description | Core Tags |",
        "|--------|-------|-------------|-----------|",
    ]
    for row in domain_rows(rules):
        lines.append(
            "| "
            + f"`{markdown_cell(row['domain'])}`"
            + " | "
            + f"{row['matches']}"
            + " | "
            + markdown_cell(row["description"])
            + " | "
            + markdown_cell(", ".join(row["tags"]))
            + " |"
        )
    return "\n".join(lines)


# Checklist Payloads


def checklist_item_kind(label: str) -> str:
    value = label.strip()
    lower = value.lower()
    if lower.startswith("op_") or lower in RULE_OPCODE_LABELS:
        return "rule_opcode"
    return "template_semantic"


def checklist_item_text(kind: str, label: str) -> str:
    if kind == "rule_opcode":
        return f"implement/verify {label}"
    return f"cover template/semantic {label}"


def checklist_item(label: str, sources: set[str]) -> dict[str, Any]:
    kind = checklist_item_kind(label)
    return {
        "checked": False,
        "kind": kind,
        "label": label,
        "source": ",".join(sorted(sources)),
        "item": checklist_item_text(kind, label),
    }


def sorted_items(labels: dict[str, set[str]]) -> list[dict[str, Any]]:
    return [checklist_item(label, labels[label]) for label in sorted(label for label in labels if label)]


def items_by_kind(items: list[dict[str, Any]], kind: str) -> list[dict[str, Any]]:
    return [item for item in items if item.get("kind") == kind]


def add_label(labels: dict[str, set[str]], value: Any, source: str) -> None:
    label = str(value)
    if label:
        labels.setdefault(label, set()).add(source)


def checklist_payload(projection: dict[str, Any], rules: list[dict[str, Any]], domain: str | None = None) -> dict[str, Any]:
    observed_values: dict[str, set[str]] = {}
    domain_values: dict[str, set[str]] = {}
    for value in matched_domain_tags(domain):
        add_label(domain_values, value, "domain_tags")
    fixture_map: dict[str, dict[str, Any]] = {}
    for rule in rules:
        for value in rule.get("required_rules", []):
            add_label(observed_values, value, "rule_required_rules")
        for fixture in rule.get("fixtures", []):
            if not isinstance(fixture, dict):
                continue
            fixture_id = str(fixture.get("fixture_id", ""))
            if fixture_id:
                fixture_map[fixture_id] = fixture
            for value in fixture.get("groups", []):
                add_label(observed_values, value, "fixture_groups")
            for value in fixture.get("required_rules", []):
                add_label(observed_values, value, "fixture_required_rules")

    supporting_values = {
        label: sources
        for label, sources in observed_values.items()
        if label not in domain_values
    }
    implementation_values = {**observed_values}
    if domain:
        for label, sources in domain_values.items():
            implementation_values.setdefault(label, set()).update(sources)
    domain_core_items = sorted_items(domain_values)
    supporting_items = sorted_items(supporting_values)
    implementation_items = sorted_items(implementation_values)
    rule_opcode_items = items_by_kind(implementation_items, "rule_opcode")
    template_semantic_items = items_by_kind(implementation_items, "template_semantic")
    fixture_items = []
    for fixture_id, fixture in sorted(
        fixture_map.items(),
        key=lambda item: (
            item[1].get("height") if isinstance(item[1].get("height"), int) else 10**12,
            item[0],
        ),
    ):
        required_fixture_files = fixture.get("required_fixture_files", [])
        if not isinstance(required_fixture_files, list):
            required_fixture_files = []
        fixture_items.append(
            {
                "checked": False,
                "fixture_id": fixture_id,
                "height": fixture.get("height"),
                "template": fixture.get("template") or "",
                "expected_result": fixture.get("expected_result") or "",
                "missing_rule": fixture.get("missing_rule") or "",
                "required_rules": fixture.get("required_rules", []),
                "groups": fixture.get("groups", []),
                "required_fixture_files": required_fixture_files,
                "item": f"run fixture {fixture_id}",
            }
        )
    proof_items = [
        {"checked": False, "item": "run the Shared script corpus for the target port"},
        {"checked": False, "item": "emit a port-owned port.script_corpus_result.v1 artifact"},
    ]
    return {
        "authority": projection.get("authority"),
        "does_not_prove": projection.get("does_not_prove"),
        "historical_provenance": HISTORICAL_PROVENANCE,
        "rule_count": len(rules),
        "fixture_count": len(fixture_items),
        "domain_core_items": domain_core_items,
        "supporting_items": supporting_items,
        "rule_opcode_items": rule_opcode_items,
        "template_semantic_items": template_semantic_items,
        "implementation_items": implementation_items,
        "fixture_items": fixture_items,
        "proof_items": proof_items,
    }


def filter_label(args: argparse.Namespace) -> str:
    labels: list[str] = []
    if args.domain:
        labels.append(f"domain {args.domain}")
    if args.rule_id:
        labels.append(f"rule {args.rule_id}")
    if args.fixture_id:
        labels.append(f"fixture {args.fixture_id}")
    if args.tag:
        labels.append(f"tag {args.tag}")
    if args.height is not None:
        labels.append(f"height {args.height}")
    return " + ".join(labels) if labels else "all matched projection rows"


def checklist_markdown(payload: dict[str, Any], label: str) -> str:
    def extend_kind_section(title: str, items: list[dict[str, Any]]) -> None:
        lines.append(f"### {title}")
        if items:
            lines.extend(f"- [ ] {item['item']}" for item in items)
        else:
            lines.append("None.")
        lines.append("")

    lines = [
        f"# Consensus Work Bundle: {label}",
        "",
        "## Boundary",
        f"- authority: {payload['authority']}",
        "- does_not_prove: " + ", ".join(payload["does_not_prove"]),
        f"- historical_provenance: {payload['historical_provenance']}",
        "",
        "## Summary",
        f"- rules: {payload['rule_count']}",
        f"- fixtures: {payload['fixture_count']}",
        "",
    ]
    if payload["domain_core_items"]:
        lines.append("## Domain-Core Items")
        extend_kind_section("Rule/Opcode Items", items_by_kind(payload["domain_core_items"], "rule_opcode"))
        extend_kind_section("Template/Semantic Coverage", items_by_kind(payload["domain_core_items"], "template_semantic"))
        lines.append("## Supporting Items")
        extend_kind_section("Rule/Opcode Items", items_by_kind(payload["supporting_items"], "rule_opcode"))
        extend_kind_section("Template/Semantic Coverage", items_by_kind(payload["supporting_items"], "template_semantic"))
    else:
        lines.append("## Rule/Opcode Items")
        if payload["rule_opcode_items"]:
            lines.extend(f"- [ ] {item['item']}" for item in payload["rule_opcode_items"])
        else:
            lines.append("None.")
        lines.append("")
        lines.append("## Template/Semantic Coverage")
        if payload["template_semantic_items"]:
            lines.extend(f"- [ ] {item['item']}" for item in payload["template_semantic_items"])
        else:
            lines.append("None.")
        lines.append("")
    lines.append("## Fixtures")
    for item in payload["fixture_items"]:
        lines.append(f"- [ ] `{item['fixture_id']}` at height {item['height']}")
        lines.append(f"  - template: {item['template'] or '-'}")
        lines.append(f"  - expected_result: {item['expected_result'] or '-'}")
        lines.append(f"  - missing_rule: {item['missing_rule'] or '-'}")
        groups = ", ".join(item.get("groups", [])) or "-"
        required = ", ".join(item.get("required_rules", [])) or "-"
        lines.append(f"  - groups: {groups}")
        lines.append(f"  - required_rules: {required}")
        fixture_files = item.get("required_fixture_files", [])
        lines.append(f"  - total_fixture_files={len(fixture_files)}")
        lines.append(f"  - files: {format_markdown_file_items(fixture_files)}")
    lines.append("")
    lines.append("## Proof Follow-up")
    lines.extend(f"- [ ] {item['item']}" for item in payload["proof_items"])
    return "\n".join(lines)


def checklist_output(
    projection: dict[str, Any],
    rules: list[dict[str, Any]],
    domain: str | None,
    as_json: bool,
    as_markdown: bool = False,
    label: str = "all matched projection rows",
) -> str:
    payload = checklist_payload(projection, rules, domain)
    if as_json:
        return json.dumps(payload, indent=2, sort_keys=True)
    if as_markdown:
        return checklist_markdown(payload, label)
    lines = [
        f"authority={payload['authority']}",
        "does_not_prove=" + ",".join(payload["does_not_prove"]),
        f"historical_provenance={payload['historical_provenance']}",
        f"rules={payload['rule_count']}",
        f"fixtures={payload['fixture_count']}",
        "",
    ]
    if payload["domain_core_items"]:
        lines.append("Domain-core items:")
        lines.append("  Rule/opcode items:")
        lines.extend(f"[ ] {item['item']}" for item in items_by_kind(payload["domain_core_items"], "rule_opcode"))
        lines.append("  Template/semantic coverage:")
        lines.extend(f"[ ] {item['item']}" for item in items_by_kind(payload["domain_core_items"], "template_semantic"))
        lines.append("")
        lines.append("Supporting items:")
        lines.append("  Rule/opcode items:")
        lines.extend(f"[ ] {item['item']}" for item in items_by_kind(payload["supporting_items"], "rule_opcode"))
        lines.append("  Template/semantic coverage:")
        lines.extend(f"[ ] {item['item']}" for item in items_by_kind(payload["supporting_items"], "template_semantic"))
    else:
        lines.append("Rule/opcode items:")
        lines.extend(f"[ ] {item['item']}" for item in payload["rule_opcode_items"])
        lines.append("")
        lines.append("Template/semantic coverage:")
        lines.extend(f"[ ] {item['item']}" for item in payload["template_semantic_items"])
    lines.append("")
    lines.append("Fixture items:")
    for item in payload["fixture_items"]:
        lines.append(
            f"[ ] {item['item']} "
            + f"(height={item['height']} expected={item['expected_result'] or '-'} template={item['template'] or '-'})"
        )
        lines.append(f"    missing_rule={item['missing_rule'] or '-'}")
        lines.append(f"    files={format_file_items(item.get('required_fixture_files', []))}")
    lines.append("")
    lines.append("Proof follow-up:")
    lines.extend(f"[ ] {item['item']}" for item in payload["proof_items"])
    return "\n".join(lines)


# Self-Tests


def assert_filter_counts(rules: list[dict[str, Any]]) -> None:
    """Check exact lookup, intersection, domain, and empty-result behavior."""
    cases = [
        ({"rule_id": "script.scripts_p2wsh_booland_136369"}, 1),
        ({"fixture_id": "scripts.p2tr_tapscript_133634"}, 1),
        ({"tag": "op_checksequenceverify"}, 5),
        ({"domain": "tapscript"}, 15),
        ({"domain": "p2wsh"}, 13),
        ({"domain": "relative-locktime"}, 5),
        ({"domain": "arithmetic"}, 16),
        ({"domain": "stack"}, 18),
        ({"height": 136369}, 1),
        ({"tag": "op_checksequenceverify", "fixture_id": "scripts.p2wsh_rot_62754"}, 1),
        ({"domain": "relative-locktime", "fixture_id": "scripts.p2wsh_rot_62754"}, 1),
        ({"tag": "op_booland", "fixture_id": "scripts.p2tr_tapscript_133634"}, 0),
    ]
    for filters, expected in cases:
        actual = len(filter_rules(rules, **filters))
        if actual != expected:
            raise AssertionError(f"filters {filters} expected {expected} match(es), got {actual}")


def assert_tag_and_domain_lists(rules: list[dict[str, Any]]) -> None:
    tags = all_tags(rules)
    for value in ("op_checksequenceverify", "op_booland", "p2tr"):
        if value not in tags:
            raise AssertionError(f"missing tag {value}")
    domains = {row["domain"]: row for row in domain_rows(rules)}
    for name in ("tapscript", "arithmetic", "relative-locktime"):
        if name not in domains:
            raise AssertionError(f"missing domain {name}")
    try:
        filter_rules(rules, domain="not-a-domain")
    except ValueError:
        pass
    else:
        raise AssertionError("unknown domain did not fail")


def assert_projection_metadata(projection: dict[str, Any]) -> None:
    input_sha256 = projection.get("input_sha256")
    if not isinstance(input_sha256, dict):
        raise AssertionError("projection missing input_sha256 metadata")
    for key in ("rule_ledger", "script_fixture_manifest"):
        value = input_sha256.get(key)
        if not isinstance(value, str) or not SHA256_HEX_RE.fullmatch(value):
            raise AssertionError(f"projection input_sha256.{key} must be a SHA256 hex digest")


def assert_checklist_payloads(projection: dict[str, Any], rules: list[dict[str, Any]]) -> None:
    stack_payload = checklist_payload(projection, filter_rules(rules, domain="stack"), "stack")
    if stack_payload["fixture_count"] != 18:
        raise AssertionError(f"stack checklist fixture_count expected 18, got {stack_payload['fixture_count']}")
    stack_items = {item["item"] for item in stack_payload["rule_opcode_items"]}
    for item in ("implement/verify op_2drop", "implement/verify op_depth", "implement/verify op_swap"):
        if item not in stack_items:
            raise AssertionError(f"stack checklist missing {item}")

    tapscript_payload = checklist_payload(projection, filter_rules(rules, domain="tapscript"), "tapscript")
    if tapscript_payload["fixture_count"] != 15:
        raise AssertionError(f"tapscript checklist fixture_count expected 15, got {tapscript_payload['fixture_count']}")
    tapscript_template_items = {item["item"] for item in tapscript_payload["template_semantic_items"]}
    for item in ("cover template/semantic p2tr", "cover template/semantic P2TR script-path"):
        if item not in tapscript_template_items:
            raise AssertionError(f"tapscript checklist missing template coverage {item}")
    for item in tapscript_payload["template_semantic_items"]:
        if item["item"].startswith("implement/verify"):
            raise AssertionError(f"template/semantic item uses implementation wording: {item['item']}")

    relative_payload = checklist_payload(
        projection,
        filter_rules(rules, domain="relative-locktime", fixture_id="scripts.p2wsh_rot_62754"),
        "relative-locktime",
    )
    if relative_payload["fixture_count"] != 1:
        raise AssertionError("relative-locktime fixture checklist should contain exactly 1 fixture")
    relative_core = {item["item"] for item in relative_payload["domain_core_items"]}
    for item in (
        "implement/verify csv",
        "implement/verify op_checksequenceverify",
        "implement/verify relative_locktime",
    ):
        if item not in relative_core:
            raise AssertionError(f"relative-locktime core missing {item}")
    relative_supporting = {item["item"] for item in relative_payload["supporting_items"]}
    if "implement/verify op_rot" not in relative_supporting:
        raise AssertionError("relative-locktime supporting items missing op_rot")
    for key in (
        "authority",
        "does_not_prove",
        "historical_provenance",
        "domain_core_items",
        "supporting_items",
        "rule_opcode_items",
        "template_semantic_items",
        "implementation_items",
        "fixture_items",
        "proof_items",
    ):
        if key not in relative_payload:
            raise AssertionError(f"checklist JSON payload missing {key}")
    if relative_payload["historical_provenance"] != HISTORICAL_PROVENANCE:
        raise AssertionError("checklist JSON payload has wrong historical provenance boundary")
    relative_fixture = relative_payload["fixture_items"][0]
    for key in ("template", "expected_result", "missing_rule", "required_fixture_files"):
        if key not in relative_fixture:
            raise AssertionError(f"fixture item missing {key}")
    if not relative_fixture["required_fixture_files"]:
        raise AssertionError("fixture item required_fixture_files should be non-empty")
    for item in relative_payload["implementation_items"]:
        for key in ("checked", "kind", "label", "source", "item"):
            if key not in item:
                raise AssertionError(f"typed checklist item missing {key}")


def assert_renderers(projection: dict[str, Any], rules: list[dict[str, Any]]) -> None:
    checklist_text = checklist_output(projection, filter_rules(rules, domain="stack"), "stack", False)
    if "[x]" in checklist_text.lower():
        raise AssertionError("checklist output must not contain checked items")
    if f"historical_provenance={HISTORICAL_PROVENANCE}" not in checklist_text:
        raise AssertionError("checklist text missing historical provenance boundary")

    markdown_text = checklist_output(
        projection,
        filter_rules(rules, domain="stack"),
        "stack",
        False,
        True,
        "domain stack",
    )
    if not markdown_text.startswith("# Consensus Work Bundle: domain stack"):
        raise AssertionError("markdown checklist title is wrong")
    for heading in ("## Boundary", "## Domain-Core Items", "## Supporting Items", "## Fixtures", "## Proof Follow-up"):
        if heading not in markdown_text:
            raise AssertionError(f"markdown checklist missing {heading}")
    if f"- historical_provenance: {HISTORICAL_PROVENANCE}" not in markdown_text:
        raise AssertionError("markdown checklist missing historical provenance boundary")
    tapscript_markdown = checklist_output(
        projection,
        filter_rules(rules, domain="tapscript"),
        "tapscript",
        False,
        True,
        "domain tapscript",
    )
    for forbidden in ("implement/verify p2tr", "implement/verify P2TR script-path"):
        if forbidden in tapscript_markdown:
            raise AssertionError(f"markdown checklist contains template implementation wording: {forbidden}")
    for expected in ("## Domain-Core Items", "### Rule/Opcode Items", "### Template/Semantic Coverage"):
        if expected not in tapscript_markdown:
            raise AssertionError(f"markdown checklist missing typed heading {expected}")
    if "- [ ]" not in markdown_text:
        raise AssertionError("markdown checklist missing unchecked items")
    if "- [x]" in markdown_text.lower():
        raise AssertionError("markdown checklist must not contain checked items")

    domain_markdown = domains_markdown_output(projection, rules)
    if not domain_markdown.startswith("# Consensus Domain Index"):
        raise AssertionError("domain markdown title is wrong")
    for value in ("## Boundary", "## Domains", "relative-locktime", "stack", "tapscript", "projection_only"):
        if value not in domain_markdown:
            raise AssertionError(f"domain markdown missing {value}")

    non_domain_markdown = checklist_output(
        projection,
        filter_rules(rules, fixture_id="scripts.p2wsh_rot_62754"),
        None,
        False,
        True,
        "fixture scripts.p2wsh_rot_62754",
    )
    if "## Rule/Opcode Items" not in non_domain_markdown:
        raise AssertionError("non-domain markdown checklist should include Rule/Opcode Items")
    if "## Template/Semantic Coverage" not in non_domain_markdown:
        raise AssertionError("non-domain markdown checklist should include Template/Semantic Coverage")
    if "## Domain-Core Items" in non_domain_markdown:
        raise AssertionError("non-domain markdown checklist should not include Domain-Core Items")
    template_only_markdown = checklist_output(
        projection,
        filter_rules(rules, fixture_id="scripts.p2tr_tapscript_133634"),
        None,
        False,
        True,
        "fixture scripts.p2tr_tapscript_133634",
    )
    if "## Rule/Opcode Items\nNone." not in template_only_markdown:
        raise AssertionError("empty non-domain Rule/Opcode Items section should render None.")
    for expected in ("template:", "expected_result:", "missing_rule:", "files:"):
        if expected not in non_domain_markdown:
            raise AssertionError(f"markdown fixture item missing {expected}")
    if "total_fixture_files=" not in markdown_text:
        raise AssertionError("markdown checklist missing total fixture file count")
    tapscript_mega_markdown = checklist_output(
        projection,
        filter_rules(rules, fixture_id="scripts.p2tr_tapscript_121035"),
        None,
        False,
        True,
        "fixture scripts.p2tr_tapscript_121035",
    )
    if "witness: 552 files" not in tapscript_mega_markdown:
        raise AssertionError("markdown mega-witness fixture should summarize witness files")
    if "tx_p2tr_tapscript_121035_witness_551.hex" in tapscript_mega_markdown:
        raise AssertionError("markdown mega-witness fixture should not expand every witness path")
    mega_json = checklist_payload(projection, filter_rules(rules, fixture_id="scripts.p2tr_tapscript_121035"), None)
    mega_fixture = mega_json["fixture_items"][0]
    if len(mega_fixture["required_fixture_files"]) < 500:
        raise AssertionError("JSON checklist fixture should keep full required_fixture_files")
    focused_text = checklist_output(projection, filter_rules(rules, fixture_id="scripts.p2wsh_rot_62754"), None, False)
    if "witness_script:scripts.p2wsh_rot_62754/tx_p2wsh_rot_62754_witness_script.hex" not in focused_text:
        raise AssertionError("text checklist fixture should keep full file paths")

    sample_text = text_summary(projection, filter_rules(rules, rule_id="script.scripts_p2wsh_booland_136369"))
    for forbidden in ("full_node ready", "benchmark ready", "port ready"):
        if forbidden in sample_text.lower():
            raise AssertionError(f"query text includes forbidden readiness wording: {forbidden}")


def assert_cli_guardrails() -> None:
    cases = [
        argparse.Namespace(markdown=True, checklist=False, list_domains=False, json=False),
        argparse.Namespace(markdown=True, checklist=True, list_domains=False, json=True),
        argparse.Namespace(markdown=True, checklist=False, list_domains=True, json=True),
    ]
    for args in cases:
        try:
            validate_args(args)
        except ValueError:
            continue
        raise AssertionError(f"invalid CLI mode passed validation: {args}")

    valid_cases = [
        argparse.Namespace(markdown=True, checklist=True, list_domains=False, json=False),
        argparse.Namespace(markdown=True, checklist=False, list_domains=True, json=False),
        argparse.Namespace(markdown=False, checklist=False, list_domains=False, json=True),
    ]
    for args in valid_cases:
        validate_args(args)


def run_self_test(projection: dict[str, Any]) -> None:
    rules = projection["rules"]
    assert_filter_counts(rules)
    assert_tag_and_domain_lists(rules)
    assert_projection_metadata(projection)
    assert_checklist_payloads(projection, rules)
    assert_renderers(projection, rules)
    assert_cli_guardrails()


# CLI Entrypoint


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--projection", default=DEFAULT_PROJECTION, help="projection JSON path")
    parser.add_argument("--rule", dest="rule_id", help="exact rule_id to match")
    parser.add_argument("--fixture", dest="fixture_id", help="exact fixture_id to match")
    parser.add_argument("--tag", help="exact rule tag, fixture group, or fixture required rule to match")
    parser.add_argument("--domain", help="semantic domain name to match")
    parser.add_argument("--height", type=int, help="exact observed/fixture height to match")
    parser.add_argument("--list-tags", action="store_true", help="list available tags/groups and exit")
    parser.add_argument("--list-domains", action="store_true", help="list semantic domains and exit")
    parser.add_argument("--checklist", action="store_true", help="emit a generic unchecked implementation checklist")
    parser.add_argument("--markdown", action="store_true", help="emit checklist output as pasteable Markdown")
    parser.add_argument("--json", action="store_true", help="emit machine-readable query output")
    parser.add_argument("--self-test", action="store_true", help="run built-in query checks")
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.markdown and not (args.checklist or args.list_domains):
        raise ValueError("--markdown requires --checklist or --list-domains")
    if args.markdown and args.json:
        raise ValueError("--json and --markdown are ambiguous together")


def main() -> int:
    args = parse_args()
    root = repo_root()
    projection = load_projection(root / args.projection)
    rules = projection["rules"]

    try:
        validate_args(args)
    except ValueError as exc:
        raise SystemExit(str(exc))

    if args.self_test:
        run_self_test(projection)
        print(json.dumps({"result": "passed", "rules": len(rules), "tags": len(all_tags(rules))}, indent=2, sort_keys=True))
        return 0

    if args.list_tags:
        tags = all_tags(rules)
        if args.json:
            print(json.dumps({"authority": projection.get("authority"), "does_not_prove": projection.get("does_not_prove"), "tags": tags}, indent=2, sort_keys=True))
        else:
            print(f"authority={projection.get('authority')}")
            print("does_not_prove=" + ",".join(projection.get("does_not_prove", [])))
            for tag in tags:
                print(tag)
        return 0

    if args.list_domains:
        if args.markdown:
            print(domains_markdown_output(projection, rules))
        else:
            print(domains_output(projection, rules, args.json))
        return 0

    try:
        matches = filter_rules(
            rules,
            rule_id=args.rule_id,
            fixture_id=args.fixture_id,
            tag=args.tag,
            domain=args.domain,
            height=args.height,
        )
    except ValueError as exc:
        raise SystemExit(str(exc))
    if args.checklist:
        print(checklist_output(projection, matches, args.domain, args.json, args.markdown, filter_label(args)))
        return 0 if matches else 1
    if args.json:
        print(json_output(projection, matches))
    else:
        print(text_summary(projection, matches))
    return 0 if matches else 1


if __name__ == "__main__":
    raise SystemExit(main())
