#!/usr/bin/env python3
"""Emit conservative crypto capability contract artifacts.

This is the shared command-surface bridge. Ports can replace the default
missing rows with real pass/fail rows once their vector and backend probes are
wired, but the Project matrix should never hide missing crypto evidence.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[4]
BIP340_VECTORS = ROOT / "Nodes/Shared/testing/fixtures/bip340/test-vectors.csv"
NATIVE_CRYPTO_VECTORS = ROOT / "Nodes/Shared/conformance/fixtures/native_crypto_v1_vectors.json"
EQUIVALENCE_MANIFEST = ROOT / "Nodes/Shared/testing/fixtures/crypto_backend_equivalence_v1.json"
BLOCK_CONNECT_MANIFEST = ROOT / "Nodes/Shared/testing/fixtures/block_connect_backend_probe_v1.json"

BACKENDS = {
    "cpp": "libsecp256k1",
    "csharp": "libsecp256k1-secp256k1.net",
    "go": "libsecp256k1",
    "java": "libsecp256k1-acinq",
    "ocaml": "libsecp256k1",
    "rust": "rust-secp256k1",
    "swift": "libsecp256k1",
    "zig": "libsecp256k1",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bip340_case_total() -> int:
    with BIP340_VECTORS.open(newline="", encoding="utf-8") as handle:
        return sum(1 for _ in csv.DictReader(handle))


def suite(
    suite_id: str,
    suite_version: str,
    suite_hash: str,
    case_total: int,
    provenance: list[str],
    does_not_prove: str,
) -> dict[str, Any]:
    return {
        "suite_id": suite_id,
        "suite_version": suite_version,
        "suite_hash": suite_hash,
        "case_total": case_total,
        "provenance": provenance,
        "does_not_prove": does_not_prove,
    }


def contract(
    *,
    port: str,
    capability: str,
    status: str,
    backend: str,
    evidence_kind: str,
    evidence_path: str,
    command_key: str,
    provenance: list[str],
    does_not_prove: str,
) -> dict[str, Any]:
    return {
        "port": port,
        "contract_id": f"{port}.{capability}",
        "capability": capability,
        "status": status,
        "scope": "host",
        "backend": backend,
        "evidence_kind": evidence_kind,
        "evidence_path": evidence_path,
        "command_key": command_key,
        "provenance": provenance,
        "does_not_prove": does_not_prove,
        "blocking_for": ["pure_crypto_experiment"],
    }


def crypto_vectors_payload(port: str, backend: str) -> dict[str, Any]:
    bip_hash = sha256(BIP340_VECTORS)
    equivalence_hash = sha256(EQUIVALENCE_MANIFEST)
    native = json.loads(NATIVE_CRYPTO_VECTORS.read_text(encoding="utf-8"))
    native_total = len(native.get("vectors", []))
    return {
        "schema": "port.test_capability_contract.v1",
        "category": "test_capability_contracts",
        "port": port,
        "captured_at": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "suites": [
            suite(
                "bitcoin.bip340_schnorr_vectors",
                "2026-06-07",
                bip_hash,
                bip340_case_total(),
                ["bip_standard_vector"],
                "BIP340 verification vectors do not prove ECDSA, Taproot tweak handling, block connect usage, or every secp256k1 implementation behavior.",
            ),
            suite(
                "rb.crypto_backend_equivalence_v1",
                "2026-06-07",
                equivalence_hash,
                bip340_case_total() + native_total,
                ["bip_standard_vector", "proof_derived"],
                "Backend equivalence vectors do not prove every libsecp256k1 internal test, every consensus path, or block-connect usage.",
            ),
        ],
        "contracts": [
            contract(
                port=port,
                capability="crypto_bip340_vectors",
                status="missing",
                backend=backend,
                evidence_kind="suite",
                evidence_path="Nodes/Shared/testing/fixtures/bip340/test-vectors.csv",
                command_key="test_crypto_vectors",
                provenance=["bip_standard_vector"],
                does_not_prove="Missing means this port has not emitted a BIP340 vector result for the shared suite.",
            ),
            contract(
                port=port,
                capability="crypto_libsecp256k1_equivalence",
                status="missing",
                backend=backend,
                evidence_kind="suite",
                evidence_path="Nodes/Shared/testing/fixtures/crypto_backend_equivalence_v1.json",
                command_key="test_crypto_vectors",
                provenance=["bip_standard_vector", "proof_derived"],
                does_not_prove="Missing means this port has not compared its selected backend against the shared libsecp256k1-equivalence vector suite.",
            ),
        ],
    }


def block_connect_payload(port: str, backend: str) -> dict[str, Any]:
    return {
        "schema": "port.test_capability_contract.v1",
        "category": "test_capability_contracts",
        "port": port,
        "captured_at": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "suites": [
            suite(
                "rb.block_connect_backend_probe_v1",
                "2026-06-07",
                sha256(BLOCK_CONNECT_MANIFEST),
                2,
                ["rb_live_chain_regression", "proof_derived"],
                "Bounded backend probe does not prove long-sync safety, tip maintenance, or every future script template.",
            )
        ],
        "contracts": [
            contract(
                port=port,
                capability="block_connect_with_backend",
                status="missing",
                backend=backend,
                evidence_kind="suite",
                evidence_path="Nodes/Shared/testing/fixtures/block_connect_backend_probe_v1.json",
                command_key="test_block_connect_backend",
                provenance=["rb_live_chain_regression", "proof_derived"],
                does_not_prove="Missing means this port has not emitted bounded block-connect evidence that observes the selected backend on ECDSA and Taproot/Schnorr fixture paths.",
            )
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=["crypto-vectors", "block-connect-backend"])
    parser.add_argument("--port", required=True, choices=sorted(BACKENDS))
    parser.add_argument("--backend", default="")
    parser.add_argument("--result-path", required=True)
    args = parser.parse_args()

    backend = args.backend or BACKENDS[args.port]
    payload = crypto_vectors_payload(args.port, backend) if args.kind == "crypto-vectors" else block_connect_payload(args.port, backend)
    path = Path(args.result_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
