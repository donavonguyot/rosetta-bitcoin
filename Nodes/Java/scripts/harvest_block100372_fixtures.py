#!/usr/bin/env python3
"""Harvest block 100372 P2TR tapscript fixtures (JavaNode)."""
from __future__ import annotations

import base64
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

HEIGHT = 100372
BLOCK_HASH = "0000000000000001045601b31d97ed13432063adc1230f0e671a72612e4dd585"
TXID = "3f827e83af1e19ca365c694209bcb347d7e0719beed1a86ae7cd6c0c5af2c2b0"
INPUT_INDEX = 0
PREV_SPK = "51204f6ace74750488830e5298071ff3a8a9ed6e101add19c2ac8f6910646c9282f0"


def rpc(method: str, params: list) -> object:
    body = json.dumps({"jsonrpc": "1.0", "id": "x", "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC_URL, data=body, method="POST")
    token = base64.b64encode(f"{RPC_AUTH[0]}:{RPC_AUTH[1]}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("Content-Type", "text/plain;")
    with urllib.request.urlopen(req, timeout=120) as resp:
        out = json.loads(resp.read())
    if out.get("error"):
        raise RuntimeError(out["error"])
    return out["result"]


def main() -> int:
    assert rpc("getblockhash", [HEIGHT]) == BLOCK_HASH
    block_hex = rpc("getblock", [BLOCK_HASH, False])
    block = rpc("getblock", [BLOCK_HASH, 3])
    tx = next(t for t in block["tx"] if t["txid"] == TXID)
    vin = tx["vin"][INPUT_INDEX]
    prevout = vin["prevout"]
    prev_spk = prevout["scriptPubKey"]["hex"]
    prev_amount = int(round(prevout["value"] * 1e8))
    assert prev_spk == PREV_SPK

    witness = vin.get("txinwitness") or vin.get("witness") or []
    tapscript = witness[-2]
    control_block = witness[-1]
    prefix = "tx_p2tr_tapscript_100372"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(tx["hex"], encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_tapscript.hex").write_text(tapscript, encoding="ascii")
    (FIXTURES / f"{prefix}_control_block.hex").write_text(control_block, encoding="ascii")
    for index, item in enumerate(witness[:-2]):
        (FIXTURES / f"{prefix}_witness_{index}.hex").write_text(item if item else "", encoding="ascii")

    prevout_rows = []
    for block_vin in tx["vin"]:
        block_prevout = block_vin["prevout"]
        prevout_rows.append(
            {
                "txid": block_vin["txid"],
                "vout": block_vin["vout"],
                "amount": int(round(block_prevout["value"] * 1e8)),
                "spk": block_prevout["scriptPubKey"]["hex"],
                "height": block_prevout.get("height"),
            }
        )
    (FIXTURES / f"{prefix}_prevouts.json").write_text(
        json.dumps(prevout_rows, indent=2) + "\n",
        encoding="ascii",
    )

    meta = {
        "height": HEIGHT,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "input_index": INPUT_INDEX,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": prev_amount,
        "template": "P2TR script-path",
        "tapscript_asm": rpc("decodescript", [tapscript]).get("asm"),
        "witness_stack_len": len(witness),
        "input_sequence": vin["sequence"],
        "tx_version": tx["version"],
        "locktime": tx["locktime"],
        "missing_rule": "(pending classify)",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
