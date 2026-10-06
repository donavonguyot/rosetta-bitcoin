#!/usr/bin/env python3
"""Report Zig doc coverage. Always exits 0.

Emits port.docs.coverage.v1. A declaration counts as documented when a ///
block sits on the lines immediately above it. A proof reference is a
test "..." name that exists under this tree, a fixture id
(consensus.|mining.|script.|codec.), a gate name, or a zig_* result
filename that exists under the Shared conformance results directory.
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
FIXTURE_RE = re.compile(r"\b(?:consensus|mining|script|codec)\.[a-z0-9_]+")
RESULT_RE = re.compile(r"zig_[A-Za-z0-9_.-]+\.json")


def consensus(path: Path) -> bool:
    if "cli" in path.parts:
        return False
    stem = path.stem
    return stem in EXACT or stem.startswith("crypto")


def test_names() -> set[str]:
    found: set[str] = set()
    for path in ROOT.rglob("*.zig"):
        if any(part in path.parts for part in (".zig-cache", "zig-out")):
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


def has_proof(doc: str, tests: set[str], results: set[str]) -> bool:
    if any(name in tests for name in TEST_RE.findall(doc)):
        return True
    if FIXTURE_RE.search(doc):
        return True
    if any(gate in doc for gate in GATES):
        return True
    return any(name in results for name in RESULT_RE.findall(doc))


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
    for index, line in enumerate(lines):
        if not DECL_RE.match(line):
            continue
        pub_count += 1
        doc = doc_block(lines, index)
        if doc is None:
            continue
        documented += 1
        if has_proof(doc, tests, results):
            with_proof += 1
    row["pub_count"] = pub_count
    row["documented"] = documented
    row["with_proof_ref"] = with_proof
    return row


def main() -> int:
    tests = test_names()
    results = result_names()
    modules = [module_row(path, tests, results) for path in sorted(SRC.rglob("*.zig"))]
    headers_present = sum(1 for row in modules if row["module_header"])
    payload = {
        "schema": "port.docs.coverage.v1",
        "port": "zig",
        "modules": modules,
        "module_headers_present": headers_present,
        "module_headers_absent": len(modules) - headers_present,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    counted = [row for row in modules if "pub_count" in row]
    pub_count = sum(row["pub_count"] for row in counted)
    documented = sum(row["documented"] for row in counted)
    proved = sum(row["with_proof_ref"] for row in counted)
    print(
        f"port.docs.coverage.v1 headers {headers_present}/{len(modules)} "
        f"pub {documented}/{pub_count} proof {proved}/{pub_count} -> {OUT.name}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
