from __future__ import annotations

import struct
from dataclasses import dataclass

from pybitnode.wire.serialize import read_varint, write_varint

WITNESS_MARKER = b"\x00\x01"


@dataclass(frozen=True)
class OutPoint:
    hash: bytes
    index: int

    def serialize(self) -> bytes:
        return self.hash + struct.pack("<I", self.index)


@dataclass(frozen=True)
class TxIn:
    previous_output: OutPoint
    script_sig: bytes
    sequence: int

    def serialize(self) -> bytes:
        payload = self.previous_output.serialize()
        payload += write_varint(len(self.script_sig))
        payload += self.script_sig
        payload += struct.pack("<I", self.sequence)
        return payload


@dataclass(frozen=True)
class TxOut:
    value: int
    script_pubkey: bytes

    def serialize(self) -> bytes:
        payload = struct.pack("<q", self.value)
        payload += write_varint(len(self.script_pubkey))
        payload += self.script_pubkey
        return payload


@dataclass(frozen=True)
class Transaction:
    version: int
    inputs: tuple[TxIn, ...]
    outputs: tuple[TxOut, ...]
    lock_time: int
    witness: tuple[tuple[bytes, ...], ...] = ()

    @property
    def is_coinbase(self) -> bool:
        return (
            len(self.inputs) == 1
            and self.inputs[0].previous_output.hash == b"\x00" * 32
            and self.inputs[0].previous_output.index == 0xFFFFFFFF
        )

    def serialize(self, *, include_witness: bool = False) -> bytes:
        payload = struct.pack("<i", self.version)
        use_witness = include_witness and bool(self.witness)
        if use_witness:
            payload += WITNESS_MARKER
        payload += write_varint(len(self.inputs))
        for tx_in in self.inputs:
            payload += tx_in.serialize()
        payload += write_varint(len(self.outputs))
        for tx_out in self.outputs:
            payload += tx_out.serialize()
        if use_witness:
            for stack in self.witness:
                payload += write_varint(len(stack))
                for item in stack:
                    payload += write_varint(len(item))
                    payload += item
        payload += struct.pack("<I", self.lock_time)
        return payload

    @classmethod
    def deserialize(cls, data: bytes, offset: int = 0) -> tuple[Transaction, int]:
        start = offset
        version, = struct.unpack_from("<i", data, offset)
        offset += 4
        witness = False
        if offset + 1 < len(data) and data[offset : offset + 2] == WITNESS_MARKER:
            witness = True
            offset += 2
        input_count, offset = read_varint(data, offset)
        inputs: list[TxIn] = []
        for _ in range(input_count):
            prev_hash = data[offset : offset + 32]
            offset += 32
            (index,) = struct.unpack_from("<I", data, offset)
            offset += 4
            script_len, offset = read_varint(data, offset)
            script_sig = data[offset : offset + script_len]
            offset += script_len
            (sequence,) = struct.unpack_from("<I", data, offset)
            offset += 4
            inputs.append(
                TxIn(
                    previous_output=OutPoint(hash=prev_hash, index=index),
                    script_sig=script_sig,
                    sequence=sequence,
                )
            )
        output_count, offset = read_varint(data, offset)
        outputs: list[TxOut] = []
        for _ in range(output_count):
            (value,) = struct.unpack_from("<q", data, offset)
            offset += 8
            script_len, offset = read_varint(data, offset)
            script_pubkey = data[offset : offset + script_len]
            offset += script_len
            outputs.append(TxOut(value=value, script_pubkey=script_pubkey))
        witness_stacks: list[tuple[bytes, ...]] = []
        if witness:
            for _ in range(input_count):
                stack_count, offset = read_varint(data, offset)
                stack: list[bytes] = []
                for _ in range(stack_count):
                    item_len, offset = read_varint(data, offset)
                    stack.append(data[offset : offset + item_len])
                    offset += item_len
                witness_stacks.append(tuple(stack))
        (lock_time,) = struct.unpack_from("<I", data, offset)
        offset += 4
        if offset < start:
            raise ValueError("transaction deserialization underflow")
        return cls(
            version=version,
            inputs=tuple(inputs),
            outputs=tuple(outputs),
            lock_time=lock_time,
            witness=tuple(witness_stacks),
        ), offset
