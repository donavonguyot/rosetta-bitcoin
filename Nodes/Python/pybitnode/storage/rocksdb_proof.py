from __future__ import annotations

import argparse
import json
import platform
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from pybitnode.consensus.secp256k1 import native_crypto_backend_metadata

try:
    from rocksdict import Rdict, WriteBatch
except ImportError as exc:  # pragma: no cover - proof command reports this cleanly.
    Rdict = None  # type: ignore[assignment]
    WriteBatch = None  # type: ignore[assignment]
    _IMPORT_ERROR = exc
else:
    _IMPORT_ERROR = None


def _utcnow() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _sqlite_artifacts(root: Path) -> list[str]:
    suffixes = {".db", ".sqlite", ".sqlite3", ".db-wal", ".db-shm", ".db-journal"}
    return [
        str(path.relative_to(root))
        for path in root.rglob("*")
        if path.is_file() and (path.suffix in suffixes or path.name.endswith((".db-wal", ".db-shm", ".db-journal")))
    ]


def run_proof(datadir: Path) -> dict[str, Any]:
    if Rdict is None:
        return {
            "result": "failed",
            "failure": f"rocksdict import failed: {_IMPORT_ERROR}",
            "captured_at": _utcnow(),
        }

    if datadir.exists():
        shutil.rmtree(datadir)
    rocks_dir = datadir / "chainstate-rocksdb"
    rocks_dir.mkdir(parents=True)

    db = Rdict(str(rocks_dir / "rocksdb"))
    db[b"meta|backend"] = b"rocksdb"
    db[b"prefix|001"] = b"one"
    db[b"prefix|002"] = b"two"

    batch = WriteBatch()
    batch.put(b"batch|a", b"A")
    batch.put(b"batch|b", b"B")
    batch.delete(b"prefix|001")
    db.write(batch)

    prefix_seen = sorted(
        key.decode()
        for key, _value in db.items()
        if (key if isinstance(key, bytes) else str(key).encode()).startswith(b"prefix|")
    )
    batch_values = [db.get(b"batch|a"), db.get(b"batch|b")]
    db.close()

    reopened = Rdict(str(rocks_dir / "rocksdb"))
    persisted = reopened.get(b"meta|backend") == b"rocksdb"
    reopened.close()

    sqlite_artifacts = _sqlite_artifacts(datadir)
    passed = persisted and prefix_seen == ["prefix|002"] and batch_values == [b"A", b"B"] and not sqlite_artifacts

    return {
        "implementation": "PythonNode",
        "node_id": "pybitnode-native-rocksdb-proof",
        "category": "storage",
        "captured_at": _utcnow(),
        "runtime_surface": "host_or_docker",
        "python_version": platform.python_version(),
        "machine": platform.machine(),
        "datadir": str(datadir),
        "chainstate_backend": "rocksdb",
        "crypto_backend": native_crypto_backend_metadata(),
        "native_storage": True,
        "atomic_batch": batch_values == [b"A", b"B"],
        "prefix_iteration": prefix_seen,
        "restart_persisted": persisted,
        "local_sqlite_artifact_absent": not sqlite_artifacts,
        "sqlite_artifacts": sqlite_artifacts,
        "result": "passed" if passed else "failed",
    }


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Prove Python RocksDB binding basics.")
    parser.add_argument("--datadir", default="./data-python-rocksdb-proof")
    parser.add_argument("--proof-path", default="")
    args = parser.parse_args(argv)

    result = run_proof(Path(args.datadir))
    if args.proof_path:
        out = Path(args.proof_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    raise SystemExit(0 if result.get("result") == "passed" else 1)


if __name__ == "__main__":
    main()
