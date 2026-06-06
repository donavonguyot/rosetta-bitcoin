#!/usr/bin/env python3
"""Check that the local Reference Core P2P endpoint speaks Bitcoin v1."""

from __future__ import annotations

import argparse
import hashlib
import os
import socket
import struct
import time
from pathlib import Path


TESTNET4_MAGIC = 0x283F161C


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def default_peer() -> str:
    topology = read_env_file(Path(__file__).with_name("reference_topology.env"))
    peer = topology.get("REFERENCE_P2P_PEER", "").strip()
    if not peer:
        raise RuntimeError("REFERENCE_P2P_PEER is missing from reference_topology.env")
    return peer


def checksum(payload: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]


def message(command: str, payload: bytes) -> bytes:
    command_bytes = command.encode("ascii")
    if len(command_bytes) > 12:
        raise ValueError(f"command too long: {command}")
    return (
        struct.pack("<L", TESTNET4_MAGIC)
        + command_bytes.ljust(12, b"\x00")
        + struct.pack("<L", len(payload))
        + checksum(payload)
        + payload
    )


def net_addr(host: str, port: int) -> bytes:
    try:
        ip = socket.inet_aton(host)
    except OSError:
        ip = socket.inet_aton("127.0.0.1")
    return struct.pack("<Q16sH", 0, b"\x00" * 10 + b"\xff\xff" + ip, port)


def read_exact(sock: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError(f"short read: wanted {length} bytes")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def build_version_payload(start_height: int) -> bytes:
    user_agent = b"/rb-reference-p2p-check:1/"
    payload = struct.pack("<iQq", 70016, 1 | 8, int(time.time()))
    payload += net_addr("127.0.0.1", 48333)
    payload += net_addr("127.0.0.1", 48333)
    payload += struct.pack("<Q", int.from_bytes(os.urandom(8), "little"))
    payload += bytes([len(user_agent)]) + user_agent
    payload += struct.pack("<i?", start_height, False)
    return payload


def check_peer(peer: str, timeout: float, start_height: int) -> None:
    if ":" not in peer:
        raise RuntimeError(f"peer must be host:port, got {peer!r}")
    host, port_text = peer.rsplit(":", 1)
    port = int(port_text)
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(message("version", build_version_payload(start_height)))
        header = read_exact(sock, 24)
        magic, command_raw, length, expected_checksum = struct.unpack("<L12sL4s", header)
        command = command_raw.rstrip(b"\x00").decode("ascii", "replace")
        if magic != TESTNET4_MAGIC:
            raise RuntimeError(f"wrong magic from {peer}: {magic:#x}")
        if command != "version":
            raise RuntimeError(f"expected version from {peer}, got {command!r}")
        payload = read_exact(sock, length)
        if checksum(payload) != expected_checksum:
            raise RuntimeError(f"bad checksum in version response from {peer}")
        print(f"reference_p2p_ok peer={peer} command={command} payload_bytes={len(payload)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--peer", default=default_peer())
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--start-height", type=int, default=0)
    args = parser.parse_args()
    try:
        check_peer(args.peer, args.timeout, args.start_height)
    except Exception as exc:
        print(f"reference_p2p_failed peer={args.peer} error={exc}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
