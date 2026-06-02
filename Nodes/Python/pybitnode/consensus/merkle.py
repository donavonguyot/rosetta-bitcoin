from __future__ import annotations

from pybitnode.messages.transaction import Transaction
from pybitnode.wire.serialize import double_sha256


def transaction_txid(transaction: Transaction) -> bytes:
    return double_sha256(transaction.serialize(include_witness=False))


def merkle_root(hashes: list[bytes]) -> bytes:
    if not hashes:
        return b"\x00" * 32
    layer = list(hashes)
    while len(layer) > 1:
        if len(layer) % 2 == 1:
            layer.append(layer[-1])
        next_layer: list[bytes] = []
        for left, right in zip(layer[0::2], layer[1::2], strict=True):
            next_layer.append(double_sha256(left + right))
        layer = next_layer
    return layer[0]


def block_merkle_root(transactions: list[Transaction]) -> bytes:
    return merkle_root([transaction_txid(tx) for tx in transactions])
