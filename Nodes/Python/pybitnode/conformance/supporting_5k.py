from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from pybitnode.chain.params import get_chain
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.consensus.secp256k1 import native_crypto_backend_metadata


def _utcnow() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _load_details(row: dict[str, Any]) -> dict[str, Any]:
    raw = row.get("details_json") or "{}"
    try:
        payload = json.loads(str(raw))
    except json.JSONDecodeError:
        return {}
    return payload if isinstance(payload, dict) else {}


def _timing_summary(tracker: ProjectTracker) -> dict[str, Any]:
    totals: dict[str, float] = defaultdict(float)
    max_stage: dict[str, float] = defaultdict(float)
    counts: dict[str, int] = defaultdict(int)
    slow_blocks: list[dict[str, Any]] = []

    for row in tracker.list_events(category="timing"):
        details = _load_details(row)
        stages = details.get("stages_ms")
        if not isinstance(stages, dict):
            continue
        for stage, value in stages.items():
            elapsed = float(value)
            totals[str(stage)] += elapsed
            max_stage[str(stage)] = max(max_stage[str(stage)], elapsed)
            counts[str(stage)] += 1
        slow_blocks.append(
            {
                "height": int(details.get("height", 0)),
                "block_hash": str(details.get("block_hash", "")),
                "tx_count": int(details.get("tx_count", 0)),
                "input_count": int(details.get("input_count", 0)),
                **{f"{stage}_ms": int(round(float(value))) for stage, value in stages.items()},
            }
        )

    stage_totals_ms = {stage: int(round(value)) for stage, value in sorted(totals.items())}
    ranked_blocks = sorted(
        slow_blocks,
        key=lambda item: int(item.get("block_connect_store_commit_ms", 0)),
        reverse=True,
    )[:10]
    for rank, item in enumerate(ranked_blocks, start=1):
        item["rank"] = rank

    slow_stages = [
        {
            "stage": stage,
            "count": counts[stage],
            "max_ms": int(round(max_stage[stage])),
        }
        for stage in sorted(totals, key=lambda name: totals[name], reverse=True)
    ]

    return {
        "stage_totals_ms": stage_totals_ms,
        "total_ms": stage_totals_ms.get("block_connect_store_commit", 0),
        "slow_stages": slow_stages,
        "slow_blocks": ranked_blocks,
    }


def _current_blocker(summary: dict[str, Any]) -> str | None:
    for event in summary.get("recent_events", []):
        message = str(event.get("message", ""))
        if message.startswith("Block connect failed"):
            return message
        if message in {"Rejected invalid block", "Block unavailable from peers"}:
            return message
    return None


def _run_sync(args: argparse.Namespace, datadir: Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "CHAIN": args.chain,
            "DATA_DIR": str(datadir),
            "STATE_PATH": str(datadir / "chainstate-rocksdb"),
            "LOG_LEVEL": args.log_level,
            "MAX_OUTBOUND_PEERS": "1",
            "SKIP_GETADDR": "1",
            "BLOCKS_TARGET_HEIGHT": str(args.target),
            "BLOCKS_MAX_PER_RUN": str(args.target),
            "PARALLEL_BLOCK_DOWNLOADS": str(args.prefetch_depth),
            "PAR_SCRIPT_VERIFY": "1",
            "PAR_SCRIPT_THREADS": args.script_threads,
            "PAR_SCRIPT_MIN_INPUTS": "2",
            "SYNC_TIMING": "1",
        }
    )
    command = [
        sys.executable,
        "-m",
        "pybitnode.sync_runner",
        "--chain",
        args.chain,
        "--datadir",
        str(datadir),
        "--peers",
        args.peer,
        "--blocks-target",
        str(args.target),
        "--blocks-max",
        str(args.target),
        "--log-level",
        args.log_level,
    ]
    return subprocess.run(command, env=env, text=True, capture_output=True)


