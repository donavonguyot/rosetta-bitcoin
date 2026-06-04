#!/usr/bin/env python3
"""Print compact Project mission-control reports."""

from __future__ import annotations

import argparse
import sqlite3
from pathlib import Path
from typing import Iterable


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project SQLite DB path")
    parser.add_argument(
        "--section",
        choices=("summary", "docker", "status", "conformance", "blockers", "benchmarks", "decisions", "all"),
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
        union all select 'status_snapshots', count(*) from status_snapshots
        union all select 'blockers', count(*) from blockers
        union all select 'conformance_results', count(*) from conformance_results
        union all select 'benchmarks', count(*) from benchmarks
        union all select 'timing_samples', count(*) from timing_samples
        union all select 'decisions', count(*) from decisions
        """,
    )
    print(table(("table", "count"), ((row["table_name"], row["count"]) for row in data)))


def print_docker(connection: sqlite3.Connection) -> None:
    print("## Docker Contracts")
    print()
    data = rows(connection, "select port, status, supervisor_volume from docker_contracts order by port")
    print(table(("port", "status", "supervisor_volume"), data))


def print_status(connection: sqlite3.Connection) -> None:
    print("## Latest Status")
    print()
    data = rows(
        connection,
        """
        with ranked as (
          select *, row_number() over (
            partition by node_id order by validated_height desc, captured_at desc
          ) as rn
          from status_snapshots
        )
        select node_id, sync_status, binary_gate_status, header_height,
               stored_block_height, validated_height, chainstate_backend
        from ranked
        where rn = 1
        order by node_id
        """,
    )
    print(table(("node", "sync", "binary", "headers", "stored", "validated", "backend"), data))


def print_conformance(connection: sqlite3.Connection) -> None:
    print("## Conformance")
    print()
    data = rows(
        connection,
        """
        select node_id, category, result, count(*) as count
        from conformance_results
        group by node_id, category, result
        order by node_id, category, result
        """,
    )
    print(table(("node", "category", "result", "count"), data))


def print_blockers(connection: sqlite3.Connection) -> None:
    print("## Blockers")
    print()
    data = rows(
        connection,
        """
        select height, missing_rule, status, source_port
        from blockers
        order by height, missing_rule
        limit 40
        """,
    )
    print(table(("height", "missing_rule", "status", "source"), data))


def print_benchmarks(connection: sqlite3.Connection) -> None:
    print("## Benchmarks")
    print()
    data = rows(
        connection,
        """
        select node_id, benchmark_name, height, backend, captured_at
        from benchmarks
        order by node_id, benchmark_name
        """,
    )
    print(table(("node", "benchmark", "height", "backend", "captured_at"), data))


def print_decisions(connection: sqlite3.Connection) -> None:
    print("## Decisions")
    print()
    data = rows(connection, "select decision_id, status, title from decisions order by decision_id")
    print(table(("decision_id", "status", "title"), data))


def main() -> int:
    args = parse_args()
    db_path = Path(args.db)
    with sqlite3.connect(db_path) as connection:
        connection.row_factory = sqlite3.Row
        sections = ["summary", "docker", "status", "conformance", "blockers", "benchmarks", "decisions"]
        selected = sections if args.section == "all" else [args.section]
        for index, section in enumerate(selected):
            if index:
                print()
            globals()[f"print_{section}"](connection)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
