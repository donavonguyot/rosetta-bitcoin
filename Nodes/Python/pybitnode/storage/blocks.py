from __future__ import annotations

import struct
from pathlib import Path

from pybitnode.messages.headers import BlockHeader


class BlockStore:
    """Append-only block flat files (Bitcoin Core blk*.dat style)."""

    def __init__(self, blocks_dir: Path, network_magic: bytes) -> None:
        if len(network_magic) != 4:
            raise ValueError("network magic must be 4 bytes")
        self.blocks_dir = blocks_dir
        self.network_magic = network_magic
        self.blocks_dir.mkdir(parents=True, exist_ok=True)
        self._file_index = 0
        self._file_path = self._open_file()
        self._offset = self._file_path.stat().st_size if self._file_path.exists() else 0

    def _open_file(self) -> Path:
        path = self.blocks_dir / f"blk{self._file_index:05d}.dat"
        path.touch(exist_ok=True)
        return path

    def write(self, block_data: bytes) -> tuple[str, int, int]:
        record = self.network_magic + struct.pack("<I", len(block_data)) + block_data
        if self._offset + len(record) > 128 * 1024 * 1024 and self._offset > 0:
            self._file_index += 1
            self._file_path = self._open_file()
            self._offset = 0
        offset = self._offset
        with self._file_path.open("ab") as handle:
            handle.write(record)
        self._offset += len(record)
        return self._file_path.name, offset, len(block_data)

    def read(self, file_name: str, offset: int, size: int) -> bytes:
        path = self.blocks_dir / file_name
        with path.open("rb") as handle:
            handle.seek(offset)
            magic = handle.read(4)
            (payload_size,) = struct.unpack("<I", handle.read(4))
            if payload_size != size:
                raise ValueError(f"Block size mismatch: expected {size}, file has {payload_size}")
            if magic != self.network_magic:
                raise ValueError("Block file magic mismatch")
            data = handle.read(size)
        if len(data) != size:
            raise ValueError("Unexpected EOF reading block")
        return data


def block_hash_from_payload(payload: bytes) -> bytes:
    header, _ = BlockHeader.deserialize(payload, 0)
    return header.block_hash()


def block_hash_hex_from_payload(payload: bytes) -> str:
    return block_hash_from_payload(payload)[::-1].hex()
