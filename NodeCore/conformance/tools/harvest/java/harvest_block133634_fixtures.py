#!/usr/bin/env python3
"""Harvest block 133634 P2TR tapscript CSV-disable fixtures (JavaNode)."""
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

HEIGHT = 133634
BLOCK_HASH = "00000000000000015ec29857fab62c48cc035f2f9f315dce1c905ded3682f704"
TXID = "d7cf3d38458c05b40651aa89e70b0d1eb64f94f4fcbb730dc9e52f20afe5ef6c"
PREV_SPK = "51206fccfbb9b6866623bb150ee234b95910952db82f72c72795cb6e7740579fa906"
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
    prevouts = []
    for vin_row in rpc_tx["vin"]:
        row_prevout = vin_row["prevout"]
        prevouts.append(
            {
                "txid": vin_row["txid"],
                "vout": vin_row["vout"],
                "amount": int(round(row_prevout["value"] * 1e8)),
                "spk": row_prevout["scriptPubKey"]["hex"],
                "height": row_prevout.get("height"),
            }
        )

    prefix = "tx_p2tr_tapscript_133634"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(rpc_tx["hex"], encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_tapscript.hex").write_text(tapscript, encoding="ascii")
    (FIXTURES / f"{prefix}_control_block.hex").write_text(control_block, encoding="ascii")
    for index, item in enumerate(witness[:-2]):
        (FIXTURES / f"{prefix}_witness_{index}.hex").write_text(item if item else "", encoding="ascii")
    (FIXTURES / f"{prefix}_prevouts.json").write_text(json.dumps(prevouts, indent=2) + "\n", encoding="ascii")

    tapscript_asm = rpc("decodescript", [tapscript]).get("asm")
    meta = {
        "height": HEIGHT,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "input_index": INPUT_INDEX,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": prev_amount,
        "template": "P2TR script-path",
        "tapscript_asm": tapscript_asm,
        "tapscript_len": len(bytes.fromhex(tapscript)),
        "witness_stack_len": len(witness),
        "input_sequence": vin["sequence"],
        "tx_version": rpc_tx["version"],
        "locktime": rpc_tx["locktime"],
        "java_blocker": "script verification failed for input 0 @133634",
        "missing_rule": "CHECKSEQUENCEVERIFY must decode 5-byte locktime operands and no-op when the operand disable flag is set",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
