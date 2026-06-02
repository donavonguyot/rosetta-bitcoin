"""Tests for pybitnode.endpoint_parse (manual peer strings + endpoint validation)."""

from __future__ import annotations

import pytest

from pybitnode.endpoint_parse import (
    host_port_is_well_formed_endpoint,
    normalize_peer_manual_spec,
    split_manual_peer_list,
)


def test_rejects_mapped_ipv6_garbage_port_segment():
    assert not host_port_is_well_formed_endpoint("::ffff:8849", 8333)


@pytest.mark.parametrize(
    ("raw", "host", "port"),
    (
        ("8.8.8.8:48333", "8.8.8.8", 48333),
        ("[2001:db8::1]:8333", "2001:db8::1", 8333),
        ("seed.example.invalid", "seed.example.invalid", 18333),
    ),
)
def test_normalize_peer_manual_spec_ok(raw: str, host: str, port: int):
    ep = normalize_peer_manual_spec(raw, default_port=18333)
    assert ep == (host, port)


def test_split_manual_peer_list_skips_garbage():
    out = split_manual_peer_list("203.0.113.10:48333,::ffff:9999,,badport:", 48333)
    assert out == [("203.0.113.10", 48333)]
