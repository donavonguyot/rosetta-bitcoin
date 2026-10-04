#!/usr/bin/env python3
"""Capture a rung-0 mempool trace from the local Reference Core.

The trace shape is Nodes/Shared/mempool/MEMPOOL_CONTRACT.md. Reference Core is a
byte source. This tool does not decide layer-1 validity except for the cheap
input-overlap annotation expected_layer1.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import socket
import struct
import tarfile
import threading
import time
import urllib.request
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONF = ROOT / "Nodes/Reference/bitcoin.conf"
FIXTURE_ROOT = ROOT / "Nodes/Shared/fixtures/mempool"
LEDGER = ROOT / "Nodes/Zig/docs/blocker_ledger.jsonl"
MAGIC = bytes.fromhex("1c163f28")
SEED = 0x524F5345545441
MASK = (1 << 64) - 1
MUL = 0x2545F4914F6CDD1D
KIND_TX = 1
KIND_BLOCK = 2
MAX_MESSAGE = 8_000_000
RAW_CAP = 200 * 1024 * 1024
WINDOW_S = 3600
KEEP = 32

MSG_WITNESS = 1 << 30
TX_TYPES = {1, 5, 1 | MSG_WITNESS, 5 | MSG_WITNESS}
BLOCK_TYPES = {2, 2 | MSG_WITNESS}


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def sha256d(data: bytes) -> bytes:
    return sha256(sha256(data))


def display(raw: bytes) -> str:
    return raw[::-1].hex()


def internal(text: str) -> bytes:
    return bytes.fromhex(text)[::-1]


def xorshift64star(state: int) -> tuple[int, int]:
    x = state & MASK
    x ^= (x >> 12) & MASK
    x ^= (x << 25) & MASK
    x ^= (x >> 27) & MASK
    x &= MASK
    return x, (x * MUL) & MASK


def shuffle(items: list, seed: int = SEED) -> list:
    out = list(items)
    state = seed
    for i in range(len(out) - 1, 0, -1):
        state, key = xorshift64star(state)
        j = key % (i + 1)
        out[i], out[j] = out[j], out[i]
    return out


def compact_size(data: bytes, offset: int) -> tuple[int, int]:
    first = data[offset]
    if first < 253:
        return first, offset + 1
    width = {253: 2, 254: 4, 255: 8}[first]
    end = offset + 1 + width
    return int.from_bytes(data[offset + 1:end], "little"), end


def encode_compact(value: int) -> bytes:
    if value < 253:
        return bytes([value])
    if value <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", value)
    if value <= 0xFFFFFFFF:
        return b"\xfe" + struct.pack("<I", value)
    return b"\xff" + struct.pack("<Q", value)


def script_pushes(script: bytes) -> list[tuple[bytes, int]]:
    """Return (item, absolute offset of the item bytes) for each push."""
    out = []
    i = 0
    while i < len(script):
        op = script[i]
        if op == 0:
            out.append((b"", i))
            i += 1
        elif 1 <= op <= 75:
            item = script[i + 1:i + 1 + op]
            if len(item) != op:
                break
            out.append((item, i + 1))
            i += 1 + op
        elif op == 76 and i + 1 < len(script):
            length = script[i + 1]
            item = script[i + 2:i + 2 + length]
            if len(item) != length:
                break
            out.append((item, i + 2))
            i += 2 + length
        elif op == 77 and i + 3 <= len(script):
            length = int.from_bytes(script[i + 1:i + 3], "little")
            item = script[i + 3:i + 3 + length]
            if len(item) != length:
                break
            out.append((item, i + 3))
            i += 3 + length
        elif op == 78 and i + 5 <= len(script):
            length = int.from_bytes(script[i + 1:i + 5], "little")
            item = script[i + 5:i + 5 + length]
            if len(item) != length:
                break
            out.append((item, i + 5))
            i += 5 + length
        else:
            i += 1
    return out


def is_signature(item: bytes) -> bool:
    if len(item) in (64, 65):
        return True
    return len(item) >= 9 and item[0] == 0x30 and item[1] == len(item) - 3


class Tx:
    def __init__(self, raw: bytes, exact: bool = True):
        self.raw = raw
        self.inputs = []
        self.outputs = []
        self.witness = []
        self.sig_spans = []
        offset = 0
        self.version = struct.unpack_from("<i", raw, offset)[0]
        offset += 4
        witness = len(raw) >= offset + 2 and raw[offset] == 0 and raw[offset + 1] == 1
        if witness:
            offset += 2
        count, offset = compact_size(raw, offset)
        for _ in range(count):
            prev = raw[offset:offset + 32]
            prev_at = offset
            offset += 32
            vout = struct.unpack_from("<I", raw, offset)[0]
            offset += 4
            slen, offset = compact_size(raw, offset)
            script = raw[offset:offset + slen]
            script_at = offset
            offset += slen
            sequence = struct.unpack_from("<I", raw, offset)[0]
            seq_at = offset
            offset += 4
            self.inputs.append({
                "prev": prev, "vout": vout, "script": script, "sequence": sequence,
                "prev_at": prev_at, "seq_at": seq_at,
            })
            for item, at in script_pushes(script):
                if is_signature(item):
                    self.sig_spans.append((script_at + at, len(item)))
        count, offset = compact_size(raw, offset)
        for _ in range(count):
            value = struct.unpack_from("<q", raw, offset)[0]
            offset += 8
            slen, offset = compact_size(raw, offset)
            script = raw[offset:offset + slen]
            offset += slen
            self.outputs.append((value, script))
        if witness:
            for _ in self.inputs:
                stack_n, offset = compact_size(raw, offset)
                stack = []
                for _item in range(stack_n):
                    ilen, offset = compact_size(raw, offset)
                    item = raw[offset:offset + ilen]
                    if is_signature(item):
                        self.sig_spans.append((offset, ilen))
                    stack.append(item)
                    offset += ilen
                self.witness.append(stack)
        self.lock_at = offset
        self.locktime = struct.unpack_from("<I", raw, offset)[0]
        offset += 4
        if exact and offset != len(raw):
            raise ValueError("trailing transaction bytes")
        self.raw = raw[:offset]
        self.witness_bytes = witness
        stripped = serialize(self, witness=False)
        self.txid = sha256d(stripped)
        self.wtxid = sha256d(self.raw) if witness else self.txid

    @property
    def txid_hex(self) -> str:
        return display(self.txid)

    @property
    def wtxid_hex(self) -> str:
        return display(self.wtxid)


def serialize(tx: Tx, witness: bool) -> bytes:
    out = struct.pack("<i", tx.version)
    if witness and tx.witness_bytes:
        out += b"\x00\x01"
    out += encode_compact(len(tx.inputs))
    for inp in tx.inputs:
        out += inp["prev"] + struct.pack("<I", inp["vout"])
        out += encode_compact(len(inp["script"])) + inp["script"]
        out += struct.pack("<I", inp["sequence"])
    out += encode_compact(len(tx.outputs))
    for value, script in tx.outputs:
        out += struct.pack("<q", value) + encode_compact(len(script)) + script
    if witness and tx.witness_bytes:
        for stack in tx.witness:
            out += encode_compact(len(stack))
            for item in stack:
                out += encode_compact(len(item)) + item
    out += struct.pack("<I", tx.locktime)
    return out


def header_hash(raw: bytes) -> bytes:
    return sha256d(raw[:80])


def fold_wtxids(wtxids: list[bytes]) -> str:
    acc = bytearray(32)
    for wtxid in wtxids:
        digest = sha256(wtxid)
        for i, byte in enumerate(digest):
            acc[i] ^= byte
    return acc.hex()


def topo_sort(txs: list[dict], tie) -> list[dict]:
    produced = {}
    for index, event in enumerate(txs):
        for vout in range(len(event["tx"].outputs)):
            produced.setdefault((event["tx"].txid, vout), index)
    children = [[] for _ in txs]
    deps = [0] * len(txs)
    for index, event in enumerate(txs):
        parents = set()
        for inp in event["tx"].inputs:
            parent = produced.get((inp["prev"], inp["vout"]))
            if parent is not None and parent != index:
                parents.add(parent)
        for parent in parents:
            children[parent].append(index)
            deps[index] += 1
    ready = sorted((i for i, dep in enumerate(deps) if dep == 0), key=lambda i: tie(txs[i]))
    ordered = []
    while ready:
        index = ready.pop(0)
        ordered.append(txs[index])
        unlocked = []
        for child in children[index]:
            deps[child] -= 1
            if deps[child] == 0:
                unlocked.append(child)
        if unlocked:
            ready.extend(unlocked)
            ready.sort(key=lambda i: tie(txs[i]))
    if len(ordered) != len(txs):
        seen = {id(event) for event in ordered}
        ordered.extend(event for event in txs if id(event) not in seen)
    return ordered


def arrange(preface: list[dict], live: list[dict]) -> list[dict]:
    ordered = topo_sort(preface, lambda event: event["tx"].wtxid)
    segment = []
    for event in live:
        if event["kind"] == "tx":
            segment.append(event)
        else:
            ordered.extend(topo_sort(segment, lambda item: item["capture_seq"]))
            segment = []
            ordered.append(event)
    ordered.extend(topo_sort(segment, lambda item: item["capture_seq"]))
    for apply_seq, event in enumerate(ordered, start=1):
        event["apply_seq"] = apply_seq
    return ordered


def assign_expected(events: list[dict]) -> None:
    spent = {}
    pool = {}
    for event in events:
        if event["kind"] == "block":
            remove = set()
            block_spends = set()
            confirmed = set()
            for tx in event["txs"]:
                confirmed.add(tx.txid)
                for inp in tx.inputs[1:] if tx.inputs and tx.inputs[0]["prev"] == bytes(32) and tx.inputs[0]["vout"] == 0xFFFFFFFF else tx.inputs:
                    if not (inp["prev"] == bytes(32) and inp["vout"] == 0xFFFFFFFF):
                        block_spends.add((inp["prev"], inp["vout"]))
            for txid, tx in pool.items():
                if txid in confirmed or any((inp["prev"], inp["vout"]) in block_spends for inp in tx.inputs):
                    remove.add(txid)
            changed = True
            while changed:
                changed = False
                for txid, tx in pool.items():
                    if txid in remove:
                        continue
                    for inp in tx.inputs:
                        parent = pool.get(inp["prev"])
                        if parent is not None and inp["prev"] in remove and inp["vout"] < len(parent.outputs):
                            remove.add(txid)
                            changed = True
                            break
            for txid in remove:
                tx = pool.pop(txid)
                for inp in tx.inputs:
                    if spent.get((inp["prev"], inp["vout"])) == txid:
                        spent.pop((inp["prev"], inp["vout"]), None)
            event["expected_set_hash"] = fold_wtxids([item.wtxid for item in pool.values()])
            core_hash = event.get("core_set_hash")
            event["policy_divergent"] = core_hash is not None and event["expected_set_hash"] != core_hash
            continue
        tx = event["tx"]
        overlap = any((inp["prev"], inp["vout"]) in spent for inp in tx.inputs)
        event["expected_layer1"] = "input_spent_in_pool" if overlap else "accepted"
        if overlap:
            continue
        pool[tx.txid] = tx
        for inp in tx.inputs:
            spent[(inp["prev"], inp["vout"])] = tx.txid


def mark_out_of_order(events: list[dict]) -> None:
    """A non-preface tx is out of order when an in-trace parent arrived later."""
    by_txid = {event["tx"].txid: event for event in events if event["kind"] == "tx"}
    for event in events:
        if event["kind"] != "tx" or event.get("preface") or event.get("capture_seq") is None:
            continue
        for inp in event["tx"].inputs:
            parent = by_txid.get(inp["prev"])
            if parent is None or parent.get("preface") or parent.get("capture_seq") is None:
                continue
            if parent["capture_seq"] > event["capture_seq"]:
                event["out_of_order"] = True
                break


def signature_bearing_inputs(tx: Tx) -> int:
    count = 0
    for index, inp in enumerate(tx.inputs):
        signed = any(is_signature(item) for item, _at in script_pushes(inp["script"]))
        if not signed and index < len(tx.witness):
            signed = any(is_signature(item) for item in tx.witness[index])
        if signed:
            count += 1
    return count


def per_window_rows(ordered: list[dict]) -> list[dict]:
    rows = []
    for start in range(0, len(ordered), 1000):
        chunk = ordered[start:start + 1000]
        tx_count = input_count = sig_inputs = payload = 0
        for event in chunk:
            payload += len(event["raw"])
            if event["kind"] != "tx":
                continue
            tx_count += 1
            input_count += len(event["tx"].inputs)
            sig_inputs += signature_bearing_inputs(event["tx"])
        rows.append({
            "start_apply_seq": chunk[0]["apply_seq"],
            "tx_count": tx_count,
            "input_count": input_count,
            "signature_input_count": sig_inputs,
            "payload_bytes": payload,
        })
    return rows


def coverage_report(ordered: list[dict], min_tx: int, min_blocks: int = 3) -> dict:
    tx_events = [event for event in ordered if event["kind"] == "tx"]
    divergent = [event for event in ordered if event["kind"] == "block" and event.get("policy_divergent")]
    report = {
        "status": "unmet",
        "tx_count": len(tx_events),
        "replacements": sum(1 for event in tx_events if event.get("expected_layer1") == "input_spent_in_pool"),
        "out_of_order": sum(1 for event in tx_events if event.get("out_of_order")),
        "policy_divergence_boundaries": len(divergent),
        "policy_divergence_heights": [event.get("height") for event in divergent],
        "blocks": sum(1 for event in ordered if event["kind"] == "block"),
    }
    if (
        report["tx_count"] >= min_tx
        and report["replacements"] >= 1
        and report["out_of_order"] >= 1
        and report["policy_divergence_boundaries"] >= 1
        and report["blocks"] >= min_blocks
    ):
        report["status"] = "met"
    return report


def gbt_for_block(last_gbt: dict | None, previous_arrival_ms: int | None) -> dict | None:
    """Drop a template captured before the previous block event arrived."""
    if not last_gbt or last_gbt.get("captured_unix_ms") is None:
        return None
    if previous_arrival_ms is not None and last_gbt["captured_unix_ms"] < previous_arrival_ms:
        return None
    return last_gbt


def assemble(preface: list[dict], live: list[dict]) -> list[dict]:
    parse_events(preface)
    parse_events(live)
    ordered = arrange(preface, [event for event in live if event["kind"] in ("block", "tx")])
    assign_expected(ordered)
    mark_out_of_order(ordered)
    return ordered


def state_root() -> Path:
    return Path(os.environ.get("RB_STATE_ROOT", Path.home() / ".rblab"))


def watch_log(row: dict) -> None:
    row.setdefault("unix_ms", int(time.time() * 1000))
    line = json.dumps(row, sort_keys=True)
    print(line, flush=True)
    path = state_root() / "traces" / "watch.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        stream.write(line + "\n")


def mutate(events: list[dict], start_height: int) -> list[dict]:
    spent_pool = set()
    spent_chain = set()
    pool = {}
    height = start_height
    snapshots = {}
    for event in events:
        if event["kind"] == "block":
            height += 1
            remove = set()
            block_spends = set()
            confirmed = {tx.txid for tx in event["txs"]}
            for tx in event["txs"]:
                for inp in tx.inputs:
                    if not (inp["prev"] == bytes(32) and inp["vout"] == 0xFFFFFFFF):
                        block_spends.add((inp["prev"], inp["vout"]))
                        spent_chain.add((inp["prev"], inp["vout"]))
            for txid, tx in pool.items():
                if txid in confirmed or any((inp["prev"], inp["vout"]) in block_spends for inp in tx.inputs):
                    remove.add(txid)
            changed = True
            while changed:
                changed = False
                for txid, tx in list(pool.items()):
                    if txid in remove:
                        continue
                    if any(inp["prev"] in remove for inp in tx.inputs):
                        remove.add(txid)
                        changed = True
            for txid in remove:
                tx = pool.pop(txid, None)
                if tx is None:
                    continue
                for inp in tx.inputs:
                    spent_pool.discard((inp["prev"], inp["vout"]))
            continue
        if event.get("expected_layer1") != "accepted":
            continue
        tx = event["tx"]
        snapshots[event["apply_seq"]] = {
            "pool": set(spent_pool),
            "chain": set(spent_chain),
            "next_height": height + 1,
            "tx": tx,
        }
        pool[tx.txid] = tx
        for inp in tx.inputs:
            spent_pool.add((inp["prev"], inp["vout"]))
    classes = {
        "script_failed": [],
        "input_spent_in_pool": [],
        "input_spent_on_chain": [],
        "locktime_unsatisfied": [],
        "coinbase": [],
    }
    for apply_seq, snap in snapshots.items():
        tx = snap["tx"]
        if tx.sig_spans:
            classes["script_failed"].append(apply_seq)
        if snap["pool"]:
            classes["input_spent_in_pool"].append(apply_seq)
        if snap["chain"]:
            classes["input_spent_on_chain"].append(apply_seq)
        classes["locktime_unsatisfied"].append(apply_seq)
        classes["coinbase"].append(apply_seq)
    rows = []
    for name, eligible in classes.items():
        for apply_seq in shuffle(eligible)[:KEEP]:
            snap = snapshots[apply_seq]
            raw = bytearray(snap["tx"].raw)
            if name == "script_failed":
                at, length = snap["tx"].sig_spans[-1]
                raw[at + length - 1] ^= 0xFF
            elif name == "input_spent_in_pool":
                prev, vout = min(snap["pool"])
                raw[snap["tx"].inputs[0]["prev_at"]:snap["tx"].inputs[0]["prev_at"] + 36] = prev + struct.pack("<I", vout)
            elif name == "input_spent_on_chain":
                prev, vout = min(snap["chain"])
                raw[snap["tx"].inputs[0]["prev_at"]:snap["tx"].inputs[0]["prev_at"] + 36] = prev + struct.pack("<I", vout)
            elif name == "locktime_unsatisfied":
                struct.pack_into("<I", raw, snap["tx"].lock_at, snap["next_height"] + 1)
                if all(inp["sequence"] == 0xFFFFFFFF for inp in snap["tx"].inputs):
                    struct.pack_into("<I", raw, snap["tx"].inputs[0]["seq_at"], 0xFFFFFFFE)
            else:
                raw = bytearray(coinbase_bytes(snap["tx"]))
            rows.append({
                "class": name,
                "source_apply_seq": apply_seq,
                "expected_reason": name,
                "raw_hex": bytes(raw).hex(),
            })
    return rows


def coinbase_bytes(tx: Tx) -> bytes:
    out = struct.pack("<i", tx.version if tx.version >= 2 else 2)
    out += encode_compact(1)
    out += bytes(32) + struct.pack("<I", 0xFFFFFFFF) + encode_compact(0) + struct.pack("<I", 0xFFFFFFFF)
    out += encode_compact(len(tx.outputs))
    for value, script in tx.outputs:
        out += struct.pack("<q", value) + encode_compact(len(script)) + script
    out += struct.pack("<I", tx.locktime)
    return out


def frame(apply_seq: int, ms: int, kind: int, payload: bytes) -> bytes:
    return struct.pack("<IQBI", apply_seq, ms, kind, len(payload)) + payload


def write_tar(directory: Path) -> bytes:
    import io
    buffer = io.BytesIO()
    files = sorted(p for p in directory.rglob("*") if p.is_file())
    with tarfile.open(fileobj=buffer, mode="w|", format=tarfile.PAX_FORMAT) as archive:
        for path in files:
            info = tarfile.TarInfo(path.relative_to(directory).as_posix())
            info.size = path.stat().st_size
            info.mode = 0o644
            info.mtime = info.uid = info.gid = 0
            info.uname = info.gname = ""
            with path.open("rb") as stream:
                archive.addfile(info, stream)
    return buffer.getvalue()


def load_rpc() -> tuple[str, str]:
    user = password = None
    for line in CONF.read_text().splitlines():
        if line.startswith("rpcuser="):
            user = line.split("=", 1)[1]
        elif line.startswith("rpcpassword="):
            password = line.split("=", 1)[1]
    if not user or not password:
        raise SystemExit("Reference RPC credentials are missing from Nodes/Reference/bitcoin.conf")
    return user, password


class Rpc:
    def __init__(self, user: str, password: str):
        token = __import__("base64").b64encode(f"{user}:{password}".encode()).decode()
        self.auth = f"Basic {token}"

    def call(self, method: str, params: list | None = None):
        body = json.dumps({"jsonrpc": "1.0", "id": "capture", "method": method, "params": params or []}).encode()
        request = urllib.request.Request(
            "http://127.0.0.1:48332/", data=body, headers={"content-type": "text/plain", "Authorization": self.auth})
        with urllib.request.urlopen(request, timeout=120) as response:
            payload = json.load(response)
        if payload.get("error"):
            raise RuntimeError(f"{method}: {payload['error']}")
        return payload["result"]


def ledger(kind: str, failure: str) -> None:
    row = {
        "kind": kind,
        "site": "Project/scripts/capture_mempool_trace.py",
        "failure": failure,
        "missing_rule": "",
        "fix": "retry the capture when Reference Core is current and the chain is stable",
        "follower_notes": "A reorg or an unavailable Core is not a synthetic trace.",
    }
    with LEDGER.open("a") as stream:
        stream.write(json.dumps(row, separators=(",", ":")) + "\n")


def preflight(rpc: Rpc) -> dict:
    info = rpc.call("getblockchaininfo")
    if info.get("initialblockdownload") or info.get("blocks") != info.get("headers"):
        raise RuntimeError(f"Reference Core is not current: blocks={info.get('blocks')} headers={info.get('headers')} ibd={info.get('initialblockdownload')}")
    version = rpc.call("getnetworkinfo")["subversion"]
    return {"info": info, "version": version}


def message(command: str, payload: bytes = b"") -> bytes:
    return MAGIC + command.encode().ljust(12, b"\0") + struct.pack("<I", len(payload)) + sha256d(payload)[:4] + payload


def version_payload(height: int) -> bytes:
    # services || 16-byte IPv4-mapped address || port. 127.0.0.1.
    address = struct.pack("<Q", 9) + b"\x00" * 10 + b"\xff\xff" + bytes((127, 0, 0, 1)) + struct.pack(">H", 48333)
    agent = b"/rosetta-mempool-capture:0/"
    return (
        struct.pack("<iQq", 70016, 9, int(time.time()))
        + address + address
        + struct.pack("<Q", 1)
        + encode_compact(len(agent)) + agent
        + struct.pack("<i?", height, True)
    )


def read_message(sock: socket.socket) -> tuple[str, bytes]:
    header = recv_exact(sock, 24)
    if header[:4] != MAGIC:
        raise RuntimeError("Reference peer did not speak v1 P2P")
    size = struct.unpack_from("<I", header, 16)[0]
    if size > MAX_MESSAGE:
        raise RuntimeError("oversized P2P message")
    payload = recv_exact(sock, size) if size else b""
    if sha256d(payload)[:4] != header[20:24]:
        raise RuntimeError("P2P checksum mismatch")
    return header[4:16].rstrip(b"\0").decode(), payload


def recv_exact(sock: socket.socket, count: int) -> bytes:
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return bytes(data)


def handshake(sock: socket.socket, height: int) -> None:
    sock.sendall(message("version", version_payload(height)))
    # BIP339, before verack, so Core announces witness transactions by wtxid.
    sock.sendall(message("wtxidrelay"))
    seen_version = seen_verack = sent_verack = False
    deadline = time.time() + 30
    while not (seen_version and seen_verack):
        if time.time() > deadline:
            raise RuntimeError("v1 handshake timed out")
        command, payload = read_message(sock)
        if command == "version" and not sent_verack:
            sock.sendall(message("verack"))
            sent_verack = True
            seen_version = True
        elif command == "verack":
            seen_verack = True
        elif command == "ping":
            sock.sendall(message("pong", payload))
    sock.sendall(message("sendheaders"))


def parse_inv(payload: bytes) -> list[tuple[int, bytes]]:
    count, offset = compact_size(payload, 0)
    items = []
    for _ in range(count):
        kind = struct.unpack_from("<I", payload, offset)[0]
        items.append((kind, payload[offset + 4:offset + 36]))
        offset += 36
    return items


def capture_window(
    rpc: Rpc, height: int, start_hash: str, window_s: int, max_bytes: int = RAW_CAP, reorg_hash: str | None = None,
) -> tuple[list[dict], list[dict], dict]:
    live = []
    last_gbt = None
    raw_bytes = 0
    cursor = start_hash
    cursor_height = height
    seen = set()
    capture_seq = 0
    started = time.time()
    next_progress = started + 60
    next_reorg = 0.0
    sock = socket.create_connection(("127.0.0.1", 48333), timeout=30)
    try:
        handshake(sock, height)
        sock.settimeout(1.0)
        next_gbt = 0.0
        while time.time() - started < window_s and raw_bytes < max_bytes:
            now = time.time()
            if reorg_hash and now >= next_reorg:
                next_reorg = now + 10
                if start_hash_reorged(rpc, reorg_hash):
                    return live, [], {"stop": "reorg", "started": int(started * 1000), "ended": int(time.time() * 1000)}
            if now >= next_gbt:
                last_gbt = poll_gbt(rpc)
                next_gbt = now + 10
            if time.time() >= next_progress:
                print(f"capture progress txs={sum(1 for e in live if e['kind']=='tx')} blocks={sum(1 for e in live if e['kind']=='block')} bytes={raw_bytes} elapsed={int(time.time()-started)}", flush=True)
                next_progress = time.time() + 60
            try:
                command, payload = read_message(sock)
            except socket.timeout:
                continue
            if command == "ping":
                sock.sendall(message("pong", payload))
            elif command == "inv":
                wanted = [item for item in parse_inv(payload) if item[0] in TX_TYPES or item[0] in BLOCK_TYPES]
                if wanted:
                    body = encode_compact(len(wanted))
                    for kind, txhash in wanted:
                        # MSG_WTX (5) is already a witness request. Other tx and block
                        # types need the BIP144 witness bit or Core omits the witness.
                        request = kind if kind == 5 else kind | MSG_WITNESS
                        body += struct.pack("<I", request) + txhash
                    sock.sendall(message("getdata", body))
            elif command == "tx":
                if payload in seen:
                    continue
                seen.add(payload)
                capture_seq += 1
                raw_bytes += len(payload)
                entry = annotate_tx(rpc, payload)
                live.append({
                    "kind": "tx", "raw": payload, "capture_seq": capture_seq,
                    "ms": int(time.time() * 1000), "entry": entry, "preface": False,
                })
            elif command == "block":
                added, cursor, cursor_height, capture_seq, raw_bytes = take_block(
                    rpc, payload, cursor, cursor_height, live, capture_seq, raw_bytes, last_gbt)
                if added is None:
                    return live, [], {"stop": "reorg", "started": int(started * 1000), "ended": int(time.time() * 1000)}
    finally:
        sock.close()
    stop = "bytes" if raw_bytes >= max_bytes else "time"
    return live, [], {"stop": stop, "started": int(started * 1000), "ended": int(time.time() * 1000)}


def start_hash_reorged(rpc: Rpc, start_hash: str) -> bool:
    try:
        header = rpc.call("getblockheader", [start_hash])
    except Exception:
        return True
    return int(header.get("confirmations", 0)) < 1


def poll_gbt(rpc: Rpc) -> dict:
    try:
        result = rpc.call("getblocktemplate", [{"rules": ["segwit"]}])
    except Exception:
        return None
    txs = result.get("transactions") or []
    return {
        "captured_unix_ms": int(time.time() * 1000),
        "fees_sat": sum(int(tx.get("fee") or 0) for tx in txs),
        "tx_count": len(txs),
        "txids": [tx.get("txid") for tx in txs],
    }


def annotate_tx(rpc: Rpc, raw: bytes) -> dict | None:
    try:
        txid = display(sha256d(serialize(Tx(raw), witness=False)))
        entry = rpc.call("getmempoolentry", [txid])
    except Exception:
        return None
    fee = entry.get("fees", {}).get("base", entry.get("fee"))
    return {
        "fee_sat": int(round(float(fee) * 100_000_000)) if fee is not None else None,
        "vsize": entry.get("vsize"),
        "ancestor_count": entry.get("ancestorcount"),
    }


def take_block(rpc, raw, cursor, cursor_height, live, capture_seq, raw_bytes, gbt):
    block_hash = display(header_hash(raw))
    try:
        header = rpc.call("getblockheader", [block_hash])
    except Exception:
        ledger("capture_reorg", f"block {block_hash} is not on the Reference chain from {cursor}")
        return None, cursor, cursor_height, capture_seq, raw_bytes
    if header["height"] <= cursor_height:
        return False, cursor, cursor_height, capture_seq, raw_bytes
    chain = []
    walk = block_hash
    while walk != cursor:
        info = rpc.call("getblockheader", [walk])
        chain.append(walk)
        walk = info["previousblockhash"]
        if info["height"] <= cursor_height:
            ledger("capture_reorg", f"block {block_hash} does not extend {cursor}")
            return None, cursor, cursor_height, capture_seq, raw_bytes
        if len(chain) > 64:
            ledger("capture_reorg", f"block gap from {cursor} to {block_hash} is not a single chain step")
            return None, cursor, cursor_height, capture_seq, raw_bytes
    previous_arrival = next((event["ms"] for event in reversed(live) if event["kind"] == "block"), None)
    for digest in reversed(chain):
        payload = bytes.fromhex(rpc.call("getblock", [digest, 0]))
        capture_seq += 1
        raw_bytes += len(payload)
        info = rpc.call("getblockheader", [digest])
        pool = rpc.call("getrawmempool", [True])
        wtxids = [internal(entry["wtxid"]) for entry in pool.values()]
        block_txs = parse_block_txs(payload)
        arrived = int(time.time() * 1000)
        live.append({
            "kind": "block", "raw": payload, "capture_seq": capture_seq,
            "ms": arrived, "preface": False, "txs": block_txs,
            "hash": digest, "prev_hash": info["previousblockhash"], "height": info["height"],
            "gbt": gbt_for_block(gbt, previous_arrival),
            "core_set_hash": fold_wtxids(wtxids),
            "core_pool_count": len(pool),
        })
        previous_arrival = arrived
        cursor = digest
        cursor_height = info["height"]
    return True, cursor, cursor_height, capture_seq, raw_bytes


def rpc_height_of(start_hash: str, rpc: Rpc) -> int:
    return rpc.call("getblockheader", [start_hash])["height"]


def parse_block_txs(raw: bytes) -> list[Tx]:
    count, offset = compact_size(raw, 80)
    txs = []
    for _ in range(count):
        tx = Tx(raw[offset:], exact=False)
        txs.append(tx)
        offset += len(tx.raw)
        if offset > len(raw):
            raise ValueError("block transaction overruns payload")
    if offset != len(raw):
        raise ValueError("block did not consume its transaction payload")
    return txs


def snapshot_preface(rpc: Rpc) -> list[dict]:
    pool = rpc.call("getrawmempool", [False])
    preface = []
    ms = int(time.time() * 1000)
    for txid in pool:
        raw = bytes.fromhex(rpc.call("getrawtransaction", [txid]))
        preface.append({"kind": "tx", "raw": raw, "ms": ms, "preface": True, "entry": None, "capture_seq": None})
    return preface


def parse_events(events: list[dict]) -> None:
    for event in events:
        if event["kind"] == "tx":
            event["tx"] = Tx(event["raw"])
        elif "txs" not in event:
            event["txs"] = parse_block_txs(event["raw"])


def publish(
    preface, live, meta, info, version, synthetic: bool,
    manifest_extra: dict | None = None, staging: Path | None = None, min_tx: int | None = None,
) -> tuple[Path | None, dict]:
    ordered = assemble(preface, live)
    report = coverage_report(ordered, 0 if min_tx is None else min_tx)
    if min_tx is not None and report["status"] != "met":
        return None, report
    start_height = info["blocks"]
    mutations = mutate(ordered, start_height)
    staging = staging or (FIXTURE_ROOT / ".staging-trace")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    events = b"".join(
        frame(event["apply_seq"], event["ms"], KIND_TX if event["kind"] == "tx" else KIND_BLOCK, event["raw"])
        for event in ordered
    )
    (staging / "events.bin").write_bytes(events)
    annotations = []
    boundaries = []
    for event in ordered:
        if event["kind"] == "tx":
            row = {
                "apply_seq": event["apply_seq"],
                "preface": bool(event.get("preface")),
                "txid": event["tx"].txid_hex,
                "wtxid": event["tx"].wtxid_hex,
                "expected_layer1": event["expected_layer1"],
                "input_count": len(event["tx"].inputs),
            }
            if event.get("out_of_order"):
                row["out_of_order"] = True
            if event.get("capture_seq") is not None:
                row["capture_seq"] = event["capture_seq"]
            if event.get("entry"):
                row.update(event["entry"])
            annotations.append(row)
        else:
            annotations.append({
                "apply_seq": event["apply_seq"],
                "capture_seq": event["capture_seq"],
                "hash": event["hash"],
                "prev_hash": event["prev_hash"],
                "tx_count": len(event["txs"]),
            })
            boundaries.append({
                "apply_seq": event["apply_seq"],
                "height": event["height"],
                "hash": event["hash"],
                "core_set_hash": event["core_set_hash"],
                "core_pool_count": event["core_pool_count"],
                "gbt": event.get("gbt"),
            })
    (staging / "annotations.jsonl").write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in annotations))
    (staging / "boundaries.jsonl").write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in boundaries))
    (staging / "mutations.json").write_text(json.dumps({
        "schema": "mempool.mutations.v1",
        "seed": "0x524F5345545441",
        "algorithm": "xorshift64*",
        "mutations": mutations,
    }, indent=2) + "\n")
    core_version = version.strip("/")
    manifest = {
        "schema": "mempool.trace.v1",
        "chain": "testnet4",
        "core_version": core_version,
        "policy": f"policy@core-{core_version}",
        "policy_note": "policy, not consensus",
        "fixture": "synthetic" if synthetic else "live",
        "window": meta,
        "start_height": start_height,
        "start_hash": info["bestblockhash"],
        "preface_count": sum(1 for event in ordered if event["kind"] == "tx" and event.get("preface")),
        "event_count": len(ordered),
        "tx_count": sum(1 for event in ordered if event["kind"] == "tx"),
        "block_count": sum(1 for event in ordered if event["kind"] == "block"),
        "raw_bytes": sum(len(event["raw"]) for event in ordered if not event.get("preface")),
        "mutation_seed": "0x524F5345545441",
        "set_hash": "xor-sha256-wtxid-v1",
        "per_window": per_window_rows(ordered),
    }
    if min_tx is not None:
        manifest["coverage"] = report
    if manifest_extra:
        manifest.update(manifest_extra)
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    digest = hashlib.sha256(write_tar(staging)).hexdigest()
    dest = FIXTURE_ROOT / f"trace-{digest}"
    if staging.parent == dest.parent:
        staging.rename(dest)
    else:
        shutil.move(str(staging), dest)
    index_path = FIXTURE_ROOT / "index.json"
    index = {"schema": "mempool.trace_index.v1", "traces": []}
    if index_path.exists():
        index = json.loads(index_path.read_text())
    index["traces"].append({
        "trace_hash": digest,
        "path": f"Nodes/Shared/fixtures/mempool/trace-{digest}",
        "chain": "testnet4",
        "core_version": core_version,
        "fixture": manifest["fixture"],
        "window": meta,
        "preface_count": manifest["preface_count"],
        "event_count": manifest["event_count"],
        "tx_count": manifest["tx_count"],
        "block_count": manifest["block_count"],
        "raw_bytes": manifest["raw_bytes"],
        "policy": manifest["policy"],
    })
    if "coverage" in manifest:
        index["traces"][-1]["coverage"] = manifest["coverage"]
    index_path.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")
    print(f"CAPTURE_DONE trace={digest} path={dest} txs={manifest['tx_count']} blocks={manifest['block_count']} fixture={manifest['fixture']}")
    return dest, report


def build_synthetic(rpc: Rpc | None) -> None:
    """Short chain inside the 5k corpus. Used only when Core cannot serve a live window."""
    if rpc is None:
        raise SystemExit("synthetic capture needs historical block bytes from Reference or a datadir")
    blocks = []
    for height in range(0, 160):
        digest = rpc.call("getblockhash", [height])
        blocks.append(bytes.fromhex(rpc.call("getblock", [digest, 0])))
    preface = []
    live = []
    ms = int(time.time() * 1000)
    for raw in blocks[:150]:
        header = rpc.call("getblockheader", [display(header_hash(raw))])
        live.append({
            "kind": "block", "raw": raw, "capture_seq": header["height"] + 1, "ms": ms,
            "preface": False, "hash": display(header_hash(raw)), "prev_hash": header.get("previousblockhash", "00" * 32),
            "height": header["height"], "gbt": None, "core_set_hash": fold_wtxids([]), "core_pool_count": 0,
        })
    seq = 151
    for raw in blocks[150:]:
        for tx in parse_block_txs(raw)[1:]:
            live.append({"kind": "tx", "raw": tx.raw, "capture_seq": seq, "ms": ms, "preface": False, "entry": None})
            seq += 1
        header = rpc.call("getblockheader", [display(header_hash(raw))])
        live.append({
            "kind": "block", "raw": raw, "capture_seq": seq, "ms": ms, "preface": False,
            "hash": display(header_hash(raw)), "prev_hash": header.get("previousblockhash", "00" * 32),
            "height": header["height"], "gbt": None, "core_set_hash": fold_wtxids([]), "core_pool_count": 0,
        })
        seq += 1
    info = {"blocks": 0, "bestblockhash": display(header_hash(blocks[0]))}
    # start height 0 with genesis as the first applied block. publish() uses info["blocks"]
    # as start_height. Genesis is height 0 and is itself a preface block, so the empty
    # store's next block is genesis. Report start_height -1 by using blocks= -1? The
    # contract's sync target for synthetic is an empty store. start_height 0 and the
    # first event is the genesis block only works if sync-to-0 leaves an empty store
    # whose tip hash is unset. Record start_height 0 and start_hash of the genesis
    # previous (all zeros is wrong). Use the genesis hash and let replay treat a
    # synthetic fixture as "connect the included blocks from empty" when start_height
    # is 0 and the first events are blocks. See publish synthetic flag.
    info = {"blocks": 0, "bestblockhash": display(header_hash(blocks[0]))}
    meta = {"started_unix_ms": ms, "ended_unix_ms": ms, "stop_reason": "synthetic"}
    # Move genesis out of the "already synced" tip: replay of synthetic starts empty
    # and the block events include genesis. start_height stays 0 meaning "no blocks yet"
    # only if we do not require the tip hash to be genesis before events. The live
    # contract requires that. For synthetic, the manifest start_hash is genesis and
    # the block preface begins at genesis, so replay skips sync and connects events
    # onto an empty store. Encode that with fixture=synthetic and start_height 0,
    # start_hash = genesis, and the first event the genesis block whose prev is zeros.
    # An empty store has no tip. mempool-replay must not require a tip hash match
    # when fixture is synthetic and start_height is 0; it connects the block preface.
    publish(preface, live, meta, info, "synthetic", True)


def self_test() -> None:
    parent = Tx(build_tx(bytes(32), 0, [(1000, b"\x51")]))
    child_raw = build_tx(parent.txid, 0, [(900, b"\x51")])
    child = Tx(child_raw)
    other = Tx(build_tx(parent.txid, 0, [(800, b"\x51")]))
    # Child arrives before parent.
    live = [
        {"kind": "tx", "raw": child.raw, "tx": child, "capture_seq": 1, "ms": 1, "preface": False, "entry": None},
        {"kind": "tx", "raw": parent.raw, "tx": parent, "capture_seq": 2, "ms": 2, "preface": False, "entry": None},
        {"kind": "tx", "raw": other.raw, "tx": other, "capture_seq": 3, "ms": 3, "preface": False, "entry": None},
    ]
    ordered = arrange([], live)
    assert [event["tx"].txid for event in ordered][:2] == [parent.txid, child.txid]
    assign_expected(ordered)
    reasons = [event["expected_layer1"] for event in ordered]
    assert reasons == ["accepted", "accepted", "input_spent_in_pool"], reasons
    signed = bytearray(parent.raw)
    # Graft a 64-byte witness by rebuilding is unnecessary: a scriptSig push of 64 bytes.
    signed = bytearray(build_tx(bytes(32), 0, [(1000, b"\x51")], script=b"\x40" + bytes(64)))
    event = {"kind": "tx", "raw": bytes(signed), "tx": Tx(bytes(signed)), "capture_seq": 1, "ms": 1, "preface": False, "apply_seq": 1, "expected_layer1": "accepted"}
    rows = mutate([event], 10)
    flipped = [row for row in rows if row["class"] == "script_failed"]
    assert flipped and flipped[0]["raw_hex"] != event["raw"].hex()
    mark_out_of_order(ordered)
    assert ordered[1].get("out_of_order") is True
    assert "out_of_order" not in ordered[0]
    preface = [{"kind": "tx", "raw": parent.raw, "tx": parent, "capture_seq": None, "ms": 0, "preface": True}]
    pref_ordered = arrange(preface, [{"kind": "tx", "raw": child.raw, "tx": child, "capture_seq": 1, "ms": 1, "preface": False}])
    mark_out_of_order(pref_ordered)
    assert not any(item.get("out_of_order") for item in pref_ordered)
    stale = {"captured_unix_ms": 100, "fees_sat": 5, "tx_count": 1, "txids": []}
    assert gbt_for_block(None, None) is None
    assert gbt_for_block(stale, None) is stale
    assert gbt_for_block(stale, 100) is stale
    assert gbt_for_block(stale, 101) is None
    traced = arrange([], [
        {"kind": "tx", "raw": child.raw, "tx": child, "capture_seq": 1, "ms": 1, "preface": False},
        {"kind": "tx", "raw": parent.raw, "tx": parent, "capture_seq": 2, "ms": 2, "preface": False},
        {"kind": "tx", "raw": other.raw, "tx": other, "capture_seq": 3, "ms": 3, "preface": False},
        {"kind": "block", "raw": b"", "capture_seq": 4, "ms": 200, "preface": False, "txs": [],
         "hash": "11" * 32, "prev_hash": "00" * 32, "height": 11,
         "core_set_hash": "00" * 32, "core_pool_count": 0, "gbt": gbt_for_block(stale, 200)},
    ])
    assign_expected(traced)
    mark_out_of_order(traced)
    assert traced[-1]["gbt"] is None
    report = coverage_report(traced, min_tx=1, min_blocks=1)
    assert report["status"] == "met", report
    assert report["policy_divergence_heights"] == [11]
    assert report["replacements"] == 1
    assert report["out_of_order"] == 1
    assert signature_bearing_inputs(event["tx"]) == 1
    window_rows = per_window_rows([event])
    assert window_rows == [{
        "start_apply_seq": 1,
        "tx_count": 1,
        "input_count": 1,
        "signature_input_count": 1,
        "payload_bytes": len(event["raw"]),
    }]
    print("self-test ok")


def build_tx(prev: bytes, vout: int, outputs: list[tuple[int, bytes]], script: bytes = b"") -> bytes:
    raw = struct.pack("<i", 2)
    raw += encode_compact(1)
    raw += prev + struct.pack("<I", vout) + encode_compact(len(script)) + script + struct.pack("<I", 0xFFFFFFFE)
    raw += encode_compact(len(outputs))
    for value, out_script in outputs:
        raw += struct.pack("<q", value) + encode_compact(len(out_script)) + out_script
    raw += struct.pack("<I", 0)
    return raw


class ArrivalMeter:
    """Count tx messages on a dedicated P2P connection over a 120s window."""

    def __init__(self):
        self.sock = None
        self.arrivals = deque()
        self.lock = threading.Lock()
        self.thread = None
        self.failure = None

    def close(self) -> None:
        sock = self.sock
        self.sock = None
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass

    def ensure(self, height: int) -> None:
        if self.thread is not None and self.thread.is_alive():
            return
        if self.failure:
            watch_log({"event": "handshake_failure", "failure": self.failure})
            self.failure = None
        try:
            sock = socket.create_connection(("127.0.0.1", 48333), timeout=10)
            handshake(sock, height)
            sock.settimeout(30)
            self.sock = sock
            self.thread = threading.Thread(target=self._read_loop, name="mempool-arrival", daemon=True)
            self.thread.start()
        except Exception as exc:
            self.close()
            watch_log({"event": "handshake_failure", "failure": str(exc)})

    def _read_loop(self) -> None:
        sock = self.sock
        try:
            while sock is not None and sock is self.sock:
                command, payload = read_message(sock)
                now = time.time()
                if command == "ping":
                    sock.sendall(message("pong", payload))
                elif command == "inv":
                    wanted = [item for item in parse_inv(payload) if item[0] in TX_TYPES]
                    if wanted:
                        body = encode_compact(len(wanted))
                        for kind, txhash in wanted:
                            request = kind if kind == 5 else kind | MSG_WITNESS
                            body += struct.pack("<I", request) + txhash
                        sock.sendall(message("getdata", body))
                elif command == "tx":
                    with self.lock:
                        self.arrivals.append(now)
        except Exception as exc:
            self.failure = str(exc)
            self.close()

    def rate(self) -> float:
        now = time.time()
        with self.lock:
            while self.arrivals and now - self.arrivals[0] > 120:
                self.arrivals.popleft()
            return len(self.arrivals) / 120.0


def watcher_thresholds(args) -> dict:
    return {
        "open_pool": args.open_pool,
        "open_rate": args.open_rate,
        "min_tx": args.min_tx,
        "max_seconds": args.max_seconds,
        "max_bytes": args.max_bytes,
        "keep": args.keep,
        "max_watch_seconds": args.max_watch_seconds,
    }


def record_window(args, rpc: Rpc, chain: dict, trigger: dict, thresholds: dict) -> bool:
    start_hash = chain["bestblockhash"]
    staging = state_root() / "traces" / "inflight" / ".staging-trace"
    try:
        version = rpc.call("getnetworkinfo")["subversion"]
        preface = snapshot_preface(rpc)
        live, _, meta = capture_window(
            rpc, int(chain["blocks"]), start_hash, args.max_seconds, args.max_bytes, reorg_hash=start_hash)
    except Exception as exc:
        watch_log({"event": "close", "stop_reason": "error", "failure": str(exc), "trigger": trigger})
        watch_log({"event": "discard", "discard_reason": "capture_error", "failure": str(exc), "trigger": trigger, "thresholds": thresholds})
        return False
    window = {"started_unix_ms": meta["started"], "ended_unix_ms": meta["ended"], "stop_reason": meta["stop"]}
    watch_log({
        "event": "close",
        "stop_reason": meta["stop"],
        "trigger": trigger,
        "live_tx": sum(1 for event in live if event["kind"] == "tx"),
        "live_blocks": sum(1 for event in live if event["kind"] == "block"),
    })
    if meta["stop"] == "reorg":
        watch_log({"event": "discard", "discard_reason": "reorg", "trigger": trigger, "thresholds": thresholds, "coverage": "unmet"})
        return False
    info = {"blocks": chain["blocks"], "bestblockhash": start_hash}
    try:
        dest, report = publish(
            preface, live, window, info, version, False,
            manifest_extra={"trigger": trigger, "thresholds": thresholds},
            staging=staging, min_tx=args.min_tx,
        )
    except Exception as exc:
        if staging.exists():
            shutil.rmtree(staging)
        watch_log({"event": "discard", "discard_reason": "capture_error", "failure": str(exc), "trigger": trigger, "thresholds": thresholds})
        return False
    if dest is None:
        if staging.exists():
            shutil.rmtree(staging)
        watch_log({"event": "discard", "discard_reason": "coverage", "coverage": report, "trigger": trigger, "thresholds": thresholds})
        return False
    watch_log({
        "event": "keep",
        "coverage": report,
        "path": f"Nodes/Shared/fixtures/mempool/{dest.name}",
        "trace_hash": dest.name.removeprefix("trace-"),
        "trigger": trigger,
    })
    return True


def run_watch(args, rpc: Rpc) -> None:
    meter = ArrivalMeter()
    deadline = time.time() + args.max_watch_seconds
    kept = 0
    thresholds = watcher_thresholds(args)
    while time.time() < deadline and kept < args.keep:
        try:
            chain = rpc.call("getblockchaininfo")
            pool = rpc.call("getmempoolinfo")
        except Exception as exc:
            watch_log({"event": "poll", "failure": str(exc)})
            time.sleep(30)
            continue
        ibd = bool(chain.get("initialblockdownload")) or chain.get("blocks") != chain.get("headers")
        meter.ensure(int(chain.get("blocks") or 0))
        rate = round(meter.rate(), 6)
        pool_size = int(pool.get("size") or 0)
        watch_log({
            "event": "poll",
            "ibd": ibd,
            "blocks": chain.get("blocks"),
            "headers": chain.get("headers"),
            "pool_size": pool_size,
            "pool_bytes": int(pool.get("bytes") or 0),
            "rate_tx_per_s": rate,
        })
        if ibd:
            time.sleep(30)
            continue
        trigger = None
        if pool_size >= args.open_pool:
            trigger = {"rule": "open_pool", "value": pool_size}
        elif rate >= args.open_rate:
            trigger = {"rule": "open_rate", "value": rate}
        if trigger is None:
            time.sleep(30)
            continue
        watch_log({
            "event": "open",
            "trigger": trigger,
            "thresholds": thresholds,
            "start_height": chain.get("blocks"),
            "start_hash": chain.get("bestblockhash"),
        })
        if record_window(args, rpc, chain, trigger, thresholds):
            kept += 1
    watch_log({"event": "stop", "kept": kept, "reason": "keep" if kept >= args.keep else "max_watch_seconds"})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--synthetic", action="store_true")
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--window-seconds", type=int, default=WINDOW_S)
    parser.add_argument("--open-pool", type=int, default=200)
    parser.add_argument("--open-rate", type=float, default=1.0)
    parser.add_argument("--min-tx", type=int, default=2000)
    parser.add_argument("--max-seconds", type=int, default=WINDOW_S)
    parser.add_argument("--max-bytes", type=int, default=RAW_CAP)
    parser.add_argument("--keep", type=int, default=3)
    parser.add_argument("--max-watch-seconds", type=int, default=86400)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    user, password = load_rpc()
    rpc = Rpc(user, password)
    if args.watch:
        run_watch(args, rpc)
        return
    try:
        state = preflight(rpc)
    except Exception as exc:
        ledger("reference_capture_unavailable", str(exc))
        print(f"reference_capture_unavailable {exc}")
        if args.synthetic or True:
            build_synthetic(rpc if "not current" not in str(exc) else None)
        return
    if args.synthetic:
        build_synthetic(rpc)
        return
    info = state["info"]
    print(f"capture start height={info['blocks']} hash={info['bestblockhash']} version={state['version']}", flush=True)
    try:
        preface = snapshot_preface(rpc)
        print(f"preface txs={len(preface)}", flush=True)
        live, _, meta = capture_window(rpc, info["blocks"], info["bestblockhash"], args.window_seconds)
    except SystemExit:
        print("CAPTURE_REORG", flush=True)
        raise
    except Exception as exc:
        ledger("reference_capture_unavailable", f"v1 capture failed: {exc}")
        print(f"reference_capture_unavailable {exc}", flush=True)
        build_synthetic(rpc)
        return
    if meta["stop"] == "reorg":
        print("CAPTURE_REORG", flush=True)
        raise SystemExit(2)
    meta = {"started_unix_ms": meta["started"], "ended_unix_ms": meta["ended"], "stop_reason": meta["stop"]}
    publish(preface, live, meta, info, state["version"], False)


if __name__ == "__main__":
    main()
