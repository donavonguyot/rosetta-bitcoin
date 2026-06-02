#!/usr/bin/env python3
"""Offline survey of native state and stored block output templates."""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

from pybitnode.config import Settings
from pybitnode.db.tracker import ProjectTracker


def _classify_scriptpubkey(spk: bytes) -> str:
    from pybitnode.consensus.script.interpreter import (
        is_bare_op_n,
        is_p2pk,
        is_p2pkh,
        is_p2sh,
        is_p2tr,
        is_p2wpkh,
        is_p2wsh,
        witness_program_version,
    )

    if is_p2tr(spk):
        return "p2tr"
    if is_p2wpkh(spk):
        return "p2wpkh"
    if is_p2wsh(spk):
        return "p2wsh"
    wpv = witness_program_version(spk)
    if wpv is not None and wpv > 1:
        return f"witness_v{wpv}"
    if is_p2sh(spk):
        return "p2sh"
    if is_p2pkh(spk):
        return "p2pkh"
    if is_p2pk(spk):
        return "p2pk"
    if is_bare_op_n(spk):
        return "bare_op_n"
    if not spk:
        return "empty"
    if spk[0] == 0x6A:
        return "op_return"
    return f"other(0x{spk[0]:02x},len={len(spk)})"


def _summarize_supported_templates() -> tuple[str, ...]:
    return (
        "P2PK (<pubkey> checksig)",
        "P2PKH",
        "Bare OP_1..OP_16 / OP_1NEGATE (legacy, empty scriptSig)",
        "P2SH (nested evaluation; inner script uses interpreter opcode subset)",
        "Witness v0 P2WPKH / P2WSH (incl. multisig redeem scripts via CHECKMULTISIG)",
        "Taproot v1 P2TR key-path and script-path (BIP341/342 subset)",
        "Witness v2+ programs: explicitly rejected at spend time (unsupported witness program version N)",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-path", type=Path, default=None)
    parser.add_argument("--chain", default=None)
    parser.add_argument("--scan-blocks", type=int, metavar="N", default=0)
    parser.add_argument("--blocks-dir", type=Path, default=None)
    args = parser.parse_args()

    settings = Settings.from_env()
    if args.state_path:
        settings.state_path = str(args.state_path)
    if args.chain:
        settings.chain = args.chain

    from pybitnode.chain.params import get_chain
    from pybitnode.consensus.block import Block
    from pybitnode.storage.blocks import BlockStore

    chain = get_chain(settings.chain)
    blocks_dir = args.blocks_dir or Path(settings.blocks_dir())
    tracker = ProjectTracker(settings.resolved_state_path())
    try:
        summary = tracker.summary(settings.chain)
        sync = summary.get("sync", {}) if isinstance(summary.get("sync"), dict) else {}
        print("=== chain_state ===")
        print(f"  validated_height: {summary.get('validated_height', 0)}")
        print(f"  validated_hash:   {summary.get('validated_hash', '')}")
        print("=== sync_state ===")
        print(f"  best_height:   {sync.get('best_height', 0)}")
        print(f"  header_count:  {summary.get('header_count', 0)}")
        print(f"  sync_status:   {sync.get('sync_status', 'unknown')}")
        print("=== blocks index ===")
        print(f"  max_stored_height: {tracker.max_stored_block_height()}")
        print(f"  stored_minus_validated: {tracker.max_stored_block_height() - int(summary.get('validated_height', 0) or 0)}")

        print("\n=== supported spend templates ===")
        for item in _summarize_supported_templates():
            print(f"  - {item}")

        if args.scan_blocks <= 0:
            return 0
        store = BlockStore(blocks_dir, chain.magic)
        counts: Counter[str] = Counter()
        validated = tracker.get_validated_height(settings.chain)
        for height in range(validated + 1, validated + args.scan_blocks + 1):
            row = tracker.get_block(height)
            if row is None:
                continue
            raw = store.read(row["file_name"], int(row["file_offset"]), int(row["size"]))
            block = Block.deserialize(raw)
            for tx in block.transactions:
                for out in tx.outputs:
                    counts[_classify_scriptpubkey(out.script_pubkey)] += 1
        print("\n=== next stored block output templates ===")
        for template, count in counts.most_common():
            print(f"  {template}: {count}")
        return 0
    finally:
        tracker.close()


if __name__ == "__main__":
    raise SystemExit(main())
