#!/usr/bin/env python3
"""Cache current Mojo docs used by agents working on the feasibility spike."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
from urllib.request import Request, urlopen


DOCS = {
    "llms.txt": "https://mojolang.org/llms.txt",
    "llms-cli.txt": "https://mojolang.org/llms-cli.txt",
    "llms-manual.txt": "https://mojolang.org/llms-manual.txt",
    "llms-reference.txt": "https://mojolang.org/llms-reference.txt",
    "llms-stdlib.txt": "https://mojolang.org/llms-stdlib.txt",
    "releases.html": "https://mojolang.org/releases/",
    "skills.md": "https://mojolang.org/docs/tools/skills.md",
    "testing.md": "https://mojolang.org/docs/tools/testing.md",
}


def fetch(url: str) -> bytes:
    request = Request(url, headers={"User-Agent": "RosettaBitcoin-Mojo-doc-cache/1.0"})
    with urlopen(request, timeout=30) as response:
        return response.read()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", default=".mojo-docs", help="generated docs cache directory")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    manifest: dict[str, object] = {
        "schema": "mojo.docs_cache.v1",
        "fetched_at": dt.datetime.now(dt.UTC).isoformat(),
        "files": [],
    }
    files: list[dict[str, object]] = []

    for name, url in DOCS.items():
        body = fetch(url)
        path = output_dir / name
        path.write_bytes(body)
        files.append(
            {
                "path": name,
                "url": url,
                "bytes": len(body),
                "sha256": hashlib.sha256(body).hexdigest(),
            }
        )

    manifest["files"] = files
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"cached {len(files)} Mojo docs into {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
