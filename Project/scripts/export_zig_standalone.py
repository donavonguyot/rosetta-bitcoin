#!/usr/bin/env python3
"""Export Zig source and declared dependencies without Git metadata or lab state."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PORT = Path("Nodes/Zig")
CRYPTO = Path("Libraries/Zig/libsecp256k1-zig")
SHARED = Path("Nodes/Shared")
WORKFLOW = Path(".github/workflows/zig-standalone.yml")
FIXTURE_ROOTS = ("conformance/fixtures", "testing/fixtures", "fixtures")


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True)


def inputs() -> list[tuple[Path, Path]]:
    scopes = [str(PORT), str(CRYPTO), str(WORKFLOW), *(str(SHARED / p) for p in FIXTURE_ROOTS)]
    names = sorted(set(git("ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *scopes).split("\0")) - {""})
    result = []
    for name in names:
        source = Path(name)
        if source == PORT / "libsecp256k1-zig":
            continue  # Materialized from its single canonical source below.
        if source == WORKFLOW:
            destination = WORKFLOW
        elif source.is_relative_to(PORT):
            destination = source.relative_to(PORT)
        elif source.is_relative_to(CRYPTO):
            destination = Path("libsecp256k1-zig") / source.relative_to(CRYPTO)
        else:
            destination = Path("fixtures") / source.relative_to(SHARED)
        if (ROOT / source).is_symlink() or not (ROOT / source).is_file():
            raise ValueError(f"export requires a regular source file: {source}")
        result.append((source, destination))
    return result


def export(destination: Path) -> dict:
    destination = destination.expanduser().resolve()
    if destination.is_relative_to(ROOT):
        raise ValueError("export outside the workspace; no nested repository or build tree")
    selected = inputs()
    destination.mkdir(parents=True, exist_ok=False)
    entries = []
    for source, relative in selected:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / source, target)
        entries.append({"path": relative.as_posix(), "source": source.as_posix(),
                        "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
    manifest = {"schema": "zigbitnode.standalone_source.v1", "source_commit": git("rev-parse", "HEAD").strip(),
                "source_dirty": bool(git("status", "--porcelain", "--", str(PORT), str(CRYPTO), str(WORKFLOW), *(str(SHARED / p) for p in FIXTURE_ROOTS)).strip()),
                "zig_version": "0.16.0", "fixture_roots": list(FIXTURE_ROOTS), "files": entries}
    (destination / "standalone-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return {"destination": str(destination), "files": len(entries), "source_commit": manifest["source_commit"], "source_dirty": manifest["source_dirty"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="new directory outside the workspace")
    args = parser.parse_args()
    print(json.dumps(export(args.destination)))


if __name__ == "__main__":
    main()
