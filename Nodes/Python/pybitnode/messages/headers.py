from __future__ import annotations

import struct
from dataclasses import dataclass

from pybitnode.wire.serialize import double_sha256, read_varint, write_varint

HEADER_STRUCT = struct.Struct("<i32s32sIII")
HEADER_SIZE = HEADER_STRUCT.size  # 80 bytes


@dataclass(frozen=True)
class BlockHeader:
    version: int
    prev_block: bytes
    merkle_root: bytes
    timestamp: int
    bits: int
    nonce: int

    def serialize(self) -> bytes:
        return HEADER_STRUCT.pack(
            self.version,
            self.prev_block,
            self.merkle_root,
            self.timestamp,
            self.bits,
            self.nonce,
        )

    @classmethod
    def deserialize(cls, data: bytes, offset: int = 0) -> tuple[BlockHeader, int]:
        (
            version,
            prev_block,
            merkle_root,
            timestamp,
            bits,
            nonce,
        ) = HEADER_STRUCT.unpack_from(data, offset)
        return cls(
            version=version,
            prev_block=prev_block,
            merkle_root=merkle_root,
            timestamp=timestamp,
            bits=bits,
            nonce=nonce,
        ), offset + HEADER_SIZE

    def block_hash(self) -> bytes:
        return double_sha256(self.serialize())

    def block_hash_hex(self) -> str:
        return self.block_hash()[::-1].hex()


@dataclass(frozen=True)
class HeadersMessage:
    headers: tuple[BlockHeader, ...]
    COMMAND = "headers"

    @classmethod
    def deserialize(cls, payload: bytes) -> HeadersMessage:
        count, offset = read_varint(payload, 0)
        headers: list[BlockHeader] = []
        for _ in range(count):
            header, offset = BlockHeader.deserialize(payload, offset)
            _, offset = read_varint(payload, offset)  # tx count, always 0 on the wire
            headers.append(header)
        return cls(headers=tuple(headers))

    def serialize(self) -> bytes:
        payload = write_varint(len(self.headers))
        for header in self.headers:
            payload += header.serialize()
            payload += b"\x00"  # zero transactions
        return payload
