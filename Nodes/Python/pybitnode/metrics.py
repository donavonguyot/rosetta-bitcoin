"""
Lightweight persisted metrics via SQLite meta keys (stdlib only).

Counters survive process restarts and are readable from offline tools like ``healthcheck``.
"""

from __future__ import annotations

from pybitnode.chainstate.tracker import ProjectTracker

META_BLOCKS_VALIDATED_TOTAL = "metric_blocks_validated_total"
META_TXS_RELAYED_TOTAL = "metric_txs_relayed_total"
META_LAST_ERROR = "last_error"


def _read_int(meta_value: str | None) -> int:
    if not meta_value:
        return 0
    try:
        return int(meta_value)
    except ValueError:
        return 0


def incr_meta_counter(tracker: ProjectTracker, key: str, delta: int = 1) -> int:
    """Add delta to a numeric meta key; returns the new value."""
    if delta == 0:
        return _read_int(tracker.get_meta(key))
    prev = _read_int(tracker.get_meta(key))
    total = prev + delta
    tracker.set_meta(key, str(total))
    return total


def snapshot_counters(tracker: ProjectTracker) -> dict[str, int]:
    """Read counter values for dashboards / health JSON (defaults to 0 if unset)."""
    return {
        "blocks_validated_total": _read_int(tracker.get_meta(META_BLOCKS_VALIDATED_TOTAL)),
        "txs_relayed_total": _read_int(tracker.get_meta(META_TXS_RELAYED_TOTAL)),
    }


def _escape_prometheus_label_value(raw: str) -> str:
    """Escape ``value`` for use inside Prometheus label double-quotes (text exposition)."""
    out: list[str] = []
    for ch in raw:
        if ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == '"':
            out.append('\\"')
        else:
            out.append(ch)
    return "".join(out)


def prometheus_exposition_format(tracker: ProjectTracker, *, chain: str) -> str:
    """
    Prometheus text exposition lines from SQLite-backed counters.

    Names match the numeric keys under ``metrics`` in ``docker_health_document``;
    samples carry the chosen ``chain`` label.
    """
    counters = snapshot_counters(tracker)
    chain_esc = _escape_prometheus_label_value(chain)
    lines = [
        "# HELP blocks_validated_total Blocks validated and connected.",
        "# TYPE blocks_validated_total counter",
        f'blocks_validated_total{{chain="{chain_esc}"}} {counters["blocks_validated_total"]}',
        "",
        "# HELP txs_relayed_total Transactions relayed toward peers.",
        "# TYPE txs_relayed_total counter",
        f'txs_relayed_total{{chain="{chain_esc}"}} {counters["txs_relayed_total"]}',
        "",
    ]
    return "\n".join(lines)


def record_last_error(tracker: ProjectTracker, message: str) -> None:
    tracker.set_meta(META_LAST_ERROR, message[:4000])


def clear_last_error(tracker: ProjectTracker) -> None:
    tracker.set_meta(META_LAST_ERROR, "")
