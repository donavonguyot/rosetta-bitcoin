from __future__ import annotations

import struct
from dataclasses import dataclass

from pybitnode.config import Settings


@dataclass(frozen=True)
class FeeFilterMessage:
    """BIP133 feefilter: minimum fee rate in satoshis per 1000 virtual bytes (sat/kvB)."""

    feerate_sat_kvb: int
    COMMAND = "feefilter"

    def serialize(self) -> bytes:
        value = max(0, int(self.feerate_sat_kvb)) & ((1 << 64) - 1)
        return struct.pack("<Q", value)

    @classmethod
    def deserialize(cls, payload: bytes) -> FeeFilterMessage:
        if len(payload) != 8:
            raise ValueError(f"feefilter expects 8 bytes, got {len(payload)}")
        (value,) = struct.unpack("<Q", payload[:8])
        return cls(feerate_sat_kvb=int(value))


def feefilter_wire_sat_kvb_from_settings(settings: Settings) -> int:
    """Map local min relay (sat/vB) to wire feefilter units (sat/kvB)."""
    return max(0, int(settings.min_relay_feerate_sat_vb)) * 1000


FEEFILTER_MIN_VERSION = 70013
