from __future__ import annotations

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.messages.handshake import SendHeadersMessage
from pybitnode.messages.handshake import (
    NODE_NETWORK,
    NODE_WITNESS,
    NetworkAddress,
    PingMessage,
    VersionMessage,
)
from pybitnode.wire.frame import HEADER_SIZE, build_message, parse_header, verify_checksum


def test_message_framing_roundtrip():
    payload = PingMessage(nonce=123456789).serialize()
    frame = build_message(TESTNET4.magic, "ping", payload)
    header = parse_header(frame[:HEADER_SIZE])
    body = frame[HEADER_SIZE:]

    assert header.command == "ping"
    assert header.length == len(payload)
    assert verify_checksum(body, header.checksum)
    assert PingMessage.deserialize(body).nonce == 123456789


def test_version_message_serialization():
    addr = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="127.0.0.1", port=48333)
    version = VersionMessage.build(
        protocol_version=70016,
        services=NODE_NETWORK | NODE_WITNESS,
        addr_recv=addr,
        addr_from=addr,
        user_agent="/pybitnode:0.1.0/",
        start_height=0,
    )
    payload = version.serialize()
    restored = VersionMessage.deserialize(payload)
    assert restored.version == 70016
    assert restored.user_agent == "/pybitnode:0.1.0/"
    assert restored.start_height == 0


def test_sendheaders_is_empty_payload():
    msg = SendHeadersMessage()
    frame = build_message(TESTNET4.magic, msg.COMMAND, msg.serialize())
    header = parse_header(frame[:HEADER_SIZE])
    assert header.command == "sendheaders"
    assert header.length == 0
