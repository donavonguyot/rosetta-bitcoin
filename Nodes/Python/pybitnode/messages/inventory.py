from __future__ import annotations

import struct
from dataclasses import dataclass

from pybitnode.wire.serialize import read_varint, write_varint


@dataclass(frozen=True)
class InventoryVector:
    type: int
    hash: bytes  # 32 bytes, internal byte order

    MSG_TX = 1
    MSG_BLOCK = 2
    MSG_WITNESS_TX = 1 | (1 << 30)
    MSG_WITNESS_BLOCK = 2 | (1 << 30)

    def serialize(self) -> bytes:
        if len(self.hash) != 32:
            raise ValueError("inventory hash must be 32 bytes")
        return struct.pack("<I", self.type) + self.hash


@dataclass
class InvMessage:
    inventory: list[InventoryVector]
    COMMAND = "inv"

    def serialize(self) -> bytes:
        payload = write_varint(len(self.inventory))
        for item in self.inventory:
            payload += item.serialize()
        return payload

    @classmethod
    def deserialize(cls, payload: bytes) -> InvMessage:
        count, offset = read_varint(payload, 0)
        items: list[InventoryVector] = []
        for _ in range(count):
            (inv_type,) = struct.unpack_from("<I", payload, offset)
            offset += 4
            inv_hash = payload[offset : offset + 32]
            offset += 32
            items.append(InventoryVector(type=inv_type, hash=inv_hash))
        return cls(inventory=items)


BLOCK_INVENTORY_TYPES = frozenset(
    {
        InventoryVector.MSG_BLOCK,
        InventoryVector.MSG_WITNESS_BLOCK,
    }
)

TX_INVENTORY_TYPES = frozenset(
    {
        InventoryVector.MSG_TX,
        InventoryVector.MSG_WITNESS_TX,
    }
)


def has_block_inventory(message: InvMessage) -> bool:
    return any(item.type in BLOCK_INVENTORY_TYPES for item in message.inventory)


def has_transaction_inventory(message: InvMessage) -> bool:
    return any(item.type in TX_INVENTORY_TYPES for item in message.inventory)


def block_inventory_hashes(message: InvMessage) -> list[bytes]:
    return [item.hash for item in message.inventory if item.type in BLOCK_INVENTORY_TYPES]


@dataclass
class GetHeadersMessage:
    version: int
    locator_hashes: list[bytes]
    hash_stop: bytes
    COMMAND = "getheaders"

    def serialize(self) -> bytes:
        payload = struct.pack("<i", self.version)
        payload += write_varint(len(self.locator_hashes))
        for block_hash in self.locator_hashes:
            payload += block_hash
        payload += self.hash_stop
        return payload

    @classmethod
    def deserialize(cls, payload: bytes) -> GetHeadersMessage:
        (version,) = struct.unpack_from("<i", payload, 0)
        offset = 4
        count, offset = read_varint(payload, offset)
        locator_hashes: list[bytes] = []
        for _ in range(count):
            locator_hashes.append(payload[offset : offset + 32])
            offset += 32
        if offset + 32 != len(payload):
            raise ValueError("invalid getheaders payload length")
        hash_stop = payload[offset : offset + 32]
        return cls(version=version, locator_hashes=locator_hashes, hash_stop=hash_stop)
