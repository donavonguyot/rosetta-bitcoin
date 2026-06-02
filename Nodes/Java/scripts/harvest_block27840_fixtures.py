#!/usr/bin/env python3
"""One-off harvest for block 27840 bare 2-of-3 multisig fixtures (JavaNode)."""
from __future__ import annotations

import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

BLOCK_HASH = "000000000000004ba29c976c33753742a34fb029eb261e146dfd31bccdadb9bc"
TXID = "f2b2a965cac99c85f71f8705454793183e93a47b558c485dec92c1101bdacf55"
PREV_TXID = "65d9e14560f3a2e854fd835cf525640812f1f6fd133655dd6be5db263371f421"
PREV_VOUT = 0
PREV_AMOUNT = 477645
PREV_SPK = (
    "524104ad34a2c1bbd3aec7ebae0c3cfab37c0715ec3a189597ae31b1ed1f44abe93047e2ec7a945c2a121"
    "9484bdb458068bb8a7ce13c190325357a29424a089b8bd756410478607280574ccab25285b26d225c02988"
    "b68cf2adead05f2d21a12b3006026d6e71aa2491733c8731d4ac44be2ae5eb4552180c9d0cb29f37fb0167"
    "adb51b37e4104bf81ac047f76bd187351a9dc5ea2fead1b0de39fc367e9b6ebdcc1d877dfb2da8ec28ad50d"
    "de6732dc94bdd4f26382bac4f69cda10987b43151cb613f7e06f7653ae"
)


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
    rpc_hash = rpc("getblockhash", [27840])
    assert rpc_hash == BLOCK_HASH, (rpc_hash, BLOCK_HASH)

    block_hex = rpc("getblock", [BLOCK_HASH, False])
    block_verbose = rpc("getblock", [BLOCK_HASH, 2])
    rpc_tx = next(t for t in block_verbose["tx"] if t["txid"] == TXID)
    assert rpc_tx["txid"] == TXID

    payload = bytes.fromhex(rpc_tx["hex"])
    script_sig = bytes.fromhex(rpc_tx["vin"][0]["scriptSig"]["hex"])
    pushes = parse_script_pushes(script_sig)
    dummy, sig1, sig2 = pushes[0][0], pushes[1][0], pushes[2][0]

    prev_spk = bytes.fromhex(PREV_SPK)
    spk_pushes = parse_script_pushes(prev_spk)
    assert spk_pushes[0][1] == "OP_52"
    assert spk_pushes[-2][1] == "OP_53"
    assert spk_pushes[-1][1] == "OP_ae"

    FIXTURES.mkdir(parents=True, exist_ok=True)
    write_hex(FIXTURES / "block_27840.hex", bytes.fromhex(block_hex))
    write_hex(FIXTURES / "tx_bare_multisig_27840.hex", payload)
    write_hex(FIXTURES / "tx_bare_multisig_27840_prev_spk.hex", prev_spk)
    (FIXTURES / "tx_bare_multisig_27840_prevouts.json").write_text(
        json.dumps([{"amount": PREV_AMOUNT, "spk": PREV_SPK}], indent=2) + "\n",
        encoding="ascii",
    )
    write_hex(FIXTURES / "tx_bare_multisig_27840_scriptsig.hex", script_sig)
    write_hex(FIXTURES / "tx_bare_multisig_27840_scriptsig_dummy.hex", dummy)
    write_hex(FIXTURES / "tx_bare_multisig_27840_scriptsig_sig1.hex", sig1)
    write_hex(FIXTURES / "tx_bare_multisig_27840_scriptsig_sig2.hex", sig2)

    meta = {
        "height": 27840,
        "block_hash": BLOCK_HASH,
        "txid": TXID,
        "block_tx_index": block_verbose["tx"].index(rpc_tx),
        "input_index": 0,
        "prev_txid": PREV_TXID,
        "prev_vout": PREV_VOUT,
        "prev_amount_sats": PREV_AMOUNT,
        "scriptPubKey_template": "OP_2 + 3x PUSH(65) uncompressed pubkey + OP_3 OP_CHECKMULTISIG",
        "scriptSig_template": "OP_0 dummy + 2x DER signature (CHECKMULTISIG)",
        "python_test": "test_real_testnet4_block27840_bare_multisig_accepted",
    }
    (FIXTURES / "tx_bare_multisig_27840_meta.json").write_text(
        json.dumps(meta, indent=2) + "\n", encoding="ascii"
    )

    print("scriptSig pushes:", [label for _, label in pushes])
    print("scriptPubKey pushes:", [label for _, label in spk_pushes])
    print("sig1 len:", len(sig1), "sig2 len:", len(sig2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
