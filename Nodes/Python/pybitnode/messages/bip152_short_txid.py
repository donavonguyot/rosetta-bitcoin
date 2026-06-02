"""Bitcoin BIP152 short transaction identifiers (Bitcoin Core ``PresaltedSipHasher``)."""

from __future__ import annotations

import hashlib
import struct

from pybitnode.messages.headers import BlockHeader

_U64_MASK = (1 << 64) - 1
_C0 = 0x736F6D6570736575
_C1 = 0x646F72616E646F6D
_C2 = 0x6C7967656E657261
_C3 = 0x7465646279746573


def _rotl_u64(value: int, bits: int) -> int:
    value &= _U64_MASK
    return ((value << bits) | (value >> (64 - bits))) & _U64_MASK


def _sip_round(v0: int, v1: int, v2: int, v3: int) -> tuple[int, int, int, int]:
    v0 = (v0 + v1) & _U64_MASK
    v1 = _rotl_u64(v1 ^ v0, 13)
    v0 = _rotl_u64(v0, 32)
    v2 = (v2 + v3) & _U64_MASK
    v3 = _rotl_u64(v3 ^ v2, 16)
    v0 = (v0 + v3) & _U64_MASK
    v3 = _rotl_u64(v3 ^ v0, 21)
    v2 = (v2 + v1) & _U64_MASK
    v1 = _rotl_u64(v1 ^ v2, 17)
    v2 = _rotl_u64(v2, 32)
    return v0, v1, v2, v3


def _sip_state_from_keys(k0: int, k1: int) -> tuple[int, int, int, int]:
    return (
        (_C0 ^ k0) & _U64_MASK,
        (_C1 ^ k1) & _U64_MASK,
        (_C2 ^ k0) & _U64_MASK,
        (_C3 ^ k1) & _U64_MASK,
    )


def short_id_nonce_key(header: BlockHeader, short_id_nonce: int) -> tuple[int, int]:
    digest = hashlib.sha256(header.serialize() + struct.pack("<Q", short_id_nonce)).digest()
    return int.from_bytes(digest[0:8], "little"), int.from_bytes(digest[8:16], "little")


def presalted_short_id_from_uint256_digest(k0: int, k1: int, digest32: bytes) -> bytes:
    """Lower 48 bits of Bitcoin Core's ``PresaltedSipHasher{k0,k1}(uint256)`` as 6-byte LE."""

    if len(digest32) != 32:
        raise ValueError("digest must be 32 bytes")
    v0, v1, v2, v3 = _sip_state_from_keys(k0, k1)
    for chunk in range(0, 32, 8):
        d = int.from_bytes(digest32[chunk : chunk + 8], "little") & _U64_MASK
        v3 = (v3 ^ d) & _U64_MASK
        v0, v1, v2, v3 = _sip_round(v0, v1, v2, v3)
        v0, v1, v2, v3 = _sip_round(v0, v1, v2, v3)
        v0 = (v0 ^ d) & _U64_MASK
    tail = (4 << 59) & _U64_MASK
    v3 = (v3 ^ tail) & _U64_MASK
    v0, v1, v2, v3 = _sip_round(v0, v1, v2, v3)
    v0, v1, v2, v3 = _sip_round(v0, v1, v2, v3)
    v0 = (v0 ^ tail) & _U64_MASK
    v2 = (v2 ^ 0xFF) & _U64_MASK
    v0, v1, v2, v3 = _sip_round(v0, v1, v2, v3)
    v0, v1, v2, v3 = _sip_round(v0, v1, v2, v3)
    v0, v1, v2, v3 = _sip_round(v0, v1, v2, v3)
    v0, v1, v2, v3 = _sip_round(v0, v1, v2, v3)
    out = (v0 ^ v1 ^ v2 ^ v3) & _U64_MASK
    out &= _U64_MASK >> 16
    return out.to_bytes(6, "little")