def _build_artifact(
    args: argparse.Namespace,
    *,
    datadir: Path,
    started_at: str,
    elapsed_ms: int,
    completed: subprocess.CompletedProcess[str],
) -> dict[str, Any]:
    chain = get_chain(args.chain)
    tracker = ProjectTracker(datadir / "chainstate-rocksdb")
    try:
        summary = tracker.summary(args.chain)
        sync_state = summary.get("sync", {})
        validated_height = int(summary.get("validated_height", 0) or 0)
        header_height = int(summary.get("header_count", 0) or 0) - 1
        if sync_state:
            header_height = int(sync_state.get("best_height", header_height) or header_height)
        validated_hash = str(summary.get("validated_hash") or "")
        timing_summary = _timing_summary(tracker)
        current_blocker = _current_blocker(summary)
        passed = (
            completed.returncode == 0
            and validated_height >= args.target
            and header_height == args.target
            and current_blocker is None
        )
        failures: list[str] = []
        if completed.returncode != 0:
            failures.append(f"sync_exit_code={completed.returncode}")
        if validated_height < args.target:
            failures.append(f"validated_height {validated_height} < target {args.target}")
        if header_height != args.target:
            failures.append(f"header_height {header_height} != header_target_height {args.target}")
        if current_blocker:
            failures.append(current_blocker)

        return {
            "benchmark_contract_version": 1,
            "benchmark_gate": "supporting_5k",
            "benchmark_kind": "supporting_5k_p2p",
            "benchmark_lane": "supporting_5k_p2p",
            "binary_gate_status": "not_attempted",
            "blocks_connected": max(0, validated_height - int(args.reference_start_height)),
            "blocks_fetched": max(0, validated_height - int(args.reference_start_height)),
            "byte_source": "local_reference_p2p",
            "captured_at": _utcnow(),
            "category": "local_reference_sync",
            "chain": args.chain,
            "chainstate_backend": "rocksdb",
            "chainstate_status": "usable" if validated_height >= args.target else "partial",
            "chainstate_utxo_count": summary.get("utxo_count"),
            "current_blocker": current_blocker,
            "datadir": str(datadir),
            "docker_volume": args.docker_volume,
            "elapsed_ms": timing_summary.get("total_ms") or elapsed_ms,
            "failures": failures,
            "fresh_state": True,
            "header_hash": tracker.get_header_hash(header_height),
            "header_height": header_height,
            "header_target_height": args.target,
            "implementation": "PythonNode",
            "local_reference_status": "target_reached" if validated_height >= args.target else "target_not_reached",
            "native_crypto_available": bool(native_crypto_backend_metadata().get("native")),
            "native_crypto_backend": native_crypto_backend_metadata().get("backend"),
            "native_storage": True,
            "node": "PythonNode",
            "peer": args.peer,
            "peer_mode": "local_reference",
            "port": "python",
            "prefetch_depth": args.prefetch_depth,
            "proof_mode": "p2p_sync",
            "proof_wrapper_elapsed_ms": elapsed_ms,
            "reference_finish_hash": tracker.get_header_hash(args.target),
            "reference_finish_height": args.target,
            "reference_start_hash": chain.genesis_hash,
            "reference_start_height": int(args.reference_start_height),
            "result": "passed" if passed else "failed",
            "resume_supported": True,
            "rocksdb_wal_disabled": False,
            "runtime_surface": "docker",
            "script_runner_mode": "parallel",
            "script_threads": args.script_threads,
            "started_at": started_at,
            "status": summary,
            "stored_block_hash": validated_hash,
            "stored_block_height": validated_height,
            "sync_exit_code": completed.returncode,
            "sync_status": sync_state.get("sync_status", "unknown"),
            "target_height": args.target,
            "target_label": "5k",
            "timing_summary": timing_summary,
            "validated_hash": validated_hash,
            "validated_height": validated_height,
            "verification": {
                "command": "make docker-proof-local",
                "docker_volume": args.docker_volume,
                "live_progress_reporting": False,
            },
        }
    finally:
        tracker.close()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Run Python official supporting 5k local-reference Docker proof.")
    parser.add_argument("--chain", default="testnet4")
    parser.add_argument("--datadir", default="/proof/data")
    parser.add_argument("--result-path", default="/results/python_docker_supporting_5k_benchmark.json")
    parser.add_argument("--target", type=int, default=5000)
    parser.add_argument("--peer", default="host.docker.internal:48333")
    parser.add_argument("--prefetch-depth", type=int, default=4)
    parser.add_argument("--script-threads", default=str(os.cpu_count() or 1))
    parser.add_argument("--docker-volume", default=os.environ.get("DOCKER_PROOF_VOLUME", "pybitnode_proof_data"))
    parser.add_argument("--reference-start-height", type=int, default=0)
    parser.add_argument("--log-level", default=os.environ.get("LOG_LEVEL", "info"))
    args = parser.parse_args(argv)

    datadir = Path(args.datadir)
    if datadir.exists():
        shutil.rmtree(datadir)
    datadir.mkdir(parents=True, exist_ok=True)

    started_at = _utcnow()
    started = time.perf_counter()
    completed = _run_sync(args, datadir)
    elapsed_ms = int(round((time.perf_counter() - started) * 1000))

    artifact = _build_artifact(
        args,
        datadir=datadir,
        started_at=started_at,
        elapsed_ms=elapsed_ms,
        completed=completed,
    )
    artifact["stdout_tail"] = completed.stdout[-4000:]
    artifact["stderr_tail"] = completed.stderr[-4000:]

    out = Path(args.result_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(artifact, indent=2, sort_keys=True))
    raise SystemExit(0 if artifact.get("result") == "passed" else 1)


if __name__ == "__main__":
    main()
