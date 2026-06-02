#!/usr/bin/env python3
"""Harvest block 108972 P2SH stack-op redeem fixtures (JavaNode)."""
from __future__ import annotations

import base64
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

HEIGHT = 108972
BLOCK_HASH = "00000000000000018efb8d326b651300cc066ffbd804b4cfc0f41a5f00fe0552"
TXID = "9a3d5d60b83e3b0d0469be19e8df6510c04d6d89f7e9db14b509dbf853da79f0"
INPUT_INDEX = 0
PREV_SPK = "a914844a0e2219b6b30d31fddb92f78581e17031a2de87"


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


def parse_pushes(script_hex: str) -> list[bytes]:
    script = bytes.fromhex(script_hex)
    pushes: list[bytes] = []
    offset = 0
    while offset < len(script):
        op = script[offset]
        if 1 <= op <= 75:
            pushes.append(script[offset + 1 : offset + 1 + op])
            offset += 1 + op
        elif op == 0x4C:
            size = script[offset + 1]
            pushes.append(script[offset + 2 : offset + 2 + size])
            offset += 2 + size
        elif op == 0x4D:
            size = int.from_bytes(script[offset + 1 : offset + 3], "little")
            pushes.append(script[offset + 3 : offset + 3 + size])
            offset += 3 + size
        else:
            offset += 1
    return pushes


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

    scriptsig = vin["scriptSig"]["hex"]
    redeem_script = parse_pushes(scriptsig)[-1].hex()
    redeem_asm = rpc("decodescript", [redeem_script]).get("asm")

    prefix = "tx_p2sh_108972"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(tx["hex"], encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_scriptsig.hex").write_text(scriptsig, encoding="ascii")
    (FIXTURES / f"{prefix}_redeem_script.hex").write_text(redeem_script, encoding="ascii")
    (FIXTURES / f"{prefix}_prevouts.json").write_text(
        json.dumps(
            [
                {
                    "txid": vin["txid"],
                    "vout": vin["vout"],
                    "amount": prev_amount,
                    "spk": prev_spk,
                    "height": prevout.get("height"),
                }
            ],
            indent=2,
        )
        + "\n",
        encoding="ascii",
    )
    meta = {
        "height": HEIGHT,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "input_index": INPUT_INDEX,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": prev_amount,
        "template": "P2SH",
        "redeem_script_hex": redeem_script,
        "redeem_script_asm": redeem_asm,
        "scriptsig_asm": vin["scriptSig"]["asm"],
        "witness_stack_len": len(vin.get("txinwitness") or []),
        "java_blocker": "script verification failed for input 0 @108972",
        "missing_rule": "OP_2SWAP (0x72), OP_PICK (0x79), OP_2OVER (0x70), OP_DEPTH (0x74) in legacy P2SH redeem",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
