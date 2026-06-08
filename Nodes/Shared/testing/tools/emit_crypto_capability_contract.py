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
STORAGE_CODEC_VECTORS = ROOT / "Nodes/Shared/conformance/fixtures/chainstate_codec_v2_vectors.json"
STORAGE_GATE_CONTRACT = ROOT / "Nodes/Shared/storage/STORAGE_GATE.md"
SUITE_VERSION = "2026-06-07"

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


def native_crypto_case_total() -> int:
    native = json.loads(NATIVE_CRYPTO_VECTORS.read_text(encoding="utf-8"))
    return len(native.get("vectors", []))


SUITES: dict[str, dict[str, Any]] = {
    "bitcoin.bip340_schnorr_vectors": {
        "path": BIP340_VECTORS,
        "case_total": bip340_case_total,
        "provenance": ["bip_standard_vector"],
        "does_not_prove": "BIP340 verification vectors do not prove ECDSA, Taproot tweak handling, block connect usage, or every secp256k1 implementation behavior.",
    },
    "rb.crypto_backend_equivalence_v1": {
        "path": EQUIVALENCE_MANIFEST,
        "case_total": lambda: bip340_case_total() + native_crypto_case_total(),
        "provenance": ["bip_standard_vector", "proof_derived"],
        "does_not_prove": "Backend equivalence vectors do not prove every libsecp256k1 internal test, every consensus path, or block-connect usage.",
    },
    "rb.block_connect_backend_probe_v1": {
        "path": BLOCK_CONNECT_MANIFEST,
        "case_total": lambda: 2,
        "provenance": ["rb_live_chain_regression", "proof_derived"],
        "does_not_prove": "Bounded backend probe does not prove long-sync safety, tip maintenance, or every future script template.",
    },
    "rb.storage_codec_vectors_v1": {
        "path": STORAGE_CODEC_VECTORS,
        "case_total": lambda: 7,
        "provenance": ["proof_derived"],
        "does_not_prove": "Storage codec vectors do not prove live sync safety, every future key family, or performance under long-run load.",
    },
    "rb.storage_restart_probe_v1": {
        "path": STORAGE_GATE_CONTRACT,
        "case_total": lambda: 2,
        "provenance": ["proof_derived"],
        "does_not_prove": "Bounded restart storage probes do not prove crash safety for every possible interruption point or long-run tip maintenance.",
    },
}

CAPABILITY_DEFAULTS: dict[str, dict[str, Any]] = {
    "crypto_bip340_vectors": {
        "contract_suffix": "crypto_bip340_vectors",
        "command_key": "test_crypto_vectors",
        "suite_id": "bitcoin.bip340_schnorr_vectors",
        "evidence_kind": "suite",
        "blocking_for": ["pure_crypto_experiment"],
    },
    "crypto_libsecp256k1_equivalence": {
        "contract_suffix": "crypto_libsecp256k1_equivalence",
        "command_key": "test_crypto_vectors",
        "suite_id": "rb.crypto_backend_equivalence_v1",
        "evidence_kind": "suite",
        "blocking_for": ["pure_crypto_experiment"],
    },
    "block_connect_with_backend": {
        "contract_suffix": "block_connect_with_backend",
        "command_key": "test_block_connect_backend",
        "suite_id": "rb.block_connect_backend_probe_v1",
        "evidence_kind": "suite",
        "blocking_for": ["pure_crypto_experiment"],
    },
    "storage_codec_vectors": {
        "contract_suffix": "storage_codec_vectors",
        "command_key": "test_storage_capability",
        "suite_id": "rb.storage_codec_vectors_v1",
        "evidence_kind": "storage_proof",
        "blocking_for": ["storage_codec_change"],
    },
    "storage_restart_after_codec_change": {
        "contract_suffix": "storage_restart_after_codec_change",
        "command_key": "test_storage_capability",
        "suite_id": "rb.storage_restart_probe_v1",
        "evidence_kind": "storage_proof",
        "blocking_for": ["storage_codec_change"],
    },
    "rocksdb_restart_persistence": {
        "contract_suffix": "rocksdb_restart_persistence",
        "command_key": "test_storage_capability",
        "suite_id": "rb.storage_restart_probe_v1",
        "evidence_kind": "storage_proof",
        "blocking_for": ["storage_codec_change"],
    },
}


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


