#!/usr/bin/env python3
"""Audit active-port product progress posture without running proofs."""

from __future__ import annotations

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[2] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths

import argparse
import json
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
ACTIVE_PORTS = ("rust", "zig", "cpp", "go", "swift", "csharp", "java", "ocaml")
REQUIRED_FIELDS = (
    "chain",
    "sync_status",
    "header_height",
    "validated_height",
    "validated_hash",
    "stored_block_height",
    "chainstate_utxo_count",
    "current_blocker",
)
RECOMMENDED_FIELDS = (
    "peer",
    "header_hash",
    "stored_block_hash",
    "current_block_height",
    "current_block_hash",
    "current_block_tx_count",
    "current_block_vin_count",
    "current_block_script_input_count",
    "reconnect_count",
    "disconnect_reason",
    "timing_buckets_ms",
)
PRODUCT_PREFIX = "rb.port_progress "
PRODUCT_PREFIX_EQ = "rb.port_progress="


@dataclass(frozen=True)
class SourcePosture:
    port: str
    posture: str
    source_paths: tuple[str, ...]
    wrapper_paths: tuple[str, ...] = ()
    notes: str = ""


SOURCE_POSTURES = {
    "go": SourcePosture(
        "go",
        "writer_owned",
        ("Nodes/Go/cmd/gobitnode-local-reference-proof/main.go",),
        notes="direct proof-loop emitter",
    ),
    "rust": SourcePosture(
        "rust",
        "writer_owned",
        ("Nodes/Rust/src/local_reference.rs",),
        notes="direct proof-loop emitter",
    ),
    "zig": SourcePosture(
        "zig",
        "writer_owned",
        ("Nodes/Zig/src/main.zig",),
        notes="direct proof-loop emitter",
    ),
    "swift": SourcePosture(
        "swift",
        "writer_owned",
        ("Nodes/Swift/Sources/swiftbitnode/LocalReferenceProof.swift",),
        notes="direct proof-loop emitter",
    ),
    "ocaml": SourcePosture(
        "ocaml",
        "writer_owned",
        ("Nodes/OCaml/lib/local_reference.ml",),
        notes="direct proof-loop emitter",
    ),
    "cpp": SourcePosture(
        "cpp",
        "writer_owned",
        ("Nodes/Cpp/src/consensus/connect.cpp",),
        notes="direct block-connect emitter",
    ),
    "csharp": SourcePosture(
        "csharp",
        "writer_owned",
        ("Nodes/CSharp/src/CsBitNode/Cli/SyncLocalCoreProgram.cs",),
        ("Nodes/CSharp/scripts/docker_sync_proof.sh",),
        notes="writer emits progress; wrapper is control pass-through",
    ),
    "java": SourcePosture(
        "java",
        "writer_owned",
        ("Nodes/Java/src/main/java/com/jbitnode/cli/SyncLocalCoreService.java",),
        ("Nodes/Java/scripts/docker_5k_benchmark.sh",),
        notes="writer emits progress; wrapper is control pass-through",
    ),
}


def rel(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(ROOT))
    except ValueError:
        return str(resolved)


def source_text(path: str) -> str:
    full_path = ROOT / path
    if not full_path.exists():
        return ""
    return full_path.read_text(encoding="utf-8", errors="replace")


def source_audit(port: str) -> dict[str, Any]:
    posture = SOURCE_POSTURES.get(port)
    if posture is None:
        return {
            "port": port,
            "posture": "missing",
            "source_progress": False,
            "wrapper_progress": False,
            "line_atomicity": "unknown",
            "source_paths": [],
            "wrapper_paths": [],
            "notes": "no active-port posture rule",
        }
    source_hits = [path for path in posture.source_paths if "rb.port_progress" in source_text(path)]
    wrapper_hits = [path for path in posture.wrapper_paths if "rb.port_progress" in source_text(path)]
    line_atomicity = "ok"
    if port == "cpp":
        text = source_text("Nodes/Cpp/src/consensus/connect.cpp")
        if "std::cerr << \"cpbitnode_sync_timing\"" in text and "std::cout << \"rb.port_progress \"" in text:
            line_atomicity = "risk"
    if posture.wrapper_paths and not wrapper_hits:
        line_atomicity = "unknown"
    return {
        "port": port,
        "posture": posture.posture,
        "source_progress": bool(source_hits),
        "wrapper_control": bool(posture.wrapper_paths),
        "wrapper_progress": bool(wrapper_hits),
        "line_atomicity": line_atomicity,
        "source_paths": list(posture.source_paths),
        "wrapper_paths": list(posture.wrapper_paths),
        "notes": posture.notes,
    }


