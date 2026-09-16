#!/usr/bin/env python3
"""Bound a v1 P2P byte stream without deciding block validity for the receiver."""
import hashlib
import json
import os
import socket
import struct
import threading

MAGIC = bytes.fromhex("1c163f28")
LIMIT = 5000
MAX_MESSAGE = 4_000_000


def sha256d(data):
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def compact(data, offset=0):
    first = data[offset]
    size = {253: 2, 254: 4, 255: 8}.get(first, 0)
    if not size:
        return first, offset + 1
    end = offset + 1 + size
    if end > len(data):
        raise ValueError("Truncated CompactSize")
    return int.from_bytes(data[offset + 1:end], "little"), end


def encode_compact(value):
    if value < 253:
        return bytes([value])
    if value <= 65535:
        return b"\xfd" + struct.pack("<H", value)
    return b"\xfe" + struct.pack("<I", value)


class Boundary:
    def __init__(self, genesis):
        self.heights = {bytes.fromhex(genesis)[::-1]: 0}
        self.lock = threading.Lock()
        self.withheld_requests = 0
        self.withheld_blocks = 0
        self.forwarded_blocks = 0

    def transform(self, command, payload, upstream):
        with self.lock:
            if upstream and command == b"headers":
                count, offset = compact(payload)
                if count > 2000:
                    raise ValueError("Too many headers")
                for _ in range(count):
                    header = payload[offset:offset + 80]
                    if len(header) != 80:
                        raise ValueError("Truncated header")
                    previous = self.heights.get(header[4:36])
                    if previous is not None and previous < LIMIT:
                        self.heights[sha256d(header)] = previous + 1
                    transactions, offset = compact(payload, offset + 80)
                    if transactions:
                        raise ValueError("Nonzero header transaction count")
                if offset != len(payload):
                    raise ValueError("Unexpected header suffix")
            elif not upstream and command == b"getdata":
                count, offset = compact(payload)
                if count > 50000 or len(payload) != offset + count * 36:
                    raise ValueError("Malformed inventory request")
                entries = []
                for i in range(count):
                    entry = payload[offset + i * 36:offset + (i + 1) * 36]
                    kind = int.from_bytes(entry[:4], "little") & 0x3fffffff
                    if kind in (2, 3, 4) and entry[4:] not in self.heights:
                        self.withheld_requests += 1
                    else:
                        entries.append(entry)
                if not entries:
                    return None
                return encode_compact(len(entries)) + b"".join(entries)
            elif upstream and command in (b"block", b"cmpctblock"):
                if len(payload) < 80 or sha256d(payload[:80]) not in self.heights:
                    self.withheld_blocks += 1
                    return None
                self.forwarded_blocks += 1
            return payload


def receive(sock, count):
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return bytes(data)


def bridge(receiver, source, boundary):
    errors = []

    def pump(origin, destination, upstream):
        try:
            while True:
                header = receive(origin, 24)
                if header[:4] != MAGIC:
                    raise ValueError("Expected testnet4 v1 P2P; v2 transport must be disabled")
                size = int.from_bytes(header[16:20], "little")
                if size > MAX_MESSAGE:
                    raise ValueError("Oversized P2P message")
                payload = receive(origin, size)
                if sha256d(payload)[:4] != header[20:24]:
                    raise ValueError("P2P checksum mismatch")
                transformed = boundary.transform(header[4:16].rstrip(b"\0"), payload, upstream)
                if transformed is not None:
                    destination.sendall(header[:16] + struct.pack("<I", len(transformed)) +
                                        sha256d(transformed)[:4] + transformed)
        except (EOFError, ConnectionError):
            pass
        except OSError as exc:
            if exc.errno not in (9, 22):
                errors.append(str(exc))
        except Exception as exc:
            errors.append(str(exc))
        finally:
            for sock in (origin, destination):
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    threads = [threading.Thread(target=pump, args=(receiver, source, False)),
               threading.Thread(target=pump, args=(source, receiver, True))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if errors:
        raise RuntimeError("; ".join(errors))


def main():
    boundary = Boundary(os.environ["REFERENCE_GENESIS_HASH"])
    host, port = os.environ["REFERENCE_P2P_PEER"].rsplit(":", 1)
    with socket.create_server(("0.0.0.0", 48333)) as server:
        print("relay_ready", flush=True)
        receiver, _ = server.accept()
        with receiver, socket.create_connection((host, int(port))) as source:
            for sock in (receiver, source):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            bridge(receiver, source, boundary)
    print(json.dumps({"withheld_requests": boundary.withheld_requests,
                      "withheld_blocks": boundary.withheld_blocks,
                      "forwarded_blocks": boundary.forwarded_blocks,
                      "known_bounded_headers": len(boundary.heights) - 1}), flush=True)


if __name__ == "__main__":
    main()