def suite_for_id(suite_id: str) -> dict[str, Any]:
    if suite_id not in SUITES:
        raise SystemExit(f"unknown suite_id: {suite_id}")
    spec = SUITES[suite_id]
    path = spec["path"]
    return suite(
        suite_id,
        SUITE_VERSION,
        sha256(path),
        int(spec["case_total"]()),
        list(spec["provenance"]),
        str(spec["does_not_prove"]),
    )


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
    suite_id: str = "",
    suite_version: str = "",
    suite_hash: str = "",
    case_passed: int | None = None,
    case_total: int | None = None,
    blocking_for: list[str] | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "port": port,
        "contract_id": f"{port}.{capability}",
        "capability": capability,
        "status": status,
        "scope": "host",
        "backend": backend,
        "evidence_kind": evidence_kind,
        "evidence_path": evidence_path,
        "command_key": command_key,
        "suite_id": suite_id,
        "suite_version": suite_version,
        "suite_hash": suite_hash,
        "provenance": provenance,
        "does_not_prove": does_not_prove,
        "blocking_for": blocking_for or ["pure_crypto_experiment"],
    }
    if case_passed is not None:
        payload["case_passed"] = case_passed
    if case_total is not None:
        payload["case_total"] = case_total
    return payload


def crypto_vectors_payload(port: str, backend: str) -> dict[str, Any]:
    bip = suite_for_id("bitcoin.bip340_schnorr_vectors")
    equivalence = suite_for_id("rb.crypto_backend_equivalence_v1")
    return {
        "schema": "port.test_capability_contract.v1",
        "category": "test_capability_contracts",
        "port": port,
        "captured_at": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "suites": [
            bip,
            equivalence,
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
    block_suite = suite_for_id("rb.block_connect_backend_probe_v1")
    return {
        "schema": "port.test_capability_contract.v1",
        "category": "test_capability_contracts",
        "port": port,
        "captured_at": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "suites": [
            block_suite
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


def outcome_payload(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    port = str(data.get("port") or "").strip().lower()
    if port not in BACKENDS:
        raise SystemExit(f"{path}: valid port is required")
    backend = str(data.get("backend") or BACKENDS[port]).strip()
    outcomes = data.get("outcomes")
    if not isinstance(outcomes, list) or not outcomes:
        raise SystemExit(f"{path}: outcomes list is required")

    suite_ids: list[str] = []
    contracts: list[dict[str, Any]] = []
    results: list[dict[str, Any]] = []
    for index, row in enumerate(outcomes):
        if not isinstance(row, dict):
            raise SystemExit(f"{path}: outcomes[{index}] must be an object")
        capability = str(row.get("capability") or "").strip()
        if capability not in CAPABILITY_DEFAULTS:
            raise SystemExit(f"{path}: outcomes[{index}] unknown capability {capability!r}")
        status = str(row.get("status") or "").strip()
        if status not in {"pass", "fail", "missing"}:
            raise SystemExit(f"{path}: outcomes[{index}] status must be pass, fail, or missing")
        case_passed = row.get("case_passed")
        case_total = row.get("case_total")
        has_counts = case_passed is not None or case_total is not None
        if status in {"pass", "fail"} and not has_counts:
            raise SystemExit(f"{path}: outcomes[{index}] pass/fail rows require case_passed and case_total")
        if has_counts:
            if not isinstance(case_passed, int) or not isinstance(case_total, int):
                raise SystemExit(f"{path}: outcomes[{index}] case_passed and case_total must be integers when present")
            if case_passed < 0 or case_total < 0 or case_passed > case_total:
                raise SystemExit(f"{path}: outcomes[{index}] invalid case counts")

        defaults = CAPABILITY_DEFAULTS[capability]
        suite_id = str(row.get("suite_id") or defaults["suite_id"])
        suite_doc = suite_for_id(suite_id)
        if status != "missing":
            suite_ids.append(suite_id)
        notes = str(row.get("notes") or "").strip()
        contracts.append(
            contract(
                port=port,
                capability=capability,
                status=status,
                backend=backend,
                evidence_kind=str(defaults["evidence_kind"]),
                evidence_path=str(row.get("evidence_path") or repo_suite_path(suite_id)),
                command_key=str(defaults["command_key"]),
                provenance=list(suite_doc["provenance"]),
                does_not_prove=str(suite_doc["does_not_prove"]),
                suite_id=suite_id if status != "missing" else "",
                suite_version=str(suite_doc["suite_version"]) if status != "missing" else "",
                suite_hash=str(suite_doc["suite_hash"]) if status != "missing" else "",
                case_passed=case_passed if has_counts else None,
                case_total=case_total if has_counts else None,
                blocking_for=list(defaults["blocking_for"]),
            )
        )
        if notes:
            contracts[-1]["notes"] = notes
        results.append(
            {
                "suite_id": suite_id,
                "result": status,
                "case_passed": case_passed if has_counts else None,
                "case_total": case_total if has_counts else None,
                "notes": notes,
            }
        )

    unique_suites = []
    seen = set()
    for suite_id in suite_ids:
        if suite_id not in seen:
            unique_suites.append(suite_for_id(suite_id))
            seen.add(suite_id)
    return {
        "schema": "port.test_capability_contract.v1",
        "category": "test_capability_contracts",
        "port": port,
        "captured_at": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "suites": unique_suites,
        "contracts": contracts,
        "results": results,
    }


def repo_suite_path(suite_id: str) -> str:
    path = SUITES[suite_id]["path"]
    return str(path.relative_to(ROOT)).replace("\\", "/")


def self_test() -> int:
    missing = crypto_vectors_payload("rust", "rust-secp256k1")
    assert missing["contracts"][0]["status"] == "missing"
    assert "case_total" not in missing["contracts"][0]

    bip_hash = sha256(BIP340_VECTORS)
    passed = contract(
        port="rust",
        capability="crypto_bip340_vectors",
        status="pass",
        backend="rust-secp256k1",
        evidence_kind="suite",
        evidence_path="Nodes/Shared/testing/fixtures/bip340/test-vectors.csv",
        command_key="test_crypto_vectors",
        provenance=["bip_standard_vector"],
        does_not_prove="BIP340 verification vectors do not prove ECDSA.",
        suite_id="bitcoin.bip340_schnorr_vectors",
        suite_version="2026-06-07",
        suite_hash=bip_hash,
        case_passed=19,
        case_total=19,
    )
    assert passed["status"] == "pass"
    assert passed["case_passed"] == 19
    assert passed["case_total"] == 19
    assert passed["suite_hash"] == bip_hash

    failed = dict(passed)
    failed["status"] = "fail"
    failed["case_passed"] = 18
    assert failed["status"] == "fail"
    assert failed["case_passed"] < failed["case_total"]
    tmp = ROOT / "Nodes/Shared/testing/results/.emit_self_test_outcomes.json"
    try:
        tmp.write_text(
            json.dumps(
                {
                    "port": "rust",
                    "backend": "rust-secp256k1",
                    "outcomes": [
                        {
                            "capability": "crypto_bip340_vectors",
                            "status": "pass",
                            "case_passed": 19,
                            "case_total": 19,
                        },
                        {
                            "capability": "crypto_libsecp256k1_equivalence",
                            "status": "fail",
                            "case_passed": 26,
                            "case_total": 27,
                            "notes": "intentional self-test failure row",
                        },
                        {
                            "capability": "storage_codec_vectors",
                            "status": "missing",
                            "notes": "intentional self-test missing storage row",
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )
        payload = outcome_payload(tmp)
        assert payload["contracts"][0]["suite_id"] == "bitcoin.bip340_schnorr_vectors"
        assert payload["contracts"][1]["status"] == "fail"
        assert payload["contracts"][1]["case_total"] == 27
        assert payload["contracts"][2]["capability"] == "storage_codec_vectors"
        assert payload["contracts"][2]["status"] == "missing"
        assert "case_total" not in payload["contracts"][2]
    finally:
        tmp.unlink(missing_ok=True)
    print("emit_crypto_capability_contract self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", nargs="?", choices=["crypto-vectors", "block-connect-backend"])
    parser.add_argument("--port", choices=sorted(BACKENDS))
    parser.add_argument("--backend", default="")
    parser.add_argument("--outcomes", help="Read counted pass/fail outcomes from JSON")
    parser.add_argument("--result-path")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if args.outcomes:
        if not args.result_path:
            parser.error("--result-path is required with --outcomes")
        payload = outcome_payload(Path(args.outcomes))
        path = Path(args.result_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(path)
        return 0

    if not args.kind:
        parser.error("kind is required unless --self-test is used")
    if not args.port:
        parser.error("--port is required unless --self-test is used")
    if not args.result_path:
        parser.error("--result-path is required unless --self-test is used")

    backend = args.backend or BACKENDS[args.port]
    payload = crypto_vectors_payload(args.port, backend) if args.kind == "crypto-vectors" else block_connect_payload(args.port, backend)
    path = Path(args.result_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
