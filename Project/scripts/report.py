#!/usr/bin/env python3
"""Print Project mission-control projections from Project/project.db."""

from __future__ import annotations

import argparse
import json
import sqlite3
import subprocess
from pathlib import Path
from typing import Callable, Iterable

from post_100k_source_state import classify_source_state, reference_finish_truth
from port_progress_posture import audit_ports


SECTIONS = (
    "summary",
    "port-status",
    "docker-coverage",
    "port-lifecycle",
    "current-evidence",
    "historical-evidence-candidates",
    "command-surface",
    "test-commands",
    "test-coverage",
    "critical-test-domains",
    "test-capabilities",
    "test-capability-gaps",
    "experiment-readiness",
    "conformance",
    "blocker-catalog",
    "blocker-matrix",
    "benchmark-suite",
    "leaderboard",
    "benchmark-gates",
    "benchmark-comparability",
    "baseline-5k",
    "shakedown-50k",
    "performance-100k",
    "post-100k-readiness",
    "port-progress-posture",
    "post-100k-to-tip",
    "tip-once",
    "tip-maintenance",
    "port-baseline-5k",
    "consensus-runway",
    "benchmark-summary",
    "decisions",
)

GATES = (
    "baseline_5k",
    "shakedown_50k",
    "performance_100k",
    "post_100k_to_tip",
    "tip_once",
    "tip_maintenance",
)

SECTION_ALIASES = {
    "status": "port-status",
    "docker": "docker-coverage",
    "lifecycle": "port-lifecycle",
    "evidence": "current-evidence",
    "current": "current-evidence",
    "historical": "historical-evidence-candidates",
    "commands": "command-surface",
    "tests": "test-coverage",
    "coverage": "test-coverage",
    "domains": "critical-test-domains",
    "capabilities": "test-capabilities",
    "capability-gaps": "test-capability-gaps",
    "experiments": "experiment-readiness",
    "blockers": "blocker-catalog",
    "benchmark-suite": "benchmark-suite",
    "rankings": "leaderboard",
    "5k-leaderboard": "leaderboard",
    "50k-leaderboard": "leaderboard",
    "100k-leaderboard": "leaderboard",
    "gates": "benchmark-gates",
    "comparability": "benchmark-comparability",
    "baseline": "baseline-5k",
    "5k-baseline": "baseline-5k",
    "port-baseline-5k": "baseline-5k",
    "50k": "shakedown-50k",
    "100k": "performance-100k",
    "post-100k": "post-100k-to-tip",
    "100k-to-tip": "post-100k-to-tip",
    "tip-readiness": "post-100k-to-tip",
    "tip-source-readiness": "post-100k-readiness",
    "progress-posture": "port-progress-posture",
    "product-progress": "port-progress-posture",
    "runway": "consensus-runway",
    "consensus": "consensus-runway",
    "benchmarks": "benchmark-summary",
}