def parse_progress_payload(line: str) -> dict[str, Any] | None:
    payload = None
    if PRODUCT_PREFIX in line:
        payload = line.split(PRODUCT_PREFIX, 1)[1].strip()
    elif PRODUCT_PREFIX_EQ in line:
        payload = line.split(PRODUCT_PREFIX_EQ, 1)[1].strip()
    if not payload:
        return None
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def analyze_progress_lines(lines: Iterable[str]) -> dict[str, Any]:
    total = 0
    parseable = 0
    malformed = 0
    complete = 0
    incomplete = 0
    missing_required: set[str] = set()
    recommended_seen: set[str] = set()
    first_height: int | None = None
    final_height: int | None = None
    before_first_block = False
    after_first_block = False
    final_status = ""
    final_blocker: Any = ""
    for line in lines:
        if PRODUCT_PREFIX not in line and PRODUCT_PREFIX_EQ not in line:
            continue
        total += 1
        payload = parse_progress_payload(line)
        if payload is None:
            malformed += 1
            continue
        parseable += 1
        height = payload.get("validated_height")
        if isinstance(height, int):
            if first_height is None:
                first_height = height
            final_height = height
            if height == 0:
                before_first_block = True
            if height > 0:
                after_first_block = True
        missing_for_line = [field for field in REQUIRED_FIELDS if field not in payload]
        if missing_for_line:
            incomplete += 1
            missing_required.update(missing_for_line)
        else:
            complete += 1
        recommended_seen.update(field for field in RECOMMENDED_FIELDS if field in payload)
        final_status = str(payload.get("sync_status") or "")
        final_blocker = payload.get("current_blocker")
    required_ok = complete > 0
    return {
        "progress_lines": total,
        "parseable_lines": parseable,
        "malformed_lines": malformed,
        "complete_lines": complete,
        "incomplete_lines": incomplete,
        "required_ok": required_ok,
        "missing_required": sorted(missing_required),
        "recommended_seen": sorted(recommended_seen),
        "before_first_block": before_first_block,
        "after_first_block": after_first_block,
        "first_height": first_height,
        "final_height": final_height,
        "final_sync_status": final_status,
        "final_blocker": final_blocker,
    }


def latest_proof_log(port: str) -> Path | None:
    campaign_dir = (_rb_paths()['campaigns'])
    if not campaign_dir.exists():
        return None
    candidates = []
    for path in campaign_dir.rglob("*.log"):
        if "worktrees" in path.parts:
            continue
        name = path.name.lower()
        if port.lower() in name and ("proof" in name or "run" in name):
            candidates.append(path)
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def audit_port(port: str, log_path: Path | None = None) -> dict[str, Any]:
    source = source_audit(port)
    path = log_path or latest_proof_log(port)
    if path and path.exists():
        log_analysis = analyze_progress_lines(path.read_text(encoding="utf-8", errors="replace").splitlines())
        log_analysis["log_path"] = rel(path)
    else:
        log_analysis = analyze_progress_lines(())
        log_analysis["log_path"] = ""
    return {**source, **log_analysis}


def audit_ports(ports: Iterable[str] = ACTIVE_PORTS) -> list[dict[str, Any]]:
    return [audit_port(port) for port in ports]


def self_test() -> int:
    clean = (
        'rb.port_progress {"chain":"testnet4","sync_status":"blocks_connecting",'
        '"header_height":1,"validated_height":0,"validated_hash":"0",'
        '"stored_block_height":0,"chainstate_utxo_count":0,"current_blocker":null,"peer":"ref"}\n'
        'rb.port_progress {"chain":"testnet4","sync_status":"target_reached",'
        '"header_height":2,"validated_height":2,"validated_hash":"abc",'
        '"stored_block_height":2,"chainstate_utxo_count":3,"current_blocker":null,'
        '"current_block_height":2,"timing_buckets_ms":{"commit":1}}\n'
    )
    malformed = 'rb.port_progress {"chain":\n'
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "go_proof.log"
        log.write_text(clean + malformed, encoding="utf-8")
        result = audit_port("go", log)
    assert result["posture"] == "writer_owned"
    assert result["progress_lines"] == 3
    assert result["parseable_lines"] == 2
    assert result["malformed_lines"] == 1
    assert result["required_ok"] is True
    assert result["before_first_block"] is True
    assert result["after_first_block"] is True
    assert "peer" in result["recommended_seen"]
    print("port_progress_posture_self_test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ports", default=",".join(ACTIVE_PORTS), help="Comma-separated port list")
    parser.add_argument("--json", action="store_true", help="Print JSON")
    parser.add_argument("--self-test", action="store_true", help="Run self-tests")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    ports = [port.strip() for port in args.ports.split(",") if port.strip()]
    payload = audit_ports(ports)
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        for row in payload:
            print(
                f"{row['port']}: posture={row['posture']} source_progress={row['source_progress']} "
                f"parseable={row['parseable_lines']}/{row['progress_lines']} "
                f"required_ok={row['required_ok']} atomicity={row['line_atomicity']}"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
