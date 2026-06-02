"""Peer ban score increments (Phase 5 lite; aggregate in peer_addresses, session deltas on peers).

Ban **constants** live here (per-event increments). Operational knobs for aggregates are **not** in this module:

- ``PEER_BAN_SCORE_THRESHOLD`` — bootstrap skips high-score endpoints (`Settings.peer_ban_score_threshold`).
- ``PEER_BAN_DECAY_UPTIME_SECONDS`` / ``PEER_BAN_DECAY_AMOUNT`` — after a long-lived session, decay runs
  once on activity ticks (`PeerConnection._maybe_decay_ban_after_long_uptime`).

See ``docs/OPERATIONS.md`` for tuning guidance.
"""

from __future__ import annotations

from pybitnode.messages.reject import (
    REJECT_DUPLICATE,
    REJECT_DUST,
    REJECT_INSUFFICIENTFEE,
    REJECT_INVALID,
    REJECT_MALFORMED,
    REJECT_NONSTANDARD,
    REJECT_OBSOLETE,
)

# Outbound/inbound failed before or during version exchange.
BAN_HANDSHAKE_FAIL = 15
# Bad magic, checksum, or framing errors in read_message.
BAN_PROTOCOL_VIOLATION = 25
# Connection reset, peer closed, stale timeout, etc.
BAN_DISCONNECT = 10
# Deserialization issues while staying connected (e.g. malformed tx).
BAN_INVALID_MESSAGE = 8
# Many inbound reject messages from one peer in a single session (light flood hint).
BAN_REJECT_FLOOD = 3

# Inbound BIP61-style `reject` ccode → per-message ban hint (see ban_score_for_reject_ccode).
BAN_REJECT_CC_MALFORMED = 10
BAN_REJECT_CC_INVALID = 12
BAN_REJECT_CC_OBSOLETE = 7
BAN_REJECT_CC_DUPLICATE = 3
BAN_REJECT_CC_POLICY = 5  # nonstandard / dust / insufficient fee
BAN_REJECT_CC_UNKNOWN = 4


def ban_score_for_reject_ccode(ccode: int) -> int:
    """Ban score increment when a peer sends a well-formed inbound `reject` (BIP61 ccode)."""

    c = int(ccode)
    if c == REJECT_MALFORMED:
        return BAN_REJECT_CC_MALFORMED
    if c == REJECT_INVALID:
        return BAN_REJECT_CC_INVALID
    if c == REJECT_OBSOLETE:
        return BAN_REJECT_CC_OBSOLETE
    if c == REJECT_DUPLICATE:
        return BAN_REJECT_CC_DUPLICATE
    if c in (REJECT_NONSTANDARD, REJECT_DUST, REJECT_INSUFFICIENTFEE):
        return BAN_REJECT_CC_POLICY
    return BAN_REJECT_CC_UNKNOWN
