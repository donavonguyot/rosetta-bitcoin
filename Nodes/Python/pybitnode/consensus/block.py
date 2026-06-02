from __future__ import annotations

from dataclasses import dataclass

from pybitnode.messages.headers import BlockHeader
from pybitnode.messages.transaction import Transaction
from pybitnode.wire.serialize import read_varint

WITNESS_MARKER = b"\x00\x01"


@dataclass(frozen=True)
class Block:
    header: BlockHeader
    transactions: tuple[Transaction, ...]

    @classmethod
    def deserialize(cls, payload: bytes) -> Block:
        header, offset = BlockHeader.deserialize(payload, 0)
        tx_count, offset = read_varint(payload, offset)
        if offset + 1 < len(payload) and payload[offset : offset + 2] == WITNESS_MARKER:
            offset += 2
        transactions: list[Transaction] = []
        for _ in range(tx_count):
            transaction, offset = Transaction.deserialize(payload, offset)
            transactions.append(transaction)
        if offset != len(payload):
            raise ValueError(f"trailing block bytes: {len(payload) - offset}")
        return cls(header=header, transactions=tuple(transactions))
