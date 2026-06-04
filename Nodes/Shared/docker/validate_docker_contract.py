#!/usr/bin/env python3
"""Report-only validator for Shared Docker contract manifests."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def repo_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / "Nodes" / "Shared").exists() and (parent / "Project").exists():
            return parent
    raise SystemExit("could not locate repository root")


ROOT = repo_root()
PORTS_DIR = Path(__file__).resolve().parent / "ports"

REQUIRED_TOP_LEVEL = {
    "manifest_version",
    "port",
    "status",
    "paths",
    "images",
    "volumes",
    "commands",
    "peer_modes",
    "supervisor",
    "tick_json",
    "proof_artifacts",
    "known_caveats",
}

VALID_STATUSES = {
    "missing",
    "daemon_only",
    "proof_partial",
    "supervisor_partial",
    "contract_passed",
    "non_compliant",
}

STANDARD_COMMANDS = [
    "docker_config",
    "docker_build",
    "docker_status",
    "docker_proof_local",
    "docker_probe_external",
    "docker_supervisor",
    "docker_supervisor_status",
    "docker_supervisor_stop",
    "docker_supervisor_resume",
    "docker_smoke_once",
]

PEER_MODES = ["local_reference", "external_manual", "external_seed"]

TICK_FIELDS = [
    "phase",
    "runtime_surface",
    "peer_mode",
    "peer",
    "validated_height",
    "header_height",
    "stored_block_height",
    "sync_status",
    "delta_since_last",
    "process_running",
    "current_blocker",
]


def rel_exists(path_value: str | None) -> bool:
    if path_value is None:
        return False
    return (ROOT / path_value).exists()


def add_issue(issues: list[dict[str, str]], severity: str, message: str) -> None:
    issues.append({"severity": severity, "message": message})


def validate_manifest(path: Path, *, strict: bool = False) -> dict[str, Any]:
    data = json.loads(path.read_text())
    issues: list[dict[str, str]] = []
    port = data.get("port", path.stem)
    status = data.get("status")
    layout_severity = "error" if strict else "warning"

    missing = sorted(REQUIRED_TOP_LEVEL - set(data))
    for key in missing:
        add_issue(issues, "error", f"missing top-level field: {key}")

    if data.get("manifest_version") != 1:
        add_issue(issues, "error", "manifest_version must be 1")
    if status not in VALID_STATUSES:
        add_issue(issues, "error", f"invalid status: {status}")

    paths = data.get("paths", {})
    commands = data.get("commands", {})
    volumes = data.get("volumes", {})
    peer_modes = data.get("peer_modes", {})
    supervisor = data.get("supervisor", {})
    tick_fields = data.get("tick_json", {}).get("required_fields", [])

    root_path = paths.get("root")
    if root_path and not rel_exists(root_path):
        add_issue(issues, "error", f"root path does not exist: {root_path}")

    dockerfile = paths.get("dockerfile")
    compose = paths.get("compose")
    dockerignore = paths.get("dockerignore")

    if status != "missing":
        if not dockerfile and port != "reference":
            add_issue(issues, "error", "dockerfile is required for Docker-capable ports")
        if dockerfile and not rel_exists(dockerfile):
            add_issue(issues, "error", f"dockerfile does not exist: {dockerfile}")
        if dockerfile and "/docker/" not in dockerfile:
            add_issue(issues, layout_severity, f"dockerfile should use standard docker/ layout: {dockerfile}")
        if not compose:
            add_issue(issues, "error", "compose path is required for Docker-capable ports")
        if compose and not rel_exists(compose):
            add_issue(issues, "error", f"compose path does not exist: {compose}")
        if compose and "/docker/" not in compose:
            add_issue(issues, layout_severity, f"compose should use standard docker/ layout: {compose}")
        if port != "reference" and not dockerignore:
            add_issue(issues, "warning", ".dockerignore is missing or not declared")
        if dockerignore and not rel_exists(dockerignore):
            add_issue(issues, "warning", f".dockerignore path does not exist: {dockerignore}")
        if dockerignore and "/docker/" not in dockerignore:
            add_issue(issues, layout_severity, f".dockerignore should use standard docker/ layout: {dockerignore}")

    for command_name in STANDARD_COMMANDS:
        if command_name not in commands:
            add_issue(issues, "error", f"missing command declaration: {command_name}")

    if status in {"proof_partial", "supervisor_partial", "contract_passed"}:
        if not commands.get("docker_proof_local"):
            add_issue(issues, "error", "proof-capable status requires docker_proof_local")
        if not volumes.get("proof"):
            add_issue(issues, "error", "proof-capable status requires proof volume")

    if status in {"supervisor_partial", "contract_passed"}:
        for name in [
            "docker_supervisor",
            "docker_supervisor_status",
            "docker_supervisor_stop",
            "docker_supervisor_resume",
        ]:
            if not commands.get(name):
                add_issue(issues, "error", f"supervisor-capable status requires {name}")
        if not volumes.get("supervisor"):
            add_issue(issues, "error", "supervisor-capable status requires supervisor volume")
        if not supervisor.get("stop_marker") or not supervisor.get("resume_marker"):
            add_issue(issues, "error", "supervisor status requires stop/resume markers")

    if status == "contract_passed":
        for name in STANDARD_COMMANDS:
            if not commands.get(name):
                add_issue(issues, "error", f"contract_passed requires command: {name}")
        if len({volumes.get("data"), volumes.get("proof"), volumes.get("supervisor")} - {None}) < 3:
            add_issue(issues, "error", "contract_passed requires distinct data/proof/supervisor volumes")

    volume_values = [value for value in volumes.values() if value]
    if len(volume_values) != len(set(volume_values)):
        add_issue(issues, "error", "volume roles must not reuse the same volume name")

    for mode in PEER_MODES:
        peer = peer_modes.get(mode)
        if peer is None:
            add_issue(issues, "error", f"missing peer mode: {mode}")
            continue
        if peer.get("supported") and not peer.get("command"):
            add_issue(issues, "error", f"supported peer mode {mode} requires a command")
        if peer.get("supported") and not peer.get("peer"):
            add_issue(issues, "error", f"supported peer mode {mode} requires peer description")

    missing_tick = [field for field in TICK_FIELDS if field not in tick_fields]
    for field in missing_tick:
        add_issue(issues, "error", f"missing tick JSON field: {field}")

    errors = sum(1 for issue in issues if issue["severity"] == "error")
    warnings = sum(1 for issue in issues if issue["severity"] == "warning")
    return {
        "manifest": str(path.relative_to(ROOT)),
        "port": port,
        "status": status,
        "errors": errors,
        "warnings": warnings,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit JSON only")
    parser.add_argument("--ports-dir", default=str(PORTS_DIR), help="manifest directory")
    parser.add_argument("--strict", action="store_true", help="exit nonzero on errors and enforce layout as errors")
    args = parser.parse_args()

    ports_dir = Path(args.ports_dir)
    results = [validate_manifest(path, strict=args.strict) for path in sorted(ports_dir.glob("*.docker.json"))]
    summary = {
        "manifest_count": len(results),
        "error_count": sum(result["errors"] for result in results),
        "warning_count": sum(result["warnings"] for result in results),
        "results": results,
    }

    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(
            f"docker_contract_report manifests={summary['manifest_count']} "
            f"errors={summary['error_count']} warnings={summary['warning_count']}"
        )
        for result in results:
            print(
                f"- {result['port']}: status={result['status']} "
                f"errors={result['errors']} warnings={result['warnings']}"
            )
            for issue in result["issues"]:
                print(f"  {issue['severity']}: {issue['message']}")

    if args.strict and summary["error_count"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
