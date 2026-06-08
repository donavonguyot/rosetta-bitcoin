#!/usr/bin/env python3
"""Import canonical RB evidence into Project/project.db.

This is Project mission-control import tooling. It writes only the Project
database; it never opens port-local operational datadirs.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import json
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import dataclass, replace
from io import StringIO
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR_PATH = ROOT / "Nodes/Shared/conformance/tools/validate_benchmark_artifact.py"
_validator_spec = importlib.util.spec_from_file_location("rb_benchmark_validator", VALIDATOR_PATH)
if _validator_spec is None or _validator_spec.loader is None:
    raise RuntimeError(f"cannot load benchmark artifact validator: {VALIDATOR_PATH}")
_validator = importlib.util.module_from_spec(_validator_spec)
_validator_spec.loader.exec_module(_validator)

PORTS: dict[str, tuple[str, str, str]] = {
    "csharp": ("CSharpNode", "C#", "follower"),
    "cpp": ("CppNode", "C++", "follower"),
    "elixir": ("ElixirNode", "Elixir", "follower"),
    "go": ("GoNode", "Go", "follower"),
    "java": ("JavaNode", "Java", "lead"),
    "ocaml": ("OCamlNode", "OCaml", "follower"),
    "python": ("PythonNode", "Python", "scout"),
    "reference": ("BitcoinCoreReference", "C++", "reference"),
    "rust": ("RustNode", "Rust", "follower"),
    "swift": ("SwiftNode", "Swift", "follower"),
    "typescript": ("TypeScriptNode", "TypeScript", "follower"),
    "zig": ("ZigNode", "Zig", "follower"),
}

IMPLEMENTATION_PORTS: tuple[tuple[str, str], ...] = (
    ("csharp", "csharp"),
    ("csbitnode", "csharp"),
    ("cpp", "cpp"),
    ("cpbitnode", "cpp"),
    ("elixir", "elixir"),
    ("exbitnode", "elixir"),
    ("go", "go"),
    ("gobitnode", "go"),
    ("java", "java"),
    ("jbitnode", "java"),
    ("ocaml", "ocaml"),
    ("ocbitnode", "ocaml"),
    ("python", "python"),
    ("pybitnode", "python"),
    ("reference", "reference"),
    ("bitcoin", "reference"),
    ("rust", "rust"),
    ("rsbitnode", "rust"),
    ("swift", "swift"),
    ("swbitnode", "swift"),
    ("typescript", "typescript"),
    ("tsbitnode", "typescript"),
    ("zig", "zig"),
    ("zigbitnode", "zig"),
)

PORT_LIFECYCLE: tuple[dict[str, str], ...] = (
    {
        "port": "cpp",
        "lifecycle_status": "active_contender",
        "benchmark_scope": "full_suite",
        "retired_at_gate": "",
        "retired_reason": "",
        "notes": "Serious benchmark-table port; continue through shakedown_50k, performance_100k, and future tip gates.",
    },
    {
        "port": "csharp",
        "lifecycle_status": "active_contender",
        "benchmark_scope": "full_suite",
        "retired_at_gate": "",
        "retired_reason": "",
        "notes": "Serious benchmark-table port; continue through shakedown_50k, performance_100k, and future tip gates.",
    },
    {
        "port": "go",
        "lifecycle_status": "active_contender",
        "benchmark_scope": "full_suite",
        "retired_at_gate": "",
        "retired_reason": "",
        "notes": "Lead fast-native contender; continue through the full official benchmark suite.",
    },
    {
        "port": "java",
        "lifecycle_status": "active_contender",
        "benchmark_scope": "full_suite",
        "retired_at_gate": "",
        "retired_reason": "",
        "notes": "Serious JVM contender; continue through the full official benchmark suite.",
    },
    {
        "port": "rust",
        "lifecycle_status": "active_contender",
        "benchmark_scope": "full_suite",
        "retired_at_gate": "",
        "retired_reason": "",
        "notes": "Lead native contender; continue through the full official benchmark suite.",
    },
    {
        "port": "swift",
        "lifecycle_status": "active_contender",
        "benchmark_scope": "full_suite",
        "retired_at_gate": "",
        "retired_reason": "",
        "notes": "Serious contender after baseline and long-run modernization; continue through the full official benchmark suite.",
    },
    {
        "port": "zig",
        "lifecycle_status": "active_contender",
        "benchmark_scope": "full_suite",
        "retired_at_gate": "",
        "retired_reason": "",
        "notes": "Promoted after clean unit telemetry, script corpus, baseline_5k, and shakedown_50k evidence; continue through the full official benchmark suite.",
    },
    {
        "port": "python",
        "lifecycle_status": "baseline_retired",
        "benchmark_scope": "baseline_5k_only",
        "retired_at_gate": "baseline_5k",
        "retired_reason": "Useful provenance and baseline proof are preserved, but continued long-run optimization is not worth the maintenance burden.",
        "notes": "Keep source, tests, and 5k evidence. Do not push through 50k/100k unless explicitly reactivated.",
    },
    {
        "port": "typescript",
        "lifecycle_status": "baseline_retired",
        "benchmark_scope": "baseline_5k_only",
        "retired_at_gate": "baseline_5k",
        "retired_reason": "Useful baseline and portability lessons are preserved, but continued long-run optimization is not worth the maintenance burden.",
        "notes": "Keep source, tests, and 5k evidence. Do not push through 50k/100k unless explicitly reactivated.",
    },
    {
        "port": "elixir",
        "lifecycle_status": "baseline_retired",
        "benchmark_scope": "baseline_5k_only",
        "retired_at_gate": "baseline_5k",
        "retired_reason": "Interesting BEAM implementation and 5k proof are preserved, but the next long-run wall would be a project within the project.",
        "notes": "Keep source, tests, and 5k evidence. Do not push through 50k/100k unless explicitly reactivated.",
    },
    {
        "port": "reference",
        "lifecycle_status": "reference",
        "benchmark_scope": "reference_only",
        "retired_at_gate": "",
        "retired_reason": "",
        "notes": "Bitcoin Core Reference is the byte source and comparison anchor, not a follower benchmark contender.",
    },
)

DECISIONS: tuple[dict[str, str], ...] = (
    {
        "decision_id": "project-db-is-mission-control",
        "title": "Project DB is mission control",
        "status": "accepted",
        "context": "Project needs a tracked cross-port evidence index that is separate from node runtime state.",
        "decision": "Project/project.db is the mission-control database for observations, indexes, reports, and decisions.",
        "consequences": "Ports may export observations into Project, but may not read Project DB for operational node truth.",
        "source_path": "Project/README.md",
        "decided_at": "2026-06-04",
    },
    {
        "decision_id": "native-runtime-storage-boundary",
        "title": "Native runtime storage owns node truth",
        "status": "accepted",
        "context": "Follower ports must prove their own operational state instead of depending on another implementation or coordination database.",
        "decision": "Native/Core mode must use RocksDB/native operational storage for headers, block index, sync state, validated tip, UTXO, undo, blockers, and status truth.",
        "consequences": "Compatibility surfaces may exist only outside baseline proof paths and cannot support Core/native compliance claims.",
        "source_path": "Docs/storage-contract.md",
        "decided_at": "2026-06-04",
    },
    {
        "decision_id": "shared-results-remain-canonical-proof",
        "title": "Shared proof JSON remains canonical evidence",
        "status": "accepted",
        "context": "Project needs queryability without replacing compact proof artifacts.",
        "decision": "Nodes/Shared/conformance/results remains the canonical compact proof directory; Project indexes those artifacts.",
        "consequences": "Project rows must retain source artifact links, and historical proof JSON is preserved.",
        "source_path": "Docs/artifact-retention.md",
        "decided_at": "2026-06-04",
    },
    {
        "decision_id": "project-reports-generated-on-demand",
        "title": "Reports are projections, not another source of truth",
        "status": "accepted",
        "context": "Markdown and JSON sprawl made current status harder to audit.",
        "decision": "Repeated status tables and reports should be generated from Project/project.db instead of hand-maintained.",
        "consequences": "Markdown keeps contracts and runbooks; Project carries repeated mission-control rows.",
        "source_path": "Project/scripts/README.md",
        "decided_at": "2026-06-04",
    },
)

BENCHMARK_GATES: tuple[dict[str, Any], ...] = (
    {
        "gate_id": "baseline_5k",
        "target_height": 5000,
        "target_label": "5k",
        "benchmark_kind": "baseline_5k_p2p",
        "role": "birth certificate baseline",
        "preferred_runtime_surface": "docker",
        "preferred_command_key": "docker_proof_local",
        "official_lane": "baseline_5k_p2p",
        "official_byte_source": "local_reference_p2p",
        "official_peer_mode": "local_reference",
        "official_proof_mode": "p2p_sync",
        "official_header_target_height": 5000,
        "official_prefetch_depth": 4,
        "official_script_runner_mode": "parallel",
        "official_utxo_accounting_policy": "core_spendable_v1",
        "official_chainstate_utxo_count": 4574,
        "fresh_state_required": 1,
        "local_reference_required": 1,
        "durable_required": 1,
        "wal_disabled_required": 0,
        "resume_supported_required": 1,
        "binary_gate_status": "not_attempted",
        "result_name_pattern": "<port>_<surface>_baseline_5k_benchmark_<YYYY-MM-DD>.json",
        "notes": "Birth certificate lane: Docker, local Reference P2P, fixed knobs, WAL enabled, fresh proof volume, clean corpus proof, and required timing buckets. Existing supporting_5k artifacts remain import-compatible aliases.",
    },
    {
        "gate_id": "shakedown_50k",
        "target_height": 50000,
        "target_label": "50k",
        "benchmark_kind": "shakedown_50k_p2p",
        "role": "serious readiness and telemetry shakedown",
        "preferred_runtime_surface": "docker",
        "preferred_command_key": "docker_proof_50k",
        "official_lane": "shakedown_50k_p2p",
        "official_byte_source": "local_reference_p2p",
        "official_peer_mode": "local_reference",
        "official_proof_mode": "p2p_sync",
        "official_header_target_height": 50000,
        "official_prefetch_depth": 4,
        "official_script_runner_mode": "parallel",
        "official_utxo_accounting_policy": "core_spendable_v1",
        "official_chainstate_utxo_count": 568855,
        "fresh_state_required": 1,
        "local_reference_required": 1,
        "durable_required": 1,
        "wal_disabled_required": 0,
        "resume_supported_required": 1,
        "binary_gate_status": "not_attempted",
        "result_name_pattern": "<port>_<surface>_shakedown_50k_benchmark_<YYYY-MM-DD>.json",
        "notes": "Serious readiness lane: Docker/local Reference P2P with live telemetry, slow-block detail, complete timing buckets, and fresh state. Existing supporting_50k artifacts remain import-compatible aliases.",
    },
    {
        "gate_id": "performance_100k",
        "target_height": 100000,
        "target_label": "100k",
        "benchmark_kind": "performance_100k_p2p",
        "role": "primary performance and optimization gate",
        "preferred_runtime_surface": "docker",
        "preferred_command_key": "docker_proof_100k",
        "official_lane": "performance_100k_p2p",
        "official_byte_source": "local_reference_p2p",
        "official_peer_mode": "local_reference",
        "official_proof_mode": "p2p_sync",
        "official_header_target_height": 100000,
        "official_prefetch_depth": 4,
        "official_script_runner_mode": "parallel",
        "official_utxo_accounting_policy": "core_spendable_v1",
        "official_chainstate_utxo_count": 13154991,
        "fresh_state_required": 1,
        "local_reference_required": 1,
        "durable_required": 1,
        "wal_disabled_required": 0,
        "resume_supported_required": 1,
        "binary_gate_status": "not_attempted",
        "result_name_pattern": "<port>_<surface>_performance_100k_benchmark_<YYYY-MM-DD>.json",
        "notes": "Primary optimization lane: Docker/local Reference P2P with WAL enabled, fresh state, fixed knobs, full telemetry, and complete timing import. Existing primary_100k artifacts remain import-compatible aliases.",
    },
    {
        "gate_id": "post_100k_to_tip",
        "target_height": -1,
        "target_label": "100k to tip",
        "benchmark_kind": "post_100k_to_tip_p2p",
        "role": "tip readiness from canonical 100k checkpoint",
        "preferred_runtime_surface": "docker",
        "preferred_command_key": "docker_proof_post_100k_to_tip",
        "official_lane": "post_100k_to_tip_p2p",
        "official_byte_source": "local_reference_p2p",
        "official_peer_mode": "local_reference",
        "official_proof_mode": "p2p_sync",
        "official_header_target_height": -1,
        "official_prefetch_depth": 4,
        "official_script_runner_mode": "parallel",
        "official_utxo_accounting_policy": "core_spendable_v1",
        "official_chainstate_utxo_count": -1,
        "fresh_state_required": 0,
        "local_reference_required": 1,
        "durable_required": 1,
        "wal_disabled_required": 0,
        "resume_supported_required": 1,
        "binary_gate_status": "not_attempted",
        "result_name_pattern": "<port>_<surface>_post_100k_to_tip_<YYYY-MM-DD>.json",
        "notes": "Immediate tip readiness lane: restore canonical performance_100k checkpoint state, sync to fixed local Reference finish height/hash, and build current evidence from Project control harness product progress. Not an empty-state tip_once audit.",
    },
    {
        "gate_id": "tip_once",
        "target_height": -1,
        "target_label": "tip once",
        "benchmark_kind": "tip_once_p2p",
        "role": "one-time empty-state-to-tip credibility proof",
        "preferred_runtime_surface": "docker",
        "preferred_command_key": "docker_proof_tip_once",
        "official_lane": "tip_once_p2p",
        "official_byte_source": "local_reference_p2p",
        "official_peer_mode": "local_reference",
        "official_proof_mode": "p2p_sync",
        "official_header_target_height": -1,
        "official_prefetch_depth": 4,
        "official_script_runner_mode": "parallel",
        "official_utxo_accounting_policy": "core_spendable_v1",
        "official_chainstate_utxo_count": -1,
        "fresh_state_required": 1,
        "local_reference_required": 1,
        "durable_required": 1,
        "wal_disabled_required": 0,
        "resume_supported_required": 1,
        "binary_gate_status": "not_attempted",
        "result_name_pattern": "<port>_<surface>_tip_once_<YYYY-MM-DD>.json",
        "notes": "One-time credibility lane: empty state to current tip with exact Reference start/finish height/hash, full telemetry summary, and no skipped consensus. Not ranked by empty-sync speed.",
    },
    {
        "gate_id": "tip_maintenance",
        "target_height": -1,
        "target_label": "tip maintenance",
        "benchmark_kind": "tip_maintenance_p2p",
        "role": "ongoing operational reality near tip",
        "preferred_runtime_surface": "docker",
        "preferred_command_key": "docker_tip_maintenance",
        "official_lane": "tip_maintenance_p2p",
        "official_byte_source": "network_or_local_reference_p2p",
        "official_peer_mode": "tip_peer",
        "official_proof_mode": "tip_maintenance",
        "official_header_target_height": -1,
        "official_prefetch_depth": 4,
        "official_script_runner_mode": "parallel",
        "official_utxo_accounting_policy": "core_spendable_v1",
        "official_chainstate_utxo_count": -1,
        "fresh_state_required": 0,
        "local_reference_required": 0,
        "durable_required": 1,
        "wal_disabled_required": 0,
        "resume_supported_required": 1,
        "binary_gate_status": "not_attempted",
        "result_name_pattern": "<port>_<surface>_tip_maintenance_<YYYY-MM-DD>.json",
        "notes": "Operational maintenance lane: start near or at tip, maintain blocks_current, record reconnects/stalls/restart recovery, and emit health/status telemetry. Not a speed ranking.",
    },
)

COMMAND_PURPOSES: dict[str, str] = {
    "docker_config": "validate compose configuration",
    "docker_build": "build the Docker runtime/proof image",
    "docker_warm": "warm Docker images before a benchmark campaign",
    "docker_status": "read status from inside the Docker runtime surface",
    "docker_proof_local": "run official baseline_5k Docker/local-reference P2P proof",
    "docker_proof_10k": "run historical/diagnostic Docker/local-reference P2P 10k proof",
    "docker_proof_50k": "run official shakedown_50k Docker/local-reference P2P proof",
    "docker_proof_100k": "run official performance_100k Docker/local-reference P2P proof",
    "docker_proof_post_100k_to_tip": "run official post_100k_to_tip Docker/local-reference P2P proof from a restored 100k checkpoint",
    "docker_tuning_100k_from_50k": "run historical/diagnostic resumed 50k-to-100k proof",
    "docker_proof_tip_once": "run one-time empty-state-to-tip credibility proof",
    "docker_tip_maintenance": "run near-tip operational maintenance proof",
    "docker_proof_rpc_replay": "run Docker/local-reference RPC replay proof",
    "docker_diagnostic_sync_proof": "run nonstandard diagnostic Docker sync proof",
    "docker_probe_external": "run bounded probe against external peers",
    "docker_supervisor": "start persistent Docker supervisor",
    "docker_supervisor_status": "read persistent supervisor status",
    "docker_supervisor_stop": "write the supervisor stop marker",
    "docker_supervisor_resume": "write the supervisor resume marker",
    "docker_smoke_once": "run one-shot Docker supervisor smoke",
    "docker_storage_proof": "run storage proof alias",
    "docker_script_corpus": "run shared script corpus alias",
}

TEST_COMMAND_PURPOSES = {
    "test_unit": "run the port's normal unit/regression test suite",
    "test_coverage": "run optional local coverage telemetry",
    "test_crypto_vectors": "run shared crypto vector capability contracts",
    "test_block_connect_backend": "run bounded block-connect backend capability probe",
}

TEST_CAPABILITY_STATUSES = {"pass", "fail", "missing", "not_applicable"}

TEST_CAPABILITY_PROVENANCE = {
    "bip_standard_vector",
    "bitcoin_core_upstream_vector",
    "libsecp256k1_upstream_vector",
    "rb_live_chain_regression",
    "rb_synthetic_edge_case",
    "port_regression",
    "proof_derived",
}

ECOSYSTEM_TEST_FALLBACKS = {
    "csharp": "SECP256K1_BACKEND=native dotnet test",
    "cpp": "cmake --build build && ctest --test-dir build --output-on-failure",
    "elixir": "mix test",
    "go": "go test ./...",
    "java": "mvn test",
    "ocaml": "dune runtest",
    "python": "python3 -m pytest",
    "rust": "cargo test",
    "swift": "swift test",
    "typescript": "npm test",
    "zig": "zig build test",
}


@dataclass(frozen=True)
class Artifact:
    artifact_id: str
    path: Path
    rel_path: str
    kind: str
    node_id: str
    source_sha256: str
    captured_at: str
    summary: dict[str, Any]
    raw_json: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project mission-control DB path")
    parser.add_argument("--rebuild", action="store_true", help="Delete and rebuild the DB before import")
    parser.add_argument("--results-dir", default="Nodes/Shared/conformance/results", help="Canonical result JSON directory")
    parser.add_argument("--testing-results-dir", default="Nodes/Shared/testing/results", help="Curated test and coverage result JSON directory")
    parser.add_argument("--current-evidence", default="Nodes/Shared/conformance/current_evidence.json", help="Curated current evidence index")
    parser.add_argument("--docker-dir", default="Nodes/Shared/docker/ports", help="Docker manifest directory")
    parser.add_argument("--status-json", action="append", default=[], help="Additional exported status JSON path")
    parser.add_argument("--blocker-ledger", action="append", default=[], help="Additional blocker ledger Markdown path")
    parser.add_argument("--include-history", action="store_true", help="Import every result JSON instead of only current_evidence entries")
    parser.add_argument("--tracked-only", action="store_true", help="Import only git-tracked default manifest/result/status/ledger files")
    parser.add_argument("--skip-sqlite-utils-check", action="store_true", help="Do not require the sqlite-utils CLI")
    parser.add_argument("--self-test", action="store_true", help="Run importer validation self-tests without importing")
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def stable_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def pretty_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True)


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def resolve_env_tokens(value: Any, env: dict[str, str]) -> Any:
    if isinstance(value, str):
        for key, replacement in env.items():
            value = value.replace("${" + key + "}", replacement)
        return value
    if isinstance(value, list):
        return [resolve_env_tokens(item, env) for item in value]
    if isinstance(value, dict):
        return {key: resolve_env_tokens(item, env) for key, item in value.items()}
    return value


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_id(*parts: Any) -> str:
    payload = "\x1f".join("" if part is None else str(part) for part in parts)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def rel(path: Path, root: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return payload


def tracked_paths(root: Path, pattern: str) -> set[Path]:
    try:
        completed = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--", pattern],
            check=True,
            capture_output=True,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return set()
    return {root / line.strip() for line in completed.stdout.splitlines() if line.strip()}


def iter_default_json_files(root: Path, directory: Path, tracked_only: bool) -> list[Path]:
    if not tracked_only:
        return sorted(directory.glob("*.json"))
    try:
        pattern = rel(directory, root) + "/*.json"
    except ValueError:
        return []
    return sorted(path for path in tracked_paths(root, pattern) if path.exists())


def text(value: Any, default: str = "") -> str:
    if value is None:
        return default
    return str(value)


def integer(value: Any, default: int | None = None) -> int | None:
    try:
        if value is None or value == "":
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def first(payload: dict[str, Any], *keys: str, default: Any = None) -> Any:
    for key in keys:
        if key in payload and payload[key] is not None:
            return payload[key]
    return default


def nested(payload: dict[str, Any], *keys: str, default: Any = None) -> Any:
    current: Any = payload
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def port_for_payload(path: Path, payload: dict[str, Any]) -> str:
    explicit_port = text(payload.get("port")).strip().lower()
    if explicit_port in PORTS:
        return explicit_port
    for candidate in (text(payload.get("node_id")), text(payload.get("implementation"))):
        haystack = candidate.lower()
        for needle, port in IMPLEMENTATION_PORTS:
            if needle in haystack:
                return port
    haystack = f"{path.name} {path.as_posix()}".lower()
    for needle, port in IMPLEMENTATION_PORTS:
        if needle in haystack:
            return port
    return "unknown"


def node_for_port(port: str) -> tuple[str, str, str, str]:
    implementation, language, role = PORTS.get(port, ("UnknownNode", "unknown", "unknown"))
    return port, implementation, language, role


def node_id_for_payload(path: Path, payload: dict[str, Any]) -> str:
    node_id = text(payload.get("node_id")).strip()
    if node_id:
        return node_id
    port = port_for_payload(path, payload)
    if port != "unknown":
        return port
    implementation = text(payload.get("implementation"), "unknown-node").strip()
    return implementation.lower().replace(" ", "-") or "unknown-node"


def implementation_for_node(node_id: str, payload: dict[str, Any]) -> tuple[str, str, str]:
    port = port_for_payload(Path(node_id), payload)
    implementation, language, role = PORTS.get(port, ("UnknownNode", "unknown", "unknown"))
    return (
        text(payload.get("implementation"), implementation) or implementation,
        text(payload.get("language"), language) or language,
        text(payload.get("role"), role) or role,
    )


def captured_at_for_payload(payload: dict[str, Any]) -> str:
    return text(first(payload, "captured_at", "updated_at", "started_at", "finished_at", default=""))


def benchmark_kind_for_payload(payload: dict[str, Any]) -> str:
    explicit = text(payload.get("benchmark_kind")).strip()
    if explicit:
        return canonical_benchmark_label(explicit)
    target_height = integer(payload.get("target_height"), None)
    if target_height == 5000:
        return "baseline_5k_p2p"
    if target_height == 10000:
        return "diagnostic_10k_p2p"
    if target_height == 50000:
        return "shakedown_50k_p2p"
    if target_height == 100000:
        return "performance_100k_p2p"
    return text(payload.get("category") or payload.get("artifact_kind"))


def canonical_benchmark_label(value: str) -> str:
    aliases = {
        "supporting_5k": "baseline_5k",
        "supporting_5k_p2p": "baseline_5k_p2p",
        "supporting_5k_rpc_replay": "baseline_5k_rpc_replay",
        "supporting_50k": "shakedown_50k",
        "supporting_50k_p2p": "shakedown_50k_p2p",
        "supporting_50k_rpc_replay": "shakedown_50k_rpc_replay",
        "primary_100k": "performance_100k",
        "primary_100k_p2p": "performance_100k_p2p",
        "primary_100k_rpc_replay": "performance_100k_rpc_replay",
        "supporting_10k": "diagnostic_10k",
        "supporting_10k_p2p": "diagnostic_10k_p2p",
        "tuning_50k_to_100k": "diagnostic_50k_to_100k",
        "tuning_50k_to_100k_p2p": "diagnostic_50k_to_100k_p2p",
    }
    return aliases.get(value, value)


def target_label_for_payload(payload: dict[str, Any]) -> str:
    explicit = text(payload.get("target_label")).strip()
    if explicit:
        return explicit
    target_height = integer(payload.get("target_height"), None)
    labels = {
        5000: "5k",
        10000: "10k",
        50000: "50k",
        100000: "100k",
    }
    return labels.get(target_height, "")


def artifact_kind(path: Path, payload: dict[str, Any]) -> str:
    if path.match("*.docker.json") or "peer_modes" in payload and "proof_artifacts" in payload:
        return "docker_manifest"
    if text(payload.get("schema")) in {
        "port.test_result",
        "port.coverage_summary",
        "port.domain_coverage",
        "port.test_capability_contract.v1",
        "port.test_result.v1",
        "port.coverage_summary.v1",
        "port.domain_coverage.v1",
    }:
        return text(payload.get("schema"))
    if isinstance(payload.get("fixtures"), list):
        return "script_corpus_result"
    if "artifact_kind" in payload:
        return text(payload["artifact_kind"])
    if any(key in payload for key in ("sync_timing", "stage_totals_ms", "pipeline_timing_summary", "timing_events")):
        return "benchmark_result"
    if any(key in payload for key in ("validated_height", "sync_status", "chainstate_backend", "results")):
        return "conformance_result"
    return "json_artifact"


def artifact_summary(payload: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "implementation",
        "node_id",
        "port",
        "category",
        "result",
        "chain",
        "runtime_surface",
        "peer_mode",
        "sync_status",
        "binary_gate_status",
        "bounded_gate_status",
        "validated_height",
        "header_height",
        "stored_block_height",
        "chainstate_backend",
        "chainstate_status",
        "fixture_count",
        "complete_count",
        "incomplete_count",
        "schema",
        "command_key",
        "line_percent",
        "branch_percent",
        "suite_id",
        "suite_hash",
    ]
    return {key: payload[key] for key in keys if key in payload}


def make_artifact(path: Path, root: Path, payload: dict[str, Any]) -> Artifact:
    source_sha = file_sha256(path)
    rel_path = rel(path, root)
    node_id = node_id_for_payload(path, payload)
    return Artifact(
        artifact_id=stable_id(rel_path, source_sha),
        path=path,
        rel_path=rel_path,
        kind=artifact_kind(path, payload),
        node_id=node_id,
        source_sha256=source_sha,
        captured_at=captured_at_for_payload(payload),
        summary=artifact_summary(payload),
        raw_json=stable_json(payload),
    )


def init_db(connection: sqlite3.Connection, schema_path: Path) -> None:
    with schema_path.open("r", encoding="utf-8") as handle:
        connection.executescript(handle.read())


def upsert_artifact(connection: sqlite3.Connection, artifact: Artifact) -> None:
    connection.execute(
        """
        INSERT INTO artifacts(
          artifact_id, path, kind, node_id, source_sha256, captured_at,
          summary_json, raw_json
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(artifact_id) DO UPDATE SET
          path = excluded.path,
          kind = excluded.kind,
          node_id = excluded.node_id,
          source_sha256 = excluded.source_sha256,
          captured_at = excluded.captured_at,
          summary_json = excluded.summary_json,
          raw_json = excluded.raw_json
        WHERE
          artifacts.path <> excluded.path OR
          artifacts.kind <> excluded.kind OR
          artifacts.node_id <> excluded.node_id OR
          artifacts.source_sha256 <> excluded.source_sha256 OR
          artifacts.captured_at <> excluded.captured_at OR
          artifacts.summary_json <> excluded.summary_json OR
          artifacts.raw_json <> excluded.raw_json
        """,
        (
            artifact.artifact_id,
            artifact.rel_path,
            artifact.kind,
            artifact.node_id,
            artifact.source_sha256,
            artifact.captured_at,
            pretty_json(artifact.summary),
            artifact.raw_json,
        ),
    )


def artifact_exists(connection: sqlite3.Connection, artifact_id: str) -> bool:
    row = connection.execute("SELECT 1 FROM artifacts WHERE artifact_id = ?", (artifact_id,)).fetchone()
    return row is not None


def upsert_node(
    connection: sqlite3.Connection,
    node_id: str,
    implementation: str,
    language: str,
    role: str,
    root_path: str,
    default_datadir: str,
    notes: str,
    source_artifact_id: str | None,
) -> None:
    connection.execute(
        """
        INSERT INTO nodes(
          node_id, implementation, language, role, repo_path, default_datadir,
          status, notes, source_artifact_id, created_at, updated_at
        ) VALUES(?, ?, ?, ?, ?, ?, 'active', ?, ?, '', '')
        ON CONFLICT(node_id) DO UPDATE SET
          implementation = excluded.implementation,
          language = excluded.language,
          role = excluded.role,
          repo_path = excluded.repo_path,
          default_datadir = excluded.default_datadir,
          status = excluded.status,
          notes = excluded.notes,
          source_artifact_id = excluded.source_artifact_id,
          updated_at = ''
        """,
        (node_id, implementation, language, role, root_path, default_datadir, notes, source_artifact_id),
    )


def docker_manifest_already_imported(
    connection: sqlite3.Connection,
    artifact_id: str,
    port: str,
    command_count: int,
) -> bool:
    contract = connection.execute(
        "SELECT 1 FROM docker_contracts WHERE port = ? AND source_artifact_id = ?",
        (port, artifact_id),
    ).fetchone()
    if contract is None:
        return False
    commands = connection.execute(
        "SELECT count(*) FROM port_commands WHERE port = ? AND source_artifact_id = ?",
        (port, artifact_id),
    ).fetchone()[0]
    return commands >= command_count


def import_port_commands(
    connection: sqlite3.Connection,
    port: str,
    node_id: str,
    commands: dict[str, Any],
    source_artifact_id: str,
) -> None:
    connection.execute("DELETE FROM port_commands WHERE port = ?", (port,))
    for command_key, command in sorted(commands.items()):
        command_text = text(command)
        connection.execute(
            """
            INSERT INTO port_commands(
              command_id, port, node_id, command_key, purpose, command,
              supported, source_artifact_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(port, command_key) DO UPDATE SET
              node_id = excluded.node_id,
              purpose = excluded.purpose,
              command = excluded.command,
              supported = excluded.supported,
              source_artifact_id = excluded.source_artifact_id
            """,
            (
                stable_id("port_command", port, command_key),
                port,
                node_id,
                command_key,
                COMMAND_PURPOSES.get(command_key, ""),
                command_text,
                1 if command_text else 0,
                source_artifact_id,
            ),
        )


def makefile_has_target(makefile: Path, target: str) -> bool:
    if not makefile.exists():
        return False
    pattern = re.compile(rf"^{re.escape(target)}\s*:")
    with makefile.open("r", encoding="utf-8") as handle:
        return any(pattern.match(line) for line in handle)


def discover_test_commands(root: Path, port: str, root_path: str) -> dict[str, dict[str, Any]]:
    if port == "reference":
        return {}
    port_root = root / root_path
    commands: dict[str, dict[str, Any]] = {}

    makefile = port_root / "Makefile"
    if makefile_has_target(makefile, "test"):
        commands["test_unit"] = {
            "category": "unit_tests",
            "command": f"cd {root_path} && make test",
            "supported": 1,
            "discovery_method": "makefile:test",
            "notes": "Discovered from port Makefile.",
        }
    else:
        fallback = ECOSYSTEM_TEST_FALLBACKS.get(port, "")
        commands["test_unit"] = {
            "category": "unit_tests",
            "command": f"cd {root_path} && {fallback}" if fallback else "",
            "supported": 1 if fallback else 0,
            "discovery_method": "ecosystem_fallback" if fallback else "missing",
            "notes": "Deterministic ecosystem fallback; verify before treating as a passing claim."
            if fallback
            else "No unit-test command discovered.",
        }

    commands["test_coverage"] = {
        "category": "coverage_report",
        "command": "",
        "supported": 0,
        "discovery_method": "not_default_posture",
        "notes": "Coverage is optional local telemetry, not part of Project default test posture.",
    }
    for command_key, target, category, notes in (
        (
            "test_crypto_vectors",
            "test-crypto-vectors",
            "capability_contract",
            "Shared crypto vector capability contract command.",
        ),
        (
            "test_block_connect_backend",
            "test-block-connect-backend",
            "capability_contract",
            "Bounded block-connect backend capability contract command.",
        ),
    ):
        supported = makefile_has_target(makefile, target)
        commands[command_key] = {
            "category": category,
            "command": f"cd {root_path} && make {target}" if supported else "",
            "supported": 1 if supported else 0,
            "discovery_method": f"makefile:{target}" if supported else "missing",
            "notes": notes if supported else f"No {target} Makefile target discovered.",
        }
    return commands


def seed_test_commands(connection: sqlite3.Connection, root: Path) -> int:
    contracts = connection.execute(
        """
        SELECT port, node_id, root_path, source_artifact_id
        FROM docker_contracts
        WHERE port <> 'reference'
        ORDER BY port
        """
    ).fetchall()
    desired_rows: list[tuple[Any, ...]] = []
    desired_ids: list[str] = []
    for port, node_id, root_path, source_artifact_id in contracts:
        for command_key, info in discover_test_commands(root, text(port), text(root_path)).items():
            command_id = stable_id("test_command", port, command_key)
            desired_ids.append(command_id)
            desired_rows.append(
                (
                    command_id,
                    port,
                    node_id,
                    command_key,
                    text(info.get("category")),
                    TEST_COMMAND_PURPOSES.get(command_key, ""),
                    text(info.get("command")),
                    1 if info.get("supported") else 0,
                    text(info.get("discovery_method")),
                    text(info.get("notes")),
                    source_artifact_id,
                )
            )
    for row in desired_rows:
        connection.execute(
            """
            INSERT INTO test_commands(
              command_id, port, node_id, command_key, category, purpose,
              command, supported, discovery_method, notes, source_artifact_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(port, command_key) DO UPDATE SET
              node_id = excluded.node_id,
              category = excluded.category,
              purpose = excluded.purpose,
              command = excluded.command,
              supported = excluded.supported,
              discovery_method = excluded.discovery_method,
              notes = excluded.notes,
              source_artifact_id = excluded.source_artifact_id
            WHERE
              test_commands.node_id <> excluded.node_id OR
              test_commands.category <> excluded.category OR
              test_commands.purpose <> excluded.purpose OR
              test_commands.command <> excluded.command OR
              test_commands.supported <> excluded.supported OR
              test_commands.discovery_method <> excluded.discovery_method OR
              test_commands.notes <> excluded.notes OR
              test_commands.source_artifact_id <> excluded.source_artifact_id
            """,
            row,
        )
    if desired_ids:
        placeholders = ",".join("?" for _ in desired_ids)
        connection.execute(
            f"DELETE FROM test_commands WHERE command_id NOT IN ({placeholders})",
            desired_ids,
        )
    else:
        connection.execute("DELETE FROM test_commands")
    return len(desired_rows)


def import_docker_manifest(connection: sqlite3.Connection, root: Path, path: Path, payload: dict[str, Any]) -> int:
    artifact = make_artifact(path, root, payload)
    payload = resolve_env_tokens(
        payload,
        read_env_file(root / "Nodes/Shared/docker/reference_topology.env"),
    )
    port = text(payload.get("port"), path.stem.split(".")[0])
    commands = payload.get("commands") if isinstance(payload.get("commands"), dict) else {}
    existing = connection.execute(
        """
        SELECT artifact_id, source_sha256
        FROM artifacts
        WHERE path = ?
        """,
        (artifact.rel_path,),
    ).fetchone()
    if existing:
        artifact = replace(artifact, artifact_id=text(existing[0]))
        if text(existing[1]) == artifact.source_sha256 and docker_manifest_already_imported(
            connection,
            artifact.artifact_id,
            port,
            len(commands),
        ):
            return len(commands)
    upsert_artifact(connection, artifact)
    node_id, implementation, language, role = node_for_port(port)
    paths = payload.get("paths") if isinstance(payload.get("paths"), dict) else {}
    volumes = payload.get("volumes") if isinstance(payload.get("volumes"), dict) else {}
    upsert_node(
        connection,
        node_id,
        implementation,
        language,
        role,
        text(paths.get("root"), f"Nodes/{implementation.removesuffix('Node')}"),
        text(volumes.get("data")),
        "imported from Shared Docker manifest",
        artifact.artifact_id,
    )
    connection.execute(
        """
        INSERT INTO docker_contracts(
          port, node_id, status, root_path, dockerfile_path, compose_path,
          dockerignore_path, data_volume, proof_volume, supervisor_volume,
          commands_json, peer_modes_json, proof_artifacts_json, known_caveats_json,
          source_artifact_id
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(port) DO UPDATE SET
          node_id = excluded.node_id,
          status = excluded.status,
          root_path = excluded.root_path,
          dockerfile_path = excluded.dockerfile_path,
          compose_path = excluded.compose_path,
          dockerignore_path = excluded.dockerignore_path,
          data_volume = excluded.data_volume,
          proof_volume = excluded.proof_volume,
          supervisor_volume = excluded.supervisor_volume,
          commands_json = excluded.commands_json,
          peer_modes_json = excluded.peer_modes_json,
          proof_artifacts_json = excluded.proof_artifacts_json,
          known_caveats_json = excluded.known_caveats_json,
          source_artifact_id = excluded.source_artifact_id
        """,
        (
            port,
            node_id,
            text(payload.get("status")),
            text(paths.get("root")),
            text(paths.get("dockerfile")),
            text(paths.get("compose")),
            text(paths.get("dockerignore")),
            text(volumes.get("data")),
            text(volumes.get("proof")),
            text(volumes.get("supervisor")),
            pretty_json(payload.get("commands", {})),
            pretty_json(payload.get("peer_modes", {})),
            pretty_json(payload.get("proof_artifacts", {})),
            pretty_json(payload.get("known_caveats", [])),
            artifact.artifact_id,
        ),
    )
    import_port_commands(connection, port, node_id, commands, artifact.artifact_id)
    return len(commands)


def import_current_evidence_index(
    connection: sqlite3.Connection,
    root: Path,
    path: Path,
    tracked_only: bool,
) -> list[Path]:
    payload = read_json(path)
    if text(payload.get("schema")) != "rb.current_evidence.v1":
        raise SystemExit(f"{path} must use schema rb.current_evidence.v1")
    entries = payload.get("entries")
    if not isinstance(entries, list):
        raise SystemExit(f"{path} must contain entries[]")

    artifact = make_artifact(path, root, payload)
    upsert_artifact(connection, artifact)

    tracked_result_paths: set[Path] = set()
    if tracked_only:
        tracked_result_paths = tracked_paths(root, "Nodes/Shared/conformance/results/*.json")

    result_paths: list[Path] = []
    seen_paths: set[str] = set()
    active_entry_ids: list[str] = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise SystemExit(f"{path} entry {index} must be an object")
        port = text(entry.get("port")).strip()
        claim = text(entry.get("claim")).strip()
        gate_id = text(entry.get("gate_id")).strip()
        evidence_path = text(entry.get("path")).strip()
        status = text(entry.get("status"), "current").strip()
        notes = text(entry.get("notes")).strip()
        if not port or not claim or not evidence_path:
            raise SystemExit(f"{path} entry {index} must include port, claim, and path")
        if status != "current":
            raise SystemExit(f"{path} entry {index} has unsupported status {status!r}; expected 'current'")
        if evidence_path.startswith("/") or ".." in Path(evidence_path).parts:
            raise SystemExit(f"{path} entry {index} path must be repo-relative: {evidence_path}")
        full_path = root / evidence_path
        if not full_path.exists():
            raise SystemExit(f"{path} entry {index} missing evidence file: {evidence_path}")
        if tracked_only and full_path not in tracked_result_paths:
            raise SystemExit(f"{path} entry {index} evidence file is not tracked: {evidence_path}")
        read_json(full_path)
        entry_id = stable_id("current_evidence", port, claim, gate_id, evidence_path)
        active_entry_ids.append(entry_id)
        connection.execute(
            """
            INSERT INTO evidence_index_entries(
              entry_id, port, claim, gate_id, path, status, notes, source_artifact_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(port, claim, gate_id, path) DO UPDATE SET
              status = excluded.status,
              notes = excluded.notes,
              source_artifact_id = excluded.source_artifact_id
            WHERE
              evidence_index_entries.status <> excluded.status OR
              evidence_index_entries.notes <> excluded.notes OR
              evidence_index_entries.source_artifact_id <> excluded.source_artifact_id
            """,
            (
                entry_id,
                port,
                claim,
                gate_id,
                evidence_path,
                status,
                notes,
                artifact.artifact_id,
            ),
        )
        if evidence_path not in seen_paths:
            result_paths.append(full_path)
            seen_paths.add(evidence_path)
    if active_entry_ids:
        placeholders = ",".join("?" for _ in active_entry_ids)
        connection.execute(
            f"DELETE FROM evidence_index_entries WHERE entry_id NOT IN ({placeholders})",
            active_entry_ids,
        )
    else:
        connection.execute("DELETE FROM evidence_index_entries")
    return result_paths


def import_benchmark_gates(connection: sqlite3.Connection) -> None:
    active_gate_ids = tuple(gate["gate_id"] for gate in BENCHMARK_GATES)
    placeholders = ",".join("?" for _ in active_gate_ids)
    connection.execute(
        f"DELETE FROM benchmark_gates WHERE gate_id NOT IN ({placeholders})",
        active_gate_ids,
    )
    for gate in BENCHMARK_GATES:
        connection.execute(
            """
            INSERT INTO benchmark_gates(
              gate_id, target_height, target_label, benchmark_kind, role,
              preferred_runtime_surface, preferred_command_key,
              official_lane, official_byte_source, official_peer_mode,
              official_proof_mode, official_header_target_height,
              official_prefetch_depth, official_script_runner_mode,
              official_utxo_accounting_policy, official_chainstate_utxo_count,
              fresh_state_required,
              local_reference_required, durable_required, wal_disabled_required,
              resume_supported_required, binary_gate_status, result_name_pattern,
              notes
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(gate_id) DO UPDATE SET
              target_height = excluded.target_height,
              target_label = excluded.target_label,
              benchmark_kind = excluded.benchmark_kind,
              role = excluded.role,
              preferred_runtime_surface = excluded.preferred_runtime_surface,
              preferred_command_key = excluded.preferred_command_key,
              official_lane = excluded.official_lane,
              official_byte_source = excluded.official_byte_source,
              official_peer_mode = excluded.official_peer_mode,
              official_proof_mode = excluded.official_proof_mode,
              official_header_target_height = excluded.official_header_target_height,
              official_prefetch_depth = excluded.official_prefetch_depth,
              official_script_runner_mode = excluded.official_script_runner_mode,
              official_utxo_accounting_policy = excluded.official_utxo_accounting_policy,
              official_chainstate_utxo_count = excluded.official_chainstate_utxo_count,
              fresh_state_required = excluded.fresh_state_required,
              local_reference_required = excluded.local_reference_required,
              durable_required = excluded.durable_required,
              wal_disabled_required = excluded.wal_disabled_required,
              resume_supported_required = excluded.resume_supported_required,
              binary_gate_status = excluded.binary_gate_status,
              result_name_pattern = excluded.result_name_pattern,
              notes = excluded.notes
            WHERE
              benchmark_gates.target_height <> excluded.target_height OR
              benchmark_gates.target_label <> excluded.target_label OR
              benchmark_gates.benchmark_kind <> excluded.benchmark_kind OR
              benchmark_gates.role <> excluded.role OR
              benchmark_gates.preferred_runtime_surface <> excluded.preferred_runtime_surface OR
              benchmark_gates.preferred_command_key <> excluded.preferred_command_key OR
              benchmark_gates.official_lane <> excluded.official_lane OR
              benchmark_gates.official_byte_source <> excluded.official_byte_source OR
              benchmark_gates.official_peer_mode <> excluded.official_peer_mode OR
              benchmark_gates.official_proof_mode <> excluded.official_proof_mode OR
              benchmark_gates.official_header_target_height <> excluded.official_header_target_height OR
              benchmark_gates.official_prefetch_depth <> excluded.official_prefetch_depth OR
              benchmark_gates.official_script_runner_mode <> excluded.official_script_runner_mode OR
              benchmark_gates.official_utxo_accounting_policy <> excluded.official_utxo_accounting_policy OR
              benchmark_gates.official_chainstate_utxo_count <> excluded.official_chainstate_utxo_count OR
              benchmark_gates.fresh_state_required <> excluded.fresh_state_required OR
              benchmark_gates.local_reference_required <> excluded.local_reference_required OR
              benchmark_gates.durable_required <> excluded.durable_required OR
              benchmark_gates.wal_disabled_required <> excluded.wal_disabled_required OR
              benchmark_gates.resume_supported_required <> excluded.resume_supported_required OR
              benchmark_gates.binary_gate_status <> excluded.binary_gate_status OR
              benchmark_gates.result_name_pattern <> excluded.result_name_pattern OR
              benchmark_gates.notes <> excluded.notes
            """,
            (
                gate["gate_id"],
                gate["target_height"],
                gate["target_label"],
                gate["benchmark_kind"],
                gate["role"],
                gate["preferred_runtime_surface"],
                gate["preferred_command_key"],
                gate["official_lane"],
                gate["official_byte_source"],
                gate["official_peer_mode"],
                gate["official_proof_mode"],
                gate["official_header_target_height"],
                gate["official_prefetch_depth"],
                gate["official_script_runner_mode"],
                gate["official_utxo_accounting_policy"],
                gate["official_chainstate_utxo_count"],
                gate["fresh_state_required"],
                gate["local_reference_required"],
                gate["durable_required"],
                gate["wal_disabled_required"],
                gate["resume_supported_required"],
                gate["binary_gate_status"],
                gate["result_name_pattern"],
                gate["notes"],
            ),
        )


def import_port_lifecycle(connection: sqlite3.Connection) -> None:
    active_ports = tuple(row["port"] for row in PORT_LIFECYCLE)
    placeholders = ",".join("?" for _ in active_ports)
    connection.execute(
        f"DELETE FROM port_lifecycle WHERE port NOT IN ({placeholders})",
        active_ports,
    )
    for row in PORT_LIFECYCLE:
        connection.execute(
            """
            INSERT INTO port_lifecycle(
              port, lifecycle_status, benchmark_scope, retired_at_gate,
              retired_reason, notes, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, '')
            ON CONFLICT(port) DO UPDATE SET
              lifecycle_status = excluded.lifecycle_status,
              benchmark_scope = excluded.benchmark_scope,
              retired_at_gate = excluded.retired_at_gate,
              retired_reason = excluded.retired_reason,
              notes = excluded.notes,
              updated_at = ''
            WHERE
              port_lifecycle.lifecycle_status <> excluded.lifecycle_status OR
              port_lifecycle.benchmark_scope <> excluded.benchmark_scope OR
              port_lifecycle.retired_at_gate <> excluded.retired_at_gate OR
              port_lifecycle.retired_reason <> excluded.retired_reason OR
              port_lifecycle.notes <> excluded.notes
            """,
            (
                row["port"],
                row["lifecycle_status"],
                row["benchmark_scope"],
                row["retired_at_gate"],
                row["retired_reason"],
                row["notes"],
            ),
        )


def iter_consensus_rules(payload: dict[str, Any]) -> list[dict[str, Any]]:
    rules = payload.get("rules")
    if isinstance(rules, list):
        return [rule for rule in rules if isinstance(rule, dict)]
    return []


def import_consensus_rule_ledger(connection: sqlite3.Connection, root: Path, path: Path) -> int:
    payload = read_json(path)
    artifact = make_artifact(path, root, payload)
    rules = iter_consensus_rules(payload)
    existing = connection.execute(
        """
        SELECT artifact_id, source_sha256
        FROM artifacts
        WHERE path = ?
        """,
        (artifact.rel_path,),
    ).fetchone()
    if existing:
        artifact = replace(artifact, artifact_id=text(existing[0]))
        existing_rules = connection.execute(
            "SELECT count(*) FROM consensus_rules WHERE source_artifact_id = ?",
            (artifact.artifact_id,),
        ).fetchone()[0]
        if text(existing[1]) == artifact.source_sha256 and existing_rules >= len(rules):
            return len(rules)
    elif artifact_exists(connection, artifact.artifact_id):
        existing_rules = connection.execute(
            "SELECT count(*) FROM consensus_rules WHERE source_artifact_id = ?",
            (artifact.artifact_id,),
        ).fetchone()[0]
        if existing_rules >= len(rules):
            return len(rules)
    upsert_artifact(connection, artifact)
    for rule in rules:
        rule_id = text(rule.get("rule_id"))
        if not rule_id:
            continue
        first_observed = rule.get("first_observed") if isinstance(rule.get("first_observed"), dict) else {}
        blocker = rule.get("blocker") if isinstance(rule.get("blocker"), dict) else {}
        first_height = integer(first_observed.get("height"), -1)
        blocker_height = integer(blocker.get("height"), first_height)
        connection.execute(
            """
            INSERT INTO consensus_rules(
              rule_id, category, title, chain, status, first_height,
              blocker_height, missing_rule, fixture_ids_json,
              required_rules_json, tags_json, raw_json, source_artifact_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(rule_id) DO UPDATE SET
              category = excluded.category,
              title = excluded.title,
              chain = excluded.chain,
              status = excluded.status,
              first_height = excluded.first_height,
              blocker_height = excluded.blocker_height,
              missing_rule = excluded.missing_rule,
              fixture_ids_json = excluded.fixture_ids_json,
              required_rules_json = excluded.required_rules_json,
              tags_json = excluded.tags_json,
              raw_json = excluded.raw_json,
              source_artifact_id = excluded.source_artifact_id
            """,
            (
                rule_id,
                text(rule.get("category")),
                text(rule.get("title")),
                text(rule.get("chain"), text(payload.get("chain"))),
                text(rule.get("status")),
                first_height,
                blocker_height,
                text(blocker.get("missing_rule")),
                pretty_json(rule.get("fixture_ids", [])),
                pretty_json(rule.get("required_rules", [])),
                pretty_json(rule.get("tags", [])),
                pretty_json(rule),
                artifact.artifact_id,
            ),
        )
        for index, evidence in enumerate(rule.get("evidence", [])):
            if not isinstance(evidence, dict):
                continue
            connection.execute(
                """
                INSERT INTO consensus_rule_evidence(
                  evidence_id, rule_id, port, artifact_path, result,
                  corpus_result, runtime_surface, verifier_json,
                  source_artifact_id
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(evidence_id) DO UPDATE SET
                  port = excluded.port,
                  artifact_path = excluded.artifact_path,
                  result = excluded.result,
                  corpus_result = excluded.corpus_result,
                  runtime_surface = excluded.runtime_surface,
                  verifier_json = excluded.verifier_json,
                  source_artifact_id = excluded.source_artifact_id
                """,
                (
                    stable_id("consensus_rule_evidence", artifact.artifact_id, rule_id, index),
                    rule_id,
                    text(evidence.get("port")).lower(),
                    text(evidence.get("artifact")),
                    text(evidence.get("result")),
                    text(evidence.get("corpus_result")),
                    text(evidence.get("runtime_surface")),
                    pretty_json(evidence.get("verifier", {})),
                    artifact.artifact_id,
                ),
            )
    return len(rules)


def result_from_payload(payload: dict[str, Any]) -> str:
    if isinstance(payload.get("passed"), bool):
        return "passed" if payload["passed"] else "failed"
    for key in ("result", "bounded_gate_status", "long_sync_status", "fixture_replay_status", "live_smoke_status"):
        value = text(payload.get(key))
        if value in {"passed", "target_reached", "ok", "success"}:
            return "passed"
        if value in {"failed", "blocked", "error"}:
            return "failed"
        if value:
            return value
    return "recorded"


def result_rows(payload: dict[str, Any]) -> list[dict[str, Any]]:
    if text(payload.get("schema")) == "shared.script_fixtures.validation.v1":
        return [
            {
                "fixture_id": "shared.script_fixtures.manifest",
                "category": "script_corpus_manifest",
                "result": result_from_payload(payload),
                "validated_height": None,
                "failure": text(payload.get("failure")),
                "raw": payload,
            }
        ]
    rows = payload.get("results")
    if isinstance(rows, list):
        return [row for row in rows if isinstance(row, dict)]
    fixtures = payload.get("fixtures")
    if isinstance(fixtures, list):
        out: list[dict[str, Any]] = []
        for row in fixtures:
            if not isinstance(row, dict):
                continue
            errors = row.get("errors")
            has_errors = isinstance(errors, list) and bool(errors)
            status = text(row.get("structural_status"))
            out.append(
                {
                    "fixture_id": row.get("fixture_id", ""),
                    "category": "script_corpus",
                    "result": "passed" if status == "complete" and not has_errors else "failed",
                    "validated_height": row.get("height"),
                    "failure": "; ".join(text(error) for error in errors) if has_errors else "",
                    "raw": row,
                }
            )
        return out
    return [
        {
            "fixture_id": payload.get("category") or payload.get("artifact_kind") or "artifact",
            "category": payload.get("category") or payload.get("artifact_kind") or "artifact",
            "result": result_from_payload(payload),
            "validated_height": payload.get("validated_height"),
            "validated_hash": payload.get("validated_hash"),
            "chainstate_backend": payload.get("chainstate_backend") or payload.get("storage_backend"),
            "duration_ms": payload.get("elapsed_ms"),
            "failure": payload.get("last_error") or payload.get("failure") or "",
            "raw": payload,
        }
    ]


def import_json_artifact(connection: sqlite3.Connection, root: Path, path: Path, payload: dict[str, Any]) -> None:
    artifact = make_artifact(path, root, payload)
    existing = connection.execute(
        """
        SELECT artifact_id, source_sha256
        FROM artifacts
        WHERE path = ?
        """,
        (artifact.rel_path,),
    ).fetchone()
    if existing:
        artifact = replace(artifact, artifact_id=text(existing[0]))
        if text(existing[1]) == artifact.source_sha256:
            return
    elif artifact_exists(connection, artifact.artifact_id):
        return
    upsert_artifact(connection, artifact)
    implementation, language, role = implementation_for_node(artifact.node_id, payload)
    upsert_node(
        connection,
        artifact.node_id,
        implementation,
        language,
        role if role != "unknown" else "conformance",
        rel(root, root),
        text(payload.get("datadir")),
        f"imported from {artifact.kind}",
        artifact.artifact_id,
    )
    import_status_snapshot(connection, artifact, payload)
    import_conformance_rows(connection, artifact, payload)
    import_benchmark_rows(connection, artifact, payload)
    import_test_rows(connection, artifact, payload)
    import_blocker_from_payload(connection, artifact, payload)


def import_status_snapshot(connection: sqlite3.Connection, artifact: Artifact, payload: dict[str, Any]) -> None:
    if not any(key in payload for key in ("validated_height", "header_height", "sync_status", "chainstate_backend")):
        return
    blocker = payload.get("current_blocker")
    blocker_id = ""
    if isinstance(blocker, dict):
        blocker_id = blocker_key(artifact.rel_path, blocker)
    snapshot_id = stable_id("status", artifact.artifact_id)
    connection.execute(
        """
        INSERT INTO status_snapshots(
          snapshot_id, node_id, captured_at, chain, sync_status,
          binary_gate_status, header_height, header_hash, stored_block_height,
          stored_block_hash, validated_height, validated_hash, chainstate_backend,
          chainstate_status, chainstate_generation_id, chainstate_utxo_count,
          utxo_accounting_policy, block_gap_count, current_blocker_id, last_error, raw_json,
          source_artifact_id
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(snapshot_id) DO UPDATE SET
          captured_at = excluded.captured_at,
          chain = excluded.chain,
          sync_status = excluded.sync_status,
          binary_gate_status = excluded.binary_gate_status,
          header_height = excluded.header_height,
          header_hash = excluded.header_hash,
          stored_block_height = excluded.stored_block_height,
          stored_block_hash = excluded.stored_block_hash,
          validated_height = excluded.validated_height,
          validated_hash = excluded.validated_hash,
          chainstate_backend = excluded.chainstate_backend,
          chainstate_status = excluded.chainstate_status,
          chainstate_generation_id = excluded.chainstate_generation_id,
          chainstate_utxo_count = excluded.chainstate_utxo_count,
          utxo_accounting_policy = excluded.utxo_accounting_policy,
          block_gap_count = excluded.block_gap_count,
          current_blocker_id = excluded.current_blocker_id,
          last_error = excluded.last_error,
          raw_json = excluded.raw_json
        """,
        (
            snapshot_id,
            artifact.node_id,
            artifact.captured_at,
            text(payload.get("chain")),
            text(payload.get("sync_status")),
            text(payload.get("binary_gate_status"), "not_attempted"),
            integer(payload.get("header_height"), -1),
            text(payload.get("header_hash")),
            integer(payload.get("stored_block_height"), integer(payload.get("validated_height"), -1)),
            text(payload.get("stored_block_hash")),
            integer(payload.get("validated_height"), -1),
            text(payload.get("validated_hash")),
            text(payload.get("chainstate_backend") or payload.get("storage_backend")),
            text(payload.get("chainstate_status")),
            text(payload.get("chainstate_generation_id")),
            integer(first(payload, "chainstate_utxo_count", "utxo_count", default=None), None),
            text(payload.get("utxo_accounting_policy")),
            integer(payload.get("block_gap_count"), None),
            blocker_id,
            text(payload.get("last_error")),
            artifact.raw_json,
            artifact.artifact_id,
        ),
    )


LEGACY_STORAGE_FIXTURE_ALIASES = {
    "storage." + "operational" + "_db_" + "boundary": "storage.rocksdb_runtime_truth",
    "storage." + "local" + "_sql" + "ite_" + "artifact_absent": "storage.rocksdb_runtime_truth",
    "storage." + "forbidden" + "_local" + "_db_" + "artifact_absent": "storage.rocksdb_runtime_truth",
    "storage.rocksdb_" + "operational_state_boundary": "storage.rocksdb_runtime_truth",
}


def normalize_conformance_fixture_id(fixture_id: str) -> str:
    return LEGACY_STORAGE_FIXTURE_ALIASES.get(fixture_id, fixture_id)


def normalize_conformance_row(row: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(row)
    fixture = text(normalized.get("fixture_id") or normalized.get("name"))
    if fixture:
        normalized["fixture_id"] = normalize_conformance_fixture_id(fixture)
    failure = text(normalized.get("failure"))
    legacy_failure = "legacy " + "local " + "DB artifact"
    if legacy_failure in failure:
        normalized["failure"] = failure.replace(legacy_failure, "RocksDB runtime truth failure")
    if "port-local operational DB artifact" in failure:
        normalized["failure"] = failure.replace(
            "port-local operational DB artifact",
            "RocksDB runtime truth failure",
        )
    return normalized


def import_conformance_rows(connection: sqlite3.Connection, artifact: Artifact, payload: dict[str, Any]) -> None:
    if not any(key in payload for key in ("results", "fixtures", "result", "bounded_gate_status", "passed")):
        return
    category = text(payload.get("category") or payload.get("artifact_kind") or artifact.kind)
    for index, row in enumerate(result_rows(payload)):
        row = normalize_conformance_row(row)
        row_payload = row.get("raw") if isinstance(row.get("raw"), dict) else row
        fixture_id = normalize_conformance_fixture_id(text(row.get("fixture_id") or row.get("name") or category or artifact.path.stem))
        result_id = stable_id("conformance", artifact.artifact_id, index, fixture_id)
        connection.execute(
            """
            INSERT INTO conformance_results(
              result_id, node_id, fixture_id, category, result, validated_height,
              validated_hash, chainstate_backend, duration_ms, failure, raw_json,
              captured_at, source_artifact_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(result_id) DO UPDATE SET
              fixture_id = excluded.fixture_id,
              category = excluded.category,
              result = excluded.result,
              validated_height = excluded.validated_height,
              validated_hash = excluded.validated_hash,
              chainstate_backend = excluded.chainstate_backend,
              duration_ms = excluded.duration_ms,
              failure = excluded.failure,
              raw_json = excluded.raw_json,
              captured_at = excluded.captured_at
            """,
            (
                result_id,
                artifact.node_id,
                fixture_id,
                text(row.get("category"), category),
                text(row.get("result"), result_from_payload(payload)),
                integer(row.get("validated_height"), integer(payload.get("validated_height"), None)),
                text(row.get("validated_hash") or payload.get("validated_hash")),
                text(row.get("chainstate_backend") or payload.get("chainstate_backend") or payload.get("storage_backend")),
                integer(row.get("duration_ms") or row.get("elapsed_ms"), None),
                text(row.get("failure")),
                pretty_json(row_payload),
                artifact.captured_at,
                artifact.artifact_id,
            ),
        )


def timing_stages(payload: dict[str, Any]) -> dict[str, int]:
    stages: dict[str, int] = {}

    def record(stage: str, elapsed: Any) -> None:
        parsed = integer(elapsed, None)
        if parsed is None:
            return
        name = text(stage)
        current = stages.get(name)
        if current is None or (current <= 0 and parsed > 0):
            stages[name] = parsed

    sync_timing = payload.get("sync_timing")
    if isinstance(sync_timing, dict):
        unit = text(sync_timing.get("Unit")).lower()
        for stage, values in (sync_timing.get("Stages") or {}).items():
            if not isinstance(values, dict):
                continue
            total = integer(values.get("TotalMicros") if "micro" in unit else values.get("TotalMillis"), None)
            if total is not None:
                record(stage, max(0, round(total / 1000)) if "micro" in unit else total)
    for container_key in ("stage_totals_ms", "timings_ms"):
        values = payload.get(container_key)
        if isinstance(values, dict):
            for stage, elapsed in values.items():
                record(stage, elapsed)
    pipeline = payload.get("pipeline_timing_summary")
    if isinstance(pipeline, dict):
        nested_stages = pipeline.get("stage_totals_ms")
        if isinstance(nested_stages, dict):
            for stage, elapsed in nested_stages.items():
                record(stage, elapsed)
        for stage, elapsed in pipeline.items():
            if stage == "stage_totals_ms" or isinstance(elapsed, (dict, list)):
                continue
            record(stage, elapsed)
    connect = payload.get("connect_summary")
    timing_summary = connect.get("timing_summary") if isinstance(connect, dict) else None
    nested_stages = timing_summary.get("stage_totals_ms") if isinstance(timing_summary, dict) else None
    if isinstance(nested_stages, dict):
        for stage, elapsed in nested_stages.items():
            record(stage, elapsed)
    timing_summary = payload.get("timing_summary")
    nested_stages = timing_summary.get("stage_totals_ms") if isinstance(timing_summary, dict) else None
    if isinstance(nested_stages, dict):
        for stage, elapsed in nested_stages.items():
            record(stage, elapsed)
    if "utxo_load" not in stages and "prevout_batch_load" in stages:
        stages["utxo_load"] = stages["prevout_batch_load"]
    if "block_connect_store_commit" not in stages and "connect_total" in stages:
        stages["block_connect_store_commit"] = stages["connect_total"]
    return stages


def timing_total_ms(payload: dict[str, Any], stages: dict[str, int]) -> int | None:
    candidates: list[Any] = [
        payload.get("elapsed_ms"),
        payload.get("duration_ms"),
        payload.get("total_ms"),
        payload.get("wall_time_ms"),
    ]
    timing_summary = payload.get("timing_summary")
    if isinstance(timing_summary, dict):
        candidates.extend(
            [
                timing_summary.get("total_ms"),
                timing_summary.get("total_wall"),
                timing_summary.get("wall_time_ms"),
            ]
        )
    pipeline = payload.get("pipeline_timing_summary")
    if isinstance(pipeline, dict):
        candidates.extend(
            [
                pipeline.get("total_ms"),
                pipeline.get("total_wall"),
                pipeline.get("wall_time_ms"),
            ]
        )
    connect = payload.get("connect_summary")
    connect_timing = connect.get("timing_summary") if isinstance(connect, dict) else None
    if isinstance(connect_timing, dict):
        candidates.extend(
            [
                connect_timing.get("total_ms"),
                connect_timing.get("total_wall"),
                connect_timing.get("wall_time_ms"),
            ]
        )
    for candidate in candidates:
        parsed = integer(candidate, None)
        if parsed is not None and parsed > 0:
            return parsed
    if stages.get("block_connect_store_commit", 0) > 0:
        return stages["block_connect_store_commit"]
    if stages.get("connect_total", 0) > 0:
        return stages["connect_total"]
    return None


def canonical_timing_summary(payload: dict[str, Any], stages: dict[str, int]) -> dict[str, Any]:
    summary: dict[str, Any] = {"stage_totals_ms": dict(sorted(stages.items()))}
    total = timing_total_ms(payload, stages)
    if total is not None:
        summary["total_ms"] = total
    pipeline = payload.get("pipeline_timing_summary")
    timing_summary = payload.get("timing_summary")
    connect = payload.get("connect_summary")
    connect_timing = connect.get("timing_summary") if isinstance(connect, dict) else None
    for source in (timing_summary, pipeline, connect_timing):
        if not isinstance(source, dict):
            continue
        slow_blocks = source.get("slow_blocks")
        if isinstance(slow_blocks, list):
            summary["slow_blocks"] = slow_blocks
            break
    return summary


def benchmark_artifact_quality(path: Path, payload: dict[str, Any]) -> str:
    return _validator.artifact_quality(payload, path)


def benchmark_telemetry_quality(payload: dict[str, Any]) -> str:
    gate_id = _validator.gate_for_payload(payload)
    spec = _validator.GATES.get(gate_id, {})
    if not spec.get("long_run"):
        return "clean"
    summary = payload.get("telemetry_summary")
    if isinstance(summary, dict):
        quality = text(summary.get("telemetry_quality") or summary.get("quality")).strip()
        if quality in {"clean", "sparse", "invalid", "missing"}:
            return quality
        return "invalid"
    if payload.get("telemetry_schema") == "benchmark.telemetry_tick.v1":
        return "sparse"
    return "missing"


def import_benchmark_rows(connection: sqlite3.Connection, artifact: Artifact, payload: dict[str, Any]) -> None:
    stages = timing_stages(payload)
    canonical_timing = canonical_timing_summary(payload, stages)
    benchmark_like = any(
        key in payload
        for key in (
            "benchmark_gate",
            "benchmark_kind",
            "benchmark_lane",
            "benchmark_contract_version",
            "target_height",
            "target_label",
        )
    )
    if not benchmark_like:
        return
    reported_benchmark_kind = text(payload.get("benchmark_kind")).strip()
    reported_benchmark_lane = text(payload.get("benchmark_lane")).strip()
    reported_benchmark_gate = text(payload.get("benchmark_gate")).strip()
    benchmark_kind = benchmark_kind_for_payload(payload)
    target_height = integer(payload.get("target_height"), None)
    target_label = target_label_for_payload(payload)
    validated_height = integer(payload.get("validated_height") or payload.get("header_height"), None)
    header_target_height = integer(first(payload, "header_target_height", "header_height", default=None), None)
    peer_mode = text(payload.get("peer_mode")).strip()
    byte_source = text(payload.get("byte_source")).strip()
    if not byte_source:
        if peer_mode == "local_reference_rpc":
            byte_source = "local_reference_rpc"
        elif peer_mode == "local_reference":
            byte_source = "local_reference_p2p"
    proof_mode = text(payload.get("proof_mode")).strip()
    if not proof_mode:
        if peer_mode == "local_reference_rpc":
            proof_mode = "rpc_replay"
        elif peer_mode == "local_reference":
            proof_mode = "p2p_sync"
    benchmark_lane = canonical_benchmark_label(reported_benchmark_lane)
    if not benchmark_lane and target_label:
        if peer_mode == "local_reference_rpc" or byte_source == "local_reference_rpc":
            benchmark_lane = canonical_benchmark_label(f"supporting_{target_label}_rpc_replay")
        elif peer_mode == "local_reference":
            benchmark_lane = canonical_benchmark_label(f"supporting_{target_label}_p2p")
    artifact_quality = benchmark_artifact_quality(artifact.path, payload)
    telemetry_quality = benchmark_telemetry_quality(payload)
    benchmark_id = stable_id("benchmark", artifact.artifact_id)
    connection.execute(
        """
        INSERT INTO benchmarks(
          benchmark_id, node_id, benchmark_name, chain, height, block_hash,
          backend, settings_json, timings_json, result_json, captured_at,
          source_artifact_id
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(benchmark_id) DO UPDATE SET
          benchmark_name = excluded.benchmark_name,
          chain = excluded.chain,
          height = excluded.height,
          block_hash = excluded.block_hash,
          backend = excluded.backend,
          settings_json = excluded.settings_json,
          timings_json = excluded.timings_json,
          result_json = excluded.result_json,
          captured_at = excluded.captured_at
        """,
            (
            benchmark_id,
            artifact.node_id,
            benchmark_kind or text(payload.get("category") or payload.get("artifact_kind") or artifact.path.stem),
            text(payload.get("chain")),
            target_height if target_height is not None else validated_height,
            text(payload.get("validated_hash")),
            text(payload.get("chainstate_backend") or payload.get("storage_backend")),
            pretty_json(
                {
                    **{
                        key: payload[key]
                        for key in (
                            "benchmark_contract_version",
                            "runtime_surface",
                            "peer_mode",
                            "peer",
                            "byte_source",
                            "proof_mode",
                            "utxo_accounting_policy",
                            "prefetch_depth",
                            "script_threads",
                            "script_runner_mode",
                            "crypto_context_mode",
                            "native_crypto_backend",
                            "native_crypto_available",
                            "taproot_tweak_backend",
                            "rocksdb_wal_disabled",
                            "resume_supported",
                            "fresh_state",
                            "docker_volume",
                        )
                        if key in payload
                    },
                    **({"benchmark_kind": benchmark_kind} if benchmark_kind else {}),
                    **({"benchmark_lane": benchmark_lane} if benchmark_lane else {}),
                    **({"benchmark_gate": canonical_benchmark_label(reported_benchmark_gate)} if reported_benchmark_gate else {}),
                    "artifact_quality": artifact_quality,
                    "telemetry_quality": telemetry_quality,
                    **({"target_height": target_height} if target_height is not None else {}),
                    **({"target_label": target_label} if target_label else {}),
                    **({"header_target_height": header_target_height} if header_target_height is not None else {}),
                    **({"byte_source": byte_source} if byte_source else {}),
                    **({"proof_mode": proof_mode} if proof_mode else {}),
                    **({"binary_gate_status": text(payload.get("binary_gate_status"))} if "binary_gate_status" in payload else {}),
                }
            ),
            pretty_json(
                {
                    **({"canonical_timing_summary": canonical_timing} if canonical_timing else {}),
                    **{
                        key: payload[key]
                        for key in (
                            "sync_timing",
                            "stage_totals_ms",
                            "pipeline_timing_summary",
                            "timing_summary",
                            "timings_ms",
                            "connect_summary",
                        )
                        if key in payload
                    },
                }
            ),
            pretty_json(
                {
                    **{
                        key: payload[key]
                        for key in (
                            "result",
                            "bounded_gate_status",
                            "binary_gate_status",
                            "long_sync_status",
                            "elapsed_ms",
                            "header_height",
                            "stored_block_height",
                            "blocks_fetched",
                            "blocks_connected",
                            "chainstate_utxo_count",
                            "current_blocker",
                            "failures",
                        )
                        if key in payload
                    },
                    **({"validated_height": validated_height} if validated_height is not None else {}),
                    **({"target_height": target_height} if target_height is not None else {}),
                    **({"target_label": target_label} if target_label else {}),
                    **({"elapsed_ms": canonical_timing["total_ms"]} if "total_ms" in canonical_timing else {}),
                    "artifact_quality": artifact_quality,
                    "telemetry_quality": telemetry_quality,
                }
            ),
            artifact.captured_at,
            artifact.artifact_id,
        ),
    )
    for stage, elapsed_ms in sorted(stages.items()):
        sample_id = stable_id("timing", artifact.artifact_id, stage)
        connection.execute(
            """
            INSERT INTO timing_samples(
              sample_id, node_id, chain, height, block_hash, stage, elapsed_ms,
              captured_at, source_artifact_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(sample_id) DO UPDATE SET
              chain = excluded.chain,
              height = excluded.height,
              block_hash = excluded.block_hash,
              elapsed_ms = excluded.elapsed_ms,
              captured_at = excluded.captured_at
            """,
            (
                sample_id,
                artifact.node_id,
                text(payload.get("chain")),
                integer(payload.get("validated_height") or payload.get("header_height"), None),
                text(payload.get("validated_hash")),
                stage,
                elapsed_ms,
                artifact.captured_at,
                artifact.artifact_id,
            ),
        )


def blocker_key(source: str, blocker: dict[str, Any]) -> str:
    return stable_id(
        "blocker",
        source,
        blocker.get("height", ""),
        blocker.get("txid", ""),
        blocker.get("input_index", ""),
        blocker.get("missing_rule", ""),
        )


def string_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [text(item).strip() for item in value if text(item).strip()]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []


def validate_provenance(values: list[str], context: str) -> None:
    if not values:
        raise SystemExit(f"{context}: provenance must name at least one source class")
    unknown = sorted(set(values) - TEST_CAPABILITY_PROVENANCE)
    if unknown:
        raise SystemExit(f"{context}: unknown provenance values: {', '.join(unknown)}")


def validate_capability_suite(suite: dict[str, Any], context: str) -> None:
    suite_id = text(suite.get("suite_id")).strip()
    suite_hash = text(suite.get("suite_hash")).strip()
    provenance = string_list(suite.get("provenance"))
    if not suite_id:
        raise SystemExit(f"{context}: suite_id is required")
    if not suite_hash:
        raise SystemExit(f"{context}: suite_hash is required")
    validate_provenance(provenance, context)
    if not text(suite.get("does_not_prove")).strip():
        raise SystemExit(f"{context}: does_not_prove is required")


def validate_capability_contract(claim: dict[str, Any], context: str) -> None:
    contract_id = text(claim.get("contract_id")).strip()
    capability = text(claim.get("capability")).strip()
    status = text(claim.get("status")).strip()
    provenance = string_list(claim.get("provenance"))
    suite_id = text(claim.get("suite_id")).strip()
    suite_hash = text(claim.get("suite_hash")).strip()
    suite_version = text(claim.get("suite_version")).strip()
    has_denominator = claim.get("case_passed") is not None or claim.get("case_total") is not None

    if not contract_id:
        raise SystemExit(f"{context}: contract_id is required")
    if not capability:
        raise SystemExit(f"{context}: capability is required")
    if status not in TEST_CAPABILITY_STATUSES:
        raise SystemExit(f"{context}: status must be one of {sorted(TEST_CAPABILITY_STATUSES)}")
    validate_provenance(provenance, context)
    if has_denominator and (not suite_id or not suite_version or not suite_hash):
        raise SystemExit(f"{context}: case counts require suite_id, suite_version, and suite_hash")
    if has_denominator and integer(claim.get("case_total"), -1) < 0:
        raise SystemExit(f"{context}: case_total must be nonnegative when present")


def node_id_for_contract_port(connection: sqlite3.Connection, port: str, fallback: str) -> str:
    row = connection.execute("SELECT node_id FROM docker_contracts WHERE port = ?", (port,)).fetchone()
    if row:
        return text(row[0])
    return fallback


def import_test_capability_contracts(connection: sqlite3.Connection, artifact: Artifact, payload: dict[str, Any]) -> None:
    suites = payload.get("suites")
    if isinstance(suites, list):
        for index, suite in enumerate(suites):
            if not isinstance(suite, dict):
                continue
            context = f"{artifact.rel_path}:suites[{index}]"
            validate_capability_suite(suite, context)
            provenance = string_list(suite.get("provenance"))
            connection.execute(
                """
                INSERT INTO test_capability_suites(
                  suite_id, suite_version, suite_hash, case_total, provenance_json,
                  does_not_prove, source_artifact_id
                ) VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(suite_id, suite_version, suite_hash) DO UPDATE SET
                  case_total = excluded.case_total,
                  provenance_json = excluded.provenance_json,
                  does_not_prove = excluded.does_not_prove,
                  source_artifact_id = excluded.source_artifact_id
                """,
                (
                    text(suite.get("suite_id")).strip(),
                    text(suite.get("suite_version")).strip(),
                    text(suite.get("suite_hash")).strip(),
                    integer(suite.get("case_total"), None),
                    stable_json(provenance),
                    text(suite.get("does_not_prove")).strip(),
                    artifact.artifact_id,
                ),
            )

    claims = payload.get("contracts")
    if not isinstance(claims, list):
        claims = payload.get("claims")
    if not isinstance(claims, list):
        return

    default_port = port_for_payload(artifact.path, payload)
    for index, claim in enumerate(claims):
        if not isinstance(claim, dict):
            continue
        context = f"{artifact.rel_path}:contracts[{index}]"
        validate_capability_contract(claim, context)
        port = text(claim.get("port") or default_port).strip().lower()
        if port not in PORTS or port == "reference":
            raise SystemExit(f"{context}: valid non-reference port is required")
        node_id = text(claim.get("node_id")).strip() or node_id_for_contract_port(connection, port, artifact.node_id)
        provenance = string_list(claim.get("provenance"))
        blocking_for = string_list(claim.get("blocking_for"))
        contract_id = text(claim.get("contract_id")).strip()
        capability = text(claim.get("capability")).strip()
        row_id = stable_id("test_capability_contract", artifact.artifact_id, index, port, contract_id, capability)
        connection.execute(
            """
            INSERT INTO test_capability_contracts(
              contract_row_id, port, node_id, contract_id, capability, status,
              scope, backend, evidence_kind, evidence_path, command_key,
              suite_id, suite_version, suite_hash, case_passed, case_total,
              provenance_json, does_not_prove, blocking_for_json, notes,
              source_artifact_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(contract_row_id) DO UPDATE SET
              port = excluded.port,
              node_id = excluded.node_id,
              contract_id = excluded.contract_id,
              capability = excluded.capability,
              status = excluded.status,
              scope = excluded.scope,
              backend = excluded.backend,
              evidence_kind = excluded.evidence_kind,
              evidence_path = excluded.evidence_path,
              command_key = excluded.command_key,
              suite_id = excluded.suite_id,
              suite_version = excluded.suite_version,
              suite_hash = excluded.suite_hash,
              case_passed = excluded.case_passed,
              case_total = excluded.case_total,
              provenance_json = excluded.provenance_json,
              does_not_prove = excluded.does_not_prove,
              blocking_for_json = excluded.blocking_for_json,
              notes = excluded.notes,
              source_artifact_id = excluded.source_artifact_id
            """,
            (
                row_id,
                port,
                node_id,
                contract_id,
                capability,
                text(claim.get("status")).strip(),
                text(claim.get("scope")).strip(),
                text(claim.get("backend")).strip(),
                text(claim.get("evidence_kind")).strip(),
                text(claim.get("evidence_path")).strip(),
                text(claim.get("command_key")).strip(),
                text(claim.get("suite_id")).strip(),
                text(claim.get("suite_version")).strip(),
                text(claim.get("suite_hash")).strip(),
                integer(claim.get("case_passed"), None),
                integer(claim.get("case_total"), None),
                stable_json(provenance),
                text(claim.get("does_not_prove")).strip(),
                stable_json(blocking_for),
                text(claim.get("notes")).strip(),
                artifact.artifact_id,
            ),
        )


def import_test_rows(connection: sqlite3.Connection, artifact: Artifact, payload: dict[str, Any]) -> None:
    schema = text(payload.get("schema"))
    port = port_for_payload(artifact.path, payload)
    node_id = artifact.node_id
    if port == "unknown":
        mapped = connection.execute(
            "SELECT port FROM project_node_ports WHERE node_id = ?",
            (node_id,),
        ).fetchone()
        port = text(mapped[0]) if mapped else "unknown"

    if schema in {"port.test_result", "port.test_result.v1"}:
        command_key = text(payload.get("command_key") or payload.get("test_command_key") or "test_unit")
        test_run_id = stable_id("test_run", artifact.artifact_id, command_key)
        connection.execute(
            """
            INSERT INTO test_runs(
              test_run_id, port, node_id, command_key, result, exit_code,
              captured_at, duration_ms, summary_json, source_artifact_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(test_run_id) DO UPDATE SET
              port = excluded.port,
              node_id = excluded.node_id,
              command_key = excluded.command_key,
              result = excluded.result,
              exit_code = excluded.exit_code,
              captured_at = excluded.captured_at,
              duration_ms = excluded.duration_ms,
              summary_json = excluded.summary_json
            """,
            (
                test_run_id,
                port,
                node_id,
                command_key,
                text(payload.get("result")),
                integer(payload.get("exit_code"), None),
                artifact.captured_at,
                integer(payload.get("duration_ms") or payload.get("elapsed_ms"), None),
                pretty_json(
                    {
                        key: payload[key]
                        for key in (
                            "summary",
                            "passed",
                            "failed",
                            "skipped",
                            "total",
                            "tool",
                            "command",
                        )
                        if key in payload
                    }
                ),
                artifact.artifact_id,
            ),
        )
        return

    if schema in {"port.coverage_summary", "port.coverage_summary.v1"}:
        coverage_id = stable_id("coverage", artifact.artifact_id)
        command_key = text(payload.get("command_key") or "test_coverage")
        test_run_id = stable_id("test_run", artifact.artifact_id, command_key)
        metrics = payload.get("metrics") if isinstance(payload.get("metrics"), dict) else payload
        connection.execute(
            """
            INSERT INTO test_runs(
              test_run_id, port, node_id, command_key, result, exit_code,
              captured_at, duration_ms, summary_json, source_artifact_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(test_run_id) DO UPDATE SET
              port = excluded.port,
              node_id = excluded.node_id,
              command_key = excluded.command_key,
              result = excluded.result,
              exit_code = excluded.exit_code,
              captured_at = excluded.captured_at,
              duration_ms = excluded.duration_ms,
              summary_json = excluded.summary_json
            """,
            (
                test_run_id,
                port,
                node_id,
                command_key,
                text(payload.get("result")),
                integer(payload.get("exit_code"), None),
                artifact.captured_at,
                integer(payload.get("duration_ms") or payload.get("elapsed_ms"), None),
                pretty_json(
                    {
                        key: payload[key]
                        for key in (
                            "summary",
                            "tool",
                            "command",
                            "command_key",
                            "metrics",
                        )
                        if key in payload
                    }
                ),
                artifact.artifact_id,
            ),
        )
        connection.execute(
            """
            INSERT INTO coverage_summaries(
              coverage_id, port, node_id, tool, line_percent, branch_percent,
              function_percent, statement_percent, covered_lines, total_lines,
              captured_at, source_artifact_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(coverage_id) DO UPDATE SET
              port = excluded.port,
              node_id = excluded.node_id,
              tool = excluded.tool,
              line_percent = excluded.line_percent,
              branch_percent = excluded.branch_percent,
              function_percent = excluded.function_percent,
              statement_percent = excluded.statement_percent,
              covered_lines = excluded.covered_lines,
              total_lines = excluded.total_lines,
              captured_at = excluded.captured_at
            """,
            (
                coverage_id,
                port,
                node_id,
                text(payload.get("tool")),
                metrics.get("line_percent"),
                metrics.get("branch_percent"),
                metrics.get("function_percent"),
                metrics.get("statement_percent"),
                integer(metrics.get("covered_lines"), None),
                integer(metrics.get("total_lines"), None),
                artifact.captured_at,
                artifact.artifact_id,
            ),
        )
        return

    if schema == "port.test_capability_contract.v1":
        import_test_capability_contracts(connection, artifact, payload)
        return

    if schema in {"port.domain_coverage", "port.domain_coverage.v1"}:
        claims = payload.get("domains")
        if not isinstance(claims, list):
            claims = payload.get("claims")
        if not isinstance(claims, list):
            return
        for index, claim in enumerate(claims):
            if not isinstance(claim, dict):
                continue
            domain = text(claim.get("domain")).strip()
            if not domain:
                continue
            claim_id = stable_id("test_domain_claim", artifact.artifact_id, index, port, domain)
            connection.execute(
                """
                INSERT INTO test_domain_claims(
                  claim_id, port, node_id, domain, status, evidence, notes,
                  source_artifact_id
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(claim_id) DO UPDATE SET
                  port = excluded.port,
                  node_id = excluded.node_id,
                  domain = excluded.domain,
                  status = excluded.status,
                  evidence = excluded.evidence,
                  notes = excluded.notes,
                  source_artifact_id = excluded.source_artifact_id
                """,
                (
                    claim_id,
                    port,
                    node_id,
                    domain,
                    text(claim.get("status"), "unknown"),
                    text(claim.get("evidence")),
                    text(claim.get("notes")),
                    artifact.artifact_id,
                ),
            )


def import_blocker_from_payload(connection: sqlite3.Connection, artifact: Artifact, payload: dict[str, Any]) -> None:
    blocker = payload.get("current_blocker")
    if not isinstance(blocker, dict):
        return
    if not blocker:
        return
    import_blocker_row(connection, artifact.rel_path, artifact.artifact_id, blocker, default_status="blocked")


def import_blocker_row(
    connection: sqlite3.Connection,
    source_path: str,
    artifact_id: str | None,
    row: dict[str, Any],
    default_status: str,
) -> None:
    height = integer(row.get("height"), None)
    if height is None:
        return
    blocker_id = blocker_key(source_path, row)
    connection.execute(
        """
        INSERT INTO blockers(
          blocker_id, height, block_hash, txid, input_index, spent_script_pubkey,
          failure, missing_rule, source_port, source_commit, fixture, test_name,
          status, first_seen_at, cleared_at, follower_notes, source_path,
          source_artifact_id
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(blocker_id) DO UPDATE SET
          block_hash = excluded.block_hash,
          txid = excluded.txid,
          input_index = excluded.input_index,
          spent_script_pubkey = excluded.spent_script_pubkey,
          failure = excluded.failure,
          missing_rule = excluded.missing_rule,
          source_port = excluded.source_port,
          source_commit = excluded.source_commit,
          fixture = excluded.fixture,
          test_name = excluded.test_name,
          status = excluded.status,
          first_seen_at = excluded.first_seen_at,
          cleared_at = excluded.cleared_at,
          follower_notes = excluded.follower_notes,
          source_path = excluded.source_path,
          source_artifact_id = excluded.source_artifact_id
        """,
        (
            blocker_id,
            height,
            text(row.get("block_hash")),
            text(row.get("txid")),
            integer(row.get("input_index"), None),
            text(row.get("spent_script_pubkey")),
            text(row.get("failure")),
            text(row.get("missing_rule") or row.get("template_rule") or row.get("rule")),
            text(row.get("source_port")),
            text(row.get("source_commit")),
            text(row.get("fixture") or row.get("source_fixture") or row.get("test_fixture")),
            text(row.get("test_name")),
            text(row.get("status"), default_status),
            text(row.get("first_seen_at")),
            text(row.get("cleared_at")),
            text(row.get("follower_notes")),
            source_path,
            artifact_id,
        ),
    )


def markdown_artifact(connection: sqlite3.Connection, root: Path, path: Path, kind: str) -> str:
    source_sha = file_sha256(path)
    rel_path = rel(path, root)
    existing = connection.execute(
        """
        SELECT artifact_id
        FROM artifacts
        WHERE path = ?
        """,
        (rel_path,),
    ).fetchone()
    if existing:
        artifact_id = text(existing[0])
        connection.execute(
            """
            UPDATE artifacts
            SET source_sha256 = ?,
                kind = CASE WHEN kind = '' THEN ? ELSE kind END
            WHERE artifact_id = ?
              AND (
                source_sha256 <> ?
                OR (kind = '' AND ? <> '')
              )
            """,
            (source_sha, kind, artifact_id, source_sha, kind),
        )
        return artifact_id
    artifact_id = stable_id(rel_path, source_sha)
    if artifact_exists(connection, artifact_id):
        return artifact_id
    connection.execute(
        """
        INSERT INTO artifacts(artifact_id, path, kind, source_sha256, summary_json)
        VALUES(?, ?, ?, ?, '{}')
        ON CONFLICT(artifact_id) DO UPDATE SET
          path = excluded.path,
          kind = excluded.kind,
          source_sha256 = excluded.source_sha256
        """,
        (artifact_id, rel_path, kind, source_sha),
    )
    return artifact_id


def parse_key_value_blocks(text_body: str) -> Iterable[dict[str, Any]]:
    current: dict[str, Any] = {}
    in_block = False
    heading_status = ""
    for line in text_body.splitlines():
        if line.startswith("## "):
            heading_status = "cleared" if "cleared" in line.lower() else ""
        if line.strip() == "```text":
            current = {}
            in_block = True
            continue
        if in_block and line.strip() == "```":
            in_block = False
            if current and "height" in current and "missing_rule" in current:
                if heading_status and "status" not in current:
                    current["status"] = heading_status
                yield current
            current = {}
            continue
        if not in_block:
            continue
        match = re.match(r"^([A-Za-z0-9_]+):\s*(.*)$", line)
        if match:
            key, value = match.groups()
            if value:
                current[key] = value


def parse_markdown_table(text_body: str) -> Iterable[dict[str, Any]]:
    for line in text_body.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|") or stripped.startswith("|---") or stripped.startswith("| Height"):
            continue
        reader = csv.reader(StringIO(stripped.strip("|")), delimiter="|")
        cells = [cell.strip().strip("`") for cell in next(reader)]
        if len(cells) < 9:
            continue
        if not re.fullmatch(r"[0-9,]+", cells[0]):
            continue
        yield {
            "height": cells[0].replace(",", ""),
            "missing_rule": cells[1],
            "block_hash": cells[2],
            "txid": cells[3],
            "input_index": cells[4],
            "spent_script_pubkey": cells[5],
            "failure": cells[6],
            "source_port": "catalog",
            "status": "cleared" if "cleared" in " ".join(cells[7:9]).lower() else "unknown",
            "follower_notes": cells[9] if len(cells) > 9 else "",
        }


def import_blocker_ledger(connection: sqlite3.Connection, root: Path, path: Path) -> int:
    source_sha = file_sha256(path)
    rel_path = rel(path, root)
    artifact_id = stable_id(rel_path, source_sha)
    if artifact_exists(connection, artifact_id):
        return 0
    artifact_id = markdown_artifact(connection, root, path, "blocker_ledger")
    text_body = path.read_text(encoding="utf-8")
    count = 0
    for row in parse_markdown_table(text_body):
        import_blocker_row(connection, rel(path, root), artifact_id, row, default_status="unknown")
        count += 1
    for row in parse_key_value_blocks(text_body):
        import_blocker_row(connection, rel(path, root), artifact_id, row, default_status=text(row.get("status"), "open"))
        count += 1
    return count


def import_decisions(connection: sqlite3.Connection, root: Path) -> None:
    for row in DECISIONS:
        source_artifact_id = None
        source_path = root / row["source_path"]
        if source_path.exists():
            source_artifact_id = markdown_artifact(connection, root, source_path, "decision_source")
        connection.execute(
            """
            INSERT OR IGNORE INTO decisions(
              decision_id, title, status, context, decision, consequences,
              source_path, source_artifact_id, decided_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                row["decision_id"],
                row["title"],
                row["status"],
                row["context"],
                row["decision"],
                row["consequences"],
                row["source_path"],
                source_artifact_id,
                row["decided_at"],
            ),
        )


def default_status_jsons(root: Path) -> list[Path]:
    candidates = [
        root / "Nodes/Python/snapshots/status.json",
        root / "Nodes/CSharp/.docker-csharp-proof-status.json",
    ]
    return [path for path in candidates if path.exists()]


def default_blocker_ledgers(root: Path) -> list[Path]:
    paths = [
        root / "Docs/consensus-blockers-testnet4.md",
        root / "Nodes/Shared/BLOCKER_LEDGER.md",
    ]
    paths.extend(sorted((root / "Nodes").glob("*/docs/BLOCKER_LEDGER.md")))
    return [path for path in paths if path.exists()]


def expect_validation_failure(fn: Any, needle: str) -> None:
    try:
        fn()
    except SystemExit as exc:
        message = str(exc)
        if needle not in message:
            raise AssertionError(f"expected {needle!r} in {message!r}") from exc
        return
    raise AssertionError(f"expected validation failure containing {needle!r}")


def self_test() -> int:
    valid_suite = {
        "suite_id": "rb.shared_script_corpus",
        "suite_version": "2026-06-07",
        "suite_hash": "9f338ff205087144c38679ebd67bde5bf372bea3082922bde5f28013e4727d06",
        "case_total": 45,
        "provenance": ["rb_live_chain_regression", "rb_synthetic_edge_case"],
        "does_not_prove": "Project-local script fixture corpus; not community-complete Bitcoin script coverage.",
    }
    validate_capability_suite(valid_suite, "self-test:suite")
    for extra_suite in (
        {
            "suite_id": "bitcoin.bip340_schnorr_vectors",
            "suite_version": "2026-06-07",
            "suite_hash": "01c8cabba63b4c9b2f44c975902990086a4fe56eee9d265b187d1e2c1d98ccfb",
            "case_total": 19,
            "provenance": ["bip_standard_vector"],
            "does_not_prove": "BIP340 verification vectors do not prove ECDSA or block-connect usage.",
        },
        {
            "suite_id": "rb.crypto_backend_equivalence_v1",
            "suite_version": "2026-06-07",
            "suite_hash": "ef27cd3e8c2f7f83923d88aaee4d50ef9130fe42c5ccc14713478772d06209af",
            "case_total": 27,
            "provenance": ["bip_standard_vector", "proof_derived"],
            "does_not_prove": "Backend equivalence vectors do not prove every libsecp256k1 internal test.",
        },
        {
            "suite_id": "rb.block_connect_backend_probe_v1",
            "suite_version": "2026-06-07",
            "suite_hash": "b746732dfd78cd1a2b2fb00513dc01c77edc8421df745109f9a803193e4c697f",
            "case_total": 2,
            "provenance": ["rb_live_chain_regression", "proof_derived"],
            "does_not_prove": "Bounded backend probe does not prove long-sync safety.",
        },
    ):
        validate_capability_suite(extra_suite, f"self-test:suite:{extra_suite['suite_id']}")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_root = Path(tmp)
        port_root = tmp_root / "Nodes/Go"
        port_root.mkdir(parents=True)
        (port_root / "Makefile").write_text(
            "test:\n\ttrue\n"
            "test-crypto-vectors:\n\ttrue\n"
            "test-block-connect-backend:\n\ttrue\n",
            encoding="utf-8",
        )
        discovered = discover_test_commands(tmp_root, "go", "Nodes/Go")
        assert discovered["test_crypto_vectors"]["supported"] == 1
        assert discovered["test_crypto_vectors"]["command"] == "cd Nodes/Go && make test-crypto-vectors"
        assert discovered["test_block_connect_backend"]["supported"] == 1
        assert discovered["test_block_connect_backend"]["command"] == "cd Nodes/Go && make test-block-connect-backend"

    valid_contract = {
        "port": "go",
        "contract_id": "shared_script_corpus",
        "capability": "shared_script_corpus",
        "status": "pass",
        "suite_id": "rb.shared_script_corpus",
        "suite_version": "2026-06-07",
        "suite_hash": "9f338ff205087144c38679ebd67bde5bf372bea3082922bde5f28013e4727d06",
        "case_passed": 45,
        "case_total": 45,
        "provenance": ["rb_live_chain_regression"],
        "does_not_prove": "Project-local script fixture corpus; not community-complete Bitcoin script coverage.",
    }
    validate_capability_contract(valid_contract, "self-test:contract")

    naked_denominator = dict(valid_contract)
    naked_denominator.pop("suite_id")
    expect_validation_failure(
        lambda: validate_capability_contract(naked_denominator, "self-test:naked"),
        "case counts require suite_id",
    )

    unknown_provenance = dict(valid_contract)
    unknown_provenance["provenance"] = ["project_vibes"]
    expect_validation_failure(
        lambda: validate_capability_contract(unknown_provenance, "self-test:unknown-provenance"),
        "unknown provenance",
    )

    with sqlite3.connect(":memory:") as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        init_db(connection, ROOT / "Project/schema.sql")
        artifact = Artifact(
            artifact_id="self-test-artifact",
            path=Path("Nodes/Shared/testing/results/self_test.json"),
            rel_path="Nodes/Shared/testing/results/self_test.json",
            kind="port.test_capability_contract.v1",
            node_id="go",
            source_sha256="",
            captured_at="2026-06-07T00:00:00Z",
            summary={},
            raw_json="{}",
        )
        connection.execute(
            """
            INSERT INTO artifacts(artifact_id, path, kind, node_id, source_sha256, captured_at, summary_json, raw_json)
            VALUES(?, ?, ?, ?, '', '', '{}', '{}')
            """,
            (artifact.artifact_id, artifact.rel_path, artifact.kind, artifact.node_id),
        )
        connection.execute(
            "INSERT INTO nodes(node_id, implementation, language, role, repo_path, default_datadir) VALUES('go', 'GoNode', 'Go', 'follower', 'Nodes/Go', './data-go')"
        )
        connection.execute(
            "INSERT INTO docker_contracts(port, node_id, status, source_artifact_id) VALUES('go', 'go', 'present', ?)",
            (artifact.artifact_id,),
        )
        import_test_rows(
            connection,
            artifact,
            {
                "schema": "port.test_capability_contract.v1",
                "suites": [valid_suite],
                "contracts": [valid_contract],
            },
        )
        assert connection.execute("SELECT count(*) FROM test_capability_suites").fetchone()[0] == 1
        assert connection.execute("SELECT count(*) FROM test_capability_contracts").fetchone()[0] == 1

        import_test_rows(
            connection,
            artifact,
            {
                "schema": "port.domain_coverage",
                "port": "go",
                "claims": [{"domain": "script_verification", "status": "covered", "evidence": "legacy"}],
            },
        )
        assert connection.execute("SELECT count(*) FROM test_domain_claims").fetchone()[0] == 1

    print("project_import self-test passed")
    return 0


def import_all(args: argparse.Namespace) -> dict[str, int]:
    if not args.skip_sqlite_utils_check and shutil.which("sqlite-utils") is None:
        raise SystemExit("sqlite-utils CLI is required; install it or pass --skip-sqlite-utils-check")
    root = repo_root()
    db_path = root / args.db
    if args.rebuild and db_path.exists():
        db_path.unlink()
    initialize_schema = not db_path.exists()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    counts = {
        "docker_manifests": 0,
        "result_json": 0,
        "status_json": 0,
        "blocker_ledgers": 0,
        "blocker_rows": 0,
        "decisions": len(DECISIONS),
        "benchmark_gates": len(BENCHMARK_GATES),
        "port_lifecycle": len(PORT_LIFECYCLE),
        "current_evidence": 0,
        "consensus_rules": 0,
        "port_commands": 0,
        "test_commands": 0,
        "testing_json": 0,
    }
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        if initialize_schema:
            init_db(connection, root / "Project/schema.sql")
        connection.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('schema', 'mission-control-baseline')")
        connection.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('sqlite_utils_cli', 'required')")
        import_benchmark_gates(connection)
        import_port_lifecycle(connection)
        current_evidence_paths = import_current_evidence_index(
            connection,
            root,
            root / args.current_evidence,
            args.tracked_only,
        )
        counts["current_evidence"] = len(current_evidence_paths)
        rules_path = root / "Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json"
        if rules_path.exists():
            counts["consensus_rules"] += import_consensus_rule_ledger(connection, root, rules_path)

        docker_dir = root / args.docker_dir
        for path in iter_default_json_files(root, docker_dir, args.tracked_only):
            counts["port_commands"] += import_docker_manifest(connection, root, path, read_json(path))
            counts["docker_manifests"] += 1
        counts["test_commands"] = seed_test_commands(connection, root)

        results_dir = root / args.results_dir
        result_paths = (
            iter_default_json_files(root, results_dir, args.tracked_only)
            if args.include_history
            else current_evidence_paths
        )
        for path in result_paths:
            import_json_artifact(connection, root, path, read_json(path))
            counts["result_json"] += 1

        testing_results_dir = root / args.testing_results_dir
        if testing_results_dir.exists():
            for path in iter_default_json_files(root, testing_results_dir, args.tracked_only):
                import_json_artifact(connection, root, path, read_json(path))
                counts["testing_json"] += 1

        default_status_paths = default_status_jsons(root)
        if args.tracked_only:
            tracked_status_paths = tracked_paths(root, "Nodes/*/docs/status.json")
            default_status_paths = [path for path in default_status_paths if path in tracked_status_paths]
        for status_path in [*(root / path for path in args.status_json), *default_status_paths]:
            if status_path.exists():
                import_json_artifact(connection, root, status_path, read_json(status_path))
                counts["status_json"] += 1

        default_ledger_paths = default_blocker_ledgers(root)
        if args.tracked_only:
            tracked_ledger_paths = tracked_paths(root, "Docs/*.md") | tracked_paths(root, "Nodes/Shared/*.md") | tracked_paths(root, "Nodes/*/docs/BLOCKER_LEDGER.md")
            default_ledger_paths = [path for path in default_ledger_paths if path in tracked_ledger_paths]
        ledgers = [*(root / path for path in args.blocker_ledger), *default_ledger_paths]
        seen_ledgers: set[Path] = set()
        for path in ledgers:
            if not path.exists() or path.resolve() in seen_ledgers:
                continue
            seen_ledgers.add(path.resolve())
            counts["blocker_rows"] += import_blocker_ledger(connection, root, path)
            counts["blocker_ledgers"] += 1

        import_decisions(connection, root)
    return counts


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    counts = import_all(args)
    print("project_import " + " ".join(f"{key}={value}" for key, value in sorted(counts.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
