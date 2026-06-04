#!/usr/bin/env python3
import json
import os
import pathlib
import sys
from datetime import datetime, timezone


def load_json(path: pathlib.Path) -> dict:
    if not path.exists() or not path.read_text().strip():
        return {}
    return json.loads(path.read_text())


def load_exit(path: pathlib.Path) -> int:
    if not path.exists():
        return 125
    return int((path.read_text().strip() or "0"))


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: capture_docker_sync_proof.py STATUS_JSON EXIT_FILE", file=sys.stderr)
        return 2
    status = load_json(pathlib.Path(sys.argv[1]))
    exit_code = load_exit(pathlib.Path(sys.argv[2]))
    target_header_height = int(os.environ.get("TARGET_HEADER_HEIGHT", "200"))
    target_block_height = int(os.environ.get("TARGET_BLOCK_HEIGHT", "2"))
    validated_height = int(status.get("validated_height", -1))
    header_height = int(status.get("header_height", 0))
    reached_target = exit_code == 0 and validated_height >= target_block_height
    proof_path = pathlib.Path(
        os.environ.get(
            "PROOF_PATH",
            "../Shared/conformance/results/csharp_native_crypto_docker_smoke_2026-06-01.json",
        )
    )
    artifact = {
        "implementation": "CSharpNode",
        "category": "docker_native_crypto_sync",
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "datadir": status.get("datadir", "/data"),
        "chain": status.get("chain", "testnet4"),
        "target_header_height": target_header_height,
        "target_block_height": target_block_height,
        "header_height": header_height,
        "validated_height": validated_height,
        "validated_hash": status.get("validated_hash", ""),
        "stored_block_height": status.get("stored_block_height", 0),
        "sync_status": status.get("sync_status", "unknown"),
        "chainstate_backend": status.get("chainstate_backend", ""),
        "codec_version": status.get("codec_version", ""),
        "chainstate_status": status.get("chainstate_status", ""),
        "native_storage": status.get("native_storage", True),
        "local_sqlite_artifact_absent": status.get("local_sqlite_artifact_absent", False),
        "native_crypto_backend": status.get("native_crypto_backend", ""),
        "native_crypto_available": status.get("native_crypto_available", False),
        "taproot_tweak_backend": status.get("taproot_tweak_backend", ""),
        "sync_timing": status.get("sync_timing"),
        "sync_exit_code": exit_code,
        "bounded_gate_status": "passed" if reached_target else "failed",
        "binary_gate_status": "not_attempted",
        "verification": {
            "command": os.environ.get("PROOF_COMMAND", "make docker-csharp-native-crypto-proof"),
            "docker_volume": os.environ.get("DOCKER_PROOF_VOLUME", "csbitnode_proof_data"),
            "live_progress_reporting": True,
            "progress_interval_seconds": int(os.environ.get("POLL_SEC", "120")),
        },
    }
    proof_path.parent.mkdir(parents=True, exist_ok=True)
    proof_path.write_text(json.dumps(artifact, indent=2) + "\n")
    print(proof_path)
    return 0 if reached_target else 1


if __name__ == "__main__":
    raise SystemExit(main())
