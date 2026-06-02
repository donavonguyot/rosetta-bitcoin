#!/usr/bin/env python3
"""Harvest testnet4 block 63603 P2SH OP_2DUP spend fixtures for jbitnode regression tests."""

from __future__ import annotations

import base64
import json
import sys
import urllib.request
from pathlib import Path

RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = base64.b64encode(b"rosetta:rosetta-dev-only").decode()
BLOCK_HASH = "000000005b5b0f125eadd4a93c0b809e81d1bd1e7f51abd2d12d384aa4d34933"
TXID = "a21adb17edebeee255310e9b37c44a667e7a510bc8181efbf734a86bcac94f74"
INPUT_INDEX = 0
HEIGHT = 63603
FIXTURE_DIR = Path(__file__).resolve().parents[1] / "src/test/resources/fixtures"


def rpc(method: str, params: list) -> object:
    payload = json.dumps({"jsonrpc": "1.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        RPC_URL,
        data=payload,
        headers={"Authorization": f"Basic {RPC_AUTH}", "Content-Type": "text/plain"},
    )
    with urllib.request.urlopen(req) as resp:
        body = json.loads(resp.read())
    if body.get("error"):
        raise RuntimeError(body["error"])
    return body["result"]


def write_hex(name: str, hex_str: str) -> None:
    path = FIXTURE_DIR / name
    path.write_text(hex_str.strip() + "\n", encoding="utf-8")
    print(f"wrote {path.name} ({len(hex_str)//2} bytes)")


def find_block_for_tx(txid: str, start_height: int, max_scan: int = 5000) -> str:
    for height in range(start_height, max(start_height - max_scan, 0), -1):
        block_hash = rpc("getblockhash", [height])
        block = rpc("getblock", [block_hash, 1])
        if txid in block["tx"]:
            return block_hash
    raise RuntimeError(f"tx {txid} not found within {max_scan} blocks of {start_height}")


def main() -> int:
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)

    block = rpc("getblock", [BLOCK_HASH, 3])
    tx_index = next(i for i, tx in enumerate(block["tx"]) if tx["txid"] == TXID)
    tx = next(t for t in block["tx"] if t["txid"] == TXID)
    vin = tx["vin"][INPUT_INDEX]
    prevout = vin["prevout"]

    raw_hex = rpc("getrawtransaction", [TXID, False, BLOCK_HASH])
    write_hex("tx_p2sh_2dup_63603.hex", raw_hex)
    write_hex("block_63603.hex", rpc("getblock", [BLOCK_HASH, False]))

    prev_spk = prevout["scriptPubKey"]["hex"]
    write_hex("tx_p2sh_2dup_63603_prev_spk.hex", prev_spk)

    script_sig_hex = vin["scriptSig"]["hex"]
    write_hex("tx_p2sh_2dup_63603_scriptsig.hex", script_sig_hex)

    pushes = []
    offset = 0
    ss = bytes.fromhex(script_sig_hex)
    while offset < len(ss):
        op = ss[offset]
        if op == 0:
            pushes.append(bytes())
            offset += 1
        elif 1 <= op <= 75:
            pushes.append(ss[offset + 1 : offset + 1 + op])
            offset += 1 + op
        elif op == 0x51:
            pushes.append(bytes([1]))
            offset += 1
        elif 0x52 <= op <= 0x60:
            pushes.append(bytes([op - 0x50]))
            offset += 1
        else:
            offset += 1
    redeem_script = pushes[-1]
    redeem_hex = redeem_script.hex()
    write_hex("tx_p2sh_2dup_63603_redeem_script.hex", redeem_hex)

    amount_sats = round(prevout["value"] * 1e8)
    prevouts = [
        {
            "amount": round(v["prevout"]["value"] * 1e8),
            "spk": v["prevout"]["scriptPubKey"]["hex"],
        }
        for v in tx["vin"]
    ]
    (FIXTURE_DIR / "tx_p2sh_2dup_63603_prevouts.json").write_text(
        json.dumps(prevouts, indent=2) + "\n", encoding="utf-8"
    )
    print("wrote tx_p2sh_2dup_63603_prevouts.json")

    redeem_asm = rpc("decodescript", [redeem_hex])["asm"]
    meta = {
        "height": HEIGHT,
        "block_hash": BLOCK_HASH,
        "block_tx_index": tx_index,
        "txid": TXID,
        "input_index": INPUT_INDEX,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": amount_sats,
        "template": "P2SH",
        "redeem_script_hex": redeem_hex,
        "redeem_script_asm": redeem_asm,
        "redeem_script_opcode_sequence": redeem_asm,
        "scriptsig_asm": vin["scriptSig"]["asm"],
        "witness_stack_len": len(vin.get("txinwitness") or []),
        "java_blocker": "script verification failed for input 0 @63603",
        "missing_rule": "OP_2DUP (0x6e) in legacy P2SH redeem evaluation",
    }
    (FIXTURE_DIR / "tx_p2sh_2dup_63603_meta.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="utf-8"
    )
    print("wrote tx_p2sh_2dup_63603_meta.json")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
