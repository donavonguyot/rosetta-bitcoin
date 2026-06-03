#!/usr/bin/env python3
"""Harvest block 67562 P2TR tapscript OP_HASH256 fixtures (JavaNode)."""
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
MEMPOOL_TX = "https://mempool.space/testnet4/api/tx/"

HEIGHT = 67562
BLOCK_HASH = "000000000000a28e307403ba980d48b92e264b798fae176d33d08443a8cdd3ae"
TXID = "d3c78c53f3558feeafe22384db58b5ee1d96c5657f366b5b84cf39aedda42c6b"
PREV_SPK = "51204ce2727f5bc13a88d4ac9b95d09a9e0f2584651e074c37820eab48f1872471a4"


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


def mempool_tx(txid: str) -> dict:
    with urllib.request.urlopen(MEMPOOL_TX + txid, timeout=60) as resp:
        return json.loads(resp.read())


def mempool_tx_hex(txid: str) -> str:
    with urllib.request.urlopen(MEMPOOL_TX + txid + "/hex", timeout=60) as resp:
        return resp.read().decode().strip()


def load_block_tx() -> tuple[str, dict]:
    try:
        assert rpc("getblockhash", [HEIGHT]) == BLOCK_HASH
        block_hex = rpc("getblock", [BLOCK_HASH, False])
        block = rpc("getblock", [BLOCK_HASH, 3])
        rpc_tx = next(t for t in block["tx"] if t["txid"] == TXID)
        return block_hex, rpc_tx
    except Exception:
        rpc_tx = mempool_tx(TXID)
        return "", rpc_tx


def main() -> int:
    block_hex, rpc_tx = load_block_tx()
    vin = rpc_tx["vin"][0]
    if "prevout" in vin:
        prevout = vin["prevout"]
        if "scriptPubKey" in prevout:
            prev_spk = prevout["scriptPubKey"]["hex"]
            prev_amount = int(round(prevout["value"] * 1e8))
        else:
            prev_spk = prevout["scriptpubkey"]
            prev_amount = int(prevout["value"])
        prev_height = prevout.get("height")
    else:
        prev_tx = mempool_tx(vin["txid"])
        prevout = prev_tx["vout"][vin["vout"]]
        prev_spk = prevout["scriptpubkey"]
        prev_amount = prevout["value"]
        prev_height = None
    assert prev_spk == PREV_SPK

    witness = vin.get("txinwitness") or vin.get("witness") or []
    tapscript = witness[-2]
    control_block = witness[-1]
    tx_hex = rpc_tx.get("hex") or mempool_tx_hex(TXID)

    prefix = "tx_p2tr_tapscript_hash256_67562"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    if block_hex:
        (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(tx_hex, encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_tapscript.hex").write_text(tapscript, encoding="ascii")
    (FIXTURES / f"{prefix}_control_block.hex").write_text(control_block, encoding="ascii")
    for index, item in enumerate(witness[:-2]):
        (FIXTURES / f"{prefix}_witness_{index}.hex").write_text(item if item else "", encoding="ascii")
    (FIXTURES / f"{prefix}_prevouts.json").write_text(
        json.dumps(
            [
                {
                    "txid": vin["txid"],
                    "vout": vin["vout"],
                    "amount": prev_amount,
                    "spk": prev_spk,
                    "height": prev_height,
                }
            ],
            indent=2,
        )
        + "\n",
        encoding="ascii",
    )

    tapscript_asm = None
    try:
        tapscript_asm = rpc("decodescript", [tapscript]).get("asm")
    except Exception:
        pass

    meta = {
        "height": HEIGHT,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "input_index": 0,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": prev_amount,
        "template": "P2TR script-path",
        "tapscript_asm": tapscript_asm,
        "tapscript_first_opcode": "OP_HASH256 (0xaa)",
        "witness_stack_len": len(witness),
        "input_sequence": vin["sequence"],
        "tx_version": rpc_tx["version"],
        "locktime": rpc_tx["locktime"],
        "missing_rule": "OP_HASH256 (0xaa) in BIP342 tapscript",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
