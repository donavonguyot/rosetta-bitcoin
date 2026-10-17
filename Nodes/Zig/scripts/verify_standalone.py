#!/usr/bin/env python3
"""Verify the exported source inventory and reject escaping symlinks."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main(manifest_path: Path | None = None) -> None:
    manifest = json.loads((manifest_path or ROOT / "standalone-manifest.json").read_text())
    if manifest["schema"] != "zigbitnode.standalone_source.v1":
        raise ValueError("unsupported standalone manifest")
    for directory, children, files in os.walk(ROOT):
        children[:] = [name for name in children if name not in {".git", ".zig-cache", "zig-out", "__pycache__"}]
        for name in children + files:
            path = Path(directory) / name
            if path.is_symlink():
                raise ValueError(f"symlink in standalone source: {path.relative_to(ROOT)}")
    for entry in manifest["files"]:
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"invalid manifest path: {relative}")
        path = ROOT / relative
        if not path.resolve().is_relative_to(ROOT) or path.is_symlink():
            raise ValueError(f"external dependency: {relative}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError(f"source checksum mismatch: {relative}")
    print(f"verified {len(manifest['files'])} standalone source files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path)
    main(parser.parse_args().manifest)
