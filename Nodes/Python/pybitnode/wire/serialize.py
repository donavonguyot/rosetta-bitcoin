from __future__ import annotations

import hashlib
import struct


def double_sha256(data: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def message_checksum(payload: bytes) -> bytes:
    return double_sha256(payload)[:4]


def pack_uint32_le(value: int) -> bytes:
    return struct.pack("<I", value)


def pack_int32_le(value: int) -> bytes:
    return struct.pack("<i", value)


def pack_int64_le(value: int) -> bytes:
    return struct.pack("<q", value)


def pack_uint64_le(value: int) -> bytes:
    return struct.pack("<Q", value)


def unpack_uint32_le(data: bytes, offset: int = 0) -> tuple[int, int]:
    (value,) = struct.unpack_from("<I", data, offset)
    return value, offset + 4


def unpack_int32_le(data: bytes, offset: int = 0) -> tuple[int, int]:
    (value,) = struct.unpack_from("<i", data, offset)
    return value, offset + 4


def unpack_int64_le(data: bytes, offset: int = 0) -> tuple[int, int]:
    (value,) = struct.unpack_from("<q", data, offset)
    return value, offset + 8


def unpack_uint64_le(data: bytes, offset: int = 0) -> tuple[int, int]:
    (value,) = struct.unpack_from("<Q", data, offset)
    return value, offset + 8


def read_varint(data: bytes, offset: int = 0) -> tuple[int, int]:
    if offset >= len(data):
        raise ValueError("varint read past end of buffer")
    prefix = data[offset]
    offset += 1
    if prefix < 0xFD:
        return prefix, offset
    if prefix == 0xFD:
        (value,) = struct.unpack_from("<H", data, offset)
        return value, offset + 2
    if prefix == 0xFE:
        (value,) = struct.unpack_from("<I", data, offset)
        return value, offset + 4
    (value,) = struct.unpack_from("<Q", data, offset)
    return value, offset + 8


def write_varint(value: int) -> bytes:
    if value < 0xFD:
        return bytes([value])
    if value <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", value)
    if value <= 0xFFFFFFFF:
        return b"\xfe" + struct.pack("<I", value)
    return b"\xff" + struct.pack("<Q", value)


def read_fixed_string(data: bytes, offset: int, length: int) -> tuple[str, int]:
    raw = data[offset : offset + length]
    return raw.rstrip(b"\x00").decode("ascii", errors="replace"), offset + length
