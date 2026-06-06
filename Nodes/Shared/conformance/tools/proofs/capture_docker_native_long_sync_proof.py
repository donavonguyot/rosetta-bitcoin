#!/usr/bin/env python3
"""Convert Docker DbStatus output into a Shared long native-sync proof."""

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


def optional_int_env(name: str) -> int | None:
    raw = os.environ.get(name, "").strip()
    return int(raw) if raw else None


def shared_root() -> pathlib.Path:
    for parent in pathlib.Path(__file__).resolve().parents:
        if parent.name == "Shared":
            return parent
    raise SystemExit("could not locate Shared root from proof capture script")


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(
            "usage: capture_docker_native_long_sync_proof.py STATUS_JSON [SYNC_EXIT_FILE]",
            file=sys.stderr,
        )
        return 2

    status_path = pathlib.Path(sys.argv[1])
    exit_path = pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else None
    status = load_status(status_path)
    sync_exit_code = load_exit_code(exit_path)

    target_header_height = int(os.environ.get("TARGET_HEADER_HEIGHT", "10000"))
    target_block_height = int(os.environ.get("TARGET_BLOCK_HEIGHT", "10000"))
    local_reference_tip_height = optional_int_env("LOCAL_REFERENCE_TIP_HEIGHT")
    local_reference_tip_hash = os.environ.get("LOCAL_REFERENCE_TIP_HASH", "").strip()
    effective_target_height = (
        min(target_block_height, local_reference_tip_height)
        if local_reference_tip_height is not None
        else target_block_height
    )
    validated_height = int(status.get("validated_height", -1))
    current_blocker = status.get("current_blocker") or ""
    reached_target = sync_exit_code == 0 and validated_height >= effective_target_height
    if sync_exit_code != 0 and not current_blocker:
        current_blocker = f"sync exited nonzero without stored blocker (exit_code={sync_exit_code})"
    binary_gate_status = (
        "passed"
        if (
            local_reference_tip_height is not None
            and reached_target
            and status["sync"]["sync_status"] == "blocks_current"
        )
        else "not_attempted"
    )

    artifact = {
        "implementation": "JavaNode",
        "category": "native_crypto_docker_long_sync",
        "runtime_surface": "docker_container",
        "captured_at": dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z"),
        "chain": status["chain"],
        "peer": os.environ.get("PEER", "bitcoin-core-testnet4:48333"),
        "docker_volume": os.environ.get("DOCKER_PROOF_VOLUME", "jbitnode_native_long_sync_data"),
        "datadir": status["data_dir"],
        "local_reference_tip_height": local_reference_tip_height,
        "local_reference_tip_hash": local_reference_tip_hash,
        "target_header_height": target_header_height,
        "target_block_height": target_block_height,
        "effective_target_height": effective_target_height,
        "header_height": status["header_height"],
        "validated_height": validated_height,
        "validated_hash": status["validated_hash"],
        "stored_block_height": status["stored_block_height"],
        "blocks_connected": validated_height,
        "utxo_count": status["utxo_count"],
        "sync_status": status["sync"]["sync_status"],
        "long_sync_status": "target_reached" if reached_target else "blocked_or_incomplete",
        "live_smoke_status": "passed" if validated_height > 0 else "failed",
        "current_blocker": current_blocker,
        "chainstate_backend": status["chainstate_backend"],
        "native_storage": status["native_storage"],
        "runtime_truth_backend": "rocksdb",
        "rocksdb_runtime_truth": status["chainstate_backend"] == "rocksdb",
        "native_crypto_backend": status["native_crypto_backend"],
        "native_crypto_available": status["native_crypto_available"],
        "taproot_tweak_backend": status["taproot_tweak_backend"],
        "binary_gate_status": binary_gate_status,
        "bounded_gate_status": status["binary_gate_status"],
        "verification": {
            "command": os.environ.get(
                "PROOF_COMMAND", "make docker-java-native-crypto-long-sync-proof"
            ),
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
                / "conformance/results/java_native_crypto_docker_long_sync_2026-06-01.json"
            ),
        )
    )
    proof_path.parent.mkdir(parents=True, exist_ok=True)
    proof_path.write_text(json.dumps(artifact, indent=2) + "\n")
    print(proof_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
