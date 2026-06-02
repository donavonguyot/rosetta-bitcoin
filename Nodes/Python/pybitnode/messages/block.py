from __future__ import annotations

import struct
from dataclasses import dataclass

from pybitnode.messages.inventory import InventoryVector
from pybitnode.wire.serialize import read_varint, write_varint


@dataclass
class GetDataMessage:
    inventory: list[InventoryVector]
    COMMAND = "getdata"

    def serialize(self) -> bytes:
        payload = write_varint(len(self.inventory))
        for item in self.inventory:
            payload += item.serialize()
        return payload

    @classmethod
    def deserialize(cls, payload: bytes) -> GetDataMessage:
        count, offset = read_varint(payload, 0)
        items: list[InventoryVector] = []
        for _ in range(count):
            (inv_type,) = struct.unpack_from("<I", payload, offset)
            offset += 4
            inv_hash = payload[offset : offset + 32]
            offset += 32
            items.append(InventoryVector(type=inv_type, hash=inv_hash))
        return cls(inventory=items)


@dataclass
class NotFoundMessage:
    inventory: list[InventoryVector]
    COMMAND = "notfound"

    def serialize(self) -> bytes:
        return GetDataMessage(inventory=self.inventory).serialize()

    @classmethod
    def deserialize(cls, payload: bytes) -> NotFoundMessage:
        msg = GetDataMessage.deserialize(payload)
        return cls(inventory=msg.inventory)


@dataclass(frozen=True)
class BlockMessage:
    payload: bytes
    COMMAND = "block"

    @classmethod
    def deserialize(cls, payload: bytes) -> BlockMessage:
        return cls(payload=payload)
