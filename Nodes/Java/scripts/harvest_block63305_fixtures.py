#!/usr/bin/env python3
"""Harvest testnet4 block 63305 P2SH OP_3DUP spend fixtures for jbitnode regression tests."""

from __future__ import annotations

import base64
import json
import sys
import urllib.request
from pathlib import Path

RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = base64.b64encode(b"rosetta:rosetta-dev-only").decode()
BLOCK_HASH = "0000000000000006d0233f081975a038cc7739f2519991b871eda65ba5c6b1e4"
TXID = "5f2ef82d267e50f4f15c4dc1c04c3b2b1ca74be0fec19697f44cb438ff85caeb"
INPUT_INDEX = 0
HEIGHT = 63305
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

    block = rpc("getblock", [BLOCK_HASH, 2])
    tx_index = next(i for i, tx in enumerate(block["tx"]) if tx["txid"] == TXID)
    tx = rpc("getrawtransaction", [TXID, True, BLOCK_HASH])
    vin = tx["vin"][INPUT_INDEX]
    prev_txid = vin["txid"]
    prev_block_hash = find_block_for_tx(prev_txid, HEIGHT - 1)
    prev_tx = rpc("getrawtransaction", [prev_txid, True, prev_block_hash])
    prevout = prev_tx["vout"][vin["vout"]]

    raw_hex = rpc("getrawtransaction", [TXID, False, BLOCK_HASH])
    write_hex("tx_p2sh_3dup_63305.hex", raw_hex)
    write_hex("block_63305.hex", rpc("getblock", [BLOCK_HASH, False]))

    prev_spk = prevout["scriptPubKey"]["hex"]
    write_hex("tx_p2sh_3dup_63305_prev_spk.hex", prev_spk)

    script_sig_hex = vin["scriptSig"]["hex"]
    write_hex("tx_p2sh_3dup_63305_scriptsig.hex", script_sig_hex)

    redeem = rpc("decodescript", [script_sig_hex])["asm"].split()[-1]
    redeem_info = rpc("decodescript", [redeem if all(c in "0123456789abcdef" for c in redeem) else script_sig_hex.split()[-1]])
    # redeem script is last push in scriptSig
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
    write_hex("tx_p2sh_3dup_63305_redeem_script.hex", redeem_hex)

    amount_sats = round(prevout["value"] * 1e8)
    prevouts = []
    for idx, input_vin in enumerate(tx["vin"]):
        prev_bh = find_block_for_tx(input_vin["txid"], HEIGHT - 1)
        ptx = rpc("getrawtransaction", [input_vin["txid"], True, prev_bh])
        po = ptx["vout"][input_vin["vout"]]
        prevouts.append(
            {
                "amount": round(po["value"] * 1e8),
                "spk": po["scriptPubKey"]["hex"],
            }
        )
    (FIXTURE_DIR / "tx_p2sh_3dup_63305_prevouts.json").write_text(
        json.dumps(prevouts, indent=2) + "\n", encoding="utf-8"
    )
    print("wrote tx_p2sh_3dup_63305_prevouts.json")

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
        "java_blocker": "script verification failed for input 0 @63305",
        "missing_rule": "OP_3DUP (0x6f) in legacy P2SH redeem evaluation",
    }
    (FIXTURE_DIR / "tx_p2sh_3dup_63305_meta.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="utf-8"
    )
    print("wrote tx_p2sh_3dup_63305_meta.json")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
