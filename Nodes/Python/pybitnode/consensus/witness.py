from __future__ import annotations

from pybitnode.consensus.constants import WITNESS_COMMITMENT_HEADER, WITNESS_RESERVED_VALUE_SIZE
from pybitnode.consensus.merkle import merkle_root
from pybitnode.messages.transaction import Transaction
from pybitnode.wire.serialize import double_sha256


def transaction_wtxid(transaction: Transaction) -> bytes:
    if transaction.is_coinbase:
        return b"\x00" * 32
    return double_sha256(transaction.serialize(include_witness=True))


def witness_merkle_root(transactions: list[Transaction]) -> bytes:
    return merkle_root([transaction_wtxid(tx) for tx in transactions])


def extract_witness_commitment(script_pubkey: bytes) -> bytes | None:
    if len(script_pubkey) < 38 or script_pubkey[0] != 0x6A or script_pubkey[1] != 0x24:
        return None
    if script_pubkey[2:6] != WITNESS_COMMITMENT_HEADER:
        return None
    return script_pubkey[6:38]


def validate_witness_commitment(coinbase: Transaction, transactions: list[Transaction]) -> None:
    if not coinbase.witness or not coinbase.witness[0]:
        raise ValueError("coinbase witness stack missing reserved value")
    reserved = coinbase.witness[0][0]
    if len(reserved) != WITNESS_RESERVED_VALUE_SIZE:
        raise ValueError("coinbase witness reserved value must be 32 bytes")

    commitment_hash = None
    for output in coinbase.outputs:
        extracted = extract_witness_commitment(output.script_pubkey)
        if extracted is not None:
            commitment_hash = extracted
            break
    if commitment_hash is None:
        raise ValueError("coinbase missing witness commitment output")

    root = witness_merkle_root(transactions)
    expected = double_sha256(root + reserved)
    if commitment_hash != expected:
        raise ValueError(
            f"witness commitment mismatch: expected {expected.hex()}, got {commitment_hash.hex()}"
        )
