#!/usr/bin/env python3
"""Validate Core-style UTXO accounting for benchmark artifacts.

The default mode checks JSON artifacts only. Use --from-reference to recompute
the 5k baseline from the running Reference Core container.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


TARGET_HEIGHT = 5000
TARGET_HASH = "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2"
POLICY = "core_spendable_v1"
CHAINSTATE_UTXO_COUNT = 4574
RAW_EXCLUDING_GENESIS = 9232
RAW_INCLUDING_GENESIS = 9233
GENESIS_HASH = "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "artifacts",
        nargs="*",
        type=Path,
        help="Artifact JSON files to validate. Defaults to 5k benchmark artifacts.",
    )
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=Path("Nodes/Shared/conformance/results"),
        help="Directory to scan when no artifacts are supplied.",
    )
    parser.add_argument(
        "--from-reference",
        action="store_true",
        help="Recompute the 5k baseline from the Reference Core container.",
    )
    parser.add_argument(
        "--strict-metadata",
        action="store_true",
        help="Require explicit utxo_accounting_policy instead of accepting legacy inferred policy.",
    )
    parser.add_argument(
        "--container",
        default="rosetta-bitcoin-core-testnet4",
        help="Reference Core container name for --from-reference.",
    )
    return parser.parse_args()


def as_int(value: Any, default: int = -1) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def artifact_paths(args: argparse.Namespace) -> list[Path]:
    if args.artifacts:
        return args.artifacts
    return sorted(
        [
            *args.results_dir.glob("*docker_baseline_5k_benchmark*.json"),
            *args.results_dir.glob("*docker_supporting_5k_benchmark*.json"),
        ]
    )


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError("artifact root must be a JSON object")
    return payload


def validate_artifact(path: Path, *, strict_metadata: bool) -> list[str]:
    errors: list[str] = []
    try:
        payload = load_json(path)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        return [f"{path}: cannot read artifact: {exc}"]

    if as_int(payload.get("target_height")) != TARGET_HEIGHT:
        return errors
    if payload.get("benchmark_lane") not in {"baseline_5k_p2p", "supporting_5k_p2p"}:
        return errors
    if payload.get("result") != "passed":
        return errors

    reported_policy = payload.get("utxo_accounting_policy")
    if reported_policy != POLICY and (reported_policy is not None or strict_metadata):
        errors.append(
            f"{path}: utxo_accounting_policy={reported_policy!r}; expected {POLICY!r}"
        )
    if as_int(payload.get("validated_height")) != TARGET_HEIGHT:
        errors.append(f"{path}: validated_height={payload.get('validated_height')!r}; expected {TARGET_HEIGHT}")
    if payload.get("validated_hash") != TARGET_HASH:
        errors.append(f"{path}: validated_hash={payload.get('validated_hash')!r}; expected {TARGET_HASH}")
    if as_int(payload.get("chainstate_utxo_count")) != CHAINSTATE_UTXO_COUNT:
        errors.append(
            f"{path}: chainstate_utxo_count={payload.get('chainstate_utxo_count')!r}; "
            f"expected {CHAINSTATE_UTXO_COUNT}"
        )
    return errors


def bitcoin_cli(container: str, *args: object) -> str:
    output = subprocess.check_output(
        ["docker", "exec", container, "bitcoin-cli", "-conf=/config/bitcoin.conf", *map(str, args)],
        text=True,
    )
    return output.strip()


def recompute_reference(container: str) -> dict[str, int | str]:
    raw: set[tuple[str, int]] = set()
    spendable: set[tuple[str, int]] = set()
    raw_with_genesis: set[tuple[str, int]] = set()
    last_hash = ""
    for height in range(0, TARGET_HEIGHT + 1):
        block_hash = bitcoin_cli(container, "getblockhash", height)
        last_hash = block_hash
        block = json.loads(bitcoin_cli(container, "getblock", block_hash, 2))
        for tx in block["tx"]:
            coinbase = bool(tx.get("vin")) and "coinbase" in tx["vin"][0]
            if not coinbase:
                for vin in tx.get("vin", []):
                    key = (vin["txid"], int(vin["vout"]))
                    raw.discard(key)
                    spendable.discard(key)
                    raw_with_genesis.discard(key)
            for vout in tx.get("vout", []):
                key = (tx["txid"], int(vout["n"]))
                script_hex = vout.get("scriptPubKey", {}).get("hex", "") or ""
                unspendable = not script_hex or script_hex.startswith("6a")
                raw_with_genesis.add(key)
                if height != 0:
                    raw.add(key)
                    if not unspendable:
                        spendable.add(key)
    return {
        "height": TARGET_HEIGHT,
        "hash": last_hash,
        "chainstate_utxo_count": len(spendable),
        "raw_unspent_outputs_excluding_genesis": len(raw),
        "raw_unspent_outputs_including_genesis": len(raw_with_genesis),
    }


def validate_reference(counts: dict[str, int | str]) -> list[str]:
    expected = {
        "height": TARGET_HEIGHT,
        "hash": TARGET_HASH,
        "chainstate_utxo_count": CHAINSTATE_UTXO_COUNT,
        "raw_unspent_outputs_excluding_genesis": RAW_EXCLUDING_GENESIS,
        "raw_unspent_outputs_including_genesis": RAW_INCLUDING_GENESIS,
    }
    return [
        f"reference {key}={counts.get(key)!r}; expected {value!r}"
        for key, value in expected.items()
        if counts.get(key) != value
    ]


def main() -> int:
    args = parse_args()
    errors: list[str] = []

    paths = artifact_paths(args)
    for path in paths:
        errors.extend(validate_artifact(path, strict_metadata=args.strict_metadata))

    if args.from_reference:
        counts = recompute_reference(args.container)
        print(json.dumps(counts, indent=2, sort_keys=True))
        errors.extend(validate_reference(counts))

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    print(
        "utxo_accounting_check "
        f"artifacts={len(paths)} policy={POLICY} "
        f"height={TARGET_HEIGHT} chainstate_utxo_count={CHAINSTATE_UTXO_COUNT}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
