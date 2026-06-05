#!/usr/bin/env python3
"""Import canonical RB evidence into Project/project.db.

This is Project mission-control import tooling. It writes only the Project
SQLite database; it never opens port-local operational datadirs.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
import sqlite3
import sys
from dataclasses import dataclass, replace
from io import StringIO
from pathlib import Path
from typing import Any, Iterable


PORTS: dict[str, tuple[str, str, str]] = {
    "csharp": ("CSharpNode", "C#", "follower"),
    "cpp": ("CppNode", "C++", "follower"),
    "elixir": ("ElixirNode", "Elixir", "follower"),
    "go": ("GoNode", "Go", "follower"),
    "java": ("JavaNode", "Java", "lead"),
    "python": ("PythonNode", "Python", "scout"),
    "reference": ("BitcoinCoreReference", "C++", "reference"),
    "rust": ("RustNode", "Rust", "follower"),
    "typescript": ("TypeScriptNode", "TypeScript", "follower"),
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
    ("python", "python"),
    ("pybitnode", "python"),
    ("reference", "reference"),
    ("bitcoin", "reference"),
    ("rust", "rust"),
    ("rsbitnode", "rust"),
    ("typescript", "typescript"),
    ("tsbitnode", "typescript"),
)

DECISIONS: tuple[dict[str, str], ...] = (
    {
        "decision_id": "project-sqlite-mission-control",
        "title": "Project SQLite is mission control",
        "status": "accepted",
        "context": "SQLite was overcorrected from forbidden port-local operational state into forbidden coordination state.",
        "decision": "Project/project.db is a tracked mission-control database for observations, indexes, reports, and decisions.",
        "consequences": "Ports may export observations into Project, but may not read Project SQLite for operational node truth.",
        "source_path": "Project/README.md",
        "decided_at": "2026-06-04",
    },
    {
        "decision_id": "port-operational-sqlite-forbidden",
        "title": "Port-local operational SQLite is not Core/native truth",
        "status": "accepted",
        "context": "Follower ports migrated operational state to native stores such as RocksDB.",
        "decision": "Native/Core mode must not create, read, or require SQLite for headers, block index, sync state, validated tip, UTXO, undo, blockers, or status truth.",
        "consequences": "Legacy SQLite surfaces remain historical or compatibility-only and cannot support Core/native compliance claims.",
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
        "gate_id": "supporting_5k",
        "target_height": 5000,
        "target_label": "5k",
        "benchmark_kind": "supporting_5k_p2p",
        "role": "first readiness gate",
        "preferred_runtime_surface": "docker",
        "preferred_command_key": "docker_proof_local",
        "official_lane": "supporting_5k_p2p",
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
        "result_name_pattern": "<port>_<surface>_supporting_5k_benchmark_<YYYY-MM-DD>.json",
        "notes": "Official comparable 5k lane: Docker, local Reference P2P, fixed knobs, WAL enabled, and fresh proof volume. RPC replay evidence remains valid but is not cross-ranked here.",
    },
    {
        "gate_id": "supporting_10k",
        "target_height": 10000,
        "target_label": "10k",
        "benchmark_kind": "supporting_10k_p2p",
        "role": "first standardized performance gate",
        "preferred_runtime_surface": "docker",
        "preferred_command_key": "docker_proof_10k",
        "official_lane": "supporting_10k_p2p",
        "official_byte_source": "local_reference_p2p",
        "official_peer_mode": "local_reference",
        "official_proof_mode": "p2p_sync",
        "official_header_target_height": 10000,
        "official_prefetch_depth": 4,
        "official_script_runner_mode": "parallel",
        "official_utxo_accounting_policy": "core_spendable_v1",
        "official_chainstate_utxo_count": 19100,
        "fresh_state_required": 1,
        "local_reference_required": 1,
        "durable_required": 1,
        "wal_disabled_required": 0,
        "resume_supported_required": 1,
        "binary_gate_status": "not_attempted",
        "result_name_pattern": "<port>_<surface>_supporting_10k_benchmark_<YYYY-MM-DD>.json",
        "notes": "Official comparable 10k lane: same Docker/local Reference P2P posture as 5k, retargeted to height 10000. Older RPC replay and long-sync artifacts remain evidence-only unless they match this lane.",
    },
)

COMMAND_PURPOSES: dict[str, str] = {
    "docker_config": "validate compose configuration",
    "docker_build": "build the Docker runtime/proof image",
    "docker_warm": "warm Docker images before a benchmark campaign",
    "docker_status": "read status from inside the Docker runtime surface",
    "docker_proof_local": "run official Docker/local-reference P2P proof",
    "docker_proof_10k": "run official Docker/local-reference P2P 10k proof",
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
    parser.add_argument("--db", default="Project/project.db", help="Project SQLite DB path")
    parser.add_argument("--rebuild", action="store_true", help="Delete and rebuild the DB before import")
    parser.add_argument("--results-dir", default="Nodes/Shared/conformance/results", help="Canonical result JSON directory")
    parser.add_argument("--docker-dir", default="Nodes/Shared/docker/ports", help="Docker manifest directory")
    parser.add_argument("--status-json", action="append", default=[], help="Additional exported status JSON path")
    parser.add_argument("--blocker-ledger", action="append", default=[], help="Additional blocker ledger Markdown path")
    parser.add_argument("--skip-sqlite-utils-check", action="store_true", help="Do not require the sqlite-utils CLI")
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def stable_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def pretty_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True)


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
        return explicit
    target_height = integer(payload.get("target_height"), None)
    if target_height == 5000:
        return "supporting_5k_p2p"
    if target_height == 10000:
        return "supporting_10k_p2p"
    if target_height == 50000:
        return "supporting_50k_p2p"
    if target_height == 100000:
        return "primary_100k_p2p"
    return text(payload.get("category") or payload.get("artifact_kind"))


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


def import_docker_manifest(connection: sqlite3.Connection, root: Path, path: Path, payload: dict[str, Any]) -> int:
    artifact = make_artifact(path, root, payload)
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


def import_benchmark_gates(connection: sqlite3.Connection) -> None:
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


def import_conformance_rows(connection: sqlite3.Connection, artifact: Artifact, payload: dict[str, Any]) -> None:
    if not any(key in payload for key in ("results", "fixtures", "result", "bounded_gate_status", "passed")):
        return
    category = text(payload.get("category") or payload.get("artifact_kind") or artifact.kind)
    for index, row in enumerate(result_rows(payload)):
        row_payload = row.get("raw") if isinstance(row.get("raw"), dict) else row
        fixture_id = text(row.get("fixture_id") or row.get("name") or category or artifact.path.stem)
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
    sync_timing = payload.get("sync_timing")
    if isinstance(sync_timing, dict):
        unit = text(sync_timing.get("Unit")).lower()
        for stage, values in (sync_timing.get("Stages") or {}).items():
            if not isinstance(values, dict):
                continue
            total = integer(values.get("TotalMicros") if "micro" in unit else values.get("TotalMillis"), None)
            if total is None:
                continue
            stages[text(stage)] = max(0, round(total / 1000)) if "micro" in unit else total
    for container_key in ("stage_totals_ms", "timings_ms"):
        values = payload.get(container_key)
        if isinstance(values, dict):
            for stage, elapsed in values.items():
                parsed = integer(elapsed, None)
                if parsed is not None:
                    stages[text(stage)] = parsed
    pipeline = payload.get("pipeline_timing_summary")
    if isinstance(pipeline, dict):
        nested_stages = pipeline.get("stage_totals_ms")
        if isinstance(nested_stages, dict):
            for stage, elapsed in nested_stages.items():
                parsed = integer(elapsed, None)
                if parsed is not None:
                    stages[text(stage)] = parsed
        for stage, elapsed in pipeline.items():
            if stage == "stage_totals_ms" or isinstance(elapsed, (dict, list)):
                continue
            parsed = integer(elapsed, None)
            if parsed is not None:
                stages[text(stage)] = parsed
    connect = payload.get("connect_summary")
    timing_summary = connect.get("timing_summary") if isinstance(connect, dict) else None
    nested_stages = timing_summary.get("stage_totals_ms") if isinstance(timing_summary, dict) else None
    if isinstance(nested_stages, dict):
        for stage, elapsed in nested_stages.items():
            parsed = integer(elapsed, None)
            if parsed is not None:
                stages[text(stage)] = parsed
    timing_summary = payload.get("timing_summary")
    nested_stages = timing_summary.get("stage_totals_ms") if isinstance(timing_summary, dict) else None
    if isinstance(nested_stages, dict):
        for stage, elapsed in nested_stages.items():
            parsed = integer(elapsed, None)
            if parsed is not None:
                stages[text(stage)] = parsed
    if "utxo_load" not in stages and "prevout_batch_load" in stages:
        stages["utxo_load"] = stages["prevout_batch_load"]
    if "block_connect_store_commit" not in stages and "connect_total" in stages:
        stages["block_connect_store_commit"] = stages["connect_total"]
    return stages


def import_benchmark_rows(connection: sqlite3.Connection, artifact: Artifact, payload: dict[str, Any]) -> None:
    stages = timing_stages(payload)
    benchmark_like = stages or any(
        key in payload
        for key in (
            "elapsed_ms",
            "pipeline_timing_summary",
            "sync_timing",
            "connect_summary",
            "slow_blocks",
            "resource_samples",
            "benchmark_kind",
            "target_height",
            "target_label",
        )
    )
    if not benchmark_like:
        return
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
    benchmark_lane = text(payload.get("benchmark_lane")).strip()
    if not benchmark_lane and target_label:
        if peer_mode == "local_reference_rpc" or byte_source == "local_reference_rpc":
            benchmark_lane = f"supporting_{target_label}_rpc_replay"
        elif peer_mode == "local_reference":
            benchmark_lane = f"supporting_{target_label}_p2p"
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
                            "benchmark_lane",
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
                    **({"target_height": target_height} if target_height is not None else {}),
                    **({"target_label": target_label} if target_label else {}),
                    **({"header_target_height": header_target_height} if header_target_height is not None else {}),
                    **({"byte_source": byte_source} if byte_source else {}),
                    **({"proof_mode": proof_mode} if proof_mode else {}),
                    **({"benchmark_lane": benchmark_lane} if benchmark_lane else {}),
                    **({"binary_gate_status": text(payload.get("binary_gate_status"))} if "binary_gate_status" in payload else {}),
                }
            ),
            pretty_json(
                {
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
        root / "Nodes/TypeScript/snapshots/status.json",
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
        "consensus_rules": 0,
        "port_commands": 0,
    }
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        if initialize_schema:
            init_db(connection, root / "Project/schema.sql")
        connection.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('schema', 'mission-control-baseline')")
        connection.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('sqlite_utils_cli', 'required')")
        import_benchmark_gates(connection)
        rules_path = root / "Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json"
        if rules_path.exists():
            counts["consensus_rules"] += import_consensus_rule_ledger(connection, root, rules_path)

        docker_dir = root / args.docker_dir
        for path in sorted(docker_dir.glob("*.docker.json")):
            counts["port_commands"] += import_docker_manifest(connection, root, path, read_json(path))
            counts["docker_manifests"] += 1

        results_dir = root / args.results_dir
        for path in sorted(results_dir.glob("*.json")):
            import_json_artifact(connection, root, path, read_json(path))
            counts["result_json"] += 1

        for status_path in [*(root / path for path in args.status_json), *default_status_jsons(root)]:
            if status_path.exists():
                import_json_artifact(connection, root, status_path, read_json(status_path))
                counts["status_json"] += 1

        ledgers = [*(root / path for path in args.blocker_ledger), *default_blocker_ledgers(root)]
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
    counts = import_all(args)
    print("project_import " + " ".join(f"{key}={value}" for key, value in sorted(counts.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
