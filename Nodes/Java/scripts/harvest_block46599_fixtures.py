#!/usr/bin/env python3
"""One-off harvest for block 46599 P2TR script-path fixtures (JavaNode)."""
from __future__ import annotations

import base64
import hashlib
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

HEIGHT = 46599
BLOCK_HASH = "00000000000000193205628255bc2004082bc1a83ba337f79fe4f591f99fc7e8"
TXID = "d16704313ed3cd64f082c92b40d72ccf5ede213f739c3f217caf59f1ca6c962f"
PREV_TXID = "f50a140a9a0d18e2142cb49a53aae83c9ba2fe0124aa764807c9015e41d66b43"
PREV_VOUT = 0
PREV_SPK = "5120a23f913d1fc28f07abbcc72218ed00e0d149287b9e86187e54b0c6340ce584b3"

OP_NAMES = {
    0x00: "OP_0",
    0x51: "OP_1",
    0x63: "OP_IF",
    0x68: "OP_ENDIF",
    0x77: "OP_NIP",
    0xAC: "OP_CHECKSIG",
    0xAD: "OP_CHECKSIGVERIFY",
    0xBA: "OP_CHECKSIGADD",
    0x9C: "OP_NUMEQUAL",
}


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


def parse_script(script: bytes) -> list[str]:
    off = 0
    labels: list[str] = []
    while off < len(script):
        op = script[off]
        off += 1
        if op == 0:
            labels.append("OP_0")
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
            labels.append(OP_NAMES.get(op, f"OP_{op:02x}"))
            continue
        labels.append(f"PUSH({n})")
        off += n
    return labels


def tagged_hash(tag: str, data: bytes) -> bytes:
    tag_hash = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(tag_hash + tag_hash + data).digest()


def ser_script(script: bytes) -> bytes:
    n = len(script)
    if n < 0xFD:
        return bytes([n]) + script
    if n <= 0xFFFF:
        return bytes([0xFD]) + n.to_bytes(2, "little") + script
    if n <= 0xFFFFFFFF:
        return bytes([0xFE]) + n.to_bytes(4, "little") + script
    return bytes([0xFF]) + n.to_bytes(8, "little") + script


def compute_tapleaf_hash(leaf_version: int, script: bytes) -> bytes:
    return tagged_hash("TapLeaf", bytes([leaf_version]) + ser_script(script))


def write_hex(path: Path, data: bytes) -> None:
    path.write_text(data.hex(), encoding="ascii")
    print(f"wrote {path.name} ({len(data)} bytes)")


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
    assert vin["txid"] == PREV_TXID and vin["vout"] == PREV_VOUT

    witness = vin["txinwitness"]
    assert len(witness) == 3

    sig = bytes.fromhex(witness[0])
    tapscript = bytes.fromhex(witness[1])
    control_block = bytes.fromhex(witness[2])
    assert len(sig) == 64
    assert len(control_block) == 33
    assert control_block[0] == 0xC0

    internal_key = control_block[1:33]
    assert tapscript[0] == 0x20 and tapscript[1:33] == internal_key

    opcode_seq = " ".join(parse_script(tapscript))
    tapleaf_hash_hex = compute_tapleaf_hash(0xC0, tapscript).hex()

    prefix = "tx_p2tr_scriptpath_46599"
    FIXTURES.mkdir(parents=True, exist_ok=True)
    write_hex(FIXTURES / "block_46599.hex", bytes.fromhex(block_hex))
    write_hex(FIXTURES / f"{prefix}.hex", bytes.fromhex(rpc_tx["hex"]))
    write_hex(FIXTURES / f"{prefix}_prev_spk.hex", bytes.fromhex(prev_spk))
    (FIXTURES / f"{prefix}_prevouts.json").write_text(
        json.dumps(
            [
                {
                    "txid": PREV_TXID,
                    "vout": PREV_VOUT,
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
    for i, item in enumerate(witness):
        write_hex(FIXTURES / f"{prefix}_witness_{i}.hex", bytes.fromhex(item))
    write_hex(FIXTURES / f"{prefix}_tapscript.hex", tapscript)
    write_hex(FIXTURES / f"{prefix}_control_block.hex", control_block)

    meta = {
        "height": HEIGHT,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "block_tx_index": block["tx"].index(rpc_tx),
        "input_index": 0,
        "prev_txid": PREV_TXID,
        "prev_vout": PREV_VOUT,
        "prev_amount_sats": prev_amount,
        "prevout_height": prevout.get("height"),
        "spent_script_pubkey": prev_spk,
        "nLockTime": rpc_tx["locktime"],
        "nSequence": vin["sequence"],
        "witness_stack_len": len(witness),
        "witness_layout": "schnorr_sig_64B, tapscript, control_block",
        "control_block_leaf_version": hex(control_block[0]),
        "control_block_internal_key": internal_key.hex(),
        "control_block_merkle_sibling_count": (len(control_block) - 33) // 32,
        "tapscript_len": len(tapscript),
        "tapscript_opcode_sequence": opcode_seq,
        "tapscript_template": "PUSH(32) x-only key OP_CHECKSIGVERIFY PUSH(2) OP_0 OP_IF envelope + OP_ENDIF + PUSH(8) OP_NIP",
        "tapleaf_hash": tapleaf_hash_hex,
        "python_test": None,
        "missing_rule": "P2TR script-path spend (witness stack len 3) — diagnose @46599 after OP_NIP fix @44295",
        "java_blocker": "script verification failed for input 0 @46599",
    }
    (FIXTURES / f"{prefix}_meta.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="ascii"
    )

    print("witness layout:", meta["witness_layout"])
    print("tapscript opcodes:", opcode_seq)
    print("control block:", control_block.hex())
    print("tapleaf hash:", tapleaf_hash_hex)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
