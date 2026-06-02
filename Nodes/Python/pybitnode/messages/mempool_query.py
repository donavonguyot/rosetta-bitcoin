from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class MempoolRequestMessage:
    """BIP35 mempool request — empty payload; peers reply with inv vectors."""

    COMMAND = "mempool"

    def serialize(self) -> bytes:
        return b""


__all__ = ["MempoolRequestMessage"]
