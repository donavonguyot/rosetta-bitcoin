from __future__ import annotations

import random
import socket
import struct
import time
from dataclasses import dataclass

from pybitnode.wire.serialize import pack_int32_le, pack_int64_le, pack_uint32_le, pack_uint64_le


# Bitcoin P2P service flags (subset used in Phase 0)
NODE_NETWORK = 1 << 0
NODE_WITNESS = 1 << 3


@dataclass
class NetworkAddress:
    """Network address as serialized in version message (protocol >= 31402)."""

    services: int
    ip: str
    port: int

    def serialize(self, with_timestamp: bool = True) -> bytes:
        parts = bytearray()
        if with_timestamp:
            parts.extend(pack_int64_le(int(time.time())))
        parts.extend(pack_uint64_le(self.services))
        parts.extend(self._ip_to_bytes())
        parts.extend(pack_uint16_be(self.port))
        return bytes(parts)

    @classmethod
    def deserialize(cls, data: bytes, offset: int = 0, with_timestamp: bool = True) -> tuple[NetworkAddress, int]:
        required = (8 if with_timestamp else 0) + 8 + 16 + 2
        if offset + required > len(data):
            raise ValueError("truncated network address")
        if with_timestamp:
            _, offset = _unpack_int64(data, offset)
        services, offset = _unpack_uint64(data, offset)
        ip_bytes = data[offset : offset + 16]
        offset += 16
        port, offset = _unpack_uint16_be(data, offset)
        return cls(services=services, ip=_bytes_to_ip(ip_bytes), port=port), offset

    def _ip_to_bytes(self) -> bytes:
        try:
            packed = socket.inet_pton(socket.AF_INET6, self.ip)
        except OSError:
            packed = socket.inet_pton(socket.AF_INET, self.ip)
            packed = b"\xff" * 10 + b"\xff\xff" + packed
        return packed


def pack_uint16_be(value: int) -> bytes:
    return struct.pack(">H", value)


def _unpack_uint16_be(data: bytes, offset: int) -> tuple[int, int]:
    (value,) = struct.unpack_from(">H", data, offset)
    return value, offset + 2


def _unpack_int64(data: bytes, offset: int) -> tuple[int, int]:
    (value,) = struct.unpack_from("<q", data, offset)
    return value, offset + 8


def _unpack_uint64(data: bytes, offset: int) -> tuple[int, int]:
    (value,) = struct.unpack_from("<Q", data, offset)
    return value, offset + 8


def _bytes_to_ip(raw: bytes) -> str:
    if raw[:12] == b"\xff" * 10 + b"\xff\xff":
        return socket.inet_ntop(socket.AF_INET, raw[12:])
    return socket.inet_ntop(socket.AF_INET6, raw)


@dataclass
class VersionMessage:
    version: int
    services: int
    timestamp: int
    addr_recv: NetworkAddress
    addr_from: NetworkAddress
    nonce: int
    user_agent: str
    start_height: int
    relay: bool = True

    COMMAND = "version"

    def serialize(self) -> bytes:
        payload = bytearray()
        payload.extend(pack_int32_le(self.version))
        payload.extend(pack_uint64_le(self.services))
        payload.extend(pack_int64_le(self.timestamp))
        payload.extend(self.addr_recv.serialize(with_timestamp=False))
        payload.extend(self.addr_from.serialize(with_timestamp=False))
        payload.extend(pack_uint64_le(self.nonce))
        ua = self.user_agent.encode("ascii")
        payload.append(len(ua))
        payload.extend(ua)
        payload.extend(pack_int32_le(self.start_height))
        payload.append(1 if self.relay else 0)
        return bytes(payload)

    @classmethod
    def deserialize(cls, payload: bytes) -> VersionMessage:
        offset = 0
        version, offset = _read_int32(payload, offset)
        services, offset = _read_uint64(payload, offset)
        timestamp, offset = _read_int64(payload, offset)
        addr_recv, offset = NetworkAddress.deserialize(payload, offset, with_timestamp=False)
        addr_from, offset = NetworkAddress.deserialize(payload, offset, with_timestamp=False)
        nonce, offset = _read_uint64(payload, offset)
        ua_len = payload[offset]
        offset += 1
        user_agent = payload[offset : offset + ua_len].decode("ascii")
        offset += ua_len
        start_height, offset = _read_int32(payload, offset)
        relay = bool(payload[offset]) if offset < len(payload) else True
        return cls(
            version=version,
            services=services,
            timestamp=timestamp,
            addr_recv=addr_recv,
            addr_from=addr_from,
            nonce=nonce,
            user_agent=user_agent,
            start_height=start_height,
            relay=relay,
        )

    @classmethod
    def build(
        cls,
        *,
        protocol_version: int,
        services: int,
        addr_recv: NetworkAddress,
        addr_from: NetworkAddress,
        user_agent: str,
        start_height: int = 0,
        relay: bool = True,
    ) -> VersionMessage:
        return cls(
            version=protocol_version,
            services=services,
            timestamp=int(time.time()),
            addr_recv=addr_recv,
            addr_from=addr_from,
            nonce=random.getrandbits(64),
            user_agent=user_agent,
            start_height=start_height,
            relay=relay,
        )


@dataclass(frozen=True)
class VerAckMessage:
    COMMAND = "verack"

    def serialize(self) -> bytes:
        return b""


@dataclass(frozen=True)
class SendHeadersMessage:
    """BIP130 — announce preference for headers-first block propagation."""

    COMMAND = "sendheaders"

    def serialize(self) -> bytes:
        return b""


@dataclass(frozen=True)
class PingMessage:
    nonce: int
    COMMAND = "ping"

    def serialize(self) -> bytes:
        return pack_uint64_le(self.nonce)

    @classmethod
    def deserialize(cls, payload: bytes) -> PingMessage:
        (nonce,) = struct.unpack("<Q", payload[:8])
        return cls(nonce=nonce)


@dataclass(frozen=True)
class PongMessage:
    nonce: int
    COMMAND = "pong"

    def serialize(self) -> bytes:
        return pack_uint64_le(self.nonce)

    @classmethod
    def deserialize(cls, payload: bytes) -> PongMessage:
        (nonce,) = struct.unpack("<Q", payload[:8])
        return cls(nonce=nonce)


def _read_int32(data: bytes, offset: int) -> tuple[int, int]:
    (value,) = struct.unpack_from("<i", data, offset)
    return value, offset + 4


def _read_int64(data: bytes, offset: int) -> tuple[int, int]:
    (value,) = struct.unpack_from("<q", data, offset)
    return value, offset + 8


def _read_uint64(data: bytes, offset: int) -> tuple[int, int]:
    (value,) = struct.unpack_from("<Q", data, offset)
    return value, offset + 8
