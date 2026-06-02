#!/usr/bin/env python3
"""Harvest block 121035 P2TR tapscript fixtures (JavaNode)."""
from __future__ import annotations

import base64
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

HEIGHT = 121035
BLOCK_HASH = "000000000000000091270387ce23a89de1c31e268f37e7840720287bc994a478"
TXID = "6125c6db4a3a16e64037cf225a05805499e8587bdf55d986515bc6d6efa12acb"
PREV_SPK = "51206ac8aea43b56713338ada9a0e365d77c2a4b7ab81265eb7bc6138132f0799d4c"
INPUT_INDEX = 0


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
    rpc_tx = next(t for t in block["tx"] if t["txid"] == TXID)
    vin = rpc_tx["vin"][INPUT_INDEX]
    prevout = vin["prevout"]
    prev_spk = prevout["scriptPubKey"]["hex"]
    prev_amount = int(round(prevout["value"] * 1e8))
    assert prev_spk == PREV_SPK

    witness = vin.get("txinwitness") or []
    tapscript = witness[-2]
    control_block = witness[-1]
    tx_hex = rpc_tx["hex"]

    prevouts = []
    for vin_row in rpc_tx["vin"]:
        prevout = vin_row["prevout"]
        prevouts.append(
            {
                "txid": vin_row["txid"],
                "vout": vin_row["vout"],
                "amount": int(round(prevout["value"] * 1e8)),
                "spk": prevout["scriptPubKey"]["hex"],
                "height": prevout.get("height"),
            }
        )

    prefix = "tx_p2tr_tapscript_121035"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(tx_hex, encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_tapscript.hex").write_text(tapscript, encoding="ascii")
    (FIXTURES / f"{prefix}_control_block.hex").write_text(control_block, encoding="ascii")
    for index, item in enumerate(witness[:-2]):
        (FIXTURES / f"{prefix}_witness_{index}.hex").write_text(item if item else "", encoding="ascii")
    (FIXTURES / f"{prefix}_prevouts.json").write_text(
        json.dumps(prevouts, indent=2) + "\n",
        encoding="ascii",
    )

    tapscript_asm = None
    try:
        tapscript_asm = rpc("decodescript", [tapscript]).get("asm")
    except Exception:
        pass

    ts = bytes.fromhex(tapscript)
    meta = {
        "height": HEIGHT,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "input_index": INPUT_INDEX,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": prev_amount,
        "template": "P2TR script-path",
        "tapscript_asm": tapscript_asm,
        "tapscript_first_opcode": f"0x{ts[0]:02x}" if ts else None,
        "tapscript_len": len(ts),
        "witness_stack_len": len(witness),
        "input_sequence": vin["sequence"],
        "tx_version": rpc_tx["version"],
        "locktime": rpc_tx["locktime"],
        "java_blocker": "script verification failed for input 0",
        "missing_rule": "tapscript OP_BOOLOR (0x9b) boolean OR of top two stack items",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
