#!/usr/bin/env python3
"""Harvest block 78841 P2TR tapscript fixtures (JavaNode)."""
from __future__ import annotations

import base64
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")
MEMPOOL_TX = "https://mempool.space/testnet4/api/tx/"

HEIGHT = 78841
BLOCK_HASH = "00000000f318b4ed5b3892d6ab9dde7fe4f97088e5f2b9da9e2f3f8726523105"
TXID = "bf0784a56eabe4ecee38125cd3734bfc9684ea217b1a77a895cc6428d08386a6"
PREV_SPK = "51200802292f03446b96320057012cf509983f667607ef39091d1e5a392705b44c0b"
INPUT_INDEX = 1


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

    prefix = "tx_p2tr_tapscript_78841"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    if block_hex:
        (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(tx_hex, encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_tapscript.hex").write_text(tapscript, encoding="ascii")
    (FIXTURES / f"{prefix}_control_block.hex").write_text(control_block, encoding="ascii")
    for index, item in enumerate(witness[:-2]):
        (FIXTURES / f"{prefix}_witness_{index}.hex").write_text(item if item else "", encoding="ascii")
    prevout_rows = []
    for index, block_vin in enumerate(rpc_tx["vin"]):
        if "prevout" in block_vin:
            prevout = block_vin["prevout"]
            if "scriptPubKey" in prevout:
                row_spk = prevout["scriptPubKey"]["hex"]
                row_amount = int(round(prevout["value"] * 1e8))
            else:
                row_spk = prevout["scriptpubkey"]
                row_amount = int(prevout["value"])
            row_height = prevout.get("height")
        else:
            prev_tx = mempool_tx(block_vin["txid"])
            prevout = prev_tx["vout"][block_vin["vout"]]
            row_spk = prevout["scriptpubkey"]
            row_amount = prevout["value"]
            row_height = None
        prevout_rows.append(
            {
                "txid": block_vin["txid"],
                "vout": block_vin["vout"],
                "amount": row_amount,
                "spk": row_spk,
                "height": row_height,
            }
        )
    (FIXTURES / f"{prefix}_prevouts.json").write_text(
        json.dumps(prevout_rows, indent=2) + "\n",
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
