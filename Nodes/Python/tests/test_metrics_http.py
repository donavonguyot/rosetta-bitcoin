from __future__ import annotations

import asyncio
import re

import pytest

from pybitnode.config import Settings
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.metrics import (
    META_BLOCKS_VALIDATED_TOTAL,
    META_TXS_RELAYED_TOTAL,
    prometheus_exposition_format,
)
from pybitnode.metrics_http import serve_metrics_http_session


def test_prometheus_exposition_shape_and_counters(tmp_path):
    db = tmp_path / "m-chainstate"
    settings = Settings(chain="testnet4", db_path=str(db), data_dir=str(tmp_path / "dd"))
    tracker = ProjectTracker(settings.resolved_db_path())
    tracker.set_meta(META_BLOCKS_VALIDATED_TOTAL, "101")
    tracker.set_meta(META_TXS_RELAYED_TOTAL, "7")

    text = prometheus_exposition_format(tracker, chain="testnet4")
    tracker.close()

    nonempty_lines = [ln for ln in text.splitlines() if ln.strip()]
    joined = "\n".join(nonempty_lines)
    for prefix in (
        "# HELP blocks_validated_total",
        "# TYPE blocks_validated_total counter",
        "# HELP txs_relayed_total",
        "# TYPE txs_relayed_total counter",
    ):
        assert prefix in joined
    assert re.search(r'^blocks_validated_total\{chain="testnet4"\}\s+101\s*$', joined, re.MULTILINE)
    assert re.search(r'^txs_relayed_total\{chain="testnet4"\}\s+7\s*$', joined, re.MULTILINE)


@pytest.mark.asyncio
async def test_metrics_http_get_metrics_prom_text(tmp_path):
    db = tmp_path / "mh-chainstate"
    settings = Settings(chain="testnet4", db_path=str(db), data_dir=str(tmp_path / "dd"))
    tracker = ProjectTracker(settings.resolved_db_path())
    tracker.set_meta(META_BLOCKS_VALIDATED_TOTAL, "42")
    tracker.set_meta(META_TXS_RELAYED_TOTAL, "9")

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await serve_metrics_http_session(reader, writer, tracker=tracker, settings=settings)

    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    sock = server.sockets[0]
    host, port = sock.getsockname()[:2]
    async with server:
        reader, writer = await asyncio.open_connection(host, port)
        writer.write(b"GET /metrics HTTP/1.1\r\nHost: test\r\n\r\n")
        await writer.drain()
        raw = await asyncio.wait_for(reader.read(16_384), timeout=5.0)
        writer.close()
        await writer.wait_closed()

    headers, sep, body = raw.partition(b"\r\n\r\n")
    assert headers.startswith(b"HTTP/1.1 200 "), headers[:120]
    assert b"404" not in headers[:20]
    assert b"Content-Type:" in headers
    assert b"text/plain" in headers.lower()

    decoded = body.decode("utf-8")
    assert "TYPE txs_relayed_total counter" in decoded
    assert re.search(r'blocks_validated_total\{chain="testnet4"\}\s+42', decoded)

    tracker.close()


@pytest.mark.asyncio
async def test_metrics_http_404_unknown_path(tmp_path):
    db = tmp_path / "nf-chainstate"
    settings = Settings(chain="testnet4", db_path=str(db), data_dir=str(tmp_path / "dd"))
    tracker = ProjectTracker(settings.resolved_db_path())

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await serve_metrics_http_session(reader, writer, tracker=tracker, settings=settings)

    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    sock = server.sockets[0]
    host, port = sock.getsockname()[:2]
    async with server:
        reader, writer = await asyncio.open_connection(host, port)
        writer.write(b"GET /not-metrics HTTP/1.1\r\nHost: x\r\n\r\n")
        await writer.drain()
        raw = await asyncio.wait_for(reader.read(8192), timeout=5.0)
        writer.close()
        await writer.wait_closed()

    assert raw.startswith(b"HTTP/1.1 404 "), raw[:120]
    tracker.close()
