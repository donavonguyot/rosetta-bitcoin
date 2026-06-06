#!/usr/bin/env python3
"""Run official benchmark gates as a serialized Project campaign.

The runner is intentionally boring: one port at a time, no hidden parallelism,
and current evidence is updated only after a fresh artifact passes validation.
Dry-run is the default.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
RESULTS_DIR = ROOT / "Nodes/Shared/conformance/results"
CURRENT_EVIDENCE = ROOT / "Nodes/Shared/conformance/current_evidence.json"
REFERENCE_TOPOLOGY = ROOT / "Nodes/Shared/docker/reference_topology.env"
TELEMETRY_PREFIX = "benchmark.telemetry_tick "

SUPPORTED_GATES = ("baseline_5k", "shakedown_50k", "performance_100k")
GATE_CLAIMS = {
    "baseline_5k": "baseline_5k",
    "shakedown_50k": "shakedown_50k",
    "performance_100k": "performance_100k",
}
EXPECTED_HASHES = {
    "baseline_5k": "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2",
    "shakedown_50k": "00000000e2c8c94ba126169a88997233f07a9769e2b009fb10cad0e893eff2cb",
    "performance_100k": "0000000000524911745ab6eee9348bca9843c2c2b1b27eada246e3dc2f80b6b1",
}
REQUIRED_FIELDS = (
    "implementation",
    "runtime_surface",
    "benchmark_contract_version",
    "benchmark_lane",
    "benchmark_kind",
    "target_height",
    "target_label",
    "header_target_height",
    "byte_source",
    "validated_height",
    "validated_hash",
    "current_blocker",
    "binary_gate_status",
    "chainstate_backend",
    "chainstate_utxo_count",
    "utxo_accounting_policy",
    "native_crypto_backend",
    "proof_mode",
    "peer_mode",
    "peer",
    "script_runner_mode",
    "rocksdb_wal_disabled",
    "prefetch_depth",
    "resume_supported",
    "fresh_state",
    "result",
    "failures",
)
REQUIRED_BUCKETS = (
    "p2p_fetch",
    "block_parse_validate",
    "utxo_load",
    "script_verify",
    "utxo_apply",
    "commit",
    "block_connect_store_commit",
)
LONG_RUN_GATES = {"shakedown_50k", "performance_100k"}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project mission-control DB path")
    parser.add_argument("--gate", default="shakedown_50k", choices=SUPPORTED_GATES)
    parser.add_argument("--ports", help="Comma-separated port list")
    parser.add_argument("--all", action="store_true", help="Use all eligible non-reference ports")
    parser.add_argument("--campaign", type=Path, help="Existing campaign state path for --resume")
    parser.add_argument("--resume", action="store_true", help="Resume a paused campaign")
    parser.add_argument("--run", action="store_true", help="Execute commands; dry-run is the default")
    parser.add_argument("--dry-run", action="store_true", help="Print the plan without executing commands")
    parser.add_argument("--pause-on", choices=("anomaly", "failure", "never"), default="anomaly")
    parser.add_argument("--current-evidence", default=str(CURRENT_EVIDENCE))
    parser.add_argument("--results-dir", default=str(RESULTS_DIR))
    parser.add_argument("--self-test", action="store_true", help="Run campaign runner self-tests")
    return parser.parse_args()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def connect(db_path: str) -> sqlite3.Connection:
    db = ROOT / db_path if not Path(db_path).is_absolute() else Path(db_path)
    if not db.exists():
        raise SystemExit(f"Project DB not found: {db}")
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    return conn


def rows(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    return [dict(row) for row in conn.execute(sql, params).fetchall()]


def one(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> dict[str, Any] | None:
    row = conn.execute(sql, params).fetchone()
    return dict(row) if row else None


def rel(path: Path) -> str:
    return str(path.resolve().relative_to(ROOT))


def as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


def falseish(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, bool):
        return not value
    if isinstance(value, int):
        return value == 0
    if isinstance(value, str):
        return value.strip().lower() in {"", "0", "false", "no", "off", "null"}
    return False


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def command_for(conn: sqlite3.Connection, port: str, command_key: str) -> str:
    row = one(
        conn,
        """
        SELECT supported, command
        FROM port_command_surface
        WHERE port = ? AND command_key = ?
        """,
        (port, command_key),
    )
    if not row or not as_bool(row["supported"]) or not str(row["command"]).strip():
        return ""
    return str(row["command"]).strip()


def gate_row(conn: sqlite3.Connection, gate: str) -> dict[str, Any]:
    row = one(conn, "SELECT * FROM benchmark_gates WHERE gate_id = ?", (gate,))
    if row is None:
        raise SystemExit(f"missing benchmark gate: {gate}")
    return row


def all_ports(conn: sqlite3.Connection, gate: str) -> list[str]:
    data = rows(
        conn,
        """
        SELECT dc.port,
               coalesce(pl.lifecycle_status, 'active_contender') AS lifecycle_status
        FROM docker_contracts dc
        LEFT JOIN port_lifecycle pl ON pl.port = dc.port
        WHERE dc.port <> 'reference'
        ORDER BY dc.port
        """,
    )
    ports: list[str] = []
    for row in data:
        if gate != "baseline_5k" and row["lifecycle_status"] == "baseline_retired":
            continue
        ports.append(row["port"])
    return ports


def requested_ports(conn: sqlite3.Connection, args: argparse.Namespace) -> list[str]:
    if args.resume:
        return []
    if args.ports:
        return [port.strip().lower() for port in args.ports.split(",") if port.strip()]
    if args.all:
        return all_ports(conn, args.gate)
    raise SystemExit("choose --all, --ports, or --resume")


def latest_prior_total_ms(conn: sqlite3.Connection, gate: str, port: str) -> float | None:
    row = one(
        conn,
        """
        SELECT total_ms
        FROM benchmark_comparability
        WHERE gate_id = ? AND port = ? AND total_ms > 0
        ORDER BY CASE comparability_status
                   WHEN 'comparable' THEN 0
                   WHEN 'evidence_only' THEN 1
                   WHEN 'diagnostic' THEN 2
                   ELSE 3
                 END,
                 captured_at DESC,
                 source_artifact_id
        LIMIT 1
        """,
        (gate, port),
    )
    return float(row["total_ms"]) if row else None


def initial_campaign(conn: sqlite3.Connection, args: argparse.Namespace) -> dict[str, Any]:
    gate = gate_row(conn, args.gate)
    proof_key = str(gate["preferred_command_key"])
    ports = requested_ports(conn, args)
    campaign_id = f"{args.gate}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    entries: list[dict[str, Any]] = []
    for port in ports:
        warm = command_for(conn, port, "docker_warm")
        proof = command_for(conn, port, proof_key)
        lifecycle = one(
            conn,
            "SELECT lifecycle_status, benchmark_scope FROM port_lifecycle WHERE port = ?",
            (port,),
        ) or {}
        status = "pending"
        reason = ""
        if not warm:
            status = "not_ready"
            reason = "missing supported docker_warm command"
        elif not proof:
            status = "not_ready"
            reason = f"missing supported {proof_key} command"
        entries.append(
            {
                "port": port,
                "lifecycle_status": lifecycle.get("lifecycle_status", "active_contender"),
                "benchmark_scope": lifecycle.get("benchmark_scope", "full_suite"),
                "status": status,
                "reason": reason,
                "warm_command": warm,
                "proof_command": proof,
                "prior_total_ms": latest_prior_total_ms(conn, args.gate, port),
                "artifact_path": "",
                "started_at": "",
                "finished_at": "",
                "exit_code": None,
                "warnings": [],
                "errors": [],
            }
        )
    return {
        "schema": "rb.benchmark_campaign.v1",
        "campaign_id": campaign_id,
        "created_at": utc_now(),
        "updated_at": utc_now(),
        "gate": args.gate,
        "run_mode": "run" if args.run else "dry_run",
        "pause_on": args.pause_on,
        "db": args.db,
        "current_evidence": str(args.current_evidence),
        "results_dir": str(args.results_dir),
        "ports": entries,
        "events": [],
    }


def campaign_dir(campaign: dict[str, Any]) -> Path:
    return ROOT / "Project/.campaigns" / str(campaign["campaign_id"])


def save_campaign(campaign: dict[str, Any]) -> Path:
    campaign["updated_at"] = utc_now()
    path = campaign_dir(campaign) / "state.json"
    write_json(path, campaign)
    return path


def load_campaign(path: Path) -> dict[str, Any]:
    payload = read_json(path if path.is_absolute() else ROOT / path)
    if payload.get("schema") != "rb.benchmark_campaign.v1":
        raise SystemExit(f"{path} is not an rb.benchmark_campaign.v1 state file")
    return payload


def run_preflight(db: str, gate: str, port: str) -> tuple[int, str]:
    cmd = [
        sys.executable,
        "Project/scripts/preflight_benchmark_gate.py",
        "--db",
        db,
        "--gate",
        gate,
        "--port",
        port,
        "--json",
    ]
    completed = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return completed.returncode, completed.stdout + completed.stderr


def ms_duration(ms: float | None) -> str:
    if ms is None:
        return "?"
    seconds = int(ms // 1000)
    minutes, seconds = divmod(seconds, 60)
    if minutes:
        return f"{minutes}m{seconds:02d}s"
    return f"{seconds}s"


def num(value: Any, default: float = 0.0) -> float:
    return float(value) if isinstance(value, (int, float)) else default


def fmt_tick(tick: dict[str, Any]) -> str:
    buckets = tick.get("timing_buckets_ms")
    if not isinstance(buckets, dict):
        buckets = {}
    blocker = "present" if tick.get("current_blocker") else "null"
    return (
        f"[{tick.get('port', '?')} {tick.get('gate', '?')}] "
        f"{tick.get('height', '?')}/{tick.get('target_height', '?')} "
        f"{num(tick.get('percent')):.1f}% "
        f"elapsed={ms_duration(num(tick.get('elapsed_ms')))} "
        f"rate={num(tick.get('rate_recent_blocks_per_second')):.1f}/"
        f"{num(tick.get('rate_total_blocks_per_second')):.1f} blocks/s "
        f"phase={tick.get('phase', '?')} "
        f"utxos={tick.get('utxos', '?')} "
        f"last={tick.get('last_block_ms', '?')}ms "
        f"p2p={buckets.get('p2p_fetch', 0)}ms "
        f"script={buckets.get('script_verify', 0)}ms "
        f"commit={buckets.get('commit', 0)}ms "
        f"connect={buckets.get('block_connect_store_commit', 0)}ms "
        f"blocker={blocker}"
    )


def should_emit_tick(tick: dict[str, Any], last: dict[str, Any] | None) -> bool:
    if last is None:
        return True
    if tick.get("current_blocker") or tick.get("phase") == "complete":
        return True
    height_delta = int(num(tick.get("height"))) - int(num(last.get("height")))
    elapsed_delta = int(num(tick.get("elapsed_ms"))) - int(num(last.get("elapsed_ms")))
    return height_delta >= 2500 or elapsed_delta >= 15_000


def parse_tick(line: str) -> dict[str, Any] | None:
    marker = line.find(TELEMETRY_PREFIX)
    if marker < 0:
        return None
    try:
        tick = json.loads(line[marker + len(TELEMETRY_PREFIX) :].strip())
    except json.JSONDecodeError:
        return None
    return tick if isinstance(tick, dict) and tick.get("schema") == "benchmark.telemetry_tick.v1" else None


def run_shell(command: str, log_path: Path) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    last_tick: dict[str, Any] | None = None
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            log.write(line)
            log.flush()
            tick = parse_tick(line)
            if tick and should_emit_tick(tick, last_tick):
                print(fmt_tick(tick), flush=True)
                last_tick = tick
        return process.wait()


def stage_totals(payload: dict[str, Any]) -> dict[str, float]:
    for key in ("timing_summary", "sync_timing"):
        candidate = payload.get(key)
        if isinstance(candidate, dict):
            totals = candidate.get("stage_totals_ms")
            if isinstance(totals, dict):
                return {k: num(v) for k, v in totals.items()}
    pipeline = payload.get("pipeline_timing_summary")
    if isinstance(pipeline, dict):
        totals = pipeline.get("stage_totals_ms")
        if isinstance(totals, dict):
            return {k: num(v) for k, v in totals.items()}
        return {k: num(v) for k, v in pipeline.items() if isinstance(v, (int, float))}
    return {}


def total_ms(payload: dict[str, Any]) -> float | None:
    for key_path in (
        ("timing_summary", "total_ms"),
        ("sync_timing", "total_ms"),
        ("pipeline_timing_summary", "total_ms"),
        ("canonical_timing_summary", "total_ms"),
    ):
        container = payload.get(key_path[0])
        if isinstance(container, dict) and isinstance(container.get(key_path[1]), (int, float)):
            return float(container[key_path[1]])
    for key in ("elapsed_ms", "total_wall_ms", "duration_ms"):
        if isinstance(payload.get(key), (int, float)):
            return float(payload[key])
    return None


def is_port_artifact(path: Path, payload: dict[str, Any], port: str) -> bool:
    lowered = path.name.lower()
    if lowered.startswith(f"{port}_") or lowered.startswith(f"{port}-"):
        return True
    marker = str(payload.get("port") or payload.get("implementation") or "").lower()
    return port in marker


def validate_artifact(
    path: Path,
    payload: dict[str, Any],
    gate: dict[str, Any],
    port: str,
    expected_peer: str,
) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    for field in REQUIRED_FIELDS:
        if field not in payload:
            errors.append(f"missing required field {field}")
    if not is_port_artifact(path, payload, port):
        errors.append(f"artifact does not look port-owned by {port}")
    checks = {
        "result": "passed",
        "runtime_surface": "docker",
        "benchmark_lane": gate["official_lane"],
        "benchmark_kind": gate["benchmark_kind"],
        "target_height": gate["target_height"],
        "target_label": gate["target_label"],
        "header_target_height": gate["official_header_target_height"],
        "byte_source": gate["official_byte_source"],
        "validated_height": gate["target_height"],
        "validated_hash": EXPECTED_HASHES[str(gate["gate_id"])],
        "binary_gate_status": gate["binary_gate_status"],
        "chainstate_backend": "rocksdb",
        "chainstate_utxo_count": gate["official_chainstate_utxo_count"],
        "utxo_accounting_policy": gate["official_utxo_accounting_policy"],
        "proof_mode": gate["official_proof_mode"],
        "peer_mode": gate["official_peer_mode"],
        "peer": expected_peer,
        "script_runner_mode": gate["official_script_runner_mode"],
        "prefetch_depth": gate["official_prefetch_depth"],
    }
    for key, expected in checks.items():
        if payload.get(key) != expected:
            errors.append(f"{key}={payload.get(key)!r}; expected {expected!r}")
    if payload.get("current_blocker") not in (None, "", False):
        errors.append(f"current_blocker must be null/empty; got {payload.get('current_blocker')!r}")
    if payload.get("failures") not in (None, [], {}, 0):
        errors.append(f"failures must be empty; got {payload.get('failures')!r}")
    if not falseish(payload.get("rocksdb_wal_disabled")):
        errors.append(f"rocksdb_wal_disabled={payload.get('rocksdb_wal_disabled')!r}; expected false")
    if not as_bool(payload.get("fresh_state")):
        errors.append(f"fresh_state={payload.get('fresh_state')!r}; expected true")
    if not as_bool(payload.get("resume_supported")):
        errors.append(f"resume_supported={payload.get('resume_supported')!r}; expected true")
    if not str(payload.get("native_crypto_backend") or "").strip():
        errors.append("native_crypto_backend must be present")
    totals = stage_totals(payload)
    for bucket in REQUIRED_BUCKETS:
        if bucket not in totals:
            errors.append(f"missing timing bucket {bucket}")
    gate_id = str(gate["gate_id"])
    if gate_id in LONG_RUN_GATES and payload.get("telemetry_schema") != "benchmark.telemetry_tick.v1":
        errors.append("long-run artifact must report telemetry_schema=benchmark.telemetry_tick.v1")
    if gate_id in LONG_RUN_GATES and "slow_blocks" not in json.dumps(payload):
        warnings.append("long-run artifact has no slow_blocks summary")
    return errors, warnings


def candidate_artifacts(results_dir: Path, started_at: float, port: str, gate: dict[str, Any]) -> list[Path]:
    candidates: list[Path] = []
    for path in sorted(results_dir.glob("*.json")):
        try:
            if path.stat().st_mtime < started_at - 1:
                continue
            payload = read_json(path)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(payload, dict) and is_port_artifact(path, payload, port):
            if payload.get("target_height") == gate["target_height"] or payload.get("benchmark_lane") == gate["official_lane"]:
                candidates.append(path)
    return candidates


def classify_anomaly(payload: dict[str, Any], prior_total: float | None) -> tuple[str, list[str]]:
    messages: list[str] = []
    current_total = total_ms(payload)
    totals = stage_totals(payload)
    p2p_fetch = totals.get("p2p_fetch")
    if current_total and p2p_fetch and p2p_fetch > 15_000 and p2p_fetch > current_total * 0.35:
        messages.append(
            f"hard anomaly: p2p_fetch {p2p_fetch:.0f}ms is more than 35% of total {current_total:.0f}ms"
        )
    if current_total and prior_total:
        delta = current_total - prior_total
        if current_total > prior_total * 2.0 and delta > 30_000:
            messages.append(
                f"hard anomaly: total {current_total:.0f}ms is >2.0x prior {prior_total:.0f}ms"
            )
        elif current_total > prior_total * 1.25 and delta > 10_000:
            messages.append(
                f"soft anomaly: total {current_total:.0f}ms is >1.25x prior {prior_total:.0f}ms"
            )
    if any(message.startswith("hard") for message in messages):
        return "hard", messages
    if messages:
        return "soft", messages
    return "none", []


def update_current_evidence(path: Path, port: str, gate_id: str, artifact_path: str, note: str) -> None:
    payload = read_json(path)
    entries = payload.get("entries")
    if not isinstance(entries, list):
        raise SystemExit(f"{path} must contain entries[]")
    claim = GATE_CLAIMS[gate_id]
    for entry in entries:
        if entry.get("port") == port and entry.get("claim") == claim and entry.get("gate_id") == gate_id:
            entry["path"] = artifact_path
            entry["status"] = "current"
            entry["notes"] = note
            break
    else:
        entries.append(
            {
                "port": port,
                "claim": claim,
                "gate_id": gate_id,
                "path": artifact_path,
                "status": "current",
                "notes": note,
            }
        )
    write_json(path, payload)


def rebuild_project(db: str) -> int:
    return subprocess.run(
        [sys.executable, "Project/scripts/import_all.py", "--db", db, "--rebuild"],
        cwd=ROOT,
    ).returncode


def verify_project_gate(db: str, gate: str, port: str) -> int:
    return subprocess.run(
        [
            sys.executable,
            "Project/scripts/preflight_benchmark_gate.py",
            "--db",
            db,
            "--gate",
            gate,
            "--port",
            port,
        ],
        cwd=ROOT,
    ).returncode


def append_event(campaign: dict[str, Any], port: str, event: str, detail: str = "") -> None:
    campaign.setdefault("events", []).append(
        {"at": utc_now(), "port": port, "event": event, "detail": detail}
    )


def print_dry_run(campaign: dict[str, Any]) -> None:
    print(f"campaign_dry_run id={campaign['campaign_id']} gate={campaign['gate']}")
    for entry in campaign["ports"]:
        status = entry["status"]
        reason = f" reason={entry['reason']}" if entry["reason"] else ""
        print(f"- {entry['port']}: {status}{reason}")
        if entry["warm_command"]:
            print(f"  warm: {entry['warm_command']}")
        if entry["proof_command"]:
            print(f"  proof: {entry['proof_command']}")
        if entry["prior_total_ms"] is not None:
            print(f"  prior_total_ms: {entry['prior_total_ms']}")


def execute_campaign(campaign: dict[str, Any]) -> int:
    conn = connect(campaign["db"])
    gate = gate_row(conn, campaign["gate"])
    expected_peer = read_env(REFERENCE_TOPOLOGY).get("REFERENCE_P2P_PEER", "")
    if not expected_peer:
        raise SystemExit("missing REFERENCE_P2P_PEER in Nodes/Shared/docker/reference_topology.env")
    state_path = save_campaign(campaign)
    print(f"campaign_state={rel(state_path)}")
    for entry in campaign["ports"]:
        port = entry["port"]
        if entry["status"] in {"accepted", "not_ready", "skipped"}:
            continue
        if entry["status"] not in {"pending", "preflighted", "warming", "running"}:
            continue
        preflight_code, preflight_output = run_preflight(campaign["db"], campaign["gate"], port)
        preflight_log = campaign_dir(campaign) / "logs" / f"{port}_preflight.log"
        preflight_log.parent.mkdir(parents=True, exist_ok=True)
        preflight_log.write_text(preflight_output, encoding="utf-8")
        if preflight_code != 0:
            entry["status"] = "failed"
            entry["errors"].append(f"preflight failed; see {rel(preflight_log)}")
            append_event(campaign, port, "preflight_failed", rel(preflight_log))
            save_campaign(campaign)
            print(f"campaign_paused port={port} reason=preflight_failed")
            return 1
        entry["status"] = "preflighted"
        save_campaign(campaign)

        print(f"campaign_port_start port={port} gate={campaign['gate']}")
        warm_log = campaign_dir(campaign) / "logs" / f"{port}_warm.log"
        warm_code = run_shell(entry["warm_command"], warm_log)
        if warm_code != 0:
            entry["status"] = "failed"
            entry["exit_code"] = warm_code
            entry["errors"].append(f"warm failed; see {rel(warm_log)}")
            append_event(campaign, port, "warm_failed", rel(warm_log))
            save_campaign(campaign)
            print(f"campaign_paused port={port} reason=warm_failed")
            return 1

        started = time.time()
        entry["started_at"] = utc_now()
        entry["status"] = "running"
        save_campaign(campaign)
        proof_log = campaign_dir(campaign) / "logs" / f"{port}_proof.log"
        exit_code = run_shell(entry["proof_command"], proof_log)
        entry["finished_at"] = utc_now()
        entry["exit_code"] = exit_code
        if exit_code != 0:
            entry["status"] = "failed"
            entry["errors"].append(f"proof failed; see {rel(proof_log)}")
            append_event(campaign, port, "proof_failed", rel(proof_log))
            save_campaign(campaign)
            print(f"campaign_paused port={port} reason=proof_failed")
            return 1

        candidates = candidate_artifacts(Path(campaign["results_dir"]), started, port, gate)
        if len(candidates) != 1:
            entry["status"] = "failed"
            entry["errors"].append(
                f"artifact selection expected 1 candidate, found {len(candidates)}: "
                + ", ".join(rel(path) for path in candidates)
            )
            append_event(campaign, port, "artifact_selection_failed", entry["errors"][-1])
            save_campaign(campaign)
            print(f"campaign_paused port={port} reason=artifact_selection_failed")
            return 1

        artifact_path = candidates[0]
        payload = read_json(artifact_path)
        if not isinstance(payload, dict):
            entry["status"] = "failed"
            entry["errors"].append(f"artifact must be a JSON object: {rel(artifact_path)}")
            save_campaign(campaign)
            return 1
        errors, warnings = validate_artifact(artifact_path, payload, gate, port, expected_peer)
        anomaly, anomaly_messages = classify_anomaly(payload, entry.get("prior_total_ms"))
        warnings.extend(anomaly_messages)
        entry["warnings"].extend(warnings)
        if errors:
            entry["status"] = "rejected"
            entry["errors"].extend(errors)
            save_campaign(campaign)
            print(f"campaign_paused port={port} reason=artifact_rejected")
            return 1
        if anomaly == "hard" and campaign["pause_on"] in {"anomaly", "failure"}:
            entry["status"] = "rejected"
            entry["errors"].extend(anomaly_messages)
            save_campaign(campaign)
            print(f"campaign_paused port={port} reason=hard_anomaly")
            return 1
        if anomaly == "soft" and campaign["pause_on"] == "anomaly":
            entry["status"] = "paused"
            save_campaign(campaign)
            print(f"campaign_paused port={port} reason=soft_anomaly")
            return 1

        artifact_rel = rel(artifact_path)
        note = f"Current comparable {port} {campaign['gate']} proof accepted by campaign {campaign['campaign_id']}."
        current_evidence_path = ROOT / campaign["current_evidence"]
        original_current_evidence = current_evidence_path.read_text(encoding="utf-8")
        update_current_evidence(current_evidence_path, port, campaign["gate"], artifact_rel, note)
        if rebuild_project(campaign["db"]) != 0 or verify_project_gate(campaign["db"], campaign["gate"], port) != 0:
            current_evidence_path.write_text(original_current_evidence, encoding="utf-8")
            rebuild_project(campaign["db"])
            entry["status"] = "failed"
            entry["errors"].append("Project import/preflight failed after evidence update")
            save_campaign(campaign)
            print(f"campaign_paused port={port} reason=project_verification_failed")
            return 1
        entry["status"] = "accepted"
        entry["artifact_path"] = artifact_rel
        append_event(campaign, port, "accepted", artifact_rel)
        save_campaign(campaign)
        print(
            f"campaign_port_accepted port={port} artifact={artifact_rel} "
            f"total_ms={total_ms(payload) if total_ms(payload) is not None else '?'}"
        )
    summary_path = campaign_dir(campaign) / "summary.json"
    write_json(summary_path, campaign)
    print(f"campaign_complete summary={rel(summary_path)}")
    return 0


def self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        evidence = tmp_path / "current_evidence.json"
        write_json(
            evidence,
            {
                "schema": "rb.current_evidence.v1",
                "generated_at": "2026-06-06",
                "entries": [
                    {
                        "port": "rust",
                        "claim": "shakedown_50k",
                        "gate_id": "shakedown_50k",
                        "path": "old.json",
                        "status": "current",
                        "notes": "old",
                    }
                ],
            },
        )
        update_current_evidence(
            evidence,
            "rust",
            "shakedown_50k",
            "Nodes/Shared/conformance/results/new.json",
            "new note",
        )
        updated = read_json(evidence)
        assert updated["entries"][0]["path"] == "Nodes/Shared/conformance/results/new.json"
        gate = {
            "gate_id": "shakedown_50k",
            "benchmark_kind": "shakedown_50k_p2p",
            "official_lane": "shakedown_50k_p2p",
            "target_height": 50000,
            "target_label": "50k",
            "official_header_target_height": 50000,
            "official_byte_source": "local_reference_p2p",
            "binary_gate_status": "not_attempted",
            "official_chainstate_utxo_count": 568855,
            "official_utxo_accounting_policy": "core_spendable_v1",
            "official_proof_mode": "p2p_sync",
            "official_peer_mode": "local_reference",
            "official_script_runner_mode": "parallel",
            "official_prefetch_depth": 4,
        }
        payload = {
            "implementation": "RustNode",
            "runtime_surface": "docker",
            "benchmark_contract_version": 1,
            "benchmark_lane": "shakedown_50k_p2p",
            "benchmark_kind": "shakedown_50k_p2p",
            "target_height": 50000,
            "target_label": "50k",
            "header_target_height": 50000,
            "byte_source": "local_reference_p2p",
            "validated_height": 50000,
            "validated_hash": EXPECTED_HASHES["shakedown_50k"],
            "current_blocker": None,
            "binary_gate_status": "not_attempted",
            "chainstate_backend": "rocksdb",
            "chainstate_utxo_count": 568855,
            "utxo_accounting_policy": "core_spendable_v1",
            "native_crypto_backend": "libsecp256k1",
            "proof_mode": "p2p_sync",
            "peer_mode": "local_reference",
            "peer": "bitcoin-core-testnet4:48333",
            "script_runner_mode": "parallel",
            "rocksdb_wal_disabled": False,
            "prefetch_depth": 4,
            "resume_supported": True,
            "fresh_state": True,
            "result": "passed",
            "failures": [],
            "telemetry_schema": "benchmark.telemetry_tick.v1",
            "timing_summary": {
                "total_ms": 100_000,
                "stage_totals_ms": {bucket: 1 for bucket in REQUIRED_BUCKETS},
                "slow_blocks": [],
            },
        }
        artifact = tmp_path / "rust_candidate.json"
        errors, warnings = validate_artifact(artifact, payload, gate, "rust", "bitcoin-core-testnet4:48333")
        assert not errors, errors
        assert classify_anomaly(payload, 30_000)[0] == "hard"
        payload["timing_summary"]["total_ms"] = 42_000
        assert classify_anomaly(payload, 30_000)[0] == "soft"
        payload["timing_summary"]["total_ms"] = 34_000
        assert classify_anomaly(payload, 30_000)[0] == "none"
        payload.pop("telemetry_schema")
        errors, _ = validate_artifact(artifact, payload, gate, "rust", "bitcoin-core-testnet4:48333")
        assert any("telemetry_schema" in error for error in errors)
        state = {
            "schema": "rb.benchmark_campaign.v1",
            "campaign_id": "selftest",
            "gate": "shakedown_50k",
            "ports": [],
        }
        state_path = tmp_path / "state.json"
        write_json(state_path, state)
        assert load_campaign(state_path)["campaign_id"] == "selftest"
    print("benchmark_campaign_self_test passed")
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    if args.dry_run:
        args.run = False
    if args.resume:
        if not args.campaign:
            raise SystemExit("--resume requires --campaign")
        campaign = load_campaign(args.campaign)
        if args.run:
            campaign["run_mode"] = "run"
    else:
        conn = connect(args.db)
        campaign = initial_campaign(conn, args)
    if campaign["run_mode"] != "run":
        print_dry_run(campaign)
        return 0
    return execute_campaign(campaign)


if __name__ == "__main__":
    raise SystemExit(main())
