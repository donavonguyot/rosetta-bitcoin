#!/usr/bin/env python3
"""Run a diagnostic parallel local-Reference bounded smoke.

This is intentionally not a Project benchmark campaign. It does not update
current evidence, rebuild Project, or rank ports. It launches existing
Docker proof commands concurrently and summarizes their product progress.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
MANIFEST_DIR = ROOT / "Nodes/Shared/docker/ports"
REFERENCE_TOPOLOGY = ROOT / "Nodes/Shared/docker/reference_topology.env"
DEFAULT_PORTS = ("ocaml", "java", "csharp", "swift", "go", "cpp", "zig", "rust")
PRODUCT_PREFIX = "rb.port_progress "
PRODUCT_PREFIX_EQ = "rb.port_progress="
LEGACY_PROGRESS_PREFIX = "sync_progress_json="
EXPECTED_5K_HASH = "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2"
EXPECTED_5K_UTXOS = 4574
EXPECTED_50K_HASH = "00000000e2c8c94ba126169a88997233f07a9769e2b009fb10cad0e893eff2cb"
EXPECTED_50K_UTXOS = 568855


@dataclass
class PortPlan:
    port: str
    warm_command: str
    proof_command: str
    proof_volume: str
    compose_project_name: str


@dataclass(frozen=True)
class GateSpec:
    gate: str
    label: str
    command_key: str
    target_height: int
    expected_hash: str
    expected_utxos: int
    default_timeout_sec: int


GATE_SPECS = {
    "baseline_5k": GateSpec(
        gate="baseline_5k",
        label="5k",
        command_key="docker_proof_local",
        target_height=5000,
        expected_hash=EXPECTED_5K_HASH,
        expected_utxos=EXPECTED_5K_UTXOS,
        default_timeout_sec=900,
    ),
    "shakedown_50k": GateSpec(
        gate="shakedown_50k",
        label="50k",
        command_key="docker_proof_50k",
        target_height=50000,
        expected_hash=EXPECTED_50K_HASH,
        expected_utxos=EXPECTED_50K_UTXOS,
        default_timeout_sec=3600,
    ),
}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ports", default=",".join(DEFAULT_PORTS), help="Comma-separated ports in launch order")
    parser.add_argument("--gate", default="baseline_5k", choices=tuple(GATE_SPECS), help="Diagnostic smoke gate")
    parser.add_argument("--stagger-sec", type=float, default=2.0, help="Delay between proof launches")
    parser.add_argument("--timeout-sec", type=int, help="Terminate unfinished proof processes after this many seconds")
    parser.add_argument("--campaign-id", help="Optional run id for Project/.campaigns")
    parser.add_argument("--run", action="store_true", help="Execute warm and proof commands")
    parser.add_argument("--dry-run", action="store_true", help="Print the plan without executing commands")
    parser.add_argument("--self-test", action="store_true", help="Run parser/classifier self-tests")
    return parser.parse_args()


def read_env(path: Path = REFERENCE_TOPOLOGY) -> dict[str, str]:
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


def read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must be a JSON object")
    return payload


def rel(path: Path) -> str:
    return str(path.resolve().relative_to(ROOT))


def parse_ports(raw: str) -> list[str]:
    ports = [part.strip().lower() for part in raw.split(",") if part.strip()]
    if not ports:
        raise SystemExit("at least one port is required")
    return ports


def gate_spec(gate: str) -> GateSpec:
    try:
        return GATE_SPECS[gate]
    except KeyError as exc:
        raise SystemExit(f"unsupported gate: {gate}") from exc


def timeout_sec(args: argparse.Namespace, spec: GateSpec) -> int:
    return args.timeout_sec if args.timeout_sec is not None else spec.default_timeout_sec


def campaign_id(args: argparse.Namespace, spec: GateSpec) -> str:
    return args.campaign_id or f"parallel_reference_{spec.label}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"


def compose_project_name(run_id: str) -> str:
    return f"rb_parallel_{run_id}".replace("-", "_")


def load_plan(ports: list[str], run_id: str, spec: GateSpec) -> list[PortPlan]:
    plan: list[PortPlan] = []
    project_name = compose_project_name(run_id)
    for port in ports:
        manifest_path = MANIFEST_DIR / f"{port}.docker.json"
        if not manifest_path.exists():
            raise SystemExit(f"missing Docker manifest for {port}: {manifest_path}")
        manifest = read_json(manifest_path)
        commands = manifest.get("commands")
        volumes = manifest.get("volumes")
        if not isinstance(commands, dict) or not isinstance(volumes, dict):
            raise SystemExit(f"{manifest_path} must contain commands and volumes objects")
        warm = str(commands.get("docker_warm") or "").strip()
        proof = str(commands.get(spec.command_key) or "").strip()
        if not warm:
            raise SystemExit(f"{port} manifest has no docker_warm command")
        if not proof:
            raise SystemExit(f"{port} manifest has no {spec.command_key} command")
        proof_volume = str(volumes.get("proof") or "").strip()
        plan.append(
            PortPlan(
                port=port,
                warm_command=warm,
                proof_command=proof,
                proof_volume=proof_volume,
                compose_project_name=project_name,
            )
        )
    return plan


def reference_check_command() -> list[str]:
    env = read_env()
    network = env.get("REFERENCE_DOCKER_NETWORK", "rosetta-reference-node_default")
    peer = env.get("REFERENCE_P2P_PEER", "bitcoin-core-testnet4:48333")
    return [
        "docker",
        "run",
        "--rm",
        "--network",
        network,
        "-v",
        f"{ROOT / 'Nodes/Shared/docker'}:/shared/docker:ro",
        "python:3.12-alpine",
        "python3",
        "/shared/docker/check_reference_p2p.py",
        "--peer",
        peer,
    ]


def run_reference_check(log_path: Path) -> int:
    command = reference_check_command()
    completed = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text((completed.stdout or "") + (completed.stderr or ""), encoding="utf-8")
    return completed.returncode


def run_shell(command: str, log_path: Path, env: dict[str, str]) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        log.write(f"$ {command}\n")
        log.flush()
        completed = subprocess.run(command, cwd=ROOT, shell=True, stdout=log, stderr=subprocess.STDOUT, env=env)
    return completed.returncode


def cleanup_unused_smoke_networks(*, exclude_project: str | None = None) -> list[str]:
    completed = subprocess.run(
        ["docker", "network", "ls", "--format", "{{.Name}}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        return []
    removed: list[str] = []
    excluded = f"{exclude_project}_default" if exclude_project else ""
    for name in completed.stdout.splitlines():
        if not name.startswith("rb_parallel_") or name == excluded:
            continue
        inspected = subprocess.run(
            ["docker", "network", "inspect", name, "--format", "{{json .Containers}}"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if inspected.returncode != 0 or inspected.stdout.strip() not in {"{}", "null", ""}:
            continue
        removed_run = subprocess.run(["docker", "network", "rm", name], cwd=ROOT, capture_output=True, text=True)
        if removed_run.returncode == 0:
            removed.append(name)
    return removed


def launch_shell(command: str, log_path: Path, env: dict[str, str]) -> subprocess.Popen[Any]:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = log_path.open("w", encoding="utf-8")
    log.write(f"$ {command}\n")
    log.flush()
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        shell=True,
        stdout=log,
        stderr=subprocess.STDOUT,
        env=env,
        start_new_session=True,
    )
    log.close()
    return process


def parse_progress_payload(raw: str) -> dict[str, Any] | None:
    line = raw.strip()
    payload_text = ""
    if PRODUCT_PREFIX in line:
        payload_text = line.split(PRODUCT_PREFIX, 1)[1].strip()
    elif PRODUCT_PREFIX_EQ in line:
        payload_text = line.split(PRODUCT_PREFIX_EQ, 1)[1].strip()
    elif LEGACY_PROGRESS_PREFIX in line:
        payload_text = line.split(LEGACY_PROGRESS_PREFIX, 1)[1].strip()
    if not payload_text:
        return None
    try:
        payload = json.loads(payload_text)
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def progress_entries(log_path: Path) -> list[dict[str, Any]]:
    if not log_path.exists():
        return []
    entries: list[dict[str, Any]] = []
    for index, raw in enumerate(log_path.read_text(encoding="utf-8", errors="replace").splitlines()):
        payload = parse_progress_payload(raw)
        if payload is None:
            continue
        payload = dict(payload)
        payload["_line_index"] = index
        entries.append(payload)
    return entries


def as_int(value: Any, default: int = 0) -> int:
    try:
        if value is None or value == "":
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def final_progress(entries: list[dict[str, Any]]) -> dict[str, Any]:
    if not entries:
        return {}
    max_height = max(as_int(entry.get("validated_height"), 0) for entry in entries)
    candidates = [entry for entry in entries if as_int(entry.get("validated_height"), 0) == max_height]
    for entry in reversed(candidates):
        if str(entry.get("validated_hash") or "").strip():
            return entry
    return candidates[-1]


def blocker_present(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        return value.strip().lower() not in {"", "none", "null"}
    return bool(value)


def timing_from(entry: dict[str, Any]) -> dict[str, int]:
    raw = entry.get("timing_buckets_ms") or entry.get("timing_counters") or {}
    if not isinstance(raw, dict):
        raw = {}
    return {
        "p2p_fetch": as_int(raw.get("p2p_fetch"), -1),
        "block_connect_store_commit": as_int(raw.get("block_connect_store_commit"), -1),
    }


def classify(exit_code: int | None, timed_out: bool, entries: list[dict[str, Any]], spec: GateSpec) -> str:
    if timed_out:
        return "timed_out"
    if not entries:
        return "missing_progress" if exit_code == 0 else "failed"
    final = final_progress(entries)
    height = as_int(final.get("validated_height"), -1)
    hash_value = str(final.get("validated_hash") or "")
    utxos = as_int(final.get("chainstate_utxo_count", final.get("utxo_count")), -1)
    if (
        exit_code == 0
        and height >= spec.target_height
        and hash_value == spec.expected_hash
        and utxos == spec.expected_utxos
        and not blocker_present(final.get("current_blocker"))
    ):
        return f"passed_{spec.label}"
    if exit_code not in (0, None):
        return "failed"
    return "unknown"


def summarize_port(
    *,
    plan: PortPlan,
    proof_log: Path,
    warm_log: Path,
    exit_code: int | None,
    timed_out: bool,
    launched_at: str,
    finished_at: str,
    elapsed_ms: int,
    spec: GateSpec,
) -> dict[str, Any]:
    entries = progress_entries(proof_log)
    first = entries[0] if entries else {}
    final = final_progress(entries)
    timing = timing_from(final)
    outcome = classify(exit_code, timed_out, entries, spec)
    return {
        "port": plan.port,
        "outcome": outcome,
        "exit_code": exit_code,
        "timed_out": timed_out,
        "launched_at": launched_at,
        "finished_at": finished_at,
        "elapsed_ms": elapsed_ms,
        "compose_project_name": plan.compose_project_name,
        "proof_volume": plan.proof_volume,
        "warm_log": rel(warm_log),
        "proof_log": rel(proof_log),
        "progress_count": len(entries),
        "first_progress": {
            "height": as_int(first.get("validated_height"), -1) if first else -1,
            "hash": first.get("validated_hash", "") if first else "",
            "utxos": as_int(first.get("chainstate_utxo_count", first.get("utxo_count")), -1) if first else -1,
        },
        "final_progress": {
            "height": as_int(final.get("validated_height"), -1) if final else -1,
            "hash": final.get("validated_hash", "") if final else "",
            "utxos": as_int(final.get("chainstate_utxo_count", final.get("utxo_count")), -1) if final else -1,
            "blocker": final.get("current_blocker") if final else None,
            "sync_status": final.get("sync_status", "") if final else "",
        },
        "timing_buckets_ms": timing,
    }


def print_dry_run(plan: list[PortPlan], args: argparse.Namespace, run_id: str, spec: GateSpec) -> None:
    print(f"parallel_reference_smoke_dry_run id={run_id} gate={spec.gate} target={spec.target_height}")
    print("project_mutation=disabled current_evidence_update=disabled project_import=disabled")
    print(f"compose_project_name={compose_project_name(run_id)}")
    print("reference_check=" + " ".join(reference_check_command()))
    print(f"proof_command_key={spec.command_key}")
    print(f"expected_hash={spec.expected_hash} expected_utxos={spec.expected_utxos}")
    print(f"stagger_sec={args.stagger_sec} timeout_sec={timeout_sec(args, spec)}")
    for index, item in enumerate(plan, start=1):
        print(f"- launch_order={index} port={item.port}")
        print(f"  compose_project_name={item.compose_project_name}")
        print(f"  proof_volume={item.proof_volume}")
        print(f"  warm={item.warm_command}")
        print(f"  proof={item.proof_command}")


def print_summary(summary: dict[str, Any]) -> None:
    print(f"parallel_reference_smoke_summary id={summary['campaign_id']} status={summary['status']}")
    print("| port | outcome | exit | elapsed_ms | progress | final_height | utxos | p2p_fetch_ms | connect_ms |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for row in summary["ports"]:
        final = row["final_progress"]
        timing = row["timing_buckets_ms"]
        print(
            f"| {row['port']} | {row['outcome']} | {row['exit_code']} | {row['elapsed_ms']} | "
            f"{row['progress_count']} | {final['height']} | {final['utxos']} | "
            f"{timing['p2p_fetch']} | {timing['block_connect_store_commit']} |"
        )


def run_smoke(args: argparse.Namespace) -> int:
    spec = gate_spec(args.gate)
    run_id = campaign_id(args, spec)
    run_timeout_sec = timeout_sec(args, spec)
    plan = load_plan(parse_ports(args.ports), run_id, spec)
    if not args.run:
        print_dry_run(plan, args, run_id, spec)
        return 0

    base_dir = ROOT / "Project/.campaigns" / run_id / f"parallel_reference_{spec.gate}"
    logs_dir = base_dir / "logs"
    removed_networks = cleanup_unused_smoke_networks(exclude_project=compose_project_name(run_id))
    reference_log = logs_dir / "reference_p2p_check.log"
    reference_code = run_reference_check(reference_log)
    if reference_code != 0:
        print(f"reference_check_failed log={rel(reference_log)}")
        return 1

    base_env = os.environ.copy()
    base_env.setdefault("RB_PARALLEL_REFERENCE_SMOKE", "1")
    summary: dict[str, Any] = {
        "schema": "rb.parallel_reference_smoke",
        "campaign_id": run_id,
        "gate": spec.gate,
        "target_height": spec.target_height,
        "expected_hash": spec.expected_hash,
        "expected_utxos": spec.expected_utxos,
        "proof_command_key": spec.command_key,
        "ports_launch_order": [item.port for item in plan],
        "started_at": utc_now(),
        "finished_at": "",
        "status": "running",
        "reference_check_log": rel(reference_log),
        "removed_stale_smoke_networks": removed_networks,
        "stagger_sec": args.stagger_sec,
        "timeout_sec": run_timeout_sec,
        "ports": [],
    }

    for item in plan:
        warm_log = logs_dir / f"{item.port}_warm.log"
        env = dict(base_env)
        env["COMPOSE_PROJECT_NAME"] = item.compose_project_name
        env["RB_PARALLEL_SMOKE_PORT"] = item.port
        code = run_shell(item.warm_command, warm_log, env)
        if code != 0:
            summary["ports"].append(
                {
                    "port": item.port,
                    "outcome": "warm_failed",
                    "exit_code": code,
                    "timed_out": False,
                    "warm_log": rel(warm_log),
                    "proof_log": "",
                    "progress_count": 0,
                    "final_progress": {"height": -1, "hash": "", "utxos": -1, "blocker": None, "sync_status": ""},
                    "timing_buckets_ms": {"p2p_fetch": -1, "block_connect_store_commit": -1},
                }
            )
            summary["status"] = "failed"
            summary["finished_at"] = utc_now()
            write_json(base_dir / "summary.json", summary)
            print_summary(summary)
            return 1

    processes: list[dict[str, Any]] = []
    for item in plan:
        proof_log = logs_dir / f"{item.port}_proof.log"
        warm_log = logs_dir / f"{item.port}_warm.log"
        env = dict(base_env)
        env["COMPOSE_PROJECT_NAME"] = item.compose_project_name
        env["RB_PARALLEL_SMOKE_PORT"] = item.port
        launched_at = utc_now()
        started = time.time()
        process = launch_shell(item.proof_command, proof_log, env)
        processes.append(
            {
                "plan": item,
                "process": process,
                "proof_log": proof_log,
                "warm_log": warm_log,
                "launched_at": launched_at,
                "started": started,
                "timed_out": False,
            }
        )
        time.sleep(max(0.0, float(args.stagger_sec)))

    deadline = time.time() + max(1, int(run_timeout_sec))
    pending = set(range(len(processes)))
    while pending and time.time() < deadline:
        for index in list(pending):
            if processes[index]["process"].poll() is not None:
                pending.remove(index)
        if pending:
            time.sleep(1.0)

    for index in list(pending):
        process = processes[index]["process"]
        processes[index]["timed_out"] = True
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if pending:
        time.sleep(3.0)
    for index in list(pending):
        process = processes[index]["process"]
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    for record in processes:
        process = record["process"]
        exit_code = process.wait()
        finished_at = utc_now()
        elapsed_ms = int(max(0.0, time.time() - float(record["started"])) * 1000)
        summary["ports"].append(
            summarize_port(
                plan=record["plan"],
                proof_log=record["proof_log"],
                warm_log=record["warm_log"],
                exit_code=exit_code,
                timed_out=bool(record["timed_out"]),
                launched_at=record["launched_at"],
                finished_at=finished_at,
                elapsed_ms=elapsed_ms,
                spec=spec,
            )
        )

    summary["finished_at"] = utc_now()
    expected_outcome = f"passed_{spec.label}"
    summary["status"] = "passed" if all(row["outcome"] == expected_outcome for row in summary["ports"]) else "completed_with_findings"
    summary["removed_final_smoke_networks"] = cleanup_unused_smoke_networks(exclude_project=None)
    write_json(base_dir / "summary.json", summary)
    print_summary(summary)
    print(f"summary={rel(base_dir / 'summary.json')}")
    return 0


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def self_test() -> int:
    failures = 0
    baseline = gate_spec("baseline_5k")
    shakedown = gate_spec("shakedown_50k")
    clean_5k = {
        "chain": "testnet4",
        "sync_status": "blocks_current",
        "validated_height": baseline.target_height,
        "validated_hash": baseline.expected_hash,
        "chainstate_utxo_count": baseline.expected_utxos,
        "current_blocker": None,
        "timing_buckets_ms": {"p2p_fetch": 12, "block_connect_store_commit": 34},
    }
    clean_50k = dict(clean_5k)
    clean_50k.update(
        {
            "validated_height": shakedown.target_height,
            "validated_hash": shakedown.expected_hash,
            "chainstate_utxo_count": shakedown.expected_utxos,
        }
    )
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        log_5k = tmp_path / "proof_5k.log"
        log_5k.write_text(PRODUCT_PREFIX + json.dumps(clean_5k) + "\n", encoding="utf-8")
        entries = progress_entries(log_5k)
        if len(entries) != 1:
            print("self_test failed: progress parse")
            failures += 1
        if classify(0, False, entries, baseline) != "passed_5k":
            print("self_test failed: clean pass classification")
            failures += 1
        if classify(0, True, entries, baseline) != "timed_out":
            print("self_test failed: timeout classification")
            failures += 1
        log_50k = tmp_path / "proof_50k.log"
        log_50k.write_text(PRODUCT_PREFIX + json.dumps(clean_50k) + "\n", encoding="utf-8")
        if classify(0, False, progress_entries(log_50k), shakedown) != "passed_50k":
            print("self_test failed: clean 50k pass classification")
            failures += 1
        empty_log = tmp_path / "empty.log"
        empty_log.write_text("no progress\n", encoding="utf-8")
        if classify(0, False, progress_entries(empty_log), baseline) != "missing_progress":
            print("self_test failed: missing progress classification")
            failures += 1
    if failures:
        print(f"parallel_reference_smoke_self_test failures={failures}")
        return 1
    print("parallel_reference_smoke_self_test passed")
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    return run_smoke(args)


if __name__ == "__main__":
    sys.exit(main())
