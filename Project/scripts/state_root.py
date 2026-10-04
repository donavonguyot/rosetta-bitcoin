"""Resolve local operational paths without allocating state."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import fcntl
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def state_paths(root: Path | None = None) -> dict[str, Path]:
    base = (root or Path(os.environ.get("RB_STATE_ROOT", "~/.rblab"))).expanduser().resolve()
    return {"root": base, "core": base / "reference/bitcoin-core-testnet4",
            "substrate": base / "substrate", "campaigns": base / "project-campaigns",
            "packages": base / "fixture-packages"}


PATHS = state_paths()
_LEASE = None


def acquire_writer_lease() -> None:
    global _LEASE
    if _LEASE is None:
        mkdir(PATHS["root"])
        lock = PATHS["root"] / "migration.lock"
        journal("writer_lease", lock, {"remove_if_unlocked": str(lock)})
        _LEASE = lock.open("a")
        fcntl.flock(_LEASE, fcntl.LOCK_SH | fcntl.LOCK_NB)


def primary_root() -> Path:
    common = subprocess.check_output(["git", "rev-parse", "--git-common-dir"], cwd=ROOT, text=True).strip()
    return (ROOT / common).resolve().parent


def operational_paths(repo: Path | None = None) -> dict[str, Path]:
    repo = repo or primary_root()
    paths = dict(PATHS)
    old = {"campaigns": repo / "Project/.campaigns", "substrate": repo / "Nodes/RosettaNode/substrate/.local",
           "core": repo / "Nodes/Reference/bitcoin-core-testnet4"}
    for key, source in old.items():
        marker = PATHS["root"] / "migrations" / (key + ".json")
        state = json.loads(marker.read_text()) if marker.exists() else {}
        if state.get("phase") == "complete":
            continue
        if state.get("phase") in {"source_retained", "switched"}:
            raise RuntimeError(f"unfinished {key} migration; run migrate_state.py --recover {key}")
        if key == "core" or ("RB_STATE_ROOT" not in os.environ and source.exists()):
            paths[key] = source
    return paths


def logical_path(path: Path) -> str:
    resolved = path.resolve()
    for key, base in operational_paths().items():
        if key != "root" and resolved.is_relative_to(base.resolve()):
            return f"state:{key}/" + resolved.relative_to(base.resolve()).as_posix()
    if resolved.is_relative_to(ROOT):
        return resolved.relative_to(ROOT).as_posix()
    raise ValueError("published path must be repository-relative or state-relative")


def resolve_path(value: str | Path) -> Path:
    text = str(value)
    if text.startswith("state:"):
        key, relative = text[6:].split("/", 1)
        base = operational_paths()[key]
        result = (base / relative).resolve()
        if not result.is_relative_to(base.resolve()):
            raise ValueError("state path escapes its class")
        return result
    path = Path(text)
    for key, prefix in (("campaigns", "Project/.campaigns/"), ("substrate", "Nodes/RosettaNode/substrate/.local/")):
        if text.startswith(prefix):
            return resolve_path(f"state:{key}/" + text[len(prefix):])
    return path if path.is_absolute() else ROOT / path


def journal(action: str, path: Path, inverse: dict) -> None:
    # The journal itself is durable recovery evidence and has no cleanup inverse.
    destination = PATHS["root"] / "effects.jsonl"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("a") as stream:
        stream.write(json.dumps({"action": action, "path": str(path), "inverse": inverse}, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def mkdir(path: Path) -> None:
    if not path.exists():
        journal("mkdir", path, {"remove_if_empty": str(path)})
        path.mkdir(parents=True, exist_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", choices=PATHS)
    parser.add_argument("--effective", action="store_true")
    args = parser.parse_args()
    paths = operational_paths() if args.effective else PATHS
    print(paths[args.path] if args.path else json.dumps({k: str(v) for k, v in paths.items()}, sort_keys=True))


if __name__ == "__main__":
    main()
