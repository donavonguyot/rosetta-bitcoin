#!/usr/bin/env python3
"""One-off harvest for block 51340 P2SH OP_ADD redeem fixtures (JavaNode)."""
from __future__ import annotations

import base64
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

HEIGHT = 51340
BLOCK_HASH = "00000000008951628db430d112a92f8dd350a1eb3681410314c0ca9cf2ced81e"
TXID = "03911305033a5aa73d7d730f16ba63b53582c6a6570d8d9f86e2f2b76fa2cbc3"
PREV_SPK = "a914c464d0169c41085bcf10e3ab2cf83e74859d640b87"
REDEEM_SCRIPT = "935387"


def rpc(method: str, params: list) -> object:
    body = json.dumps({"jsonrpc": "1.0", "id": "x", "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC_URL, data=body, method="POST")
    token = base64.b64encode(f"{RPC_AUTH[0]}:{RPC_AUTH[1]}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("Content-Type", "text/plain;")
    with urllib.request.urlopen(req, timeout=30) as resp:
        out = json.loads(resp.read())
    if out.get("error"):
        raise RuntimeError(out["error"])
    return out["result"]


def main() -> int:
    assert rpc("getblockhash", [HEIGHT]) == BLOCK_HASH

    block_hex = rpc("getblock", [BLOCK_HASH, False])
    block = rpc("getblock", [BLOCK_HASH, 3])
    rpc_tx = next(t for t in block["tx"] if t["txid"] == TXID)

    vin = rpc_tx["vin"][0]
    prevout = vin["prevout"]
    prev_spk = prevout["scriptPubKey"]["hex"]
    prev_amount = int(round(prevout["value"] * 1e8))
    assert prev_spk == PREV_SPK

    scriptsig = vin["scriptSig"]["hex"]
    prefix = "tx_p2sh_add_51340"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(rpc_tx["hex"], encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_scriptsig.hex").write_text(scriptsig, encoding="ascii")
    (FIXTURES / f"{prefix}_redeem_script.hex").write_text(REDEEM_SCRIPT, encoding="ascii")
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
        "block_tx_index": 2,
        "txid": TXID,
        "input_index": 0,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": prev_amount,
        "template": "P2SH",
        "redeem_script_hex": REDEEM_SCRIPT,
        "redeem_script_asm": "OP_ADD OP_3 OP_EQUAL",
        "redeem_script_opcode_sequence": "OP_ADD OP_3 OP_EQUAL",
        "scriptsig_asm": "1 2 -480147",
        "witness_stack_len": 0,
        "java_blocker": "script verification failed for input 0 @51340 (resolved)",
        "missing_rule": "OP_ADD (0x93) in legacy P2SH redeem evaluation (resolved)",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
