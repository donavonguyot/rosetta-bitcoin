#!/usr/bin/env python3
"""One-off harvest for block 61174 P2PKH script fixtures (JavaNode)."""
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

HEIGHT = 61174
BLOCK_HASH = "000000003995e8565576f097277246a4e52426360292aea0fa1d76636d3cd30c"
TXID = "4942f8db3e32bd1f114fbfb5c500e0f9cd06c3c235ffe77b07087750b86cc0ea"
INPUT_INDEX = 1
PREV_SPK = "76a914c103e57c094061209b419e5ca559704a8a22f3f988ac"


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

    vin = rpc_tx["vin"][INPUT_INDEX]
    prevout = vin["prevout"]
    prev_spk = prevout["scriptPubKey"]["hex"]
    prev_amount = int(round(prevout["value"] * 1e8))
    assert prev_spk == PREV_SPK

    script_sig = vin.get("scriptSig", {}).get("hex", "")
    script_sig_asm = vin.get("scriptSig", {}).get("asm", "")

    prefix = "tx_p2pkh_61174"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / f"block_{HEIGHT}.hex").write_text(block_hex, encoding="ascii")
    (FIXTURES / f"{prefix}.hex").write_text(rpc_tx["hex"], encoding="ascii")
    (FIXTURES / f"{prefix}_prev_spk.hex").write_text(prev_spk, encoding="ascii")
    (FIXTURES / f"{prefix}_scriptsig.hex").write_text(script_sig, encoding="ascii")
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

    redeem_script = None
    redeem_asm = None
    if script_sig:
        # P2PKH scriptSig is sig + pubkey; no redeem script. Try decodescript on scriptSig.
        try:
            decoded = rpc("decodescript", [script_sig])
            redeem_asm = decoded.get("asm")
        except RuntimeError:
            pass

    meta = {
        "height": HEIGHT,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "input_index": INPUT_INDEX,
        "spent_script_pubkey": prev_spk,
        "prev_amount_sats": prev_amount,
        "template": "P2PKH",
        "scriptsig_hex": script_sig,
        "scriptsig_asm": script_sig_asm,
        "input_sequence": vin["sequence"],
        "tx_version": rpc_tx["version"],
        "locktime": rpc_tx["locktime"],
        "missing_rule": "SIGHASH_SINGLE placeholder empty outputs before signed index (inputIndex > 0)",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="ascii")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
