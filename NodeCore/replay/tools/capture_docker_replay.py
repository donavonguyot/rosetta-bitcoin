#!/usr/bin/env python3
"""Capture or normalize a Docker/local-reference replay proof into telemetry v1."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from replay_common import load_json, normalize_replay_artifact, write_json


def extract_last_json(text: str) -> dict[str, Any]:
    decoder = json.JSONDecoder()
    candidates: list[dict[str, Any]] = []
    for idx, char in enumerate(text):
        if char != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[idx:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            candidates.append(value)
    if not candidates:
        raise ValueError("command output did not contain a JSON object")
    return candidates[-1]


def run_command(command: list[str]) -> tuple[int, str, int]:
    started = time.monotonic()
    proc = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    elapsed_ms = int((time.monotonic() - started) * 1000)
    return proc.returncode, proc.stdout, elapsed_ms


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-result", help="normalize an existing proof JSON instead of running a command")
    parser.add_argument("--output", required=True, help="telemetry JSON output path")
    parser.add_argument("--command-name", default="", help="human-readable command label")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="command to run after --")
    args = parser.parse_args()

    output = Path(args.output)
    if args.from_result:
        source = Path(args.from_result)
        telemetry = normalize_replay_artifact(load_json(source), source_path=source)
        write_json(output, telemetry)
        print(json.dumps({"result": "passed", "output": str(output), "source": str(source)}, indent=2, sort_keys=True))
        return 0

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise SystemExit("expected --from-result or a command after --")

    returncode, combined_output, elapsed_ms = run_command(command)
    try:
        raw = extract_last_json(combined_output)
        telemetry = normalize_replay_artifact(raw, command=command)
    except Exception as exc:
        telemetry = normalize_replay_artifact(
            {
                "result": "failed",
                "implementation": args.command_name or command[0],
                "runtime_surface": "docker",
                "proof_mode": "unknown",
                "target_height": 0,
                "validated_height": 0,
                "timing_summary": {"total_ms": elapsed_ms, "stage_totals_ms": {}},
                "current_blocker": {"failure": str(exc)},
            },
            command=command,
        )
    telemetry["command_returncode"] = returncode
    telemetry["command_elapsed_ms"] = elapsed_ms
    telemetry["stdout_tail"] = combined_output[-12000:]
    if returncode != 0 and telemetry.get("result") == "unknown":
        telemetry["result"] = "failed"
    write_json(output, telemetry)
    print(json.dumps({"result": telemetry["result"], "output": str(output), "returncode": returncode}, indent=2, sort_keys=True))
    return returncode


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(main())
