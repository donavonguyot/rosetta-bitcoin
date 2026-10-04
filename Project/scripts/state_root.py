"""Resolve local operational paths without allocating state."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def state_paths(root: Path | None = None) -> dict[str, Path]:
    base = (root or Path(os.environ.get("RB_STATE_ROOT", "~/.rblab"))).expanduser().resolve()
    return {"root": base, "core": base / "reference/bitcoin-core-testnet4",
            "substrate": base / "substrate", "campaigns": base / "project-campaigns",
            "packages": base / "fixture-packages"}


PATHS = state_paths()


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
    args = parser.parse_args()
    print(PATHS[args.path] if args.path else json.dumps({k: str(v) for k, v in PATHS.items()}, sort_keys=True))


if __name__ == "__main__":
    main()
