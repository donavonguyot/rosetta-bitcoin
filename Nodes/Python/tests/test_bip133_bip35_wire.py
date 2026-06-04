from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.messages.fee_filter import (
    FEEFILTER_MIN_VERSION,
    FeeFilterMessage,
    feefilter_wire_sat_kvb_from_settings,
)
from pybitnode.messages.handshake import (
    NODE_NETWORK,
    NODE_WITNESS,
    NetworkAddress,
    VersionMessage,
)
from pybitnode.messages.mempool_query import MempoolRequestMessage
from pybitnode.p2p.peer import PeerConnection


def test_feefilter_serialize_roundtrip():
    ff = FeeFilterMessage(feerate_sat_kvb=12345)
    assert FeeFilterMessage.deserialize(ff.serialize()) == ff


def test_feefilter_rejects_truncated_payload():
    with pytest.raises(ValueError):
        FeeFilterMessage.deserialize(b"\x01\x02")


def test_mempool_command_empty_payload():
    assert MempoolRequestMessage().serialize() == b""


def test_wire_value_from_settings_multiplies_kb():
    settings = Settings(min_relay_feerate_sat_vb=3)
    assert feefilter_wire_sat_kvb_from_settings(settings) == 3000


@pytest.mark.asyncio
async def test_post_verack_outbound_announces_fee_and_requests_mempool(tmp_path):
    recv = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
    frm = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
    tracker = ProjectTracker(tmp_path / "nego-chainstate")
    tracker.upsert_sync_state(TESTNET4.name, sync_status="headers_current")

    peer = PeerConnection(
        host="127.0.0.1",
        port=1,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        settings=Settings(min_relay_feerate_sat_vb=2),
    )
    peer.remote_version = VersionMessage.build(
        protocol_version=70016,
        services=NODE_NETWORK,
        addr_recv=recv,
        addr_from=frm,
        user_agent="/remote/",
        relay=True,
    )

    peer.send = AsyncMock()
    await peer._post_verack_negotiation(outbound=True)

    names = [c.args[0] for c in peer.send.await_args_list]
    assert names == ["feefilter", "mempool"]

    ff = FeeFilterMessage.deserialize(peer.send.await_args_list[0].args[1])
    assert ff.feerate_sat_kvb == 2000
    assert peer.send.await_args_list[1].args[1] == b""

    tracker.close()


@pytest.mark.asyncio
async def test_post_verack_initial_sync_defers_relay_messages(tmp_path):
    recv = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
    frm = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
    tracker = ProjectTracker(tmp_path / "defer-chainstate")
    tracker.upsert_sync_state(TESTNET4.name, sync_status="headers_syncing")

    peer = PeerConnection(
        host="127.0.0.1",
        port=1,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        settings=Settings(min_relay_feerate_sat_vb=2),
    )
    peer.remote_version = VersionMessage.build(
        protocol_version=70016,
        services=NODE_NETWORK,
        addr_recv=recv,
        addr_from=frm,
        user_agent="/remote/",
        relay=True,
    )

    peer.send = AsyncMock()
    await peer._post_verack_negotiation(outbound=True)

    peer.send.assert_not_awaited()
    tracker.close()


@pytest.mark.asyncio
async def test_post_verack_skips_fee_on_inbound(tmp_path):
    recv = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
    frm = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)

    tracker = ProjectTracker(tmp_path / "nego_in-chainstate")
    tracker.upsert_sync_state(TESTNET4.name, sync_status="headers_current")
    peer = PeerConnection(
        host="127.0.0.1",
        port=2,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        settings=Settings(min_relay_feerate_sat_vb=99),
    )
    peer.remote_version = VersionMessage.build(
        protocol_version=70016,
        services=NODE_NETWORK,
        addr_recv=recv,
        addr_from=frm,
        user_agent="/remote/",
        relay=True,
    )
    peer.send = AsyncMock()
    await peer._post_verack_negotiation(outbound=False)
    names = [c.args[0] for c in peer.send.await_args_list]
    assert names == ["mempool"]

    tracker.close()


@pytest.mark.asyncio
async def test_post_verack_peer_relay_disabled_skips_mempool(tmp_path):
    recv = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
    frm = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
    tracker = ProjectTracker(tmp_path / "norelay-chainstate")
    tracker.upsert_sync_state(TESTNET4.name, sync_status="headers_current")

    peer = PeerConnection(
        host="127.0.0.2",
        port=3,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=70016,
        user_agent="/pybitnode:test/",
        settings=Settings(),
    )
    v = VersionMessage.build(
        protocol_version=70016,
        services=NODE_NETWORK,
        addr_recv=recv,
        addr_from=frm,
        user_agent="/remote/",
        relay=False,
    )
    peer.remote_version = v
    peer.send = AsyncMock()
    await peer._post_verack_negotiation(outbound=True)
    names = [c.args[0] for c in peer.send.await_args_list]
    assert names == ["feefilter"]
    tracker.close()


@pytest.mark.asyncio
async def test_post_verack_legacy_peer_skips_feefilter(tmp_path):
    recv = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
    frm = NetworkAddress(services=NODE_NETWORK | NODE_WITNESS, ip="0.0.0.0", port=0)
    tracker = ProjectTracker(tmp_path / "legacy-chainstate")
    tracker.upsert_sync_state(TESTNET4.name, sync_status="headers_current")

    peer = PeerConnection(
        host="127.0.0.3",
        port=4,
        chain=TESTNET4,
        tracker=tracker,
        protocol_version=FEEFILTER_MIN_VERSION - 1,
        user_agent="/pybitnode:test/",
        settings=Settings(min_relay_feerate_sat_vb=1),
    )
    peer.remote_version = VersionMessage(
        version=FEEFILTER_MIN_VERSION - 1,
        services=NODE_NETWORK,
        timestamp=1,
        addr_recv=recv,
        addr_from=frm,
        nonce=1,
        user_agent="/old/",
        start_height=0,
        relay=True,
    )

    peer.send = AsyncMock()
    await peer._post_verack_negotiation(outbound=True)
    assert [c.args[0] for c in peer.send.await_args_list] == ["mempool"]

    tracker.close()
