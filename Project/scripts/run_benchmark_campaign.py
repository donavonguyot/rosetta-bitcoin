#!/usr/bin/env python3
"""Run official benchmark gates as a serialized Project campaign.

The runner is intentionally boring: one port at a time, no hidden parallelism,
and current evidence is updated only after a fresh artifact passes validation.
Dry-run is the default.
"""

from __future__ import annotations

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[2] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths

import argparse
import importlib.util
import json
import os
import signal
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from post_100k_source_state import classify_source_state, source_state_ready
from port_progress_posture import source_audit


ROOT = Path(__file__).resolve().parents[2]
RESULTS_DIR = ROOT / "Nodes/Shared/conformance/results"
CURRENT_EVIDENCE = ROOT / "Nodes/Shared/conformance/current_evidence.json"
REFERENCE_TOPOLOGY = ROOT / "Nodes/Shared/docker/reference_topology.env"
TELEMETRY_PREFIX = "benchmark.telemetry_tick "
VALIDATOR_PATH = ROOT / "Nodes/Shared/conformance/tools/validate_benchmark_artifact.py"
TELEMETRY_VALIDATOR_PATH = ROOT / "Project/scripts/validate_benchmark_telemetry.py"
CONTROL_HARNESS_PATH = ROOT / "Project/scripts/control_benchmark_harness.py"

_validator_spec = importlib.util.spec_from_file_location("rb_benchmark_validator", VALIDATOR_PATH)
if _validator_spec is None or _validator_spec.loader is None:
    raise RuntimeError(f"cannot load benchmark artifact validator: {VALIDATOR_PATH}")
_validator = importlib.util.module_from_spec(_validator_spec)
sys.modules[_validator_spec.name] = _validator
_validator_spec.loader.exec_module(_validator)

_telemetry_spec = importlib.util.spec_from_file_location("rb_benchmark_telemetry_validator", TELEMETRY_VALIDATOR_PATH)
if _telemetry_spec is None or _telemetry_spec.loader is None:
    raise RuntimeError(f"cannot load benchmark telemetry validator: {TELEMETRY_VALIDATOR_PATH}")
_telemetry_validator = importlib.util.module_from_spec(_telemetry_spec)
sys.modules[_telemetry_spec.name] = _telemetry_validator
_telemetry_spec.loader.exec_module(_telemetry_validator)

_control_spec = importlib.util.spec_from_file_location("rb_control_benchmark_harness", CONTROL_HARNESS_PATH)
if _control_spec is None or _control_spec.loader is None:
    raise RuntimeError(f"cannot load control benchmark harness: {CONTROL_HARNESS_PATH}")
_control_harness = importlib.util.module_from_spec(_control_spec)
sys.modules[_control_spec.name] = _control_harness
_control_spec.loader.exec_module(_control_harness)

SUPPORTED_GATES = tuple(_validator.GATES)
GATE_CLAIMS = {
    "baseline_5k": "baseline_5k",
    "shakedown_50k": "shakedown_50k",
    "performance_100k": "performance_100k",
    "post_100k_to_tip": "post_100k_to_tip",
    "tip_once": "tip_once",
    "tip_maintenance": "tip_maintenance",
}
EXPECTED_HASHES = _validator.EXPECTED_HASHES
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
    *_validator.REQUIRED_BUCKETS,
)
LONG_RUN_GATES = {gate for gate, spec in _validator.GATES.items() if spec.get("long_run")}
ACTIVE_CONTROL_PORTS = {"rust", "zig", "cpp", "go", "swift", "csharp", "java", "ocaml", "mojo"}
CONTROL_REQUIRED_GATES = {"baseline_5k", "shakedown_50k", "performance_100k", "post_100k_to_tip"}
REFERENCE_TIP_HELPER = ROOT / "Project/scripts/reference_tip.py"


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db", help="Project mission-control DB path")
    parser.add_argument("--gate", default="shakedown_50k", choices=SUPPORTED_GATES)
    parser.add_argument("--run-ref", help="Opaque external run reference")
    parser.add_argument("--ports", help="Comma-separated port list")
    parser.add_argument("--all", action="store_true", help="Use all eligible non-reference ports")
    parser.add_argument("--campaign", type=Path, help="Existing campaign state path for --resume")
    parser.add_argument("--resume", action="store_true", help="Resume a paused campaign")
    parser.add_argument("--run", action="store_true", help="Execute commands; dry-run is the default")
    parser.add_argument("--dry-run", action="store_true", help="Print the plan without executing commands")
    parser.add_argument("--pause-on", choices=("anomaly", "failure", "never"), default="anomaly")
    parser.add_argument(
        "--startup-timeout-sec",
        type=int,
        default=180,
        help="For long-run gates, stop a proof if first_block_connected is not observed within this many seconds.",
    )
    parser.add_argument(
        "--continue-on-failure",
        action="store_true",
        help="Assisted collection mode: record failed/rejected ports and continue the campaign.",
    )
    parser.add_argument(
        "--assisted",
        action="store_true",
        help="Alias for --continue-on-failure with operator-friendly wording.",
    )
    parser.add_argument(
        "--compatibility-artifacts",
        action="store_true",
        help="Allow historical port-authored artifact fallback when product progress is missing.",
    )
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
    from state_root import logical_path
    return logical_path(path)


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


