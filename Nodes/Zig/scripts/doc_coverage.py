#!/usr/bin/env python3
"""Report Zig doc coverage. Always exits 0.

Emits port.docs.coverage.v1. A declaration counts as documented when a ///
block sits on the lines immediately above it. A proof reference is a
test "..." name that exists under this tree, a fixture id
(consensus.|mining.|scripts.|script.|codec., including a family such as
scripts.*), a gate name, or a zig_* result filename that exists under the
Shared conformance results directory.

with_proof_ref counts declarations. distinct_proof_refs counts unique
references, split into fixture, gate, and unit_test. One test name repeated
on every declaration stays one unit_test.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
RESULTS = ROOT.parent / "Shared" / "conformance" / "results"
OUT = RESULTS / "zig_docs_coverage_2026-10-06.json"

EXACT = {
    "connect",
    "script",
    "tx",
    "block",
    "codec",
    "consensus_context",
    "chain_params",
    "mempool",
    "coins_view",
    "template",
    "native_store",
    "rocks_store",
    "store",
    "shadow_store",
    "pure_secp",
    "own_crypto",
}

GATES = (
    "native-storage-proof",
    "native-shadow-5k",
    "storage-proof",
    "script-corpus",
    "codec-vectors",
    "check-headers",
    "mempool-rung0",
    "crypto-bench",
    "self-hosted-50k",
    "baseline_5k",
    "shakedown_50k",
)

DECL_RE = re.compile(r"^(\s*)pub (?:fn|const) \w+")
TEST_RE = re.compile(r'test "([^"]+)"')
FIXTURE_RE = re.compile(r"\b(?:consensus|mining|scripts|script|codec)\.[a-z0-9_*]+")
RESULT_RE = re.compile(r"zig_[A-Za-z0-9_.-]+\.json")


def consensus(path: Path) -> bool:
    if "cli" in path.parts:
        return False
    stem = path.stem
    return stem in EXACT or stem.startswith("crypto")


def skipped_zig(path: Path) -> bool:
    return any(part in path.parts for part in (".zig-cache", "zig-out", "worktrees"))


def test_names() -> set[str]:
    found: set[str] = set()
    for path in ROOT.rglob("*.zig"):
        if skipped_zig(path):
            continue
        found.update(TEST_RE.findall(path.read_text(encoding="utf-8", errors="replace")))
    return found


def result_names() -> set[str]:
    if not RESULTS.is_dir():
        return set()
    return {path.name for path in RESULTS.glob("zig_*.json")}


def has_header(text: str) -> bool:
    for line in text.splitlines():
        if line.strip() == "":
            continue
        return line.startswith("//!")
    return False


def doc_block(lines: list[str], index: int) -> str | None:
    cursor = index - 1
    while cursor >= 0 and lines[cursor].strip() == "":
        return None
    collected: list[str] = []
    while cursor >= 0 and lines[cursor].lstrip().startswith("///"):
        collected.append(lines[cursor])
        cursor -= 1
    if not collected:
        return None
    return "\n".join(reversed(collected))


def proof_refs(doc: str, tests: set[str], results: set[str]) -> dict[str, str]:
    found: dict[str, str] = {}
    for name in TEST_RE.findall(doc):
        if name in tests:
            found[f'test "{name}"'] = "unit_test"
    for token in FIXTURE_RE.findall(doc):
        found[token] = "fixture"
    for gate in GATES:
        if gate in doc:
            found[gate] = "gate"
    for name in RESULT_RE.findall(doc):
        if name in results:
            found[name] = "gate"
    return found


def kind_counts(refs: dict[str, str]) -> dict[str, int]:
    counts = {"fixture": 0, "gate": 0, "unit_test": 0}
    for kind in refs.values():
        counts[kind] += 1
    return counts


def module_row(path: Path, tests: set[str], results: set[str]) -> dict:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    row = {
        "module": str(path.relative_to(ROOT)),
        "module_header": has_header(text),
    }
    if not consensus(path):
        return row
    pub_count = documented = with_proof = 0
    refs: dict[str, str] = {}
    for index, line in enumerate(lines):
        if not DECL_RE.match(line):
            continue
        pub_count += 1
        doc = doc_block(lines, index)
        if doc is None:
            continue
        documented += 1
        found = proof_refs(doc, tests, results)
        if found:
            with_proof += 1
            refs.update(found)
    row["pub_count"] = pub_count
    row["documented"] = documented
    row["with_proof_ref"] = with_proof
    row["distinct_proof_refs"] = len(refs)
    row["proof_ref_kinds"] = kind_counts(refs)
    row["_refs"] = refs
    return row


def main() -> int:
    tests = test_names()
    results = result_names()
    modules = [
        module_row(path, tests, results)
        for path in sorted(SRC.rglob("*.zig"))
        if not skipped_zig(path)
    ]
    headers_present = sum(1 for row in modules if row["module_header"])
    union: dict[str, str] = {}
    for row in modules:
        union.update(row.pop("_refs", {}))
    payload = {
        "schema": "port.docs.coverage.v1",
        "port": "zig",
        "modules": modules,
        "module_headers_present": headers_present,
        "module_headers_absent": len(modules) - headers_present,
        "distinct_proof_refs": len(union),
        "proof_ref_kinds": kind_counts(union),
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    counted = [row for row in modules if "pub_count" in row]
    pub_count = sum(row["pub_count"] for row in counted)
    documented = sum(row["documented"] for row in counted)
    proved = sum(row["with_proof_ref"] for row in counted)
    kinds = payload["proof_ref_kinds"]
    print(
        f"port.docs.coverage.v1 headers {headers_present}/{len(modules)} "
        f"pub {documented}/{pub_count} proof {proved}/{pub_count} "
        f"distinct {payload['distinct_proof_refs']} "
        f"(fixture {kinds['fixture']}, gate {kinds['gate']}, unit_test {kinds['unit_test']}) "
        f"-> {OUT.name}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
