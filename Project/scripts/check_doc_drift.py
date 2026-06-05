#!/usr/bin/env python3
"""Fail on Markdown patterns that recreate stale Project status surfaces."""

from __future__ import annotations

import re
from pathlib import Path
from urllib.parse import unquote


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

BASELINE_DOCS = [
    ROOT / "README.md",
    ROOT / "AGENTS.md",
    ROOT / "Docs/port-baseline-5k.md",
]

CONSENSUS_RUNWAY_DOCS = [
    ROOT / "README.md",
    ROOT / "AGENTS.md",
    ROOT / "Docs/agent-prompts.md",
    ROOT / "Nodes/Shared/consensus/CONSENSUS_RUNWAY.md",
]

PORT_DOC_STATUS_HEADINGS = re.compile(r"^##\s+(?:Live status|Current status|Current Status)\b")
MARKDOWN_LINK = re.compile(r"!?\[[^\]\n]+\]\(([^)\n]+)\)")
IGNORED_PATH_PARTS = {
    ".git",
    ".pytest_cache",
    ".venv",
    "_build",
    "build",
    "dist",
    "node_modules",
    "target",
}

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
    re.compile(r"forbidden\s+SQLite", re.IGNORECASE),
    re.compile(r"avoid\s+SQLite", re.IGNORECASE),
    re.compile(r"SQLite\s+at\s+all\s+cost", re.IGNORECASE),
    re.compile(r"SQLite\s+(?:scout|tracker|snapshot|script)", re.IGNORECASE),
    re.compile(r"(?:scout|tracker|snapshot|script)\s+SQLite", re.IGNORECASE),
    re.compile(r"SQLite\s+mistake", re.IGNORECASE),
    re.compile(r"SQLite\s+artifact\s+detection", re.IGNORECASE),
    re.compile(r"approved\s+native\s+" + "store", re.IGNORECASE),
    re.compile(r"RocksDB\s+or\s+(?:an?\s+)?" + "approved", re.IGNORECASE),
    re.compile("baseline" + r"\b.*\b(?:" + "Level" + r"DB|M" + r"DBX)\b", re.IGNORECASE),
    re.compile(r"baseline\b.*\b(?:managed|pure|fallback)\s+crypto\b", re.IGNORECASE),
    re.compile(r"piece\s+.*consensus\s+status\s+.*(?:port\s+README|historical|Java/Python)", re.IGNORECASE),
    re.compile(r"current\s+consensus\s+status\s+.*(?:port\s+README|historical\s+Java|historical\s+Python)", re.IGNORECASE),
    re.compile(r"sync\s+until\s+(?:the\s+)?exact\s+blocker", re.IGNORECASE),
    re.compile(r"Python(?:Node)?\s+scouts\s+live-chain\s+blockers\s+first", re.IGNORECASE),
    re.compile(r"Python\s+is\s+the\s+scout", re.IGNORECASE),
    re.compile(r"Scout\s+[—-]\s+discovers", re.IGNORECASE),
    re.compile(r"next\s+spend-path\s+stop\s+expected", re.IGNORECASE),
    re.compile(r"real\s+spend-path\s+blocker\s+expected", re.IGNORECASE),
    re.compile(r"early\s+spend/script\s+path\s+around\s+block\s+739", re.IGNORECASE),
    re.compile(r"First\s+real\s+spend-path\s+fixture", re.IGNORECASE),
    re.compile(r"blocker\s+rediscovery\s+from\s+an\s+empty", re.IGNORECASE),
    re.compile(r"rediscovers\s+or\s+clears\s+blockers", re.IGNORECASE),
    re.compile(r"rerun\s+blocker\s+discovery", re.IGNORECASE),
]

BASELINE_REQUIRED_TERMS = (
    "RocksDB",
    "native crypto",
    "45/45",
    "Docker local Reference P2P",
    "core_spendable_v1",
    "Project",
)

