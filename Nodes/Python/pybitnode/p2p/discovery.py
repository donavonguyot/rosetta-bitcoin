from __future__ import annotations

import asyncio
import logging
import random
import socket

from pybitnode.chain.params import ChainParams
from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.p2p.peer import PeerConnection, resolve_seed
from pybitnode.endpoint_parse import host_port_is_well_formed_endpoint

logger = logging.getLogger(__name__)


def _is_routable(host: str, port: int, default_port: int) -> bool:
    """Filter loopback/zero and malformed wire endpoints before outbound connect attempts."""
    if not host_port_is_well_formed_endpoint(host, port):
        return False
    if host in {"0.0.0.0", "::", "127.0.0.1", "::1"}:
        return False
    if host.startswith("127."):
        return False
    _ = default_port
    return True


async def resolve_seed_peers(chain: ChainParams, count: int) -> list[tuple[str, int]]:
    peers: list[tuple[str, int]] = []
    seen: set[tuple[str, int]] = set()
    if not chain.dns_seeds:
        return peers
    # Random order spreads load across seeds and avoids always hammering dns_seeds[0].
    seed_hosts = list(chain.dns_seeds)
    random.shuffle(seed_hosts)
    for seed in seed_hosts:
        logger.debug(
            "Resolving DNS seed %r for %s (default port %s)",
            seed,
            chain.name,
            chain.default_port,
        )
        try:
            infos = await asyncio.to_thread(
                socket.getaddrinfo,
                seed,
                chain.default_port,
                type=socket.SOCK_STREAM,
            )
        except socket.gaierror as exc:
            logger.debug("DNS seed %r failed (%s)", seed, exc)
            continue
        for info in infos:
            host = info[4][0]
            item = (host, chain.default_port)
            if item not in seen:
                seen.add(item)
                peers.append(item)
                logger.debug("DNS seed candidate %s:%s (from %r)", host, chain.default_port, seed)
            if len(peers) >= count:
                return peers
    return peers


def merge_peer_candidates(
    chain: ChainParams,
    *,
    manual: list[tuple[str, int]],
    stored: list[tuple[str, int]],
    discovered: list[tuple[str, int]],
    seeds: list[tuple[str, int]],
) -> list[tuple[str, int]]:
    merged: list[tuple[str, int]] = []
    seen: set[tuple[str, int]] = set()
    for group in (manual, stored, discovered, seeds):
        for host, port in group:
            if not _is_routable(host, port, chain.default_port):
                continue
            item = (host, port)
            if item in seen:
                continue
            seen.add(item)
            merged.append(item)
    return merged


async def bootstrap_peer_targets(
    chain: ChainParams,
    tracker: ProjectTracker,
    settings: Settings,
    manual_peers: list[tuple[str, int]],
) -> list[tuple[str, int]]:
    stored = tracker.list_peer_address_endpoints(limit=settings.max_outbound_peers * 4)
    seeds = await resolve_seed_peers(chain, settings.max_outbound_peers)
    if not manual_peers and not stored and not seeds:
        host, port = await asyncio.to_thread(resolve_seed, chain)
        seeds = [(host, port)]
    merged = merge_peer_candidates(
        chain,
        manual=manual_peers,
        stored=stored,
        discovered=[],
        seeds=seeds,
    )[: settings.max_outbound_peers * 2]
    th = settings.peer_ban_score_threshold
    manual_set = set(manual_peers)
    return [
        t
        for t in merged
        if t in manual_set or tracker.get_peer_endpoint_ban_score(t[0], t[1]) <= th
    ]
