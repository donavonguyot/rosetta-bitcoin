#!/usr/bin/env python3
"""Read-only test and coverage control preflight."""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path
from typing import Any


LEVELS = ("inventory", "baseline-par", "coverage-control")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project DB path")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--port", help="Port to preflight")
    group.add_argument("--all", action="store_true", help="Preflight all non-reference ports")
    parser.add_argument("--level", choices=LEVELS, default="inventory", help="Preflight strictness")
    parser.add_argument("--strict", action="store_true", help="Exit nonzero when selected level has errors")
    parser.add_argument("--json", action="store_true", help="Emit JSON")
    return parser.parse_args()


def connect(db_path: str) -> sqlite3.Connection:
    db = Path(db_path)
    if not db.exists():
        raise SystemExit(f"Project DB not found: {db}")
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    return conn


def rows(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    return [dict(row) for row in conn.execute(sql, params).fetchall()]


def one(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...]) -> dict[str, Any] | None:
    row = conn.execute(sql, params).fetchone()
    return dict(row) if row else None


def all_ports(conn: sqlite3.Connection) -> list[str]:
    return [
        row["port"]
        for row in rows(
            conn,
            "select port from docker_contracts where port <> 'reference' order by port",
        )
    ]


def preflight_port(conn: sqlite3.Connection, port: str, level: str) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    matrix = one(conn, "select * from test_coverage_matrix where port = ?", (port,))
    if matrix is None:
        return {
            "port": port,
            "level": level,
            "lifecycle_status": "",
            "baseline_par_status": "missing",
            "coverage_control_status": "missing",
            "errors": ["missing test_coverage_matrix row"],
            "warnings": [],
        }

    commands = rows(
        conn,
        """
        select command_key, supported, command, discovery_method, notes
        from test_command_surface
        where port = ?
        order by command_key
        """,
        (port,),
    )
    domains = rows(
        conn,
        """
        select domain, domain_status, evidence
        from critical_test_domain_coverage
        where port = ?
        order by domain
        """,
        (port,),
    )

    command_map = {row["command_key"]: row for row in commands}
    unit = command_map.get("test_unit")
    coverage = command_map.get("test_coverage")

    if unit is None:
        errors.append("missing test_unit command row")
    elif not int(unit["supported"] or 0):
        errors.append("test_unit command is not supported")
    elif not str(unit["command"]).strip():
        errors.append("test_unit command has no command text")

    if coverage is None:
        warnings.append("missing test_coverage command row")
    elif not int(coverage["supported"] or 0):
        warnings.append("test_coverage command is not supported yet")

    missing_domains = [row["domain"] for row in domains if row["domain_status"] == "missing"]
    if missing_domains:
        warnings.append("missing critical domain evidence: " + ", ".join(missing_domains))

    lifecycle = str(matrix["lifecycle_status"])
    if level in {"baseline-par", "coverage-control"} and lifecycle == "active_contender":
        if matrix["baseline_par_status"] != "baseline_par":
            errors.append(f"baseline par status is {matrix['baseline_par_status']}")

    if level == "coverage-control":
        if not int(matrix["coverage_supported"] or 0):
            warnings.append("coverage command is report-only missing")
        elif matrix["coverage_control_status"] != "coverage_metrics_available":
            warnings.append(f"coverage metrics are not imported: {matrix['coverage_control_status']}")

    return {
        "port": port,
        "level": level,
        "lifecycle_status": lifecycle,
        "baseline_par_status": matrix["baseline_par_status"],
        "coverage_control_status": matrix["coverage_control_status"],
        "unit_supported": matrix["unit_supported"],
        "coverage_supported": matrix["coverage_supported"],
        "missing_domain_count": matrix["missing_domain_count"],
        "domain_count": matrix["domain_count"],
        "commands": commands,
        "domains": domains,
        "errors": errors,
        "warnings": warnings,
    }


def print_text(results: list[dict[str, Any]]) -> None:
    for index, result in enumerate(results):
        if index:
            print()
        print(
            "test_coverage_preflight "
            f"port={result['port']} "
            f"level={result['level']} "
            f"lifecycle={result['lifecycle_status']} "
            f"baseline_par={result['baseline_par_status']} "
            f"coverage={result['coverage_control_status']} "
            f"errors={len(result['errors'])} "
            f"warnings={len(result['warnings'])}"
        )
        print(f"  unit_supported={result.get('unit_supported', '')}")
        print(f"  coverage_supported={result.get('coverage_supported', '')}")
        print(f"  domains={result.get('domain_count', 0)} missing={result.get('missing_domain_count', 0)}")
        for error in result["errors"]:
            print(f"  ERROR {error}")
        for warning in result["warnings"]:
            print(f"  WARN {warning}")


def main() -> int:
    args = parse_args()
    with connect(args.db) as conn:
        selected_ports = all_ports(conn) if args.all else [str(args.port)]
        results = [preflight_port(conn, port, args.level) for port in selected_ports]
    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        print_text(results)
    if args.strict and any(result["errors"] for result in results):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