CONSENSUS_REQUIRED_TERMS = (
    "CONSENSUS_RUNWAY",
    "testnet4_script_rules_v1.json",
    "consensus-runway",
    "preflight_consensus_runway.py",
)


def iter_text_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    return [
        candidate
        for candidate in sorted(path.rglob("*"))
        if candidate.is_file()
        and candidate.suffix.lower() in {".md", ".py", ".sql", ".txt", ".ts", ".rs", ".go", ".java", ".zig"}
        and candidate.name != "check_doc_drift.py"
        and not (set(candidate.parts) & IGNORED_PATH_PARTS)
    ]


def line_has_unqualified_sqlite_forbidden(text: str) -> bool:
    lower = text.lower()
    if "sqlite" not in lower or "forbidden" not in lower:
        return False
    qualifiers = ("port-local", "operational", "native/core", "project")
    return not any(qualifier in lower for qualifier in qualifiers)


def line_has_new_storage_scar_vocabulary(path: Path, text: str) -> bool:
    rel_parts = path.relative_to(ROOT).parts
    lower = text.lower()
    is_forward_surface = (
        path.suffix.lower() == ".md"
        or "templates" in rel_parts
        or "tests" in rel_parts
    )
    if not is_forward_surface:
        return False
    return any(
        scar in lower
        for scar in (
            "forbidden_",
            "local_sqlite_artifact_absent",
            "forbidden_local_db_artifact_absent",
            "storage.local_sqlite_artifact_absent",
        )
    )


def markdown_link_target(raw_target: str) -> str:
    target = raw_target.strip()
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1].strip()
    if " " in target:
        target = target.split(" ", 1)[0]
    return unquote(target)


def is_external_link(target: str) -> bool:
    lower = target.lower()
    return (
        not target
        or target.startswith("#")
        or lower.startswith(("http://", "https://", "mailto:", "tel:", "data:"))
    )


def local_link_exists(path: Path, target: str) -> bool:
    if is_external_link(target):
        return True
    target_without_anchor = target.split("#", 1)[0]
    if not target_without_anchor:
        return True
    if target_without_anchor.startswith("/"):
        candidate = Path(target_without_anchor)
    else:
        candidate = path.parent / target_without_anchor
    return candidate.exists()


def main() -> int:
    errors: list[str] = []

    for path in PROJECTION_DOCS:
        if not path.exists():
            errors.append(f"missing projection doc: {path.relative_to(ROOT)}")
            continue
        for index, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if line.startswith("|") and "---" in line:
                errors.append(f"{path.relative_to(ROOT)}:{index}: hand-maintained table in projection doc")

    for path in BASELINE_DOCS:
        if not path.exists():
            errors.append(f"missing baseline doc: {path.relative_to(ROOT)}")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for term in BASELINE_REQUIRED_TERMS:
            if term not in text:
                errors.append(f"{path.relative_to(ROOT)}: baseline guidance missing {term!r}")

    for path in CONSENSUS_RUNWAY_DOCS:
        if not path.exists():
            errors.append(f"missing consensus runway doc: {path.relative_to(ROOT)}")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for term in CONSENSUS_REQUIRED_TERMS:
            if term not in text:
                errors.append(f"{path.relative_to(ROOT)}: consensus runway guidance missing {term!r}")

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
                if line_has_new_storage_scar_vocabulary(path, line):
                    errors.append(f"{rel_path}:{index}: storage scar vocabulary should use operational_db_boundary: {line.strip()}")
                if path.suffix.lower() == ".md":
                    for match in MARKDOWN_LINK.finditer(line):
                        target = markdown_link_target(match.group(1))
                        if not local_link_exists(path, target):
                            errors.append(f"{rel_path}:{index}: broken local Markdown link: {target}")

    if errors:
        print("doc_drift_check status=failed")
        for error in errors:
            print(error)
        return 1

    print("doc_drift_check status=passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
