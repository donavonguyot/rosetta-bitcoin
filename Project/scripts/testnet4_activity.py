#!/usr/bin/env python3
"""One reference.activity.v1 sample of recent testnet4 block and pool activity.

Reads Reference RPC credentials from Nodes/Reference/bitcoin.conf. Writes
Nodes/Shared/conformance/results/testnet4_activity_<date>.json.
"""

from __future__ import annotations

import json
import statistics
import time
import urllib.request
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONF = ROOT / "Nodes/Reference/bitcoin.conf"
RESULTS = ROOT / "Nodes/Shared/conformance/results"
SAMPLE = 2016
RPC_URL = "http://127.0.0.1:48332/"


def load_rpc() -> tuple[str, str]:
    user = password = None
    for line in CONF.read_text().splitlines():
        if line.startswith("rpcuser="):
            user = line.split("=", 1)[1]
        elif line.startswith("rpcpassword="):
            password = line.split("=", 1)[1]
    if not user or not password:
        raise SystemExit("Reference RPC credentials are missing from Nodes/Reference/bitcoin.conf")
    return user, password


class Rpc:
    def __init__(self, user: str, password: str):
        token = __import__("base64").b64encode(f"{user}:{password}".encode()).decode()
        self.auth = f"Basic {token}"

    def call(self, method: str, params: list | None = None):
        return self.batch([(method, params or [])])[0]

    def batch(self, calls: list[tuple[str, list]]) -> list:
        body = json.dumps([
            {"jsonrpc": "1.0", "id": index, "method": method, "params": params}
            for index, (method, params) in enumerate(calls)
        ]).encode()
        request = urllib.request.Request(
            RPC_URL, data=body, headers={"content-type": "text/plain", "Authorization": self.auth})
        with urllib.request.urlopen(request, timeout=180) as response:
            payload = json.load(response)
        if isinstance(payload, dict):
            raise RuntimeError(payload.get("error") or payload)
        payload.sort(key=lambda row: row["id"])
        out = []
        for row in payload:
            if row.get("error"):
                raise RuntimeError(row["error"])
            out.append(row["result"])
        return out


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(len(ordered) * fraction + 0.999999) - 1))
    return ordered[index]


def bursts(rows: list[dict], median_txs: float) -> list[dict]:
    cutoff = median_txs * 3
    found: list[dict] = []
    start = None
    for offset, row in enumerate(rows):
        hot = row["txs"] > cutoff
        if hot and start is None:
            start = offset
        elif not hot and start is not None:
            if offset - start >= 5:
                found.append({"start_height": rows[start]["height"], "length": offset - start})
            start = None
    if start is not None and len(rows) - start >= 5:
        found.append({"start_height": rows[start]["height"], "length": len(rows) - start})
    return found


def choose_thresholds(pool_size: int, chain_tx_per_s: float, burst_rows: list[dict]) -> dict:
    open_pool = min(500, max(200, int(pool_size)))
    longest = max((row["length"] for row in burst_rows), default=0)
    open_rate = 1.0
    pool_clause = (
        f"the live pool is {pool_size} tx and the longest 3x-median burst is {longest} blocks, "
        f"so open-pool is {open_pool} inside 200-500"
    )
    if chain_tx_per_s >= 5:
        open_rate = round(chain_tx_per_s, 1)
        rate_clause = f"chain arrival is {chain_tx_per_s:.2f} tx/s, so open-rate follows that scale at {open_rate}"
    elif chain_tx_per_s < 0.2:
        rate_clause = f"chain arrival is {chain_tx_per_s:.2f} tx/s, below a busy window, so open-rate stays 1.0 tx/s"
    else:
        rate_clause = f"chain arrival is {chain_tx_per_s:.2f} tx/s, near 1 tx/s, so open-rate stays 1.0"
    return {"open_pool": open_pool, "open_rate": open_rate, "reason": f"{pool_clause}; {rate_clause}."}


def main() -> None:
    rpc = Rpc(*load_rpc())
    info = rpc.call("getblockchaininfo")
    tip = int(info["blocks"])
    start = tip - SAMPLE + 1
    heights = list(range(start, tip + 1))
    rows = []
    chunk = 64
    for offset in range(0, len(heights), chunk):
        part = heights[offset:offset + chunk]
        hashes = rpc.batch([("getblockhash", [height]) for height in part])
        stats = rpc.batch([
            ("getblockstats", [block_hash, ["height", "txs", "total_size", "time"]])
            for block_hash in hashes
        ])
        rows.extend(stats)
        print(f"sampled {len(rows)}/{SAMPLE}", flush=True)
    tx_counts = [int(row["txs"]) for row in rows]
    median_txs = float(statistics.median(tx_counts))
    chain = rpc.call("getchaintxstats", [SAMPLE])
    pool = rpc.call("getmempoolinfo")
    interval = float(chain.get("window_interval") or 0)
    window_tx = int(chain.get("window_tx_count") or 0)
    chain_tx_per_s = float(chain["txrate"]) if chain.get("txrate") is not None else (
        (window_tx / interval) if interval else 0.0)
    burst_rows = bursts(rows, median_txs)
    document = {
        "schema": "reference.activity.v1",
        "chain": "testnet4",
        "core_blocks": tip,
        "core_headers": info.get("headers"),
        "initialblockdownload": bool(info.get("initialblockdownload")),
        "sample_blocks": SAMPLE,
        "sample_start_height": start,
        "sampled_unix_ms": int(time.time() * 1000),
        "tx_per_block": {"median": median_txs, "p95": percentile([float(v) for v in tx_counts], 0.95)},
        "total_size": {
            "median": float(statistics.median([int(row["total_size"]) for row in rows])),
            "p95": percentile([float(row["total_size"]) for row in rows], 0.95),
        },
        "bursts": burst_rows,
        "chaintxstats": {
            "window_block_count": chain.get("window_block_count"),
            "window_tx_count": chain.get("window_tx_count", chain.get("txcount")),
            "window_interval": chain.get("window_interval"),
            "txrate": chain.get("txrate"),
            "tx_per_s": chain_tx_per_s,
        },
        "mempool": {"size": int(pool.get("size") or 0), "bytes": int(pool.get("bytes") or 0)},
        "watcher_thresholds": choose_thresholds(int(pool.get("size") or 0), chain_tx_per_s, burst_rows),
    }
    RESULTS.mkdir(parents=True, exist_ok=True)
    path = RESULTS / f"testnet4_activity_{date.today().isoformat()}.json"
    path.write_text(json.dumps(document, indent=2) + "\n")
    print(path)


if __name__ == "__main__":
    main()
