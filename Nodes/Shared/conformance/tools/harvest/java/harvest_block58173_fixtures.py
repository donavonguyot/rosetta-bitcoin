#!/usr/bin/env python3
"""One-off harvest for block 58173 P2WSH OP_0NOTEQUAL witness fixtures (JavaNode)."""
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

HEIGHT = 58173
BLOCK_HASH = "0000000082559fc009f52f9c28226648a820546f54d211d0ab394937b573ebbf"
TXID = "d04fef455929e77e5e4a29b6708051037a11953fbec64240c3689bef9a1320cd"
PREV_SPK = "0020bf25d8d9e80fb053af13bc24117ea4841e38483bdc87bf2058e474f33bc4d049"


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
    witness_script = witness[-1]

    prefix = "tx_p2wsh_mul_58173"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(rpc_tx["hex"], encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_witness_script.hex").write_text(witness_script, encoding="ascii")
    for index, item in enumerate(witness[:-1]):
        (FIXTURES / f"{prefix}_witness_{index}.hex").write_text(item if item else "", encoding="ascii")
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
        "input_index": 0,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": prev_amount,
        "template": "P2WSH",
        "witness_script_hex": witness_script,
        "witness_script_asm": rpc("decodescript", [witness_script]).get("asm"),
        "witness_stack_len": len(witness),
        "input_sequence": vin["sequence"],
        "tx_version": rpc_tx["version"],
        "locktime": rpc_tx["locktime"],
        "missing_rule": "OP_0NOTEQUAL (0x92) in P2WSH witness script evaluation",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
