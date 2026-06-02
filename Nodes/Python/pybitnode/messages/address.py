from __future__ import annotations

import struct
from dataclasses import dataclass

from pybitnode.messages.handshake import NetworkAddress
from pybitnode.wire.serialize import read_varint, write_varint


@dataclass(frozen=True)
class GetAddrMessage:
    COMMAND = "getaddr"

    def serialize(self) -> bytes:
        return b""


@dataclass
class AddrMessage:
    addresses: tuple[NetworkAddress, ...]
    COMMAND = "addr"

    def serialize(self) -> bytes:
        payload = write_varint(len(self.addresses))
        for address in self.addresses:
            payload += address.serialize(with_timestamp=True)
        return payload

    @classmethod
    def deserialize(cls, payload: bytes) -> AddrMessage:
        count, offset = read_varint(payload, 0)
        addresses: list[NetworkAddress] = []
        for _ in range(count):
            try:
                address, offset = NetworkAddress.deserialize(payload, offset, with_timestamp=True)
            except (ValueError, struct.error):
                break
            addresses.append(address)
        return cls(addresses=tuple(addresses))
