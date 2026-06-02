from __future__ import annotations

from pybitnode.consensus.block import Block
from pybitnode.consensus.merkle import block_merkle_root
from pybitnode.messages.headers import BlockHeader


class HeaderValidationError(ValueError):
    pass


class BlockValidationError(ValueError):
    pass


def compact_to_target(bits: int) -> int:
    exponent = bits >> 24
    mantissa = bits & 0x007FFFFF
    if mantissa == 0:
        raise HeaderValidationError(f"Invalid compact bits: {bits:#x}")
    if exponent <= 3:
        return mantissa >> (8 * (3 - exponent))
    return mantissa << (8 * (exponent - 3))


def header_meets_target(header: BlockHeader) -> bool:
    target = compact_to_target(header.bits)
    if target == 0:
        return False
    hash_value = int.from_bytes(header.block_hash(), "little")
    return hash_value <= target


def validate_header(header: BlockHeader, *, expected_prev: bytes) -> None:
    if header.prev_block != expected_prev:
        raise HeaderValidationError(
            f"prev_block mismatch: expected {expected_prev[::-1].hex()}, "
            f"got {header.prev_block[::-1].hex()}"
        )
    if not header_meets_target(header):
        raise HeaderValidationError(f"proof of work failed for bits {header.bits:#x}")


def validate_block(
    payload: bytes,
    *,
    expected_prev: bytes,
    expected_hash: bytes | None = None,
) -> Block:
    try:
        block = Block.deserialize(payload)
    except ValueError as exc:
        raise BlockValidationError(str(exc)) from exc

    header = block.header
    try:
        validate_header(header, expected_prev=expected_prev)
    except HeaderValidationError as exc:
        raise BlockValidationError(str(exc)) from exc

    if expected_hash is not None and header.block_hash() != expected_hash:
        raise BlockValidationError(
            f"block hash mismatch: expected {expected_hash[::-1].hex()}, "
            f"got {header.block_hash_hex()}"
        )

    if not block.transactions:
        raise BlockValidationError("block has no transactions")

    if not block.transactions[0].is_coinbase:
        raise BlockValidationError("first transaction must be coinbase")

    merkle_root = block_merkle_root(list(block.transactions))
    if merkle_root != header.merkle_root:
        raise BlockValidationError(
            f"merkle root mismatch: expected {header.merkle_root[::-1].hex()}, "
            f"computed {merkle_root[::-1].hex()}"
        )

    return block
