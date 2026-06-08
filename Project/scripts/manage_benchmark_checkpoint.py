#!/usr/bin/env python3
"""Capture and restore local benchmark Docker volume checkpoints.

Checkpoints are ignored operational state under Project/.checkpoints. They are
not evidence. They only let Project start post-100k-to-tip runs from a proven
100k state instead of silently rebuilding 0-100k.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CHECKPOINT_ROOT = ROOT / "Project/.checkpoints"
CURRENT_EVIDENCE = ROOT / "Nodes/Shared/conformance/current_evidence.json"
MANIFEST_DIR = ROOT / "Nodes/Shared/docker/ports"
PERFORMANCE_100K = {
    "height": 100000,
    "hash": "0000000000524911745ab6eee9348bca9843c2c2b1b27eada246e3dc2f80b6b1",
    "utxo_count": 13154991,
}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def rel(path: Path) -> str:
    return path.resolve().relative_to(ROOT).as_posix()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def docker_volume_exists(name: str) -> bool:
    return subprocess.run(["docker", "volume", "inspect", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def first_existing_volume(name: str) -> str:
    for candidate in (name, f"docker_{name}"):
        if docker_volume_exists(candidate):
            return candidate
    return ""


def manifest(port: str) -> dict[str, Any]:
    return read_json(MANIFEST_DIR / f"{port}.docker.json")


def manifest_volume(port: str, key: str) -> str:
    data = manifest(port).get("volumes", {})
    return str(data.get(key) or "")


def current_artifact_path(port: str, gate: str, current_evidence: Path = CURRENT_EVIDENCE) -> Path | None:
    payload = read_json(current_evidence)
    for entry in payload.get("entries", []):
        if entry.get("port") == port and entry.get("gate_id") == gate and entry.get("status") == "current":
            path = entry.get("path")
            if isinstance(path, str) and path:
                candidate = Path(path)
                return candidate if candidate.is_absolute() else ROOT / candidate
    return None


def checkpoint_dir(port: str) -> Path:
    return CHECKPOINT_ROOT / port / "performance_100k"


def checkpoint_meta_path(port: str) -> Path:
    return checkpoint_dir(port) / "checkpoint.json"


def checkpoint_tar_path(port: str) -> Path:
    return checkpoint_dir(port) / "volume.tar.gz"


def checkpoint_exists(port: str) -> bool:
    return checkpoint_meta_path(port).exists() and checkpoint_tar_path(port).exists()


def read_checkpoint(port: str) -> dict[str, Any]:
    if not checkpoint_exists(port):
        raise FileNotFoundError(f"missing checkpoint for {port}: {rel(checkpoint_dir(port))}")
    return read_json(checkpoint_meta_path(port))


def capture_checkpoint(port: str, *, dry_run: bool = False) -> dict[str, Any]:
    source_volume = first_existing_volume(manifest_volume(port, "proof_100k"))
    source_artifact = current_artifact_path(port, "performance_100k")
    status = "ready"
    reason = ""
    if source_artifact is None or not source_artifact.exists():
        status = "not_ready"
        reason = "missing current performance_100k artifact"
    elif not source_volume:
        status = "not_ready"
        reason = "missing performance_100k Docker proof volume"
    result = {
        "port": port,
        "status": status,
        "reason": reason,
        "source_volume": source_volume,
        "source_artifact_path": rel(source_artifact) if source_artifact else "",
        "checkpoint_dir": rel(checkpoint_dir(port)),
    }
    if dry_run or status != "ready":
        return result

    target_tar = checkpoint_tar_path(port)
    target_tar.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tmp_tar = Path(tmp) / "volume.tar.gz"
        subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "-v",
                f"{source_volume}:/source:ro",
                "-v",
                f"{tmp}:/out",
                "alpine:3.20",
                "sh",
                "-c",
                "cd /source && tar czf /out/volume.tar.gz .",
            ],
            check=True,
        )
        target_tar.write_bytes(tmp_tar.read_bytes())
    content_hash = sha256_file(target_tar)
    metadata = {
        "schema": "rb.benchmark_checkpoint",
        "port": port,
        "source_gate": "performance_100k",
        "source_artifact_path": rel(source_artifact),
        "source_height": PERFORMANCE_100K["height"],
        "source_hash": PERFORMANCE_100K["hash"],
        "source_utxo_count": PERFORMANCE_100K["utxo_count"],
        "source_volume": source_volume,
        "target_gate": "post_100k_to_tip",
        "target_volume": manifest_volume(port, "post_100k_to_tip"),
        "archive_path": rel(target_tar),
        "content_sha256": content_hash,
        "created_at": utc_now(),
    }
    write_json(checkpoint_meta_path(port), metadata)
    result.update({"checkpoint_path": rel(target_tar), "content_sha256": content_hash})
    return result


def restore_checkpoint(port: str, *, dry_run: bool = False) -> dict[str, Any]:
    metadata = read_checkpoint(port)
    target_volume = str(metadata.get("target_volume") or manifest_volume(port, "post_100k_to_tip"))
    if not target_volume:
        raise RuntimeError(f"{port} manifest is missing volumes.post_100k_to_tip")
    archive = ROOT / str(metadata["archive_path"])
    expected_hash = str(metadata.get("content_sha256") or "")
    actual_hash = sha256_file(archive)
    if expected_hash and actual_hash != expected_hash:
        raise RuntimeError(f"checkpoint content hash mismatch for {port}")
    result = {
        "port": port,
        "status": "ready",
        "target_volume": target_volume,
        "checkpoint_path": rel(archive),
        "metadata_path": rel(checkpoint_meta_path(port)),
        "content_sha256": actual_hash,
    }
    if dry_run:
        return result
    subprocess.run(["docker", "volume", "rm", "-f", target_volume, f"docker_{target_volume}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["docker", "volume", "create", target_volume], check=True, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory() as tmp:
        tmp_archive = Path(tmp) / "volume.tar.gz"
        tmp_archive.write_bytes(archive.read_bytes())
        subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "-v",
                f"{target_volume}:/target",
                "-v",
                f"{tmp}:/in:ro",
                "alpine:3.20",
                "sh",
                "-c",
                "cd /target && tar xzf /in/volume.tar.gz",
            ],
            check=True,
        )
    return result


def parse_ports(raw: str | None) -> list[str]:
    if not raw:
        return []
    return [part.strip().lower() for part in raw.split(",") if part.strip()]


def ports_from_db(db_path: str) -> list[str]:
    path = Path(db_path)
    if not path.is_absolute():
        path = ROOT / path
    conn = sqlite3.connect(path)
    try:
        return [row[0] for row in conn.execute("select port from docker_contracts where port <> 'reference' order by port")]
    finally:
        conn.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="Project/project.db")
    parser.add_argument("--gate", default="performance_100k", choices=("performance_100k",))
    parser.add_argument("--ports", help="Comma-separated ports")
    parser.add_argument("--all", action="store_true", help="Use all non-reference ports from Project")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--capture", action="store_true", help="Capture existing performance_100k volumes")
    parser.add_argument("--restore", action="store_true", help="Restore one or more checkpoints into post_100k_to_tip volumes")
    parser.add_argument("--check", action="store_true", help="Check checkpoint existence")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ports = parse_ports(args.ports) if args.ports else (ports_from_db(args.db) if args.all else [])
    if not ports:
        raise SystemExit("choose --ports or --all")
    results: list[dict[str, Any]] = []
    exit_code = 0
    for port in ports:
        try:
            if args.restore:
                result = restore_checkpoint(port, dry_run=args.dry_run)
            elif args.check:
                result = {"port": port, "status": "ready" if checkpoint_exists(port) else "not_ready", "metadata_path": rel(checkpoint_meta_path(port))}
            else:
                result = capture_checkpoint(port, dry_run=not args.capture or args.dry_run)
            if result.get("status") != "ready" and not (args.dry_run and not args.restore and not args.check):
                exit_code = 2
        except Exception as exc:
            result = {"port": port, "status": "error", "reason": str(exc)}
            exit_code = 1
        results.append(result)
    if args.json:
        print(json.dumps({"results": results}, indent=2, sort_keys=False))
    else:
        for result in results:
            detail = " ".join(f"{key}={value}" for key, value in result.items() if key != "port")
            print(f"{result['port']}: {detail}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
