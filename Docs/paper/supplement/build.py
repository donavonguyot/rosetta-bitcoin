#!/usr/bin/env python3
"""Build a byte-reproducible gzip-compressed tar supplement."""

from __future__ import annotations

import gzip
import io
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parent / "out" / "rosettabitcoin-mojo-diagnostic-supplement.tar.gz"
FILES = [
    ROOT / "README.md",
    ROOT / "manifest.json",
    ROOT / "zenodo_metadata.json",
    ROOT / "blocker_56447_provenance.json",
    ROOT / "verify.py",
] + sorted((ROOT / "evidence").glob("*.json"))


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for path in FILES:
            arcname = Path("rosettabitcoin-mojo-diagnostic-supplement") / path.relative_to(ROOT)
            info = tar.gettarinfo(str(path), str(arcname))
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mode = 0o755 if path.name == "verify.py" else 0o644
            with path.open("rb") as source:
                tar.addfile(info, source)
    with OUT.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
            zipped.write(tar_buffer.getvalue())
    print(OUT)


if __name__ == "__main__":
    main()

