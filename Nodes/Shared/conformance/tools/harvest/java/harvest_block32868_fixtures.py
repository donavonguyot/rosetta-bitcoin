#!/usr/bin/env python3
"""One-off harvest for block 32868 P2WSH IF/ELSE CLTV fixtures (JavaNode)."""
from __future__ import annotations

import json
import sys
import urllib.request
from pathlib import Path

TOOL_PATH = Path(__file__).resolve()
REPO_ROOT = next(parent for parent in TOOL_PATH.parents if (parent / "Nodes" / "Java").exists())
JAVA_ROOT = REPO_ROOT / "Nodes" / "Java"
FIXTURES = JAVA_ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

BLOCK_HASH = "00000000000000609ae7ba69fd0f7b32ea44503ff9e2bebe70eb34dd13c35ac2"
TXID = "8add2663f689111add26c4bc52a2f6060d48e41750c143cdfa8564ac114d97dc"
PREV_TXID = "9f8ad8477159c64d799486e30d2330816278f678dc77afda687f093f73f9b09c"
PREV_VOUT = 0
PREV_SPK = (
    "00201b3129860946f970569a12850caede1782d2c8163bb26e284bf3f4af1b4e5077"
)

OP_NAMES = {
    0x00: "OP_0",
    0x63: "OP_IF",
    0x67: "OP_ELSE",
    0x68: "OP_ENDIF",
    0x75: "OP_DROP",
    0x76: "OP_DUP",
    0x82: "OP_SIZE",
    0x88: "OP_EQUALVERIFY",
    0xA8: "OP_SHA256",
    0xA9: "OP_HASH160",
    0xAC: "OP_CHECKSIG",
    0xB1: "OP_CHECKLOCKTIMEVERIFY",
}


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


def parse_script(script: bytes) -> list[tuple[bytes, str]]:
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
            items.append((bytes([op]), OP_NAMES.get(op, f"OP_{op:02x}")))
            continue
        items.append((script[off : off + n], f"PUSH({n})"))
        off += n
    return items


def write_hex(path: Path, data: bytes) -> None:
    path.write_text(data.hex(), encoding="ascii")
    print(f"wrote {path.name} ({len(data)} bytes)")


def main() -> int:
    assert rpc("getblockhash", [32868]) == BLOCK_HASH

    block_hex = rpc("getblock", [BLOCK_HASH, False])
    block = rpc("getblock", [BLOCK_HASH, 3])
    rpc_tx = next(t for t in block["tx"] if t["txid"] == TXID)
    assert rpc_tx["txid"] == TXID

    vin = rpc_tx["vin"][0]
    prevout = vin["prevout"]
    prev_spk = prevout["scriptPubKey"]["hex"]
    prev_amount = int(round(prevout["value"] * 1e8))
    assert prev_spk == PREV_SPK
    assert vin["txid"] == PREV_TXID and vin["vout"] == PREV_VOUT

    witness = vin["txinwitness"]
    witness_script = bytes.fromhex(witness[-1])
    pushes = parse_script(witness_script)
    opcode_seq = " ".join(label for _, label in pushes)

    if_off = witness_script.index(0x63)
    else_off = witness_script.index(0x67)
    endif_off = witness_script.index(0x68)
    if_branch = witness_script[if_off + 1 : else_off]
    else_branch = witness_script[else_off + 1 : endif_off]
    post_endif = witness_script[endif_off + 1 :]
    locktime_value = int.from_bytes(else_branch[1:5], "little")

    FIXTURES.mkdir(parents=True, exist_ok=True)
    write_hex(FIXTURES / "block_32868.hex", bytes.fromhex(block_hex))
    write_hex(FIXTURES / "tx_p2wsh_cltv_32868.hex", bytes.fromhex(rpc_tx["hex"]))
    write_hex(FIXTURES / "tx_p2wsh_cltv_32868_prev_spk.hex", bytes.fromhex(prev_spk))
    (FIXTURES / "tx_p2wsh_cltv_32868_prevouts.json").write_text(
        json.dumps([{"amount": prev_amount, "spk": prev_spk}], indent=2) + "\n",
        encoding="ascii",
    )
    for i, item in enumerate(witness):
        write_hex(FIXTURES / f"tx_p2wsh_cltv_32868_witness_{i}.hex", bytes.fromhex(item))
    write_hex(FIXTURES / "tx_p2wsh_cltv_32868_witness_script.hex", witness_script)
    write_hex(FIXTURES / "tx_p2wsh_cltv_32868_witness_script_if_branch.hex", if_branch)
    write_hex(FIXTURES / "tx_p2wsh_cltv_32868_witness_script_else_branch.hex", else_branch)
    write_hex(FIXTURES / "tx_p2wsh_cltv_32868_witness_script_post_endif.hex", post_endif)

    import hashlib

    meta = {
        "height": 32868,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "block_tx_index": block["tx"].index(rpc_tx),
        "input_index": 0,
        "prev_txid": PREV_TXID,
        "prev_vout": PREV_VOUT,
        "prev_amount_sats": prev_amount,
        "prevout_height": prevout["height"],
        "nLockTime": rpc_tx["locktime"],
        "nSequence": vin["sequence"],
        "witness_stack_len": len(witness),
        "witness_stack_template": "DER sig + compressed pubkey + OP_0 branch selector + witnessScript",
        "branch_selector": "OP_0 (ELSE / CLTV path)",
        "witnessScript_opcode_sequence": opcode_seq,
        "witnessScript_if_branch": "OP_SIZE PUSH(1) OP_EQUALVERIFY OP_SHA256 PUSH(32) OP_EQUALVERIFY OP_DUP OP_HASH160 PUSH(20)",
        "witnessScript_else_branch": "PUSH(4) OP_CHECKLOCKTIMEVERIFY OP_DROP OP_DUP OP_HASH160 PUSH(20)",
        "witnessScript_post_endif": "OP_EQUALVERIFY OP_CHECKSIG",
        "witnessScript_locktime_value": locktime_value,
        "sha256_witness_script": hashlib.sha256(witness_script).hexdigest(),
        "python_test_synthetic": "test_p2wsh_cltv_roundtrip",
        "python_test_related": "test_real_testnet4_block30695_p2wsh_if_hashlock_op_size_accepted",
        "python_test_live": None,
        "missing_rule": "OP_CHECKLOCKTIMEVERIFY (0xb1) in legacy ScriptInterpreter.evaluateScript (P2WSH path)",
    }
    (FIXTURES / "tx_p2wsh_cltv_32868_meta.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="ascii"
    )
    branch = {
        "height": 32868,
        "txid": TXID,
        "branch_selector_hex": witness[2],
        "branch_taken": "ELSE (CLTV)",
        "locktime_value": locktime_value,
        "nLockTime": rpc_tx["locktime"],
        "pubkey_hex": witness[1],
        "python_test_synthetic": "test_p2wsh_cltv_roundtrip",
        "python_test_related": "test_real_testnet4_block30695_p2wsh_if_hashlock_op_size_accepted",
    }
    (FIXTURES / "tx_p2wsh_cltv_32868_branch.json").write_text(
        json.dumps(branch, indent=2) + "\n", encoding="ascii"
    )

    print("witnessScript opcode sequence:", opcode_seq)
    print("ELSE branch locktime value:", locktime_value)
    print("branch selector empty (OP_0):", witness[2] == "")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
