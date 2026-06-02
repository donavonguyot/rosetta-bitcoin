#!/usr/bin/env python3
"""One-off harvest for block 27807 P2SH IF/ELSE + OP_SHA256 fixtures (JavaNode)."""
from __future__ import annotations

import hashlib
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

BLOCK_HASH = "000000000024e0d475a335fe6bbf8032bd342337f98bb378423bc43fb5187ffc"
TXID = "d1a68c8f20cc0ce8297e4f4b5ec297af1c6f98630e8105fd9d63b39c004c4ff0"
PREV_SPK = "a914d569ebaca3b27115a284275caae03594e3e50db687"
PREV_AMOUNT = 489171


def rpc(method: str, params: list) -> object:
    body = json.dumps({"jsonrpc": "1.0", "id": "x", "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC_URL, data=body, method="POST")
    import base64

    token = base64.b64encode(f"{RPC_AUTH[0]}:{RPC_AUTH[1]}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("Content-Type", "text/plain;")
    with urllib.request.urlopen(req, timeout=30) as resp:
        out = json.loads(resp.read())
    if out.get("error"):
        raise RuntimeError(out["error"])
    return out["result"]


def parse_script_pushes(script: bytes) -> list[tuple[bytes, str]]:
    off = 0
    items: list[tuple[bytes, str]] = []
    while off < len(script):
        op = script[off]
        off += 1
        if op == 0:
            items.append((b"", "OP_0"))
            continue
        if 1 <= op <= 75:
            n = op
        elif op == 0x4C:
            n = script[off]
            off += 1
        elif op == 0x4D:
            n = int.from_bytes(script[off : off + 2], "little")
            off += 2
        elif op == 0x4E:
            n = int.from_bytes(script[off : off + 4], "little")
            off += 4
        else:
            items.append((bytes([op]), f"OP_{op:02x}"))
            continue
        items.append((script[off : off + n], f"PUSH({n})"))
        off += n
    return items


def write_hex(path: Path, data: bytes) -> None:
    path.write_text(data.hex(), encoding="ascii")
    print(f"wrote {path.name} ({len(data)} bytes)")


def main() -> int:
    rpc_hash = rpc("getblockhash", [27807])
    assert rpc_hash == BLOCK_HASH, (rpc_hash, BLOCK_HASH)

    block_hex = rpc("getblock", [BLOCK_HASH, False])
    block_verbose = rpc("getblock", [BLOCK_HASH, 2])
    rpc_tx = next(t for t in block_verbose["tx"] if t["txid"] == TXID)
    assert rpc_tx["txid"] == TXID

    payload = bytes.fromhex(rpc_tx["hex"])
    script_sig = bytes.fromhex(rpc_tx["vin"][0]["scriptSig"]["hex"])
    pushes = parse_script_pushes(script_sig)
    sig, preimage_push, _, redeem = pushes[0][0], pushes[1][0], pushes[2], pushes[3][0]

    else_idx = redeem.index(0x67)
    endif_idx = redeem.index(0x68)
    if_branch = redeem[1:else_idx]
    else_branch = redeem[else_idx + 1 : endif_idx]

    digest = hashlib.sha256(preimage_push).digest()

    FIXTURES.mkdir(parents=True, exist_ok=True)
    write_hex(FIXTURES / "block_27807.hex", bytes.fromhex(block_hex))
    write_hex(FIXTURES / "tx_p2sh_ifelse_sha256_27807.hex", payload)
    write_hex(FIXTURES / "tx_p2sh_ifelse_sha256_27807_prev_spk.hex", bytes.fromhex(PREV_SPK))
    (FIXTURES / "tx_p2sh_ifelse_sha256_27807_prevouts.json").write_text(
        json.dumps([{"amount": PREV_AMOUNT, "spk": PREV_SPK}], indent=2) + "\n",
        encoding="ascii",
    )
    write_hex(FIXTURES / "tx_p2sh_ifelse_sha256_27807_scriptsig.hex", script_sig)
    write_hex(FIXTURES / "tx_p2sh_ifelse_sha256_27807_scriptsig_sig.hex", sig)
    write_hex(FIXTURES / "tx_p2sh_ifelse_sha256_27807_scriptsig_preimage.hex", preimage_push)
    write_hex(FIXTURES / "tx_p2sh_ifelse_sha256_27807_scriptsig_branch.hex", b"")
    write_hex(FIXTURES / "tx_p2sh_ifelse_sha256_27807_redeem_script.hex", redeem)
    write_hex(FIXTURES / "tx_p2sh_ifelse_sha256_27807_redeem_if_branch.hex", if_branch)
    write_hex(FIXTURES / "tx_p2sh_ifelse_sha256_27807_redeem_else_branch.hex", else_branch)
    write_hex(FIXTURES / "tx_p2sh_ifelse_sha256_27807_sha256_digest.hex", digest)

    meta = {
        "height": 27807,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "block_tx_index": block_verbose["tx"].index(rpc_tx),
        "input_index": 0,
        "prev_txid": rpc_tx["vin"][0]["txid"],
        "prev_vout": rpc_tx["vin"][0]["vout"],
        "prev_amount_sats": PREV_AMOUNT,
        "branch_selector": "OP_0 (false → OP_ELSE / SHA256 hashlock path)",
        "preimage_ascii": preimage_push.decode(),
        "sha256_preimage_hex": digest.hex(),
        "if_branch_ops": "OP_IF … PUSH(2) OP_SWAP OP_SUB PUSH(1) OP_GREATERTHAN (inactive)",
        "else_branch_ops": "OP_ELSE OP_SHA256 PUSH(32) OP_EQUALVERIFY",
        "post_endif_ops": "PUSH(65) uncompressed pubkey OP_CHECKSIG",
        "python_test": "test_real_testnet4_block27807_p2sh_if_else_sha256_accepted",
    }
    (FIXTURES / "tx_p2sh_ifelse_sha256_27807_branch.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="ascii"
    )

    print("scriptSig pushes:", [label for _, label in pushes])
    print("preimage:", preimage_push.decode(), "sha256:", digest.hex())
    print("redeem len:", len(redeem))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
