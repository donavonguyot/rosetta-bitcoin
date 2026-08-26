#!/usr/bin/env python3
"""Generate the tracked supplement manifest from byte-preserved evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
EVIDENCE = ROOT / "evidence"

SPECS = {
    "mojo_docker_pure_baseline_5k_benchmark_2026-06-17.json": (
        "pure_backend_5k",
        "mojo-pure-secp256k1",
        "Recorded pure-backend validation to height 5,000.",
    ),
    "mojo_docker_pure_performance_100k_benchmark_2026-06-17.json": (
        "pure_backend_fresh_100k",
        "mojo-pure-secp256k1",
        "Recorded fresh-state pure-backend validation to height 100,000.",
    ),
    "mojo_docker_pure_post_100k_to_tip_benchmark_2026-06-17.json": (
        "pure_backend_100k_to_140234",
        "mojo-pure-secp256k1",
        "Recorded pure-backend resume from height 100,000 to 140,234.",
    ),
    "mojo_docker_script_corpus_shadow_2026-06-17.json": (
        "pure_native_shadow_45",
        "pure and native comparison",
        "Recorded agreement on the 45-fixture script corpus.",
    ),
    "mojo_docker_script_corpus_reject_native_2026-06-17.json": (
        "native_reject_6",
        "native libsecp256k1",
        "Recorded rejection of six crafted invalid cases by the native backend.",
    ),
    "mojo_docker_script_corpus_reject_pure_2026-06-17.json": (
        "pure_reject_6",
        "mojo-pure-secp256k1",
        "Recorded rejection of six crafted invalid cases by the pure backend.",
    ),
    "mojo_docker_script_corpus_reject_red_accept_ecdsa_2026-06-17.json": (
        "fault_accept_ecdsa",
        "mojo-pure-secp256k1 fault mode",
        "The ECDSA-accepting mutation made the negative corpus fail.",
    ),
    "mojo_docker_script_corpus_reject_red_accept_schnorr_2026-06-17.json": (
        "fault_accept_schnorr",
        "mojo-pure-secp256k1 fault mode",
        "The Schnorr-accepting mutation made the negative corpus fail.",
    ),
    "mojo_docker_script_corpus_reject_red_accept_taptweak_2026-06-17.json": (
        "fault_accept_taptweak",
        "mojo-pure-secp256k1 fault mode",
        "The Taproot-tweak-accepting mutation made the negative corpus fail.",
    ),
}

BOUNDARIES = [
    "full-node binary-gate completion",
    "production cryptographic safety",
    "benchmark comparability or performance ranking",
    "independent experimental replication",
    "causal productivity or model-capability effects",
    "correctness outside the exercised chain and test classes",
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


def main() -> None:
    artifacts = []
    for filename, (artifact_id, backend, claim) in sorted(SPECS.items()):
        path = EVIDENCE / filename
        if not path.is_file():
            raise SystemExit(f"missing evidence file: {path}")
        artifacts.append(
            {
                "artifact_id": artifact_id,
                "file": f"evidence/{filename}",
                "original_path": f"Nodes/Mojo/.benchmark-results/{filename}",
                "sha256": sha256(path),
                "backend": backend,
                "comparability": "diagnostic_non_comparable",
                "project_current_evidence": False,
                "supported_claim": claim,
                "does_not_prove": BOUNDARIES,
                "timestamp": "2026-06-17",
                "reproducibility": "archived JSON verification only; command does not regenerate the diagnostic run",
            }
        )

    blocker = ROOT / "blocker_56447_provenance.json"
    manifest = {
        "schema": "rosettabitcoin.paper_supplement.v1",
        "package_status": "diagnostic_non_comparable",
        "project_current_evidence": False,
        "original_snapshot": {
            "doi": "10.5281/zenodo.20738249",
            "commit": "4ade801b7ca0eb06f479e096bf285f621fd5e330",
            "archive_file": "donavonguyot/rosetta-bitcoin-v1.0.0.zip",
            "archive_md5": "b58d61b337ceed22651e498e8a4235b0",
            "publication_date": "2026-06-17",
        },
        "artifacts": artifacts,
        "post_snapshot_evidence": [
            {
                "artifact_id": "blocker_56447_provenance",
                "file": blocker.name,
                "sha256": sha256(blocker),
                "status": "post_snapshot_supplemental",
                "project_current_evidence": False,
                "supported_claim": "Exact provenance for the height-56,447 malformed-public-key blocker was recovered after the snapshot.",
                "does_not_prove": BOUNDARIES,
            }
        ],
        "package_does_not_prove": BOUNDARIES,
    }
    (ROOT / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()

