#!/usr/bin/env python3
"""Harvest block 98631 P2WSH witness fixtures (JavaNode)."""
from __future__ import annotations

import base64
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

HEIGHT = 98631
BLOCK_HASH = "0000000000000000067d80ba064a11f2c7d8a548d4e3b71dc5e618c0b7b0fc6d"
TXID = "81fcef3b937234490381c3baa91f627ad80afb9d3b393bc5e376ace380b1c791"
INPUT_INDEX = 0
PREV_SPK = "0020ec0c02a6ab2ecbc6f1e4b6fc83afc0b8ed155bd4d9be8d2b0c1f8fdf29e751d4"


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

    witness = vin["txinwitness"]
    witness_script = witness[-1]

    prefix = "tx_p2wsh_98631"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(rpc_tx["hex"], encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_witness_script.hex").write_text(witness_script, encoding="ascii")
    for index, item in enumerate(witness[:-1]):
        (FIXTURES / f"{prefix}_witness_{index}.hex").write_text(item if item else "", encoding="ascii")

    prevout_rows = []
    for block_vin in rpc_tx["vin"]:
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
        "template": "P2WSH",
        "witness_script_hex": witness_script,
        "witness_script_asm": rpc("decodescript", [witness_script]).get("asm"),
        "witness_stack_len": len(witness),
        "input_sequence": vin["sequence"],
        "tx_version": rpc_tx["version"],
        "locktime": rpc_tx["locktime"],
        "missing_rule": "(pending classify)",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
