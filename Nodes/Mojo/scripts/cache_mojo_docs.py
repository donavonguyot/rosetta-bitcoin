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
    "stdlib-parallelize.md": "https://mojolang.org/docs/std/algorithm/backend/cpu/parallelize.md",
    "stdlib-parallelize-function.md": "https://mojolang.org/docs/std/algorithm/backend/cpu/parallelize/parallelize.md",
    "stdlib-sync-parallelize.md": "https://mojolang.org/docs/std/algorithm/backend/cpu/parallelize/sync_parallelize.md",
    "stdlib-asyncrt.md": "https://mojolang.org/docs/std/runtime/asyncrt.md",
    "stdlib-asyncrt-task.md": "https://mojolang.org/docs/std/runtime/asyncrt/Task.md",
    "stdlib-asyncrt-raising-task.md": "https://mojolang.org/docs/std/runtime/asyncrt/RaisingTask.md",
    "stdlib-asyncrt-task-group.md": "https://mojolang.org/docs/std/runtime/asyncrt/TaskGroup.md",
    "stdlib-asyncrt-create-task.md": "https://mojolang.org/docs/std/runtime/asyncrt/create_task.md",
    "stdlib-asyncrt-parallelism-level.md": "https://mojolang.org/docs/std/runtime/asyncrt/parallelism_level.md",
    "stdlib-atomic.md": "https://mojolang.org/docs/std/atomic.md",
    "stdlib-atomic-module.md": "https://mojolang.org/docs/std/atomic/atomic.md",
    "stdlib-atomic-atomic.md": "https://mojolang.org/docs/std/atomic/atomic/Atomic.md",
    "stdlib-atomic-ordering.md": "https://mojolang.org/docs/std/atomic/atomic/Ordering.md",
    "stdlib-atomic-fence.md": "https://mojolang.org/docs/std/atomic/atomic/fence.md",
    "stdlib-lock.md": "https://mojolang.org/docs/std/utils/lock.md",
    "stdlib-lock-blocking-spin-lock.md": "https://mojolang.org/docs/std/utils/lock/BlockingSpinLock.md",
    "stdlib-lock-blocking-scoped-lock.md": "https://mojolang.org/docs/std/utils/lock/BlockingScopedLock.md",
    "stdlib-sys-num-logical-cores.md": "https://mojolang.org/docs/std/sys/info/num_logical_cores.md",
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
