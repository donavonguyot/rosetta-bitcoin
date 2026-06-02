#!/usr/bin/env python3
"""One-off harvest for block 27815 P2SH IF/ELSE numeric (SWAP/SUB/GT) fixtures (JavaNode)."""
from __future__ import annotations

import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

BLOCK_HASH = "00000000f649f4308fe8859ba632114ae244632461293c031cd905794981b250"
TXID = "2a691884927c92649b0c8759f929b931ba21d75bb21bc21f4a3b5868be0bc4d7"
PREV_SPK = "a9149bd8827378f1a7dbd6f5ace4c90ab98b706fb86287"
PREV_AMOUNT = 740492
OPERAND_PUSH = 2001
THRESHOLD_PUSH = 18


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
    rpc_hash = rpc("getblockhash", [27815])
    assert rpc_hash == BLOCK_HASH, (rpc_hash, BLOCK_HASH)

    block_hex = rpc("getblock", [BLOCK_HASH, False])
    block_verbose = rpc("getblock", [BLOCK_HASH, 2])
    rpc_tx = next(t for t in block_verbose["tx"] if t["txid"] == TXID)
    assert rpc_tx["txid"] == TXID

    payload = bytes.fromhex(rpc_tx["hex"])
    script_sig = bytes.fromhex(rpc_tx["vin"][0]["scriptSig"]["hex"])
    pushes = parse_script_pushes(script_sig)
    sig, operand_push, branch_sel, redeem = (
        pushes[0][0],
        pushes[1][0],
        pushes[2],
        pushes[3][0],
    )

    else_idx = redeem.index(0x67)
    endif_idx = redeem.index(0x68)
    if_branch = redeem[1:else_idx]
    else_branch = redeem[else_idx + 1 : endif_idx]

    decoded = rpc("decodescript", [redeem.hex()])
    if_asm = decoded["asm"].split(" OP_ELSE ")[0].removeprefix("OP_IF ")

    FIXTURES.mkdir(parents=True, exist_ok=True)
    write_hex(FIXTURES / "block_27815.hex", bytes.fromhex(block_hex))
    write_hex(FIXTURES / "tx_p2sh_ifelse_numeric_27815.hex", payload)
    write_hex(FIXTURES / "tx_p2sh_ifelse_27815.hex", payload)
    write_hex(FIXTURES / "tx_p2sh_ifelse_numeric_27815_prev_spk.hex", bytes.fromhex(PREV_SPK))
    write_hex(FIXTURES / "tx_p2sh_ifelse_27815_prev_spk.hex", bytes.fromhex(PREV_SPK))
    (FIXTURES / "tx_p2sh_ifelse_numeric_27815_prevouts.json").write_text(
        json.dumps([{"amount": PREV_AMOUNT, "spk": PREV_SPK}], indent=2) + "\n",
        encoding="ascii",
    )
    write_hex(FIXTURES / "tx_p2sh_ifelse_numeric_27815_scriptsig.hex", script_sig)
    write_hex(FIXTURES / "tx_p2sh_ifelse_numeric_27815_scriptsig_sig.hex", sig)
    write_hex(FIXTURES / "tx_p2sh_ifelse_numeric_27815_scriptsig_operand.hex", operand_push)
    write_hex(FIXTURES / "tx_p2sh_ifelse_numeric_27815_scriptsig_branch.hex", branch_sel[0])
    write_hex(FIXTURES / "tx_p2sh_ifelse_numeric_27815_redeem_script.hex", redeem)
    write_hex(FIXTURES / "tx_p2sh_ifelse_numeric_27815_redeem_if_branch.hex", if_branch)
    write_hex(FIXTURES / "tx_p2sh_ifelse_numeric_27815_redeem_else_branch.hex", else_branch)

    meta = {
        "height": 27815,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "block_tx_index": block_verbose["tx"].index(rpc_tx),
        "input_index": 0,
        "prev_txid": rpc_tx["vin"][0]["txid"],
        "prev_vout": rpc_tx["vin"][0]["vout"],
        "prev_amount_sats": PREV_AMOUNT,
        "branch_selector": "OP_1 (true → OP_IF numeric SWAP/SUB/GREATERTHAN path)",
        "scriptsig_operand": OPERAND_PUSH,
        "if_branch_constant": 2024,
        "if_branch_threshold": THRESHOLD_PUSH,
        "if_branch_ops": if_asm,
        "else_branch_ops": "OP_ELSE OP_SHA256 PUSH(32) OP_EQUALVERIFY (inactive when OP_1 selected)",
        "post_endif_ops": "PUSH(65) uncompressed pubkey OP_CHECKSIG",
        "python_test": "test_real_testnet4_block27815_p2sh_if_else_numeric_branch_accepted",
    }
    (FIXTURES / "tx_p2sh_ifelse_numeric_27815_branch.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="ascii"
    )

    print("scriptSig pushes:", [label for _, label in pushes])
    print("operand push (LE num):", int.from_bytes(operand_push, "little"))
    print("IF branch hex:", if_branch.hex())
    print("IF branch ops (Core):", if_asm)
    print("redeem len:", len(redeem))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