def manifest_source_volume(port: str) -> str:
    path = ROOT / "Nodes/Shared/docker/ports" / f"{port}.docker.json"
    if not path.exists():
        return ""
    payload = read_json(path)
    volumes = payload.get("volumes") if isinstance(payload, dict) else {}
    if not isinstance(volumes, dict):
        return ""
    return str(volumes.get("proof_100k") or "").strip()


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


def print_campaign_leaderboard(campaign: dict[str, Any]) -> None:
    accepted_ports = [entry["port"] for entry in campaign["ports"] if entry.get("status") == "accepted"]
    if not accepted_ports:
        return
    placeholders = ",".join("?" for _ in accepted_ports)
    db_path = str(campaign["db"])
    with connect(db_path) as conn:
        data = rows(
            conn,
            f"""
            SELECT rank, port, total_ms, telemetry_quality, artifact_path
            FROM benchmark_leaderboard
            WHERE gate_id = ?
              AND port IN ({placeholders})
            ORDER BY rank, port
            """,
            (campaign["gate"], *accepted_ports),
        )
    print(f"campaign_leaderboard gate={campaign['gate']}")
    for row in data:
        print(
            f"  rank={row['rank']} port={row['port']} "
            f"total_ms={row['total_ms']} telemetry={row['telemetry_quality']} "
            f"artifact={row['artifact_path']}"
        )


