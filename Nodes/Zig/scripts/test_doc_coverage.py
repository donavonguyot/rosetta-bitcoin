#!/usr/bin/env python3
"""A decoy under worktrees/ must not change doc coverage or the path guard."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ZIG = REPO / "Nodes" / "Zig"
DECOY = REPO / "worktrees" / "fake" / "Nodes" / "Zig" / "src" / "decoy.zig"
COVERAGE = ZIG / "scripts" / "doc_coverage.py"
GUARD = ZIG / "scripts" / "check_no_external_paths.sh"


def coverage() -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, str(COVERAGE)],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
    )
    lines = [line for line in proc.stderr.splitlines() if line.startswith("port.docs.coverage.v1")]
    if proc.returncode != 0 or not lines:
        raise SystemExit(f"doc_coverage failed\n{proc.stderr}")
    return proc.returncode, lines[-1]


def guard() -> tuple[int, str, str]:
    proc = subprocess.run(
        ["sh", str(GUARD)],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


def remove_decoy() -> None:
    if DECOY.exists():
        DECOY.unlink()
    parent = DECOY.parent
    stop = REPO / "worktrees"
    while parent != stop and parent != REPO:
        try:
            parent.rmdir()
        except OSError:
            break
        parent = parent.parent
    fake = stop / "fake"
    if fake.exists():
        raise SystemExit(f"decoy tree remains: {fake}")
    try:
        stop.rmdir()
    except OSError:
        pass


def main() -> int:
    before_coverage = coverage()
    before_guard = guard()
    if before_guard[0] != 0:
        raise SystemExit(f"path guard failed before decoy\n{before_guard[2]}")
    DECOY.parent.mkdir(parents=True, exist_ok=True)
    try:
        outside = "../" + "Shared"
        DECOY.write_text(f'pub fn decoy() void {{}}\nconst leak = "{outside}";\n', encoding="utf-8")
        after_coverage = coverage()
        after_guard = guard()
    finally:
        remove_decoy()
    if before_coverage != after_coverage:
        raise SystemExit(f"coverage changed\nbefore: {before_coverage[1]}\nafter:  {after_coverage[1]}")
    if after_guard != before_guard:
        raise SystemExit(
            "path guard changed\n"
            f"before: {before_guard}\nafter:  {after_guard}"
        )
    print(before_coverage[1])
    print(f"path guard exit {before_guard[0]} unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
