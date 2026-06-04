#!/usr/bin/env python3
"""One-off harvest for block 46779 P2WSH SIZE/LESSTHAN/CODESEPARATOR fixtures (JavaNode)."""
from __future__ import annotations

import base64
import json
import urllib.request
from pathlib import Path

TOOL_PATH = Path(__file__).resolve()
REPO_ROOT = next(parent for parent in TOOL_PATH.parents if (parent / "Nodes" / "Java").exists())
JAVA_ROOT = REPO_ROOT / "Nodes" / "Java"
FIXTURES = JAVA_ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

HEIGHT = 46779
BLOCK_HASH = "0000000000000002ed00d479b1f8f4dc5bc1d033eb6d13c3b653010ef5bdba58"
TXID = "fb9b18c782c2b45ccb77b4e22cbdf8b8cb1b8bf603289937968da52475e28aa5"
PREV_SPK = "0020359eaf2fdfc8952db69827596cf6fe9093f203bdbbd83749a9953f58a3a93829"


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

    witness = vin["txinwitness"]
    assert len(witness) == 2

    prefix = "tx_p2wsh_size_lessthan_46779"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(rpc_tx["hex"], encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_scriptsig.hex").write_text("", encoding="ascii")
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
    for index, item in enumerate(witness):
        (FIXTURES / f"{prefix}_witness_{index}.hex").write_text(item, encoding="ascii")
    (FIXTURES / f"{prefix}_witness_script.hex").write_text(witness[-1], encoding="ascii")

    witness_script = bytes.fromhex(witness[-1])
    meta = {
        "height": HEIGHT,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "input_index": 0,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": prev_amount,
        "witness_stack_len": len(witness),
        "witness_script_hex": witness[-1],
        "witness_script_template": "OP_SIZE PUSH(80) OP_LESSTHAN OP_VERIFY OP_CODESEPARATOR PUSH(33) OP_CHECKSIG",
        "codeseparator_offset": 6,
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print("witness script:", witness[-1])
    print("template:", meta["witness_script_template"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