SECTION_DEFAULT_GATES = {
    "5k-leaderboard": "baseline_5k",
    "50k-leaderboard": "shakedown_50k",
    "100k-leaderboard": "performance_100k",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project mission-control DB path")
    parser.add_argument("--gate", choices=GATES, help="Optional benchmark gate filter for leaderboard reports")
    parser.add_argument("--list-sections", action="store_true", help="List available report sections and aliases")
    parser.add_argument(
        "--section",
        choices=(*SECTIONS, *SECTION_ALIASES.keys(), "all"),
        default="summary",
        help="Report section to print",
    )
    return parser.parse_args()


def rows(connection: sqlite3.Connection, query: str) -> list[sqlite3.Row]:
    return list(connection.execute(query))


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def tracked_result_paths() -> list[str]:
    completed = subprocess.run(
        ["git", "-C", str(repo_root()), "ls-files", "--", "Nodes/Shared/conformance/results/*.json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return sorted(line.strip() for line in completed.stdout.splitlines() if line.strip())


def manifest_source_volume(port: str) -> str:
    path = repo_root() / "Nodes/Shared/docker/ports" / f"{port}.docker.json"
    if not path.exists():
        return ""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return ""
    volumes = payload.get("volumes")
    if not isinstance(volumes, dict):
        return ""
    return str(volumes.get("proof_100k") or "").strip()


def table(headers: Iterable[str], rows_: Iterable[Iterable[object]]) -> str:
    headers = list(headers)
    data = [[str(cell) if cell is not None else "" for cell in row] for row in rows_]
    widths = [len(header) for header in headers]
    for row in data:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))
    lines = [
        "| " + " | ".join(header.ljust(widths[index]) for index, header in enumerate(headers)) + " |",
        "| " + " | ".join("-" * widths[index] for index in range(len(headers))) + " |",
    ]
    for row in data:
        lines.append("| " + " | ".join(cell.ljust(widths[index]) for index, cell in enumerate(row)) + " |")
    return "\n".join(lines)


def print_summary(connection: sqlite3.Connection) -> None:
    print("## Project Summary")
    print()
    data = rows(
        connection,
        """
        select 'artifacts' as table_name, count(*) as count from artifacts
        union all select 'nodes', count(*) from nodes
        union all select 'port_lifecycle', count(*) from port_lifecycle
        union all select 'evidence_index_entries', count(*) from evidence_index_entries
        union all select 'docker_contracts', count(*) from docker_contracts
        union all select 'port_commands', count(*) from port_commands
        union all select 'benchmark_gates', count(*) from benchmark_gates
        union all select 'status_snapshots', count(*) from status_snapshots
        union all select 'blockers', count(*) from blockers
        union all select 'conformance_results', count(*) from conformance_results
        union all select 'benchmarks', count(*) from benchmarks
        union all select 'timing_samples', count(*) from timing_samples
        union all select 'decisions', count(*) from decisions
        """,
    )
    print(table(("table", "count"), ((row["table_name"], row["count"]) for row in data)))


def print_port_status(connection: sqlite3.Connection) -> None:
    print("## Port Status")
    print()
    data = rows(
        connection,
        """
        select
          lps.port,
          lps.role,
          lps.lifecycle_status,
          lps.benchmark_scope,
          lps.sync_status,
          lps.binary_gate_status,
          lps.header_height,
          lps.stored_block_height,
          lps.validated_height,
          lps.chainstate_backend,
          dc.docker_status
        from latest_port_status lps
        left join docker_coverage dc on dc.port = lps.port
        order by lps.port
        """,
    )
    print(
        table(
            ("port", "role", "lifecycle", "scope", "sync", "binary", "headers", "stored", "validated", "backend", "docker"),
            data,
        )
    )


def print_port_lifecycle(connection: sqlite3.Connection) -> None:
    print("## Port Lifecycle")
    print()
    data = rows(
        connection,
        """
        select
          dc.port,
          coalesce(pl.lifecycle_status, 'active_contender') as lifecycle_status,
          coalesce(pl.benchmark_scope, 'full_suite') as benchmark_scope,
          coalesce(pl.retired_at_gate, '') as retired_at_gate,
          coalesce(pl.retired_reason, '') as retired_reason,
          coalesce(pl.notes, '') as notes
        from docker_contracts dc
        left join port_lifecycle pl on pl.port = dc.port
        where dc.port <> 'reference'
        order by
          case coalesce(pl.lifecycle_status, 'active_contender')
            when 'active_contender' then 0
            when 'active_development' then 1
            when 'baseline_retired' then 2
            else 3
          end,
          dc.port
        """,
    )
    print(table(("port", "lifecycle", "scope", "retired_at", "reason", "notes"), data))


def print_current_evidence(connection: sqlite3.Connection) -> None:
    print("## Current Evidence")
    print()
    data = rows(
        connection,
        """
        select port, claim, gate_id, status, imported, artifact_kind,
               node_id, captured_at, path, notes
        from current_evidence_status
        order by port,
          case claim
            when 'script_corpus' then 0
            when 'storage' then 1
            when 'baseline_5k' then 2
            when 'shakedown_50k' then 3
            when 'performance_100k' then 4
            when 'external_probe' then 5
            when 'tip_once' then 6
            when 'tip_maintenance' then 7
            else 8
          end,
          gate_id,
          path
        """,
    )
    print(table(("port", "claim", "gate", "status", "imported", "kind", "node", "captured", "path", "notes"), data))


def print_historical_evidence_candidates(connection: sqlite3.Connection) -> None:
    print("## Historical Evidence Candidates")
    print()
    current_paths = {
        row["path"]
        for row in rows(connection, "select path from evidence_index_entries")
    }
    candidates = [(path,) for path in tracked_result_paths() if path not in current_paths]
    print(table(("tracked_result_json_not_current",), candidates))


def print_docker_coverage(connection: sqlite3.Connection) -> None:
    print("## Docker Coverage")
    print()
    data = rows(
        connection,
        """
        select port, lifecycle_status, docker_status, has_dockerfile, has_compose,
               has_dockerignore, data_volume, proof_volume, supervisor_volume
        from docker_coverage
        order by port
        """,
    )
    print(
        table(
            ("port", "lifecycle", "status", "dockerfile", "compose", "ignore", "data_volume", "proof_volume", "supervisor_volume"),
            data,
        )
    )


def print_command_surface(connection: sqlite3.Connection) -> None:
    print("## Command Surface")
    print()
    coverage = rows(
        connection,
        """
        select command_key, supported_ports, declared_ports, unsupported_ports
        from port_command_coverage
        order by command_key
        """,
    )
    print(table(("command", "supported", "declared", "unsupported_ports"), coverage))
    print()
    commands = rows(
        connection,
        """
        select port, command_key, supported, command
        from port_command_surface
        order by port, command_key
        """,
    )
    print(table(("port", "command", "supported", "run"), commands))


def print_test_commands(connection: sqlite3.Connection) -> None:
    print("## Test Commands")
    print()
    data = rows(
        connection,
        """
        select port, lifecycle_status, command_key, category, supported,
               discovery_method, command, notes
        from test_command_surface
        order by port, command_key
        """,
    )
    print(table(("port", "lifecycle", "command", "category", "supported", "discovery", "run", "notes"), data))


def print_test_coverage(connection: sqlite3.Connection) -> None:
    print("## Test Coverage")
    print()
    data = rows(
        connection,
        """
        select port, lifecycle_status, baseline_par_status,
               unit_supported, latest_unit_result, missing_domain_count,
               domain_count, coverage_control_status, coverage_supported,
               latest_coverage_result, coverage_tool, line_percent,
               branch_percent
        from test_coverage_matrix
        order by
          case lifecycle_status
            when 'active_contender' then 0
            when 'active_development' then 1
            when 'baseline_retired' then 2
            else 3
          end,
          port
        """,
    )
    print(
        table(
            (
                "port",
                "lifecycle",
                "baseline_par",
                "unit_cmd",
                "unit_result",
                "missing_domains",
                "domains",
                "coverage",
                "coverage_cmd",
                "coverage_result",
                "tool",
                "line",
                "branch",
            ),
            data,
        )
    )


def print_critical_test_domains(connection: sqlite3.Connection) -> None:
    print("## Critical Test Domains")
    print()
    data = rows(
        connection,
        """
        select port, lifecycle_status, domain, domain_status, evidence_source_type, evidence, notes
        from critical_test_domain_coverage
        order by port,
          case domain
            when 'script_verification' then 0
            when 'sighash_taproot_witness' then 1
            when 'utxo_apply_undo_accounting' then 2
            when 'block_connect' then 3
            when 'rocksdb_persistence_restart' then 4
            when 'p2p_fetch_handshake' then 5
            when 'node_status_reporting' then 6
            else 7
          end
        """,
    )
    print(table(("port", "lifecycle", "domain", "status", "source", "evidence", "notes"), data))


def print_test_capabilities(connection: sqlite3.Connection) -> None:
    print("## Test Capabilities")
    print()
    data = rows(
        connection,
        """
        select port,
               lifecycle_status,
               capability,
               status,
               scope,
               backend,
               evidence_kind,
               evidence_path,
               case
                 when suite_id <> '' then
                   'suite=' || suite_id ||
                   ' result=' || coalesce(case_passed, 0) || '/' || coalesce(case_total, 0) ||
                   ' suite_hash=' || substr(suite_hash, 1, 12) ||
                   ' provenance=' || provenance_json
                 else provenance_json
               end as suite_or_provenance,
               does_not_prove,
               evidence_source_type
        from test_capability_contract_matrix
        order by port,
          case capability
            when 'unit_surface' then 0
            when 'shared_script_corpus' then 1
            when 'sighash_and_witness_regressions' then 2
            when 'utxo_apply_undo_accounting' then 3
            when 'block_connect_local_reference' then 4
            when 'rocksdb_restart_persistence' then 5
            when 'p2p_deferred_handshake' then 6
            when 'status_reporting' then 7
            else 20
          end,
          capability
        """,
    )
    print(
        table(
            (
                "port",
                "lifecycle",
                "capability",
                "status",
                "scope",
                "backend",
                "evidence",
                "path",
                "suite/provenance",
                "does_not_prove",
                "source",
            ),
            data,
        )
    )


def print_test_capability_gaps(connection: sqlite3.Connection) -> None:
    print("## Test Capability Gaps")
    print()
    data = rows(
        connection,
        """
        select port, lifecycle_status, capability, status, blocking_for_json,
               evidence_kind, evidence_path, does_not_prove
        from test_capability_gaps
        order by port, capability
        """,
    )
    print(table(("port", "lifecycle", "capability", "status", "blocking_for", "evidence", "path", "does_not_prove"), data))


def print_experiment_readiness(connection: sqlite3.Connection) -> None:
    print("## Experiment Readiness")
    print()
    data = rows(
        connection,
        """
        select port, lifecycle_status, experiment, readiness, blocking_contracts
        from experiment_readiness
        order by port, experiment
        """,
    )
    print(table(("port", "lifecycle", "experiment", "readiness", "blocking_contracts"), data))


def print_conformance(connection: sqlite3.Connection) -> None:
    print("## Conformance")
    print()
    data = rows(
        connection,
        """
        select port, node_id, category, result, result_count,
               max_validated_height, latest_captured_at
        from conformance_summary
        order by port, node_id, category, result
        """,
    )
    print(table(("port", "node", "category", "result", "count", "max_height", "latest"), data))


def print_blocker_catalog(connection: sqlite3.Connection) -> None:
    print("## Blocker Catalog")
    print()
    data = rows(
        connection,
        """
        select height, missing_rule, status, sources
        from current_blocker_state
        order by height
        """,
    )
    print(table(("height", "missing_rule", "status", "sources"), data))


def print_blocker_matrix(connection: sqlite3.Connection) -> None:
    print("## Blocker Matrix")
    print()
    ports = [
        row["port"]
        for row in rows(
            connection,
            "select distinct port from follower_blocker_matrix order by port",
        )
    ]
    matrix_rows = rows(
        connection,
        """
        select height, missing_rule, port, blocker_status
        from follower_blocker_matrix
        order by height, port
        """,
    )
    grouped: dict[tuple[int, str], dict[str, str]] = {}
    for row in matrix_rows:
        key = (row["height"], row["missing_rule"])
        grouped.setdefault(key, {port: "unknown" for port in ports})
        grouped[key][row["port"]] = row["blocker_status"]
    rendered = []
    for (height, missing_rule), statuses in grouped.items():
        rendered.append((height, missing_rule, *(statuses[port] for port in ports)))
    print(table(("height", "missing_rule", *ports), rendered))


def print_benchmark_summary(connection: sqlite3.Connection) -> None:
    print("## Benchmark Summary")
    print()
    data = rows(
        connection,
        """
        select port, node_id, benchmark_name, max_height, backend,
               sample_count, best_total_ms, latest_captured_at
        from benchmark_summary
        order by port, node_id, benchmark_name
        """,
    )
    print(table(("port", "node", "benchmark", "max_height", "backend", "samples", "best_ms", "latest"), data))


def print_benchmark_gates(connection: sqlite3.Connection) -> None:
    print("## Benchmark Gates")
    print()
    gates = rows(
        connection,
        """
        select gate_id, target_label, target_height, benchmark_kind, role,
               preferred_runtime_surface, preferred_command_key, official_lane
        from benchmark_gates
        order by
          case gate_id
            when 'baseline_5k' then 0
            when 'shakedown_50k' then 1
            when 'performance_100k' then 2
            when 'post_100k_to_tip' then 3
            when 'tip_once' then 4
            when 'tip_maintenance' then 5
            else 6
          end
        """,
    )
    print(table(("gate", "label", "target", "kind", "role", "surface", "command", "official_lane"), gates))
    print()
    matrix = rows(
        connection,
        """
        select gate_id, port, lifecycle_status, gate_status, comparability_status, artifact_quality, telemetry_quality, evidence_lane,
               validated_height, header_target_height, runtime_surface, peer_mode,
               prefetch_depth, script_runner_mode, rocksdb_wal_disabled,
               fresh_state, utxo_accounting_policy, chainstate_utxo_count,
               comparability_notes, captured_at
        from benchmark_gate_matrix
        order by
          case gate_id
            when 'baseline_5k' then 0
            when 'shakedown_50k' then 1
            when 'performance_100k' then 2
            when 'post_100k_to_tip' then 3
            when 'tip_once' then 4
            when 'tip_maintenance' then 5
            else 6
          end,
          port
        """,
    )
    print(
        table(
            (
                "gate",
                "port",
                "lifecycle",
                "status",
                "comparable",
                "quality",
                "telemetry",
                "lane",
                "validated",
                "headers",
                "surface",
                "peer_mode",
                "prefetch",
                "runner",
                "wal_off",
                "fresh",
                "utxo_policy",
                "utxos",
                "notes",
                "captured",
            ),
            matrix,
        )
    )


def print_gate_matrix(connection: sqlite3.Connection, gate_id: str, title: str) -> None:
    print(f"## {title}")
    print()
    data = rows(
        connection,
        f"""
        select port, lifecycle_status, gate_status, comparability_status, artifact_quality, telemetry_quality, evidence_lane,
               validated_height, header_target_height, runtime_surface, peer_mode,
               prefetch_depth, script_runner_mode, rocksdb_wal_disabled,
               fresh_state, utxo_accounting_policy, chainstate_utxo_count,
               comparability_notes, captured_at
        from benchmark_gate_matrix
        where gate_id = '{gate_id}'
        order by port
        """,
    )
    print(
        table(
            (
                "port",
                "lifecycle",
                "status",
                "comparable",
                "quality",
                "telemetry",
                "lane",
                "validated",
                "headers",
                "surface",
                "peer_mode",
                "prefetch",
                "runner",
                "wal_off",
                "fresh",
                "utxo_policy",
                "utxos",
                "notes",
                "captured",
            ),
            data,
        )
    )


def print_post_100k_readiness(connection: sqlite3.Connection) -> None:
    print("## Post-100k Readiness")
    print()
    reference_finish = reference_finish_truth()
    ports = rows(
        connection,
        """
        select
          dc.port,
          coalesce(pl.lifecycle_status, 'active_contender') as lifecycle_status,
          max(case when pcs.command_key = 'docker_proof_post_100k_to_tip' then pcs.supported else 0 end) as post_command_supported,
          max(case when pcs.command_key = 'docker_proof_post_100k_to_tip' then pcs.command else '' end) as post_command,
          max(case when pcs.command_key = 'docker_status_100k' then pcs.supported else 0 end) as status_command_supported,
          max(case when pcs.command_key = 'docker_status_100k' then pcs.command else '' end) as status_command
        from docker_contracts dc
        left join port_lifecycle pl on pl.port = dc.port
        left join port_command_surface pcs on pcs.port = dc.port
          and pcs.command_key in ('docker_proof_post_100k_to_tip', 'docker_status_100k')
        where dc.port <> 'reference'
          and coalesce(pl.lifecycle_status, 'active_contender') = 'active_contender'
        group by dc.port, coalesce(pl.lifecycle_status, 'active_contender')
        order by dc.port
        """,
    )
    rendered = []
    ref_height = reference_finish.get("height", "") if reference_finish.get("ok") else ""
    ref_hash = reference_finish.get("hash", "") if reference_finish.get("ok") else ""
    for port_row in ports:
        port = str(port_row["port"])
        source_volume = manifest_source_volume(port)
        source = classify_source_state(connection, port, source_volume, reference_finish)
        rendered.append(
            (
                port,
                port_row["lifecycle_status"],
                "yes" if int(port_row["post_command_supported"] or 0) else "no",
                "yes" if int(port_row["status_command_supported"] or 0) else "no",
                source_volume,
                source.get("status", ""),
                source.get("height", ""),
                source.get("hash", ""),
                source.get("utxo_count", ""),
                ref_height,
                ref_hash,
                source.get("reason", ""),
            )
        )
    print(
        table(
            (
                "port",
                "lifecycle",
                "post_cmd",
                "status_cmd",
                "source_volume",
                "source_status",
                "source_height",
                "source_hash",
                "source_utxos",
                "ref_height",
                "ref_hash",
                "reason",
            ),
            rendered,
        )
    )


def print_port_progress_posture(connection: sqlite3.Connection) -> None:
    print("## Port Progress Posture")
    print()
    lifecycle = {
        row["port"]: row["lifecycle_status"]
        for row in rows(
            connection,
            """
            select port, coalesce(lifecycle_status, 'active_contender') as lifecycle_status
            from port_lifecycle
            """,
        )
    }
    data = []
    for row in audit_ports():
        recommended = ",".join(row["recommended_seen"]) if row["recommended_seen"] else ""
        missing = ",".join(row["missing_required"]) if row["missing_required"] else ""
        data.append(
            (
                row["port"],
                lifecycle.get(row["port"], "active_contender"),
                row["posture"],
                "yes" if row["source_progress"] else "no",
                "yes" if row["wrapper_control"] else "no",
                f"{row['parseable_lines']}/{row['progress_lines']}",
                f"{row['complete_lines']}/{row['parseable_lines']}",
                "yes" if row["required_ok"] else "no" if row["progress_lines"] else "unknown",
                row["line_atomicity"],
                "yes" if row["before_first_block"] else "no" if row["progress_lines"] else "unknown",
                "yes" if row["after_first_block"] else "no" if row["progress_lines"] else "unknown",
                row["final_height"] if row["final_height"] is not None else "",
                recommended,
                missing,
                row["notes"],
            )
        )
    print(
        table(
            (
                "port",
                "lifecycle",
                "posture",
                "source",
                "wrapper",
                "parseable",
                "complete",
                "required",
                "atomic",
                "pre-block",
                "post-block",
                "final_height",
                "recommended_seen",
                "missing_required",
                "notes",
            ),
            data,
        )
    )


def print_benchmark_suite(connection: sqlite3.Connection) -> None:
    print_benchmark_gates(connection)
    print()
    print_gate_matrix(connection, "baseline_5k", "Baseline 5k")
    print()
    print_gate_matrix(connection, "shakedown_50k", "Shakedown 50k")
    print()
    print_gate_matrix(connection, "performance_100k", "Performance 100k")
    print()
    print_gate_matrix(connection, "post_100k_to_tip", "Post 100k To Tip")
    print()
    print_gate_matrix(connection, "tip_once", "Tip Once")
    print()
    print_gate_matrix(connection, "tip_maintenance", "Tip Maintenance")


def print_leaderboard(connection: sqlite3.Connection, gate_id: str | None = None) -> None:
    title = "Benchmark Leaderboard"
    if gate_id:
        title += f" ({gate_id})"
    print(f"## {title}")
    print()
    where = f"where gate_id = '{gate_id}'" if gate_id else ""
    data = rows(
        connection,
        f"""
        select gate_id, rank, port, total_ms, validated_height, validated_hash,
               evidence_lane, peer, chainstate_backend, native_crypto_backend,
               artifact_quality, telemetry_quality, artifact_source, chainstate_utxo_count, p2p_fetch_ms, script_verify_ms,
               block_connect_store_commit_ms, captured_at, artifact_path
        from benchmark_leaderboard
        {where}
        order by
          case gate_id
            when 'baseline_5k' then 0
            when 'shakedown_50k' then 1
            when 'performance_100k' then 2
            when 'post_100k_to_tip' then 3
            when 'tip_once' then 4
            when 'tip_maintenance' then 5
            else 5
          end,
          rank,
          port
        """,
    )
    print(
        table(
            (
                "gate",
                "rank",
                "port",
                "total_ms",
                "validated",
                "hash",
                "lane",
                "peer",
                "backend",
                "crypto",
                "quality",
                "telemetry",
                "source",
                "utxos",
                "p2p_ms",
                "script_ms",
                "connect_ms",
                "captured",
                "artifact",
            ),
            data,
        )
    )


def print_benchmark_comparability(connection: sqlite3.Connection) -> None:
    print("## Benchmark Comparability")
    print()
    data = rows(
        connection,
        """
        select port, gate_id, gate_status, comparability_status, evidence_lane,
               validated_height, header_target_height, peer_mode, byte_source,
               proof_mode, prefetch_depth, script_runner_mode,
               rocksdb_wal_disabled, fresh_state, utxo_accounting_policy,
               chainstate_utxo_count, artifact_quality, telemetry_quality, total_ms, comparability_notes
        from benchmark_comparability
        order by
          case gate_id
            when 'baseline_5k' then 0
            when 'shakedown_50k' then 1
            when 'performance_100k' then 2
            when 'tip_once' then 3
            when 'tip_maintenance' then 4
            else 5
          end,
          port,
          captured_at
        """,
    )
    print(
        table(
            (
                "port",
                "gate",
                "status",
                "comparable",
                "lane",
                "validated",
                "headers",
                "peer_mode",
                "byte_source",
                "proof_mode",
                "prefetch",
                "runner",
                "wal_off",
                "fresh",
                "utxo_policy",
                "utxos",
                "quality",
                "telemetry",
                "total_ms",
                "notes",
            ),
            data,
        )
    )


def print_port_baseline_5k(connection: sqlite3.Connection) -> None:
    print("## Port Baseline 5k")
    print()
    data = rows(
        connection,
        """
        select port, baseline_status, gate_status, comparability_status,
               validated_height, chainstate_backend, native_crypto_backend,
               script_corpus_status, script_passed, script_failed,
               prefetch_depth, script_runner_mode, rocksdb_wal_disabled,
               fresh_state, utxo_accounting_policy, chainstate_utxo_count,
               required_timing_buckets, captured_at
        from port_baseline_5k
        order by port
        """,
    )
    print(
        table(
            (
                "port",
                "baseline",
                "gate",
                "comparable",
                "validated",
                "backend",
                "native_crypto",
                "script",
                "script_pass",
                "script_fail",
                "prefetch",
                "runner",
                "wal_off",
                "fresh",
                "utxo_policy",
                "utxos",
                "timing",
                "captured",
            ),
            data,
        )
    )


def print_consensus_runway(connection: sqlite3.Connection) -> None:
    print("## Consensus Runway")
    print()
    rules = rows(
        connection,
        """
        select chain, category, status, rule_count, min_height, max_height
        from consensus_rule_summary
        order by chain, category, status
        """,
    )
    print(table(("chain", "category", "status", "rules", "min_height", "max_height"), rules))
    print()
    data = rows(
        connection,
        """
        select port, lifecycle_status, stage, runway_status, target_height,
               has_clean_script_corpus, script_passed, script_failed,
               script_runtime_surface, script_native_crypto_backend,
               baseline_5k_status, stage_gate_status, stage_gate_comparability,
               max_validated_height, header_height, sync_status,
               open_blocker_count, open_blocker_heights
        from consensus_runway
        order by port,
          case stage
            when 'corpus' then 0
            when '5k' then 1
            when '50k' then 2
            when '100k' then 3
            when 'tip_once' then 4
            when 'tip_maintenance' then 5
            else 6
          end
        """,
    )
    print(
        table(
            (
                "port",
                "lifecycle",
                "stage",
                "status",
                "target",
                "script",
                "script_pass",
                "script_fail",
                "script_surface",
                "script_crypto",
                "5k",
                "stage_gate",
                "stage_cmp",
                "validated",
                "headers",
                "sync",
                "open_blockers",
                "blocker_heights",
            ),
            data,
        )
    )


def print_decisions(connection: sqlite3.Connection) -> None:
    print("## Decisions")
    print()
    data = rows(connection, "select decision_id, status, title from decisions order by decision_id")
    print(table(("decision_id", "status", "title"), data))


REPORTS: dict[str, Callable[[sqlite3.Connection], None]] = {
    "summary": print_summary,
    "port-status": print_port_status,
    "docker-coverage": print_docker_coverage,
    "port-lifecycle": print_port_lifecycle,
    "current-evidence": print_current_evidence,
    "historical-evidence-candidates": print_historical_evidence_candidates,
    "command-surface": print_command_surface,
    "test-commands": print_test_commands,
    "test-coverage": print_test_coverage,
    "critical-test-domains": print_critical_test_domains,
    "test-capabilities": print_test_capabilities,
    "test-capability-gaps": print_test_capability_gaps,
    "experiment-readiness": print_experiment_readiness,
    "conformance": print_conformance,
    "blocker-catalog": print_blocker_catalog,
    "blocker-matrix": print_blocker_matrix,
    "benchmark-suite": print_benchmark_suite,
    "leaderboard": print_leaderboard,
    "benchmark-gates": print_benchmark_gates,
    "benchmark-comparability": print_benchmark_comparability,
    "baseline-5k": print_port_baseline_5k,
    "shakedown-50k": lambda connection: print_gate_matrix(connection, "shakedown_50k", "Shakedown 50k"),
    "performance-100k": lambda connection: print_gate_matrix(connection, "performance_100k", "Performance 100k"),
    "post-100k-readiness": print_post_100k_readiness,
    "port-progress-posture": print_port_progress_posture,
    "post-100k-to-tip": lambda connection: print_gate_matrix(connection, "post_100k_to_tip", "Post 100k To Tip"),
    "tip-once": lambda connection: print_gate_matrix(connection, "tip_once", "Tip Once"),
    "tip-maintenance": lambda connection: print_gate_matrix(connection, "tip_maintenance", "Tip Maintenance"),
    "consensus-runway": print_consensus_runway,
    "benchmark-summary": print_benchmark_summary,
    "decisions": print_decisions,
}


def main() -> int:
    args = parse_args()
    if args.list_sections:
        print("sections:")
        for section_name in SECTIONS:
            print(f"  {section_name}")
        print("aliases:")
        for alias, section_name in sorted(SECTION_ALIASES.items()):
            suffix = ""
            if alias in SECTION_DEFAULT_GATES:
                suffix = f" --gate {SECTION_DEFAULT_GATES[alias]}"
            print(f"  {alias} -> {section_name}{suffix}")
        return 0
    db_path = Path(args.db)
    requested_section = args.section
    section = SECTION_ALIASES.get(requested_section, requested_section)
    gate_id = args.gate or SECTION_DEFAULT_GATES.get(requested_section)
    selected = list(SECTIONS) if section == "all" else [section]
    with sqlite3.connect(db_path) as connection:
        connection.row_factory = sqlite3.Row
        for index, name in enumerate(selected):
            if index:
                print()
            if name == "leaderboard":
                print_leaderboard(connection, gate_id)
            else:
                REPORTS[name](connection)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
