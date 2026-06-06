#!/usr/bin/env python3
"""Convert Elixir Docker node.status output into a long native-sync proof."""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import sys


def load_status(path: pathlib.Path) -> dict:
    raw = path.read_text()
    start = raw.find("{")
    end = raw.rfind("}")
    if start < 0 or end < start:
        raise SystemExit(f"no JSON object found in {path}")
    return json.loads(raw[start : end + 1])


def load_exit_code(path: pathlib.Path | None) -> int:
    if path is None or not path.exists():
        return 0
    text = path.read_text().strip()
    return int(text or "0")


def shared_root() -> pathlib.Path:
    for parent in pathlib.Path(__file__).resolve().parents:
        if parent.name == "Shared":
            return parent
    raise SystemExit("could not locate Shared root from proof capture script")


def as_int(value, default=-1) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(
            "usage: capture_elixir_docker_long_sync_proof.py STATUS_JSON [SYNC_EXIT_FILE]",
            file=sys.stderr,
        )
        return 2

    status_path = pathlib.Path(sys.argv[1])
    exit_path = pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else None
    status = load_status(status_path)
    sync_exit_code = load_exit_code(exit_path)

    target_header_height = int(os.environ.get("TARGET_HEADER_HEIGHT", "10000"))
    target_block_height = int(os.environ.get("TARGET_BLOCK_HEIGHT", "10000"))
    validated_height = as_int(status.get("validated_height"))
    header_height = as_int(status.get("header_height"))
    stored_block_height = as_int(status.get("stored_block_height"))
    current_blocker = status.get("current_blocker")
    last_error = status.get("last_error")
    reached_target = (
        sync_exit_code == 0
        and header_height >= target_header_height
        and validated_height >= target_block_height
        and stored_block_height >= target_block_height
        and not current_blocker
        and not last_error
    )

    if sync_exit_code != 0 and not current_blocker and not last_error:
        last_error = f"sync exited nonzero without stored blocker (exit_code={sync_exit_code})"

    artifact = {
        "implementation": "ElixirNode",
        "category": "native_crypto_docker_long_sync",
        "runtime_surface": "docker_container",
        "captured_at": dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z"),
        "chain": status.get("chain", "testnet4"),
        "peer": status.get("peer_source", "bitcoin-core-testnet4:48333"),
        "docker_volume": os.environ.get("DOCKER_PROOF_VOLUME", "exbitnode_native_10k_sync_data"),
        "datadir": status.get("datadir", "/data"),
        "target_header_height": target_header_height,
        "target_block_height": target_block_height,
        "header_height": header_height,
        "validated_height": validated_height,
        "validated_hash": status.get("validated_hash", ""),
        "stored_block_height": stored_block_height,
        "stored_block_hash": status.get("stored_block_hash", ""),
        "blocks_connected": validated_height,
        "utxo_count": as_int(status.get("utxo_count"), 0),
        "sync_status": status.get("sync_status", ""),
        "sync_timing": status.get("sync_timing", {}),
        "block_prefetch_depth": as_int(status.get("block_prefetch_depth"), 0),
        "snapshot_throttle_blocks": as_int(status.get("snapshot_throttle_blocks"), 0),
        "snapshot_throttle_sec": as_int(status.get("snapshot_throttle_sec"), 5),
        "script_verify_timeout_ms": as_int(status.get("script_verify_timeout_ms"), 300000),
        "sync_exit_code": sync_exit_code,
        "long_sync_status": "target_reached" if reached_target else "blocked_or_incomplete",
        "current_blocker": current_blocker,
        "last_error": last_error,
        "chainstate_backend": status.get("chainstate_backend", ""),
        "chainstate_status": status.get("chainstate_status", ""),
        "runtime_truth_backend": "rocksdb",
        "rocksdb_runtime_truth": status.get("chainstate_backend") == "rocksdb",
        "native_crypto_backend": status.get("native_crypto_backend", ""),
        "native_crypto_available": bool(status.get("native_crypto_available")),
        "taproot_tweak_backend": status.get("taproot_tweak_backend", ""),
        "rocksdb_disable_wal": status.get("rocksdb_disable_wal", "false"),
        "binary_gate_status": "passed" if reached_target else "not_attempted",
        "bounded_gate_status": status.get("binary_gate_status", "not_attempted"),
        "passed": reached_target,
        "verification": {
            "command": os.environ.get("PROOF_COMMAND", "make docker-10k-sync-proof"),
            "sync_exit_code": sync_exit_code,
            "reached_target": reached_target,
            "status_source": str(status_path),
        },
    }

    proof_path = pathlib.Path(
        os.environ.get(
            "PROOF_PATH",
            str(
                shared_root()
                / "conformance/results/elixir_native_docker_10k_sync_20260603.json"
            ),
        )
    )
    proof_path.parent.mkdir(parents=True, exist_ok=True)
    proof_path.write_text(json.dumps(artifact, indent=2) + "\n")
    print(proof_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
