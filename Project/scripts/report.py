#!/usr/bin/env python3
"""Print Project mission-control projections from Project/project.db."""

from __future__ import annotations

import argparse
import sqlite3
from pathlib import Path
from typing import Callable, Iterable


SECTIONS = (
    "summary",
    "port-status",
    "docker-coverage",
    "command-surface",
    "conformance",
    "blocker-catalog",
    "blocker-matrix",
    "benchmark-gates",
    "benchmark-summary",
    "decisions",
)

SECTION_ALIASES = {
    "status": "port-status",
    "docker": "docker-coverage",
    "commands": "command-surface",
    "blockers": "blocker-catalog",
    "gates": "benchmark-gates",
    "benchmarks": "benchmark-summary",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project SQLite DB path")
    parser.add_argument(
        "--section",
        choices=(*SECTIONS, *SECTION_ALIASES.keys(), "all"),
        default="summary",
        help="Report section to print",
    )
    return parser.parse_args()


def rows(connection: sqlite3.Connection, query: str) -> list[sqlite3.Row]:
    return list(connection.execute(query))


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
            ("port", "role", "sync", "binary", "headers", "stored", "validated", "backend", "docker"),
            data,
        )
    )


def print_docker_coverage(connection: sqlite3.Connection) -> None:
    print("## Docker Coverage")
    print()
    data = rows(
        connection,
        """
        select port, docker_status, has_dockerfile, has_compose,
               has_dockerignore, data_volume, proof_volume, supervisor_volume
        from docker_coverage
        order by port
        """,
    )
    print(
        table(
            ("port", "status", "dockerfile", "compose", "ignore", "data_volume", "proof_volume", "supervisor_volume"),
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
               sample_count, latest_captured_at
        from benchmark_summary
        order by port, node_id, benchmark_name
        """,
    )
    print(table(("port", "node", "benchmark", "max_height", "backend", "samples", "latest"), data))


def print_benchmark_gates(connection: sqlite3.Connection) -> None:
    print("## Benchmark Gates")
    print()
    gates = rows(
        connection,
        """
        select gate_id, target_label, target_height, benchmark_kind, role,
               preferred_runtime_surface, preferred_command_key
        from benchmark_gates
        order by target_height
        """,
    )
    print(table(("gate", "label", "target", "kind", "role", "surface", "command"), gates))
    print()
    matrix = rows(
        connection,
        """
        select gate_id, port, gate_status, validated_height,
               runtime_surface, peer_mode, rocksdb_wal_disabled, captured_at
        from benchmark_gate_matrix
        order by target_height, port
        """,
    )
    print(table(("gate", "port", "status", "validated", "surface", "peer_mode", "wal_off", "captured"), matrix))


def print_decisions(connection: sqlite3.Connection) -> None:
    print("## Decisions")
    print()
    data = rows(connection, "select decision_id, status, title from decisions order by decision_id")
    print(table(("decision_id", "status", "title"), data))


REPORTS: dict[str, Callable[[sqlite3.Connection], None]] = {
    "summary": print_summary,
    "port-status": print_port_status,
    "docker-coverage": print_docker_coverage,
    "command-surface": print_command_surface,
    "conformance": print_conformance,
    "blocker-catalog": print_blocker_catalog,
    "blocker-matrix": print_blocker_matrix,
    "benchmark-gates": print_benchmark_gates,
    "benchmark-summary": print_benchmark_summary,
    "decisions": print_decisions,
}


def main() -> int:
    args = parse_args()
    db_path = Path(args.db)
    section = SECTION_ALIASES.get(args.section, args.section)
    selected = list(SECTIONS) if section == "all" else [section]
    with sqlite3.connect(db_path) as connection:
        connection.row_factory = sqlite3.Row
        for index, name in enumerate(selected):
            if index:
                print()
            REPORTS[name](connection)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
