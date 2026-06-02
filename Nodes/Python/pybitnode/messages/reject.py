"""Bitcoin P2P `reject` message (BIP61-style parse/serialize).

Layout: compact-size message | uint8 code | compact-size reason | optional data (remainder).
"""

from __future__ import annotations

from dataclasses import dataclass

from pybitnode.wire.serialize import read_varint, write_varint

# --- BIP61 / common rejection codes ---
REJECT_MALFORMED = 0x01
REJECT_INVALID = 0x10
REJECT_OBSOLETE = 0x11
REJECT_DUPLICATE = 0x12
REJECT_NONSTANDARD = 0x40
REJECT_DUST = 0x41
REJECT_INSUFFICIENTFEE = 0x42


def _read_compact_string(payload: bytes, offset: int) -> tuple[bytes, int]:
    length, offset = read_varint(payload, offset)
    end = offset + length
    if end > len(payload):
        raise ValueError("truncated compact-string in reject")
    return payload[offset:end], end


def _write_compact_string(data: bytes) -> bytes:
    return write_varint(len(data)) + data


@dataclass(frozen=True)
class RejectMessage:
    """Deserialized reject payload (does not include the outer P2P command frame)."""

    message: str
    ccode: int
    reason: str
    data: bytes = b""

    COMMAND = "reject"

    def serialize(self) -> bytes:
        mb = self.message.encode("ascii", errors="strict")
        rb = self.reason.encode("utf-8", errors="replace")
        if not 0 <= self.ccode <= 0xFF:
            raise ValueError("ccode out of uint8 range")
        buf = bytearray()
        buf.extend(_write_compact_string(mb))
        buf.append(self.ccode)
        buf.extend(_write_compact_string(rb))
        buf.extend(self.data)
        return bytes(buf)

    @classmethod
    def deserialize(cls, payload: bytes) -> RejectMessage:
        if not payload:
            raise ValueError("empty reject payload")
        offset = 0
        msg_raw, offset = _read_compact_string(payload, offset)
        if offset >= len(payload):
            raise ValueError("truncated reject (missing code)")
        ccode = payload[offset]
        offset += 1
        reason_raw, offset = _read_compact_string(payload, offset)
        data = payload[offset:]
        return cls(
            message=msg_raw.decode("ascii", errors="replace"),
            ccode=int(ccode),
            reason=reason_raw.decode("utf-8", errors="replace"),
            data=data,
        )