def initial_campaign(conn: sqlite3.Connection, args: argparse.Namespace) -> dict[str, Any]:
    gate = gate_row(conn, args.gate)
    proof_key = str(gate["preferred_command_key"])
    ports = requested_ports(conn, args)
    campaign_id = f"{args.gate}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    entries: list[dict[str, Any]] = []
    for port in ports:
        warm = command_for(conn, port, "docker_warm")
        proof = command_for(conn, port, proof_key)
        source_state_command = command_for(conn, port, "docker_status_100k") if args.gate == "post_100k_to_tip" else ""
        source_state_volume = manifest_source_volume(port) if args.gate == "post_100k_to_tip" else ""
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
        elif args.gate == "post_100k_to_tip" and not source_state_command:
            status = "not_ready"
            reason = "missing supported docker_status_100k command"
        entries.append(
            {
                "port": port,
                "lifecycle_status": lifecycle.get("lifecycle_status", "active_contender"),
                "benchmark_scope": lifecycle.get("benchmark_scope", "full_suite"),
                "status": status,
                "reason": reason,
                "warm_command": warm,
                "proof_command": proof,
                "resume_source": "port_durable_state" if args.gate == "post_100k_to_tip" else "",
                "source_state_command": source_state_command,
                "source_state_volume": source_state_volume,
                "prior_total_ms": latest_prior_total_ms(conn, args.gate, port),
                "artifact_path": "",
                "telemetry_quality": "",
                "telemetry_summary": {},
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
        "run_ref": getattr(args, "run_ref", None),
        "created_at": utc_now(),
        "updated_at": utc_now(),
        "gate": args.gate,
        "run_mode": "run" if args.run else "dry_run",
        "pause_on": args.pause_on,
        "continue_on_failure": bool(args.continue_on_failure or args.assisted),
        "compatibility_artifacts": bool(args.compatibility_artifacts),
        "startup_timeout_sec": max(0, int(args.startup_timeout_sec)),
        "db": args.db,
        "current_evidence": str(args.current_evidence),
        "results_dir": str(args.results_dir),
        "ports": entries,
        "events": [],
    }


def campaign_dir(campaign: dict[str, Any]) -> Path:
    return (_rb_paths()['campaigns']) / str(campaign["campaign_id"])


def save_campaign(campaign: dict[str, Any]) -> Path:
    campaign["updated_at"] = utc_now()
    path = campaign_dir(campaign) / "state.json"
    write_json(path, campaign)
    return path


def load_campaign(path: Path) -> dict[str, Any]:
    from state_root import resolve_path
    payload = read_json(resolve_path(path))
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


def reference_tip() -> dict[str, Any]:
    completed = subprocess.run(
        [sys.executable, str(REFERENCE_TIP_HELPER), "--json"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(completed.stdout)
    if not payload.get("ok"):
        raise RuntimeError(str(payload.get("error") or "reference tip check failed"))
    return payload


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
    stall = tick.get("stall_class", "none")
    event = tick.get("event", "?")
    block_height = tick.get("current_block_height", "?")
    block_elapsed = tick.get("current_block_elapsed_ms", "?")
    block_shape = (
        f"tx={tick.get('current_block_tx_count', '?')}/"
        f"vin={tick.get('current_block_vin_count', '?')}/"
        f"script={tick.get('current_block_script_input_count', '?')}"
    )
    return (
        f"[{tick.get('port', '?')} {tick.get('gate', '?')}] "
        f"{tick.get('height', '?')}/{tick.get('target_height', '?')} "
        f"{num(tick.get('percent')):.1f}% "
        f"elapsed={ms_duration(num(tick.get('elapsed_ms')))} "
        f"rate={num(tick.get('rate_recent_blocks_per_second')):.1f}/"
        f"{num(tick.get('rate_total_blocks_per_second')):.1f} blocks/s "
        f"phase={tick.get('phase', '?')} "
        f"event={event} "
        f"stall={stall} "
        f"utxos={tick.get('utxos', '?')} "
        f"block={block_height} "
        f"block_elapsed={block_elapsed}ms "
        f"shape={block_shape} "
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
    if tick.get("event") in {
        "run_started",
        "container_started",
        "node_started",
        "first_peer_byte",
        "first_block_connected",
        "target_reached",
        "run_finished",
    }:
        return True
    if tick.get("stall_class") not in (None, "", "none"):
        return True
    if tick.get("current_blocker") or tick.get("phase") == "complete":
        return True
    height_delta = int(num(tick.get("height"))) - int(num(last.get("height")))
    elapsed_delta = int(num(tick.get("monotonic_ms"), num(tick.get("elapsed_ms")))) - int(
        num(last.get("monotonic_ms"), num(last.get("elapsed_ms")))
    )
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


def terminate_process_tree(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except Exception:
        process.terminate()


def run_shell(
    command: str,
    log_path: Path,
    *,
    startup_timeout_sec: int = 0,
    extra_env: dict[str, str] | None = None,
) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    last_tick: dict[str, Any] | None = None
    started = time.monotonic()
    first_block_connected = False
    env = os.environ.copy()
    if extra_env:
        env.update({key: str(value) for key, value in extra_env.items()})
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            start_new_session=True,
            env=env,
        )
        assert process.stdout is not None
        for line in process.stdout:
            log.write(line)
            log.flush()
            tick = parse_tick(line)
            if tick and tick.get("event") in {"first_block_connected", "first_health_tick"}:
                first_block_connected = True
            if tick and should_emit_tick(tick, last_tick):
                print(fmt_tick(tick), flush=True)
                last_tick = tick
            if (
                startup_timeout_sec > 0
                and not first_block_connected
                and time.monotonic() - started > startup_timeout_sec
            ):
                message = (
                    f"campaign_startup_timeout seconds={startup_timeout_sec} "
                    "reason=missing_first_block_connected\n"
                )
                log.write(message)
                log.flush()
                print(message.strip(), flush=True)
                terminate_process_tree(process)
                return 124
        return process.wait()


def stage_totals(payload: dict[str, Any]) -> dict[str, float]:
    merged: dict[str, float] = {}
    for key in ("timing_summary", "sync_timing", "pipeline_timing_summary", "canonical_timing_summary"):
        candidate = payload.get(key)
        if isinstance(candidate, dict):
            totals = candidate.get("stage_totals_ms")
            if isinstance(totals, dict):
                merged.update({k: num(v) for k, v in totals.items()})
            merged.update({k: num(v) for k, v in candidate.items() if isinstance(v, (int, float))})
    return merged


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
    return _validator.validate_payload(
        payload,
        gate_id=str(gate["gate_id"]),
        path=path,
        port=port,
        expected_peer=expected_peer,
        strict_current=True,
    )


def validate_telemetry_log(
    log_path: Path,
    gate: dict[str, Any],
    port: str,
) -> tuple[str, list[str], list[str], dict[str, Any]]:
    gate_id = str(gate["gate_id"])
    if gate_id not in LONG_RUN_GATES and gate_id != "baseline_5k":
        return "clean", [], [], {"telemetry_quality": "clean", "not_required": True}
    target_height = int(gate["target_height"]) if gate.get("target_height") not in (None, -1) else None
    result = _telemetry_validator.validate_log_paths(
        [log_path],
        gate=gate_id,
        port=port,
        target_height=target_height,
        min_ticks=1,
        heartbeat_max_ms=15_000,
    )
    return result.quality, result.errors, result.warnings, result.summary


def build_control_artifact(
    *,
    campaign: dict[str, Any],
    port: str,
    gate: dict[str, Any],
    proof_log: Path,
    elapsed_ms: int,
    expected_peer: str,
    reference_finish_height: int | None = None,
    reference_finish_hash: str | None = None,
    source_state: dict[str, Any] | None = None,
) -> Any | None:
    if not _control_harness.has_product_progress(proof_log):
        return None
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    artifact_path = Path(campaign["results_dir"]) / f"{port}_control_{campaign['gate']}_benchmark_{stamp}.json"
    telemetry_log_path = campaign_dir(campaign) / "logs" / f"{port}_control_telemetry.log"
    return _control_harness.build_artifact(
        port=port,
        gate_id=str(gate["gate_id"]),
        proof_log=proof_log,
        artifact_path=artifact_path,
        telemetry_log_path=telemetry_log_path,
        elapsed_ms=elapsed_ms,
        expected_peer=expected_peer,
        reference_finish_height=reference_finish_height,
        reference_finish_hash=reference_finish_hash,
        source_state=source_state,
        provenance=next((row.get("provenance") for row in campaign["ports"] if row["port"] == port), None),
    )


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


def current_evidence_artifact(path: Path, port: str, gate_id: str) -> Path | None:
    if not path.exists():
        return None
    payload = read_json(path)
    entries = payload.get("entries")
    if not isinstance(entries, list):
        return None
    claim = GATE_CLAIMS[gate_id]
    for entry in entries:
        if entry.get("port") == port and entry.get("claim") == claim and entry.get("gate_id") == gate_id:
            artifact_path = entry.get("path")
            if isinstance(artifact_path, str) and artifact_path.strip():
                candidate = Path(artifact_path)
                return candidate if candidate.is_absolute() else ROOT / candidate
    return None


def snapshot_file(path: Path | None) -> tuple[Path, bytes | None, bool] | None:
    if path is None:
        return None
    if path.exists():
        return path, path.read_bytes(), True
    return path, None, False


def preserve_rejected_candidate(campaign: dict[str, Any], port: str, path: Path | None) -> str:
    if path is None or not path.exists():
        return ""
    target = campaign_dir(campaign) / "candidates" / f"{port}_{path.name}"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
    return rel(target)


def restore_snapshot(snapshot: tuple[Path, bytes | None, bool] | None) -> None:
    if snapshot is None:
        return
    path, content, existed = snapshot
    if existed:
        assert content is not None
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    elif path.exists():
        path.unlink()


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
        posture = source_audit(entry["port"])
        print(f"  progress_posture: {posture['posture']} source_progress={posture['source_progress']} atomicity={posture['line_atomicity']}")
        if entry["warm_command"]:
            print(f"  warm: {entry['warm_command']}")
        if entry["proof_command"]:
            print(f"  proof: {entry['proof_command']}")
        if entry.get("resume_source"):
            print(f"  resume_source: {entry['resume_source']}")
        if entry.get("source_state_volume"):
            print(f"  source_state_volume: {entry['source_state_volume']}")
        if entry.get("source_state_command"):
            print(f"  source_state_command: {entry['source_state_command']}")
        if entry["prior_total_ms"] is not None:
            print(f"  prior_total_ms: {entry['prior_total_ms']}")


def campaign_should_pause(campaign: dict[str, Any], port: str, reason: str) -> bool:
    save_campaign(campaign)
    print(f"campaign_paused port={port} reason={reason}")
    if campaign.get("continue_on_failure"):
        print(f"campaign_continued_after_failure port={port} reason={reason}")
        return False
    return True


def execute_campaign(campaign: dict[str, Any]) -> int:
    from state_root import acquire_writer_lease
    acquire_writer_lease()
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
            if campaign_should_pause(campaign, port, "preflight_failed"):
                return 1
            continue
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
            if campaign_should_pause(campaign, port, "warm_failed"):
                return 1
            continue

        from provenance import prepare_port
        entry["provenance"], provenance_env = prepare_port(port, campaign.get("run_ref"))
        reference_finish: dict[str, Any] = {}
        if campaign["gate"] == "post_100k_to_tip":
            source_log = campaign_dir(campaign) / "logs" / f"{port}_source_state.log"
            source_status = classify_source_state(
                conn,
                port,
                str(entry.get("source_state_volume") or ""),
                None,
                log_path=source_log,
            )
            reason = str(source_status.get("reason") or source_status.get("status") or "source state not ready")
            entry["source_state_status"] = source_status
            if not source_state_ready(source_status):
                entry["status"] = "not_ready"
                entry["reason"] = reason
                entry["errors"].append(f"{reason}; see {rel(source_log)}")
                append_event(campaign, port, "source_state_not_ready", reason)
                if campaign_should_pause(campaign, port, "source_state_not_ready"):
                    return 1
                continue
            entry["source_state_status"] = source_status
            append_event(campaign, port, "source_state_ready", reason)
            try:
                reference_finish = reference_tip()
                entry["reference_finish"] = reference_finish
                append_event(
                    campaign,
                    port,
                    "reference_finish_selected",
                    f"{reference_finish.get('height', '')} {reference_finish.get('hash', '')}",
                )
            except Exception as exc:
                entry["status"] = "failed"
                entry["errors"].append(f"reference tip setup failed: {exc}")
                append_event(campaign, port, "reference_tip_setup_failed", str(exc))
                if campaign_should_pause(campaign, port, "reference_tip_setup_failed"):
                    return 1
                continue

        started = time.time()
        entry["started_at"] = utc_now()
        entry["status"] = "running"
        save_campaign(campaign)
        proof_log = campaign_dir(campaign) / "logs" / f"{port}_proof.log"
        current_evidence_path = ROOT / campaign["current_evidence"]
        protected_artifact = current_evidence_artifact(current_evidence_path, port, campaign["gate"])
        protected_snapshot = snapshot_file(protected_artifact)
        startup_timeout = campaign.get("startup_timeout_sec", 0) if campaign["gate"] in LONG_RUN_GATES else 0
        proof_command = entry["proof_command"]
        proof_env: dict[str, str] = {}
        if campaign["gate"] == "post_100k_to_tip":
            proof_env = {
                "REFERENCE_FINISH_HEIGHT": str(int(reference_finish["height"])),
                "REFERENCE_FINISH_HASH": str(reference_finish["hash"]),
                "POST_100K_TIP_TARGET": str(int(reference_finish["height"])),
            }
        proof_env.update(provenance_env)
        exit_code = run_shell(
            proof_command,
            proof_log,
            startup_timeout_sec=int(startup_timeout or 0),
            extra_env=proof_env,
        )
        finished = time.time()
        entry["finished_at"] = utc_now()
        entry["exit_code"] = exit_code
        if exit_code != 0:
            preserved = preserve_rejected_candidate(campaign, port, protected_artifact)
            restore_snapshot(protected_snapshot)
            entry["status"] = "failed"
            entry["errors"].append(f"proof failed; see {rel(proof_log)}")
            if preserved:
                entry["warnings"].append(f"rejected candidate preserved at {preserved}")
            append_event(campaign, port, "proof_failed", rel(proof_log))
            if campaign_should_pause(campaign, port, "proof_failed"):
                return 1
            continue

        control_result = build_control_artifact(
            campaign=campaign,
            port=port,
            gate=gate,
            proof_log=proof_log,
            elapsed_ms=int(max(0, finished - started) * 1000),
            expected_peer=expected_peer,
            reference_finish_height=int(reference_finish["height"]) if reference_finish else None,
            reference_finish_hash=str(reference_finish["hash"]) if reference_finish else None,
            source_state=entry.get("source_state_status") if campaign["gate"] == "post_100k_to_tip" else None,
        )
        telemetry_log = control_result.telemetry_log_path if control_result is not None else proof_log
        if control_result is not None:
            entry["control_artifact_path"] = rel(control_result.artifact_path)
            entry["control_telemetry_log"] = rel(control_result.telemetry_log_path)
            append_event(campaign, port, "control_artifact_built", rel(control_result.artifact_path))
        elif (
            port in ACTIVE_CONTROL_PORTS
            and campaign["gate"] in CONTROL_REQUIRED_GATES
            and not campaign.get("compatibility_artifacts")
        ):
            preserved = preserve_rejected_candidate(campaign, port, protected_artifact)
            restore_snapshot(protected_snapshot)
            entry["status"] = "failed"
            entry["errors"].append(
                "product progress missing; active current benchmark evidence requires rb.port_progress and a control-built artifact"
            )
            if preserved:
                entry["warnings"].append(f"rejected candidate preserved at {preserved}")
            append_event(campaign, port, "product_progress_missing", rel(proof_log))
            if campaign_should_pause(campaign, port, "product_progress_missing"):
                return 1
            continue

        telemetry_quality, telemetry_errors, telemetry_warnings, telemetry_summary = validate_telemetry_log(
            telemetry_log,
            gate,
            port,
        )
        entry["telemetry_quality"] = telemetry_quality
        entry["telemetry_summary"] = telemetry_summary
        entry["warnings"].extend(telemetry_warnings)
        if telemetry_quality != "clean":
            preserved = preserve_rejected_candidate(campaign, port, protected_artifact)
            restore_snapshot(protected_snapshot)
            entry["status"] = "rejected"
            entry["errors"].extend(telemetry_errors or [f"telemetry quality is {telemetry_quality}; see {rel(proof_log)}"])
            if preserved:
                entry["warnings"].append(f"rejected candidate preserved at {preserved}")
            append_event(campaign, port, "telemetry_rejected", rel(proof_log))
            if campaign_should_pause(campaign, port, f"telemetry_rejected quality={telemetry_quality}"):
                return 1
            continue

        if control_result is not None:
            artifact_path = control_result.artifact_path
        else:
            candidates = candidate_artifacts(Path(campaign["results_dir"]), started, port, gate)
            if len(candidates) != 1:
                preserved = preserve_rejected_candidate(campaign, port, protected_artifact)
                restore_snapshot(protected_snapshot)
                entry["status"] = "failed"
                entry["errors"].append(
                    f"artifact selection expected 1 candidate, found {len(candidates)}: "
                    + ", ".join(rel(path) for path in candidates)
                )
                if preserved:
                    entry["warnings"].append(f"rejected candidate preserved at {preserved}")
                append_event(campaign, port, "artifact_selection_failed", entry["errors"][-1])
                if campaign_should_pause(campaign, port, "artifact_selection_failed"):
                    return 1
                continue
            artifact_path = candidates[0]
        payload = read_json(artifact_path)
        if not isinstance(payload, dict):
            preserved = preserve_rejected_candidate(campaign, port, artifact_path)
            restore_snapshot(protected_snapshot)
            entry["status"] = "failed"
            entry["errors"].append(f"artifact must be a JSON object: {rel(artifact_path)}")
            if preserved:
                entry["warnings"].append(f"rejected candidate preserved at {preserved}")
            append_event(campaign, port, "artifact_rejected", entry["errors"][-1])
            if campaign_should_pause(campaign, port, "artifact_rejected"):
                return 1
            continue
        errors, warnings = validate_artifact(artifact_path, payload, gate, port, expected_peer)
        anomaly, anomaly_messages = classify_anomaly(payload, entry.get("prior_total_ms"))
        warnings.extend(anomaly_messages)
        entry["warnings"].extend(warnings)
        if errors:
            preserved = preserve_rejected_candidate(campaign, port, artifact_path)
            restore_snapshot(protected_snapshot)
            entry["status"] = "rejected"
            entry["errors"].extend(errors)
            if preserved:
                entry["warnings"].append(f"rejected candidate preserved at {preserved}")
            append_event(campaign, port, "artifact_rejected", rel(artifact_path))
            if campaign_should_pause(campaign, port, "artifact_rejected"):
                return 1
            continue
        if anomaly == "hard" and campaign["pause_on"] in {"anomaly", "failure"}:
            preserved = preserve_rejected_candidate(campaign, port, artifact_path)
            restore_snapshot(protected_snapshot)
            entry["status"] = "rejected"
            entry["errors"].extend(anomaly_messages)
            if preserved:
                entry["warnings"].append(f"rejected candidate preserved at {preserved}")
            append_event(campaign, port, "hard_anomaly", "; ".join(anomaly_messages))
            if campaign_should_pause(campaign, port, "hard_anomaly"):
                return 1
            continue
        if anomaly == "soft" and campaign["pause_on"] == "anomaly":
            preserved = preserve_rejected_candidate(campaign, port, artifact_path)
            restore_snapshot(protected_snapshot)
            entry["status"] = "paused"
            if preserved:
                entry["warnings"].append(f"rejected candidate preserved at {preserved}")
            append_event(campaign, port, "soft_anomaly", "; ".join(anomaly_messages))
            if campaign_should_pause(campaign, port, "soft_anomaly"):
                return 1
            continue

        artifact_rel = rel(artifact_path)
        note = f"Current comparable {port} {campaign['gate']} proof accepted by campaign {campaign['campaign_id']}."
        original_current_evidence = current_evidence_path.read_text(encoding="utf-8")
        update_current_evidence(current_evidence_path, port, campaign["gate"], artifact_rel, note)
        if rebuild_project(campaign["db"]) != 0 or verify_project_gate(campaign["db"], campaign["gate"], port) != 0:
            current_evidence_path.write_text(original_current_evidence, encoding="utf-8")
            preserved = preserve_rejected_candidate(campaign, port, artifact_path)
            restore_snapshot(protected_snapshot)
            rebuild_project(campaign["db"])
            entry["status"] = "failed"
            entry["errors"].append("Project import/preflight failed after evidence update")
            if preserved:
                entry["warnings"].append(f"rejected candidate preserved at {preserved}")
            append_event(campaign, port, "project_verification_failed", rel(artifact_path))
            if campaign_should_pause(campaign, port, "project_verification_failed"):
                return 1
            continue
        entry["status"] = "accepted"
        entry["artifact_path"] = artifact_rel
        append_event(campaign, port, "accepted", artifact_rel)
        save_campaign(campaign)
        print(
            f"campaign_port_accepted port={port} artifact={artifact_rel} "
            f"total_ms={total_ms(payload) if total_ms(payload) is not None else '?'} "
            f"telemetry_quality={telemetry_quality}"
        )
    summary_path = campaign_dir(campaign) / "summary.json"
    write_json(summary_path, campaign)
    print(f"campaign_complete summary={rel(summary_path)}")
    print_campaign_leaderboard(campaign)
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
        current_artifact = tmp_path / "current.json"
        current_artifact.write_text('{"result":"accepted"}\n', encoding="utf-8")
        snap = snapshot_file(current_artifact)
        current_artifact.write_text('{"result":"failed-candidate"}\n', encoding="utf-8")
        rejected = preserve_rejected_candidate(
            {"campaign_id": "selftest"},
            "rust",
            current_artifact,
        )
        assert rejected.endswith("rust_current.json"), rejected
        shutil.rmtree(campaign_dir({"campaign_id": "selftest"}), ignore_errors=True)
        restore_snapshot(snap)
        assert read_json(current_artifact)["result"] == "accepted"
        new_artifact = tmp_path / "new-current.json"
        snap = snapshot_file(new_artifact)
        new_artifact.write_text('{"result":"failed-candidate"}\n', encoding="utf-8")
        restore_snapshot(snap)
        assert not new_artifact.exists()
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
            "benchmark_gate": "shakedown_50k",
            "benchmark_lane": "shakedown_50k_p2p",
            "benchmark_kind": "shakedown_50k_p2p",
            "target_height": 50000,
            "target_label": "50k",
            "header_target_height": 50000,
            "byte_source": "local_reference_p2p",
            "reference_start_height": 0,
            "reference_start_hash": "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043",
            "reference_finish_height": 50000,
            "reference_finish_hash": EXPECTED_HASHES["shakedown_50k"],
            "validated_height": 50000,
            "validated_hash": EXPECTED_HASHES["shakedown_50k"],
            "blocks_fetched": 50001,
            "blocks_connected": 50000,
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
            "captured_at": "2026-06-06T00:00:00Z",
            "telemetry_schema": "benchmark.telemetry_tick.v1",
            "telemetry_summary": {
                "telemetry_quality": "clean",
                "tick_count": 8,
                "heartbeat_max_gap_ms": 1000,
                "lifecycle_markers": {
                    "run_started": 0,
                    "container_started": 1,
                    "node_started": 2,
                    "first_peer_byte": 3,
                    "first_block_connected": 4,
                    "target_reached": 5,
                    "run_finished": 6,
                },
            },
            "timing_summary": {
                "total_ms": 100_000,
                "stage_totals_ms": {bucket: 1 for bucket in REQUIRED_BUCKETS},
                "slow_blocks": [],
            },
        }
        artifact = tmp_path / "rust_candidate.json"
        errors, warnings = validate_artifact(artifact, payload, gate, "rust", "bitcoin-core-testnet4:48333")
        assert not errors, errors
        compatibility_payload = dict(payload)
        compatibility_payload["timing_summary"] = {
            "total_ms": 100_000,
            "stage_totals_ms": {
                "utxo_load": 1,
                "script_verify": 1,
                "utxo_apply": 1,
                "commit": 1,
                "block_connect_store_commit": 1,
            },
        }
        compatibility_payload["pipeline_timing_summary"] = {
            "stage_totals_ms": {bucket: 1 for bucket in REQUIRED_BUCKETS},
        }
        errors, _ = validate_artifact(
            artifact,
            compatibility_payload,
            gate,
            "rust",
            "bitcoin-core-testnet4:48333",
        )
        assert any("p2p_fetch" in error for error in errors), errors
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
        env_log = tmp_path / "env.log"
        env_code = run_shell(
            "sh -c 'printf \"%s\" \"$POST_100K_TIP_TARGET\"'",
            env_log,
            extra_env={"POST_100K_TIP_TARGET": "123456"},
        )
        assert env_code == 0
        assert env_log.read_text(encoding="utf-8") == "123456"
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
        if args.continue_on_failure or args.assisted:
            campaign["continue_on_failure"] = True
        if args.compatibility_artifacts:
            campaign["compatibility_artifacts"] = True
    else:
        conn = connect(args.db)
        campaign = initial_campaign(conn, args)
    if campaign["run_mode"] != "run":
        print_dry_run(campaign)
        return 0
    return execute_campaign(campaign)


if __name__ == "__main__":
    raise SystemExit(main())
