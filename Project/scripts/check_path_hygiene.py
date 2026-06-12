#!/usr/bin/env python3
"""Path hygiene preflight.

Fails loudly if tracked text artifacts or the mission-control database contain
absolute home-directory paths (or other machine-identifying path prefixes).

This gate exists because the class of leak it catches actually shipped once:
imported benchmark evidence carried absolute `/Users/<name>/...` log paths into
public artifacts. Per the workspace discipline, the failure is compiled into a
preflight rather than left as a one-time sweep.

Premises (per the premise-scoped fixture rule): this gate covers *tracked
artifacts and the tracked database only*. Local datadirs, logs, and untracked
campaign directories may freely contain absolute paths; they are not published.

Usage:
  python3 Project/scripts/check_path_hygiene.py            # scan tracked files + DB
  python3 Project/scripts/check_path_hygiene.py --db-only  # scan only project.db
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

FORBIDDEN = re.compile(r"/(?:Users|home)/([A-Za-z][A-Za-z0-9._-]*)/")

# Container-internal users: paths like /home/bitcoin/ inside Docker images are
# infrastructure, not machine identity. (This exemption is premise-scoped: it
# covers well-known service users, never real account names.)
CONTAINER_USERS = {"bitcoin", "node", "app", "runner", "root"}

# Tracked files that legitimately discuss the forbidden pattern itself.
ALLOWLIST = {
    "Project/scripts/check_path_hygiene.py",
}

TEXT_SUFFIXES = {
    ".md", ".json", ".py", ".yml", ".yaml", ".toml", ".txt", ".sh", ".sql",
    ".cfg", ".ini", ".csv", ".xml", ".gradle", ".properties",
}


def repo_root() -> Path:
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True, capture_output=True, text=True,
    )
    return Path(out.stdout.strip())


def tracked_files(root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "ls-files"], cwd=root, check=True, capture_output=True, text=True,
    )
    return out.stdout.splitlines()


def scan_files(root: Path) -> list[str]:
    failures: list[str] = []
    for rel in tracked_files(root):
        if rel in ALLOWLIST:
            continue
        path = root / rel
        if path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            match = FORBIDDEN.search(line)
            if match and match.group(1) not in CONTAINER_USERS:
                failures.append(f"{rel}:{lineno}: {match.group(0)}...")
    return failures


def scan_db(root: Path, db_rel: str = "Project/project.db") -> list[str]:
    db_path = root / db_rel
    failures: list[str] = []
    if not db_path.exists():
        return failures
    connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        tables = [
            row[0]
            for row in connection.execute(
                "select name from sqlite_master where type='table'"
            )
        ]
        for table in tables:
            columns = [
                row[1]
                for row in connection.execute(f"pragma table_info({table})")
            ]
            for column in columns:
                try:
                    count = connection.execute(
                        f"select count(*) from {table} "
                        f"where {column} like '%/Users/%' or {column} like '%/home/%'"
                    ).fetchone()[0]
                except sqlite3.OperationalError:
                    continue
                if count:
                    failures.append(f"{db_rel}: {table}.{column}: {count} row(s)")
    finally:
        connection.close()
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db-only", action="store_true")
    args = parser.parse_args()

    root = repo_root()
    failures: list[str] = []
    if not args.db_only:
        failures.extend(scan_files(root))
    failures.extend(scan_db(root))

    if failures:
        print("PATH HYGIENE: FAIL")
        for failure in failures:
            print(f"  {failure}")
        print(
            f"\n{len(failures)} finding(s). Absolute home paths must not enter "
            "tracked artifacts or the mission-control database. Scrub the source "
            "artifact and re-import; do not hand-edit database rows."
        )
        return 1

    print("PATH HYGIENE: PASS (tracked text artifacts and project.db)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
