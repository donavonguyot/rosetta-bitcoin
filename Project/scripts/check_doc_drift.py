#!/usr/bin/env python3
"""Fail on Markdown patterns that recreate stale Project status surfaces."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCAN_ROOTS = [
    ROOT / "Docs",
    ROOT / "AGENTS.md",
    ROOT / "README.md",
    ROOT / "Project",
    ROOT / "Nodes",
]

PROJECTION_DOCS = [
    ROOT / "Docs/port-status.md",
    ROOT / "Docs/follower-port-matrix.md",
]

PORT_DOC_STATUS_HEADINGS = re.compile(r"^##\s+(?:Live status|Current status|Current Status)\b")

FORBIDDEN_PATTERNS = [
    re.compile(r"update\s+.*Docs/(?:follower-port-matrix|port-status)\.md", re.IGNORECASE),
    re.compile("Current " + "Baseline"),
    re.compile("Current scout / follower " + "frontier"),
    re.compile(r"Refresh\s+`?Docs/port-status\.md`?", re.IGNORECASE),
    re.compile(r"Update\s+the\s+port\s+column\s+in\s+`?MATRIX\.md`?", re.IGNORECASE),
    re.compile(r"^##\s+Latest Validation Snapshot\b"),
    re.compile(r"^##\s+Current Follower Notes\b"),
    re.compile(r"^##\s+Current Port Posture\b"),
    re.compile(r"^##\s+Current Evidence\b"),
    re.compile(r"^##\s+Current Bootstrap Fixtures\b"),
    re.compile(r"current\s+per-port\s+Docker\s+inventory", re.IGNORECASE),
    re.compile(r"SQLite\s+is\s+forbidden", re.IGNORECASE),
    re.compile(r"avoid\s+SQLite", re.IGNORECASE),
    re.compile(r"SQLite\s+at\s+all\s+cost", re.IGNORECASE),
]


def iter_text_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    return [
        candidate
        for candidate in sorted(path.rglob("*"))
        if candidate.is_file()
        and candidate.suffix.lower() in {".md", ".py", ".sql", ".txt"}
        and candidate.name != "check_doc_drift.py"
        and ".git" not in candidate.parts
    ]


def line_has_unqualified_sqlite_forbidden(text: str) -> bool:
    lower = text.lower()
    if "sqlite" not in lower or "forbidden" not in lower:
        return False
    qualifiers = ("port-local", "operational", "native/core", "project")
    return not any(qualifier in lower for qualifier in qualifiers)


def main() -> int:
    errors: list[str] = []

    for path in PROJECTION_DOCS:
        if not path.exists():
            errors.append(f"missing projection doc: {path.relative_to(ROOT)}")
            continue
        for index, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if line.startswith("|") and "---" in line:
                errors.append(f"{path.relative_to(ROOT)}:{index}: hand-maintained table in projection doc")

    for root in SCAN_ROOTS:
        for path in iter_text_files(root):
            rel_path = path.relative_to(ROOT)
            text = path.read_text(encoding="utf-8", errors="replace")
            if path.parts[-2:] == ("docs", "STATUS.md"):
                if "Project Status Guide" not in text or "Project/project.db" not in text:
                    errors.append(f"{rel_path}: port docs STATUS.md should be a Project query guide or removed")
            for index, line in enumerate(text.splitlines(), start=1):
                if "Nodes" in path.parts and path.parent.name == "docs":
                    if PORT_DOC_STATUS_HEADINGS.search(line):
                        errors.append(f"{rel_path}:{index}: port docs must not carry live/current status headings")
                for pattern in FORBIDDEN_PATTERNS:
                    if pattern.search(line):
                        errors.append(f"{rel_path}:{index}: forbidden drift phrase: {line.strip()}")
                if line_has_unqualified_sqlite_forbidden(line):
                    errors.append(f"{rel_path}:{index}: unqualified SQLite forbidden language: {line.strip()}")

    if errors:
        print("doc_drift_check status=failed")
        for error in errors:
            print(error)
        return 1

    print("doc_drift_check status=passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
