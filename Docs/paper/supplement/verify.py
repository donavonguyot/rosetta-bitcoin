#!/usr/bin/env python3
"""Validate supplement metadata, hashes, and separation from Project evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    manifest = json.loads((ROOT / "manifest.json").read_text())
    assert manifest["schema"] == "rosettabitcoin.paper_supplement.v1"
    assert manifest["package_status"] == "diagnostic_non_comparable"
    assert manifest["project_current_evidence"] is False
    current_text = (REPO / "Nodes/Shared/conformance/current_evidence.json").read_text()
    ids: set[str] = set()
    for record in manifest["artifacts"]:
        required = {
            "artifact_id", "file", "original_path", "sha256", "backend",
            "comparability", "project_current_evidence", "supported_claim",
            "does_not_prove", "timestamp", "reproducibility",
        }
        assert required <= record.keys(), f"missing fields in {record}"
        assert record["artifact_id"] not in ids
        ids.add(record["artifact_id"])
        assert record["comparability"] == "diagnostic_non_comparable"
        assert record["project_current_evidence"] is False
        path = ROOT / record["file"]
        assert sha256(path) == record["sha256"], path
        assert path.name not in current_text, f"supplement artifact appears in current evidence: {path.name}"
        original = REPO / record["original_path"]
        assert original.read_bytes() == path.read_bytes(), f"copy differs from original: {path.name}"
    for record in manifest["post_snapshot_evidence"]:
        assert record["artifact_id"] not in ids
        ids.add(record["artifact_id"])
        assert record["project_current_evidence"] is False
        assert sha256(ROOT / record["file"]) == record["sha256"]
    print(f"supplement verified: {len(ids)} unique artifacts; all hashes and boundaries valid")


if __name__ == "__main__":
    main()

