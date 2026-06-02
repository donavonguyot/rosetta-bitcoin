from __future__ import annotations

import struct
from dataclasses import dataclass

from pybitnode.wire.serialize import message_checksum

HEADER_SIZE = 24


@dataclass(frozen=True)
class MessageHeader:
    magic: bytes
    command: str
    length: int
    checksum: bytes

    def to_bytes(self) -> bytes:
        cmd = self.command.encode("ascii")[:12].ljust(12, b"\x00")
        return struct.pack("<4s12sI4s", self.magic, cmd, self.length, self.checksum)

    @classmethod
    def from_bytes(cls, data: bytes) -> MessageHeader:
        if len(data) < HEADER_SIZE:
            raise ValueError(f"header requires {HEADER_SIZE} bytes, got {len(data)}")
        magic, cmd_raw, length, checksum = struct.unpack("<4s12sI4s", data[:HEADER_SIZE])
        command = cmd_raw.rstrip(b"\x00").decode("ascii")
        return cls(magic=magic, command=command, length=length, checksum=checksum)


def build_message(magic: bytes, command: str, payload: bytes) -> bytes:
    header = MessageHeader(
        magic=magic,
        command=command,
        length=len(payload),
        checksum=message_checksum(payload),
    )
    return header.to_bytes() + payload


def parse_header(data: bytes) -> MessageHeader:
    return MessageHeader.from_bytes(data)


def verify_checksum(payload: bytes, checksum: bytes) -> bool:
    return message_checksum(payload) == checksum
