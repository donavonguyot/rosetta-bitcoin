from __future__ import annotations

import pytest

from pybitnode.messages.reject import REJECT_NONSTANDARD, RejectMessage


def test_reject_roundtrip_empty_data():
    msg = RejectMessage(
        message="tx",
        ccode=REJECT_NONSTANDARD,
        reason="dust",
        data=b"",
    )
    assert RejectMessage.deserialize(msg.serialize()) == msg


def test_reject_roundtrip_non_empty_reason_and_extra_data():
    extra = bytes(range(77))
    msg = RejectMessage(
        message="block",
        ccode=0x10,
        reason="bad-txnk",
        data=extra,
    )
    parsed = RejectMessage.deserialize(msg.serialize())
    assert parsed == msg


def test_reject_roundtrip_utf8_reason():
    msg = RejectMessage(
        message="addr",
        ccode=1,
        reason="réussi",
        data=b"\xaa\xbb",
    )
    assert RejectMessage.deserialize(msg.serialize()) == msg


def test_reject_invalid_empty_payload_raises():
    with pytest.raises(ValueError, match="empty reject"):
        RejectMessage.deserialize(b"")


def test_reject_invalid_truncated_raises():
    with pytest.raises(ValueError):
        RejectMessage.deserialize(bytes([1, ord("x")]))  # length 1, only 'x', no code
