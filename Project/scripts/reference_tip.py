#!/usr/bin/env python3
"""Read local Reference Core tip truth for Project benchmark control."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
REFERENCE_CONTAINER = "rosetta-bitcoin-core-testnet4"
BITCOIN_CLI = ["bitcoin-cli", "-conf=/config/bitcoin.conf"]


def run_cli(*args: str) -> str:
    completed = subprocess.run(
        ["docker", "exec", REFERENCE_CONTAINER, *BITCOIN_CLI, *args],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def reference_tip() -> dict[str, Any]:
    info = json.loads(run_cli("getblockchaininfo"))
    height = int(info["blocks"])
    return {
        "height": height,
        "hash": run_cli("getblockhash", str(height)),
        "headers": int(info.get("headers", height)),
        "chain": info.get("chain", "testnet4"),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-local-reference", action="store_true", help="Require reachable local Reference Core")
    parser.add_argument("--height", type=int, help="Return the hash for a specific height instead of the current tip")
    parser.add_argument("--json", action="store_true", help="Emit JSON only")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.height is not None:
            payload = {"height": args.height, "hash": run_cli("getblockhash", str(args.height))}
        else:
            payload = reference_tip()
    except Exception as exc:
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}))
        else:
            print(f"reference_tip_check failed: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps({"ok": True, **payload}, sort_keys=True))
    else:
        print(f"reference_tip chain={payload.get('chain', 'testnet4')} height={payload['height']} hash={payload['hash']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
