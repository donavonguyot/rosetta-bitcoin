#!/usr/bin/env python3
"""Compare NodeCore replay telemetry or raw proof artifacts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from replay_common import load_json, normalize_replay_artifact


KEY_STAGES = (
    "block_connect_store_commit",
    "prevout_batch_load",
    "script_verify",
    "commit",
)


def ms_to_s(value: int | None) -> str:
    if value is None:
        return "-"
    return f"{value / 1000:.1f}s"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", nargs="+", help="raw proof or canonical replay telemetry artifacts")
    parser.add_argument("--json", action="store_true", help="emit normalized JSON array")
    args = parser.parse_args()

    rows = []
    for value in args.artifacts:
        path = Path(value)
        telemetry = normalize_replay_artifact(load_json(path), source_path=path)
        rows.append(telemetry)

    rows.sort(key=lambda item: (item.get("port", ""), item.get("target_height", 0), item.get("runtime_surface", "")))

    if args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
        return 0

    headers = [
        "port",
        "runtime",
        "mode",
        "target",
        "validated",
        "result",
        "elapsed",
        *KEY_STAGES,
        "source",
    ]
    print(" | ".join(headers))
    print(" | ".join(["---"] * len(headers)))
    for row in rows:
        stages = row.get("stage_totals_ms", {})
        values = [
            str(row.get("port", "")),
            str(row.get("runtime_surface", "")),
            str(row.get("replay_mode", "")),
            str(row.get("target_height", "")),
            str(row.get("validated_height", "")),
            str(row.get("result", "")),
            ms_to_s(row.get("elapsed_ms")),
            *(ms_to_s(stages.get(stage)) for stage in KEY_STAGES),
            str(row.get("source_artifact", "")),
        ]
        print(" | ".join(values))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
