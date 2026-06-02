"""
Minimal asyncio HTTP scrape surface for Prometheus (stdlib only).

Serves GET /metrics with text exposition; other paths receive 404.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging

from pybitnode.config import Settings
from pybitnode.db.tracker import ProjectTracker
from pybitnode.metrics import prometheus_exposition_format

logger = logging.getLogger(__name__)

_CONTENT_TYPE_PROM = "text/plain; charset=utf-8; version=0.0.4"


async def _discard_request_headers(reader: asyncio.StreamReader) -> None:
    while True:
        line = await reader.readline()
        if not line:
            break
        if line in (b"\r\n", b"\n"):
            break


async def _write_http_response(
    writer: asyncio.StreamWriter,
    *,
    status: str,
    headers: dict[str, str],
    body: bytes,
) -> None:
    hdr = "".join(f"{k}: {v}\r\n" for k, v in headers.items())
    prelude = f"HTTP/1.1 {status}\r\n{hdr}\r\n"
    writer.write(prelude.encode("iso-8859-1") + body)
    await writer.drain()


async def serve_metrics_http_session(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    *,
    tracker: ProjectTracker,
    settings: Settings,
) -> None:
    try:
        first = await asyncio.wait_for(reader.readline(), timeout=60.0)
        if not first:
            return
        request_line = first.decode("latin-1", errors="replace").strip()
        parts = request_line.split()
        if len(parts) < 2:
            await _write_http_response(
                writer,
                status="400 Bad Request",
                headers={
                    "Content-Type": "text/plain; charset=utf-8",
                    "Content-Length": "11",
                    "Connection": "close",
                },
                body=b"Bad Request",
            )
            return
        method, path_full = parts[0].upper(), parts[1]
        path = path_full.split("?", 1)[0]

        await _discard_request_headers(reader)

        if method != "GET":
            await _write_http_response(
                writer,
                status="405 Method Not Allowed",
                headers={
                    "Content-Type": "text/plain; charset=utf-8",
                    "Content-Length": "18",
                    "Connection": "close",
                },
                body=b"Method Not Allowed",
            )
            return
        if path != "/metrics":
            await _write_http_response(
                writer,
                status="404 Not Found",
                headers={
                    "Content-Type": "text/plain; charset=utf-8",
                    "Content-Length": "9",
                    "Connection": "close",
                },
                body=b"Not Found",
            )
            return

        body = prometheus_exposition_format(tracker, chain=settings.chain).encode("utf-8")
        await _write_http_response(
            writer,
            status="200 OK",
            headers={
                "Content-Type": _CONTENT_TYPE_PROM,
                "Content-Length": str(len(body)),
                "Connection": "close",
            },
            body=body,
        )
    except asyncio.TimeoutError:
        logger.debug("Metrics HTTP idle client timeout")
    except (BrokenPipeError, ConnectionResetError, OSError) as exc:
        logger.debug("Metrics HTTP peer error: %s", exc)
    finally:
        writer.close()
        with contextlib.suppress(ConnectionResetError, BrokenPipeError, OSError):
            await writer.wait_closed()


async def serve_metrics_http_forever(*, tracker: ProjectTracker, settings: Settings) -> None:
    """Listen until cancelled; binds ``settings.metrics_http_bind`` / ``metrics_http_port``."""

    bind_host = settings.metrics_http_bind.strip() or "127.0.0.1"

    async def client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await serve_metrics_http_session(reader, writer, tracker=tracker, settings=settings)

    server = await asyncio.start_server(client, host=bind_host, port=settings.metrics_http_port)
    sockets = getattr(server, "sockets", None) or ()
    ports = sorted({sock.getsockname()[1] for sock in sockets if sock})
    tracker.log_event(
        "node",
        f"Metrics HTTP listening ({bind_host} ports={ports})",
        details={"ports": ports, "bind_host": bind_host, "configured_port": settings.metrics_http_port},
    )
    async with server:
        await server.serve_forever()
