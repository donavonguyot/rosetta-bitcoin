#!/usr/bin/env python3
"""Harvest block 107951 P2PKH fixtures (JavaNode)."""
from __future__ import annotations

import base64
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

HEIGHT = 107951
BLOCK_HASH = "0000000000000000ac8dc98f4b428367f9d2938583d4d8f1066794a5f5a31cd3"
TXID = "e03dcb1abb013ee01a379d2fd01822ac00acb9df0a9e483a23f162bcc2787206"
INPUT_INDEX = 0
PREV_SPK = "76a91479337b08ef373907bae9132b85848b83f445881b88ac"


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

    prefix = "tx_p2pkh_107951"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(rpc_tx["hex"], encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_scriptsig.hex").write_text(vin["scriptSig"]["hex"], encoding="ascii")
    prevout_rows = [
        {
            "txid": block_vin["txid"],
            "vout": block_vin["vout"],
            "amount": int(round(block_vin["prevout"]["value"] * 1e8)),
            "spk": block_vin["prevout"]["scriptPubKey"]["hex"],
            "height": block_vin["prevout"].get("height"),
        }
        for block_vin in rpc_tx["vin"]
    ]
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
        "prev_height": prevout.get("height"),
        "template": "P2PKH",
        "scriptsig_asm": vin["scriptSig"].get("asm"),
        "tx_version": rpc_tx["version"],
        "locktime": rpc_tx["locktime"],
        "input_sequence": vin["sequence"],
        "missing_rule": "terminalSuccessStrict rejects extra scriptSig stack item (OP_1 prefix)",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
