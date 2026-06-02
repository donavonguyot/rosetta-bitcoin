"""Validate/normalize outbound P2P host:port targets (manual peers, DB cache, merges)."""

from __future__ import annotations

import ipaddress
import re
from typing import Final

_DNS_LABEL_SAFE: Final = re.compile(r"^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$")


def is_valid_listen_port(port: int) -> bool:
    return 1 <= port <= 65535


def _host_is_plain_hostname(host: str) -> bool:
    h = host.strip().strip(".")
    if not h or len(h) > 253:
        return False
    if "_" in h:
        return False
    # Single-label names (often seeds) OK
    return bool(_DNS_LABEL_SAFE.match(h))


def host_port_is_well_formed_endpoint(host: str, port: int) -> bool:
    """Reject obviously malformed wire/storage endpoints before connect or INSERT."""
    if not host:
        return False
    candidate = host.strip()
    # Strip IPv6 brackets for literal checks only
    if candidate.startswith("[") and candidate.endswith("]"):
        inner = candidate[1:-1]
        candidate_for_ip = inner
    else:
        candidate_for_ip = candidate

    if not is_valid_listen_port(port):
        return False

    lower = candidate_for_ip.lower()
    if lower.startswith("::ffff:"):
        suffix = candidate_for_ip[7:]
        try:
            ipaddress.IPv4Address(suffix)
        except ValueError:
            return False
        return True
    if lower in {"::ffff", "ffff"}:
        return False

    try:
        ipaddress.ip_address(candidate_for_ip)
        return True
    except ValueError:
        pass

    return _host_is_plain_hostname(candidate)


def normalize_peer_manual_spec(raw: str, default_port: int) -> tuple[str, int] | None:
    """Parse comma-separated `--peers` style entries: host, ipv4:port, [ipv6]:port."""
    item = raw.strip()
    if not item:
        return None
    host: str
    port: int
    if item.startswith("["):
        end = item.find("]")
        if end == -1:
            return None
        host = item[1:end].strip()
        rest = item[end + 1 :].strip()
        if rest.startswith(":"):
            try:
                port = int(rest[1:].strip())
            except ValueError:
                return None
        elif not rest:
            port = default_port
        else:
            return None
    elif item.count(":") >= 2:
        # IPv6 literals without brackets: last colon separates port iff suffix is numeric
        colon = item.rfind(":")
        maybe_port = item[colon + 1 :]
        try:
            p = int(maybe_port)
        except ValueError:
            host, port = item, default_port
        else:
            host, port = item[:colon].strip(), p
    elif ":" in item:
        host, port_str = item.rsplit(":", 1)
        host = host.strip()
        try:
            port = int(port_str.strip())
        except ValueError:
            return None
    else:
        host, port = item.strip(), default_port

    if not host_port_is_well_formed_endpoint(host, port):
        return None
    return host, port


def split_manual_peer_list(raw: str, default_port: int) -> list[tuple[str, int]]:
    out: list[tuple[str, int]] = []
    for fragment in raw.split(","):
        ep = normalize_peer_manual_spec(fragment, default_port)
        if ep:
            out.append(ep)
    return out
