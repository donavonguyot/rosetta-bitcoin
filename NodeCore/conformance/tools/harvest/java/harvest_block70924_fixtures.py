#!/usr/bin/env python3
"""Harvest block 70924 P2TR tapscript fixtures (JavaNode)."""
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

HEIGHT = 70924
BLOCK_HASH = "000000000000000274086aa7422c4231dda094f71d750f026adc8748b5018ce2"
TXID = "101d8cd4404f764295479dc7fb14f55623eb032fe8ffaab02482d99455eec5fb"
PREV_SPK = "51202a6d559d4b313016ce3ed49fbc1512b506262d28ad96c84cd2b1233624ac73af"
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
    vin = rpc_tx["vin"][INPUT_INDEX]
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

    prefix = "tx_p2tr_tapscript_70924"
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

    first_opcode = None
    if tapscript:
        ts = bytes.fromhex(tapscript) if isinstance(tapscript, str) else tapscript
        first_opcode = f"0x{ts[0]:02x}" if ts else None

    meta = {
        "height": HEIGHT,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "input_index": INPUT_INDEX,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": prev_amount,
        "template": "P2TR script-path",
        "tapscript_asm": tapscript_asm,
        "tapscript_first_opcode": first_opcode,
        "witness_stack_len": len(witness),
        "input_sequence": vin["sequence"],
        "tx_version": rpc_tx["version"],
        "locktime": rpc_tx["locktime"],
        "missing_rule": "(pending diagnosis)",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    print("tapscript hex:", tapscript)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
