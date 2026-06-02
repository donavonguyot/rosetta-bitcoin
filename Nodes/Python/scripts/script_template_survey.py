#!/usr/bin/env python3
"""Offline survey: validated tip, rejection events (script stubs), stored-block output tagging.

Opens the SQLite URI in **read-only** mode by default (`?mode=ro`). Does **not**
fetch from the network.

Example:

    PYTHONPATH=. ./scripts/script_template_survey.py --db ./data/pybitnode.db \\
        --chain testnet4 --scan-blocks 20

Ops playbook: docs/OPERATIONS.md (Next consensus gaps / offline survey).
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from collections import Counter
from pathlib import Path

# Allow running without installing the package (repo-root PYTHONPATH=.).
_REPO = Path(__file__).resolve().parent.parent


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
    """Parrots `verify_transaction_input`; keep in sync with verify.py manually."""
    return (
        "P2PK (<pubkey> checksig)",
        "P2PKH",
        "Bare OP_1..OP_16 / OP_1NEGATE (legacy, empty scriptSig)",
        "P2SH (nested evaluation; inner script uses interpreter opcode subset)",
        "Witness v0 P2WPKH / P2WSH (incl. multisig redeem scripts via CHECKMULTISIG)",
        "Taproot v1 P2TR key-path and script-path (BIP341/342 subset)",
        "Witness v2+ programs: explicitly rejected at spend time (unsupported witness program version N)",
    )


def _open_ro(db_path: Path) -> sqlite3.Connection:
    uri = f"file:{db_path.resolve()}?mode=ro"
    return sqlite3.connect(uri, uri=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--db",
        type=Path,
        default=_REPO / "data" / "pybitnode.db",
        help="Path to pybitnode SQLite file (default: ./data/pybitnode.db)",
    )
    parser.add_argument(
        "--chain",
        default="testnet4",
        help="chain name in chain_state / sync_state (default: testnet4)",
    )
    parser.add_argument(
        "--scan-blocks",
        type=int,
        metavar="N",
        default=0,
        help="Classify transaction output scriptPubKeys for stored blocks with height in "
        "(validated_height, validated_height+N]. Use 0 to skip (default).",
    )
    parser.add_argument(
        "--blocks-dir",
        type=Path,
        default=_REPO / "data" / "blocks",
        help="Block flat-file directory (default: ./data/blocks)",
    )
    args = parser.parse_args()

    if not args.db.is_file():
        print(f"error: database not found: {args.db}", file=sys.stderr)
        return 2

    sys.path.insert(0, str(_REPO))

    from pybitnode.chain.params import get_chain
    from pybitnode.consensus.block import Block
    from pybitnode.storage.blocks import BlockStore

    chain = get_chain(args.chain)

    conn = _open_ro(args.db)
    conn.row_factory = sqlite3.Row

    cs = conn.execute(
        "SELECT validated_height, validated_hash FROM chain_state WHERE chain = ?",
        (args.chain,),
    ).fetchone()
    if cs is None:
        print(f"error: no chain_state row for chain={args.chain!r}", file=sys.stderr)
        return 2

    ss = conn.execute(
        "SELECT best_height, header_count, sync_status FROM sync_state WHERE chain = ?",
        (args.chain,),
    ).fetchone()

    mx_row = conn.execute("SELECT MAX(height) AS mh FROM blocks").fetchone()
    max_block = int(mx_row["mh"]) if mx_row and mx_row["mh"] is not None else None

    print("=== chain_state ===")
    print(f"  validated_height: {cs['validated_height']}")
    print(f"  validated_hash:   {cs['validated_hash']}")
    if ss:
        print("=== sync_state ===")
        print(f"  best_height:   {ss['best_height']}")
        print(f"  header_count:  {ss['header_count']}")
        print(f"  sync_status:   {ss['sync_status']}")
    print("=== blocks table ===")
    print(f"  max_stored_height: {max_block}")
    gap = ""
    if max_block is not None and cs["validated_height"] is not None:
        gap = max_block - int(cs["validated_height"])
    print(f"  stored_minus_validated (download ahead): {gap}")

    print("\n=== supported spend templates (see pybitnode/consensus/script/verify.py) ===")
    for item in _summarize_supported_templates():
        print(f"  • {item}")
    print("\n=== interpreter opcode subset ===")
    print(
        "  evaluate_script knows pushes, DUP, HASH160, EQUAL/EQUALVERIFY, VERIFY, "
        "CHECKSIG/CHECKSIGVERIFY, CHECKMULTISIG/CHECKMULTISIGVERIFY, "
        "CHECKLOCKTIMEVERIFY/CHECKSEQUENCEVERIFY (legacy redeem scripts). "
        "Tapscript: CHECKSIG/CHECKSIGVERIFY, CLTV/CSV (BIP65/BIP112 with Schnorr sighash)."
    )
    print("\n=== consensus gaps (still likely on mainnet-style traffic) ===")
    print(
        "  Typical remaining gaps after P2TR (incl. tapscript timelocks) + multisig + legacy "
        "CLTV/CSV:\n"
        "  • Bare/non-template outputs spent on spend path (bare multisig, odd P2PK variants, …).\n"
        "    Unspendable outputs (common OP_RETURN commitments) skip verification.\n"
        "  • Witness v2+ programs are detected and rejected with "
        "'unsupported witness program version N' (not yet implemented; see verify.py)."
    )

    rej = conn.execute(
        "SELECT COUNT(*) AS c FROM events WHERE message = 'Rejected invalid block'"
    ).fetchone()["c"]
    unsup = conn.execute(
        "SELECT COUNT(*) AS c FROM events WHERE message = 'Rejected invalid block' "
        "AND details_json LIKE '%unsupported scriptPubKey template%'"
    ).fetchone()["c"]
    print("\n=== events (all chains in this DB file) ===")
    print(f"  Rejected invalid block (total rows):           {rej}")
    print(f"  …details_json mentions unsupported script…:      {unsup}")

    if args.scan_blocks > 0 and max_block is not None:
        v = int(cs["validated_height"])
        limit_h = min(v + args.scan_blocks, max_block)
        rows = conn.execute(
            """
            SELECT height, file_name, file_offset, size
            FROM blocks
            WHERE height > ? AND height <= ?
            ORDER BY height
            """,
            (v, limit_h),
        ).fetchall()
        conn.close()

        print(
            f"\n=== scan stored blocks heights ({v}, {v + args.scan_blocks}] "
            f"available up to {limit_h} ==="
        )
        if not rows:
            print("  (none — validated tip caught up with stored blocks or nothing downloaded past tip)")
            return 0

        store = BlockStore(Path(args.blocks_dir), chain.magic)
        out_ctr: Counter[str] = Counter()
        for row in rows:
            payload = store.read(row["file_name"], int(row["file_offset"]), int(row["size"]))
            block = Block.deserialize(payload)
            for tx in block.transactions:
                for o in tx.outputs:
                    out_ctr[_classify_scriptpubkey(o.script_pubkey)] += 1
        print(f"  scanned {len(rows)} block(s)")
        for k, cnt in out_ctr.most_common():
            print(f"    {k}: {cnt}")
    else:
        conn.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
