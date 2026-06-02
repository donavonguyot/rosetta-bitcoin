#!/usr/bin/env python3
"""One-off harvest for block 27251 P2WSH IF/ELSE fixtures (JavaNode)."""
from __future__ import annotations

import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "src/test/resources/fixtures"
RPC_URL = "http://127.0.0.1:48332/"
RPC_AUTH = ("rosetta", "rosetta-dev-only")

TX_HEX = (
    "0200000000010330fd8a6ec9e4f44fc690ba3ba5e93c3a6d09cb0537588bc11119bda171cbbdad00"
    "00000000fdffffff49eb5af1fc023de7db36334047b36234b67df236deec89787072371a30cc7635"
    "000000000000000000b49e81ecb56a49ca3bac4ad4d2ea9f51a1c80e556e37a6cf2beddb15289ba0"
    "fa00000000000000000003ea6401000000000022002059895dadf481ae39d8f1404dda7829fe69be"
    "0c626cb3bf7555d61f25141824870000000000000000086a0653594d423a31401f00000000000016"
    "0014b060d86fee83ed5c39a2387565434e45e040a128034730440220593ba46b896548f94c499ad8"
    "febc09fe2dd398686c41a70bb3cca05b2b470de702201e29b5c0c7d2fcef9988196629d1cb23d9e4"
    "990e5890c07e530aa349561538d28101018f632103edc032007bf3aadf1435674fc7bf352752840c"
    "ab77e65ee63cf8ceea9d95ab72ac67522102a8115cc83c92b96febd544fba01f928c9718c8c0c541"
    "1ab6aa117d20dd5973d721029ccad61e1379d85c1207196df8b882c8b8f4a2193990630f70e0fcee"
    "8b1114572103ec76c51c504720c017909bd29fa5d54e049502d5584b1bb25ed3a72fdba60f4553ae"
    "680347304402207d84e8684ef21b07326b94a68423960d6df045404b5d1a34517c06d82ee839a602"
    "206304835dfaef5515ce6f73646759a696671a1294a3456f071f3c28d2efb42fb78101018f632103"
    "edc032007bf3aadf1435674fc7bf352752840cab77e65ee63cf8ceea9d95ab72ac67522102a8115c"
    "c83c92b96febd544fba01f928c9718c8c0c5411ab6aa117d20dd5973d721029ccad61e1379d85c12"
    "07196df8b882c8b8f4a2193990630f70e0fcee8b1114572103ec76c51c504720c017909bd29fa5d5"
    "4e049502d5584b1bb25ed3a72fdba60f4553ae68034730440220267fe9bdc55320ee73aa47207c69"
    "b04da6eeb2ab58ac643fe229b615c0a7926302204bb269d08adc3acfec5f9217684f41e3ca0da101"
    "d46b9d909c8714d9f39b86c78101018f632103edc032007bf3aadf1435674fc7bf352752840cab77"
    "e65ee63cf8ceea9d95ab72ac67522102a8115cc83c92b96febd544fba01f928c9718c8c0c5411ab6"
    "aa117d20dd5973d721029ccad61e1379d85c1207196df8b882c8b8f4a2193990630f70e0fcee8b11"
    "14572103ec76c51c504720c017909bd29fa5d54e049502d5584b1bb25ed3a72fdba60f4553ae6800"
    "000000"
)
PREV_SPK = "0020e51d37e194ce5fb07c41c7301cdcd6391713c93c276fe115384172e86c8ba660"
PREVOUTS = [
    {"amount": 10000, "spk": PREV_SPK},
    {"amount": 10000, "spk": PREV_SPK},
    {"amount": 79761, "spk": PREV_SPK},
]
TXID = "a66a655defd3f3abef44ea0ba71dd9939b4b81f894a04fc18160c9ca5e78b0a0"
BLOCK_HASH = "00000000e32a5d69a7e766fa4c386b239d10aabe0837ebfddb7fb6c5578b9c78"


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


