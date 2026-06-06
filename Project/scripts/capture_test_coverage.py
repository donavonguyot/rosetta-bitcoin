#!/usr/bin/env python3
"""Capture product-test and coverage telemetry into Shared testing results."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sqlite3
import subprocess
import tempfile
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


ACTIVE_RUN_LIFECYCLES = {"active_contender", "active_development"}
DEFAULT_DB = "Project/project.db"
DEFAULT_RESULTS_DIR = "Nodes/Shared/testing/results"


@dataclass(frozen=True)
class CommandSurface:
    port: str
    node_id: str
    lifecycle_status: str
    command_key: str
    supported: bool
    command: str


@dataclass(frozen=True)
class PlannedCommand:
    port: str
    node_id: str
    lifecycle_status: str
    command_key: str
    command: str
    kind: str
    action: str
    reason: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=DEFAULT_DB, help="Project mission-control DB path")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--port", help="Capture one port")
    group.add_argument("--all", action="store_true", help="Capture all known non-reference ports")
    parser.add_argument("--results-dir", default=DEFAULT_RESULTS_DIR, help="Curated JSON output directory")
    parser.add_argument("--run", action="store_true", help="Execute commands and write artifacts")
    parser.add_argument("--dry-run", action="store_true", help="Print the plan without executing commands")
    parser.add_argument("--include-coverage", action="store_true", help="Also capture explicitly supported coverage commands")
    parser.add_argument("--self-test", action="store_true", help="Run parser and artifact fixture checks")
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def stamp_for_path(captured_at: str) -> str:
    return captured_at.replace("-", "").replace(":", "").replace("Z", "Z")


def connect(db_path: Path) -> sqlite3.Connection:
    if not db_path.exists():
        raise SystemExit(f"Project DB not found: {db_path}")
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def load_command_surface(conn: sqlite3.Connection) -> dict[str, dict[str, CommandSurface]]:
    rows = conn.execute(
        """
        select tcs.port,
               coalesce(dc.node_id, tcs.port) as node_id,
               tcs.lifecycle_status,
               tcs.command_key,
               tcs.supported,
               tcs.command
        from test_command_surface tcs
        left join docker_contracts dc on dc.port = tcs.port
        where tcs.port <> 'reference'
        order by tcs.port, tcs.command_key
        """
    ).fetchall()
    by_port: dict[str, dict[str, CommandSurface]] = {}
    for row in rows:
        surface = CommandSurface(
            port=str(row["port"]),
            node_id=str(row["node_id"]),
            lifecycle_status=str(row["lifecycle_status"]),
            command_key=str(row["command_key"]),
            supported=bool(row["supported"]),
            command=str(row["command"] or ""),
        )
        by_port.setdefault(surface.port, {})[surface.command_key] = surface
    return by_port


def select_ports(by_port: dict[str, dict[str, CommandSurface]], port: str | None, all_ports: bool) -> list[str]:
    if port:
        if port not in by_port:
            raise SystemExit(f"unknown port: {port}")
        return [port]
    if all_ports:
        return sorted(by_port)
    raise SystemExit("select --port <port>, --all, or --self-test")


def command_or_skip(commands: dict[str, CommandSurface], command_key: str) -> CommandSurface | None:
    surface = commands.get(command_key)
    if not surface or not surface.supported or not surface.command.strip():
        return None
    return surface


def preferred_coverage_command(commands: dict[str, CommandSurface]) -> CommandSurface | None:
    return command_or_skip(commands, "test_coverage")


def build_plan(
    by_port: dict[str, dict[str, CommandSurface]],
    selected_ports: list[str],
    explicit_port: bool,
    run_requested: bool,
    include_coverage: bool,
) -> list[PlannedCommand]:
    plan: list[PlannedCommand] = []
    for port in selected_ports:
        commands = by_port[port]
        lifecycle = next(iter(commands.values())).lifecycle_status
        node_id = next(iter(commands.values())).node_id
        retired = lifecycle == "baseline_retired"

        unit = command_or_skip(commands, "test_unit")
        if unit is None:
            plan.append(
                PlannedCommand(port, node_id, lifecycle, "test_unit", "", "test", "skip", "test_unit command is not supported")
            )
        elif retired and not explicit_port:
            plan.append(
                PlannedCommand(
                    port,
                    node_id,
                    lifecycle,
                    "test_unit",
                    unit.command,
                    "test",
                    "skip",
                    "baseline-retired ports are visible but not run by --all",
                )
            )
        else:
            plan.append(PlannedCommand(port, node_id, lifecycle, "test_unit", unit.command, "test", "run", ""))

        if not include_coverage:
            continue

        coverage = preferred_coverage_command(commands)
        if coverage is None:
            plan.append(
                PlannedCommand(
                    port,
                    node_id,
                    lifecycle,
                    "test_coverage",
                    "",
                    "coverage",
                    "skip",
                    "no supported coverage command",
                )
            )
        elif retired and not explicit_port:
            plan.append(
                PlannedCommand(
                    port,
                    node_id,
                    lifecycle,
                    coverage.command_key,
                    coverage.command,
                    "coverage",
                    "skip",
                    "baseline-retired ports are visible but not run by --all",
                )
            )
        else:
            plan.append(PlannedCommand(port, node_id, lifecycle, coverage.command_key, coverage.command, "coverage", "run", ""))
    return plan


def print_plan(plan: list[PlannedCommand], run_requested: bool) -> None:
    mode = "run" if run_requested else "dry-run"
    print(f"capture_test_coverage mode={mode} commands={len(plan)}")
    for item in plan:
        suffix = f" reason={item.reason}" if item.reason else ""
        command = f" command={item.command!r}" if item.command else ""
        print(
            f"  {item.action} port={item.port} lifecycle={item.lifecycle_status} "
            f"kind={item.kind} key={item.command_key}{suffix}{command}"
        )


def output_tail(stdout: str, stderr: str, max_lines: int = 30) -> str:
    combined = "\n".join(part for part in (stdout.strip(), stderr.strip()) if part)
    lines = combined.splitlines()
    return "\n".join(lines[-max_lines:])


def parse_test_summary(output: str) -> dict[str, int]:
    summary: dict[str, int] = {}
    dotnet = re.search(
        r"Failed:\s*(?P<failed>\d+),\s*Passed:\s*(?P<passed>\d+),\s*Skipped:\s*(?P<skipped>\d+),\s*Total:\s*(?P<total>\d+)",
        output,
        re.IGNORECASE,
    )
    if dotnet:
        return {key: int(value) for key, value in dotnet.groupdict().items()}

    maven_matches = list(
        re.finditer(
            r"Tests run:\s*(?P<total>\d+),\s*Failures:\s*(?P<failed>\d+),\s*Errors:\s*(?P<errors>\d+),\s*Skipped:\s*(?P<skipped>\d+)",
            output,
            re.IGNORECASE,
        )
    )
    if maven_matches:
        total = sum(int(match.group("total")) for match in maven_matches)
        failed = sum(int(match.group("failed")) + int(match.group("errors")) for match in maven_matches)
        skipped = sum(int(match.group("skipped")) for match in maven_matches)
        return {"total": total, "passed": max(total - failed - skipped, 0), "failed": failed, "skipped": skipped}

    cargo = re.search(
        r"test result:\s*ok\.\s*(?P<passed>\d+)\s+passed;\s*(?P<failed>\d+)\s+failed;\s*(?P<ignored>\d+)\s+ignored",
        output,
        re.IGNORECASE,
    )
    if cargo:
        passed = int(cargo.group("passed"))
        failed = int(cargo.group("failed"))
        skipped = int(cargo.group("ignored"))
        return {"total": passed + failed + skipped, "passed": passed, "failed": failed, "skipped": skipped}

    ctest = re.search(r"(?P<passed>\d+)% tests passed,\s*(?P<failed>\d+) tests failed out of (?P<total>\d+)", output)
    if ctest:
        total = int(ctest.group("total"))
        failed = int(ctest.group("failed"))
        return {"total": total, "passed": max(total - failed, 0), "failed": failed, "skipped": 0}

    generic = re.search(r"(?P<passed>\d+)\s+passed", output, re.IGNORECASE)
    if generic:
        passed = int(generic.group("passed"))
        summary["passed"] = passed
        summary["total"] = passed
    return summary


def percent(value: str) -> float:
    return round(float(value.rstrip("%")), 2)


def parse_gcovr_text(output: str) -> dict[str, float | int]:
    metrics: dict[str, float | int] = {}
    total_line = ""
    for line in output.splitlines():
        if line.strip().startswith("TOTAL"):
            total_line = line.strip()
    if total_line:
        parts = total_line.split()
        percentages = [part for part in parts if part.endswith("%")]
        numbers = [int(part) for part in parts if part.isdigit()]
        if percentages:
            metrics["line_percent"] = percent(percentages[0])
        if len(percentages) > 1:
            metrics["branch_percent"] = percent(percentages[1])
        if len(numbers) >= 2:
            total_lines = numbers[0]
            missed_lines = numbers[1]
            metrics["total_lines"] = total_lines
            metrics["covered_lines"] = max(total_lines - missed_lines, 0)

    line_match = re.search(r"lines:\s*(?P<line>[0-9.]+)%", output, re.IGNORECASE)
    branch_match = re.search(r"branches:\s*(?P<branch>[0-9.]+)%", output, re.IGNORECASE)
    if line_match:
        metrics["line_percent"] = percent(line_match.group("line"))
    if branch_match:
        metrics["branch_percent"] = percent(branch_match.group("branch"))
    return metrics


def parse_jacoco_csv(path: Path) -> dict[str, float | int]:
    if not path.exists():
        return {}
    totals = {
        "LINE_MISSED": 0,
        "LINE_COVERED": 0,
        "BRANCH_MISSED": 0,
        "BRANCH_COVERED": 0,
        "METHOD_MISSED": 0,
        "METHOD_COVERED": 0,
        "INSTRUCTION_MISSED": 0,
        "INSTRUCTION_COVERED": 0,
    }
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            for key in totals:
                totals[key] += int(row.get(key) or 0)

    def pct(covered_key: str, missed_key: str) -> float | None:
        covered = totals[covered_key]
        missed = totals[missed_key]
        total = covered + missed
        if total <= 0:
            return None
        return round((covered / total) * 100, 2)

    metrics: dict[str, float | int] = {}
    line_percent = pct("LINE_COVERED", "LINE_MISSED")
    branch_percent = pct("BRANCH_COVERED", "BRANCH_MISSED")
    function_percent = pct("METHOD_COVERED", "METHOD_MISSED")
    statement_percent = pct("INSTRUCTION_COVERED", "INSTRUCTION_MISSED")
    if line_percent is not None:
        metrics["line_percent"] = line_percent
    if branch_percent is not None:
        metrics["branch_percent"] = branch_percent
    if function_percent is not None:
        metrics["function_percent"] = function_percent
    if statement_percent is not None:
        metrics["statement_percent"] = statement_percent
    if totals["LINE_COVERED"] + totals["LINE_MISSED"]:
        metrics["covered_lines"] = totals["LINE_COVERED"]
        metrics["total_lines"] = totals["LINE_COVERED"] + totals["LINE_MISSED"]
    return metrics


def coverage_tool_for(item: PlannedCommand) -> str:
    if item.port == "cpp":
        return "gcovr"
    if item.port == "java":
        return "jacoco"
    return "unknown"


def coverage_metrics_for(root: Path, item: PlannedCommand, output: str) -> dict[str, float | int]:
    if item.port == "cpp":
        return parse_gcovr_text(output)
    if item.port == "java":
        return parse_jacoco_csv(root / "Nodes/Java/target/site/jacoco/jacoco.csv")
    return {}


def run_shell(root: Path, command: str) -> tuple[int, int, str, str]:
    started = time.monotonic()
    completed = subprocess.run(command, cwd=root, shell=True, text=True, capture_output=True)
    duration_ms = int((time.monotonic() - started) * 1000)
    return completed.returncode, duration_ms, completed.stdout, completed.stderr


def result_path(results_dir: Path, port: str, command_key: str, captured_at: str) -> Path:
    safe_key = command_key.replace("test_", "")
    return results_dir / f"{port}_{safe_key}_{stamp_for_path(captured_at)}.json"


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def build_test_artifact(
    item: PlannedCommand,
    captured_at: str,
    exit_code: int,
    duration_ms: int,
    stdout: str,
    stderr: str,
) -> dict[str, Any]:
    combined = "\n".join(part for part in (stdout, stderr) if part)
    summary = parse_test_summary(combined)
    payload: dict[str, Any] = {
        "schema": "port.test_result",
        "category": "test",
        "port": item.port,
        "node_id": item.node_id,
        "lifecycle_status": item.lifecycle_status,
        "command_key": item.command_key,
        "command": item.command,
        "result": "passed" if exit_code == 0 else "failed",
        "exit_code": exit_code,
        "captured_at": captured_at,
        "duration_ms": duration_ms,
        "summary": output_tail(stdout, stderr),
    }
    payload.update(summary)
    return payload


def build_coverage_artifact(
    root: Path,
    item: PlannedCommand,
    captured_at: str,
    exit_code: int,
    duration_ms: int,
    stdout: str,
    stderr: str,
) -> dict[str, Any]:
    combined = "\n".join(part for part in (stdout, stderr) if part)
    metrics = coverage_metrics_for(root, item, combined)
    payload: dict[str, Any] = {
        "schema": "port.coverage_summary",
        "category": "coverage",
        "port": item.port,
        "node_id": item.node_id,
        "lifecycle_status": item.lifecycle_status,
        "command_key": item.command_key,
        "command": item.command,
        "tool": coverage_tool_for(item),
        "result": "passed" if exit_code == 0 else "failed",
        "exit_code": exit_code,
        "captured_at": captured_at,
        "duration_ms": duration_ms,
        "metrics": metrics,
        "summary": output_tail(stdout, stderr),
    }
    payload.update(metrics)
    return payload


def execute_plan(root: Path, results_dir: Path, plan: list[PlannedCommand]) -> int:
    failures = 0
    for item in plan:
        if item.action != "run":
            print(f"skip port={item.port} key={item.command_key} reason={item.reason}")
            continue
        print(f"run port={item.port} key={item.command_key}")
        captured_at = utc_now()
        exit_code, duration_ms, stdout, stderr = run_shell(root, item.command)
        artifact = (
            build_test_artifact(item, captured_at, exit_code, duration_ms, stdout, stderr)
            if item.kind == "test"
            else build_coverage_artifact(root, item, captured_at, exit_code, duration_ms, stdout, stderr)
        )
        path = result_path(results_dir, item.port, item.command_key, captured_at)
        write_json(path, artifact)
        print(f"  wrote {path.relative_to(root)} result={artifact['result']} duration_ms={duration_ms}")
        if exit_code != 0:
            failures += 1
    return 1 if failures else 0


def self_test() -> int:
    dotnet = "Passed!  - Failed: 0, Passed: 41, Skipped: 2, Total: 43"
    assert parse_test_summary(dotnet) == {"failed": 0, "passed": 41, "skipped": 2, "total": 43}

    maven = "[INFO] Tests run: 3, Failures: 1, Errors: 0, Skipped: 1"
    assert parse_test_summary(maven) == {"total": 3, "passed": 1, "failed": 1, "skipped": 1}

    gcovr = "TOTAL                         100   20    80%       50    10    80%"
    parsed_gcovr = parse_gcovr_text(gcovr)
    assert parsed_gcovr["line_percent"] == 80.0
    assert parsed_gcovr["branch_percent"] == 80.0
    assert parsed_gcovr["covered_lines"] == 80
    assert parsed_gcovr["total_lines"] == 100

    with tempfile.TemporaryDirectory() as tmp:
        csv_path = Path(tmp) / "jacoco.csv"
        csv_path.write_text(
            "GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED\n"
            "g,p,C,25,75,4,6,2,8,0,0,1,9\n",
            encoding="utf-8",
        )
        parsed_jacoco = parse_jacoco_csv(csv_path)
        assert parsed_jacoco["line_percent"] == 80.0
        assert parsed_jacoco["branch_percent"] == 60.0
        assert parsed_jacoco["function_percent"] == 90.0
        assert parsed_jacoco["statement_percent"] == 75.0

    item = PlannedCommand("go", "go", "active_contender", "test_unit", "cd Nodes/Go && make test", "test", "run", "")
    artifact = build_test_artifact(item, "2026-06-06T00:00:00Z", 0, 12, "7 passed", "")
    assert artifact["schema"] == "port.test_result"
    assert artifact["result"] == "passed"
    assert artifact["port"] == "go"
    print("capture_test_coverage self-test passed")
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    root = repo_root()
    db_path = root / args.db
    with connect(db_path) as conn:
        by_port = load_command_surface(conn)
    selected_ports = select_ports(by_port, args.port, args.all)
    run_requested = bool(args.run)
    plan = build_plan(
        by_port,
        selected_ports,
        explicit_port=bool(args.port),
        run_requested=run_requested,
        include_coverage=bool(args.include_coverage),
    )
    print_plan(plan, run_requested)
    if not run_requested:
        return 0
    results_dir = root / args.results_dir
    return execute_plan(root, results_dir, plan)


if __name__ == "__main__":
    raise SystemExit(main())