def read_varint(data: bytes, offset: int) -> tuple[int, int]:
    prefix = data[offset]
    if prefix < 0xFD:
        return prefix, offset + 1
    if prefix == 0xFD:
        return int.from_bytes(data[offset + 1 : offset + 3], "little"), offset + 3
    if prefix == 0xFE:
        return int.from_bytes(data[offset + 1 : offset + 5], "little"), offset + 5
    return int.from_bytes(data[offset + 1 : offset + 9], "little"), offset + 9


def parse_witness_stacks(payload: bytes) -> list[list[bytes]]:
    offset = 0
    if payload[offset : offset + 4] != b"\x02\x00\x00\x00":
        raise ValueError("unexpected version")
    offset += 4
    if payload[offset : offset + 2] != b"\x00\x01":
        raise ValueError("expected segwit marker")
    offset += 2
    vin_count, offset = read_varint(payload, offset)
    for _ in range(vin_count):
        offset += 32 + 4
        script_len, offset = read_varint(payload, offset)
        offset += script_len + 4
    vout_count, offset = read_varint(payload, offset)
    for _ in range(vout_count):
        offset += 8
        spk_len, offset = read_varint(payload, offset)
        offset += spk_len
    stacks: list[list[bytes]] = []
    for _ in range(vin_count):
        item_count, offset = read_varint(payload, offset)
        stack: list[bytes] = []
        for _ in range(item_count):
            item_len, offset = read_varint(payload, offset)
            stack.append(payload[offset : offset + item_len])
            offset += item_len
        stacks.append(stack)
    return stacks


def write_hex(path: Path, data: bytes) -> None:
    path.write_text(data.hex(), encoding="ascii")
    print(f"wrote {path.name} ({len(data)} bytes)")


def main() -> int:
    sys.path.insert(0, str(ROOT.parent / "PythonNode"))
    from pybitnode.messages.transaction import Transaction

    payload = bytes.fromhex(TX_HEX)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    assert tx.witness

    rpc_hash = rpc("getblockhash", [27251])
    assert rpc_hash == BLOCK_HASH, (rpc_hash, BLOCK_HASH)

    block_hex = rpc("getblock", [BLOCK_HASH, False])
    block_verbose = rpc("getblock", [BLOCK_HASH, 2])
    rpc_tx = next(t for t in block_verbose["tx"] if t["txid"] == TXID)
    assert rpc_tx["hex"] == TX_HEX, "RPC tx hex mismatch vs Python test"

    FIXTURES.mkdir(parents=True, exist_ok=True)
    write_hex(FIXTURES / "block_27251.hex", bytes.fromhex(block_hex))
    write_hex(FIXTURES / "tx_p2wsh_ifelse_27251.hex", payload)
    write_hex(FIXTURES / "tx_p2wsh_ifelse_27251_prev_spk.hex", bytes.fromhex(PREV_SPK))
    (FIXTURES / "tx_p2wsh_ifelse_27251_prevouts.json").write_text(
        json.dumps(PREVOUTS, indent=2) + "\n", encoding="ascii"
    )

    stacks = parse_witness_stacks(payload)
    for inp_idx, stack in enumerate(stacks):
        for w_idx, item in enumerate(stack):
            write_hex(
                FIXTURES / f"tx_p2wsh_ifelse_27251_witness_input{inp_idx}_{w_idx}.hex",
                item,
            )

    # Input 0 is the IF/ELSE multisig path (blocker); last witness item is witnessScript.
    ws = stacks[0][-1]
    write_hex(FIXTURES / "tx_p2wsh_ifelse_27251_witness_script.hex", ws)

    print("input0 witness items:", len(stacks[0]))
    for i, item in enumerate(stacks[0]):
        print(f"  [{i}] len={len(item)} first_byte={item[0]:02x}" if item else f"  [{i}] empty")
    print("witnessScript len:", len(ws))
    print("witnessScript hex prefix:", ws.hex()[:80])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
