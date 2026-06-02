from __future__ import annotations

import os
from dataclasses import dataclass


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    return int(raw)


@dataclass
class Settings:
    chain: str = "testnet4"
    data_dir: str = "./data"
    state_path: str = ""
    db_path: str = ""
    listen: bool = False
    p2p_port: int = 0
    peers: str = ""
    log_level: str = "info"
    protocol_version: int = 70016
    user_agent: str = "/pybitnode:0.1.0/"

    blocks_batch_size: int = 32
    blocks_max_per_run: int = 64
    blocks_target_height: int = 0
    # >0: race block requests across connected peers (see sync_blocks_batch). 0 = one peer at a time.
    parallel_block_downloads: int = 0
    rebuild_validated_chain: bool = False
    max_outbound_peers: int = 3
    ping_interval_seconds: float = 1200.0
    peer_stale_seconds: float = 5400.0
    # Minimum relay feerate in satoshis per virtual byte (Bitcoin-style policy).
    # 0 disables relay feerate checks (backward compatible scaffold default).
    min_relay_feerate_sat_vb: int = 0
    # Phase 5 lite: skip bootstrap targets whose aggregate ban_score exceeds this (see peer_addresses).
    peer_ban_score_threshold: int = 100
    # After this many seconds connected, apply a one-time decay to endpoint ban score.
    peer_ban_decay_uptime_seconds: float = 300.0
    peer_ban_decay_amount: int = 15
    # Skip outbound getaddr / addr exchange during bootstrap (faster sync if peer hangs up).
    skip_getaddr: bool = False
    # When True, never call networked header sync — mark headers current and validate/download blocks using DB headers only.
    sync_skip_headers: bool = False
    # pybitnode-sync: skip networked header refresh (manual / automation); still uses DB headers for block sync.
    no_header_refresh: bool = False
    # Defer txs with unknown prevouts into OrphanPool (accept_transaction + defer_orphans).
    enable_orphan_pool: bool = False
    # Mempool policy: max pooled transactions (0 = unlimited). Eviction removes oldest clusters first.
    mempool_max_count: int = 10_000
    # Drop pooled txs older than this many wall-clock seconds (0 = disabled).
    mempool_max_age_seconds: int = 86_400
    # Optional Prometheus-compatible scrape endpoint (TCP HTTP). Disabled when METRICS_HTTP_PORT is 0.
    metrics_http_bind: str = "127.0.0.1"
    metrics_http_port: int = 0
    # Opt-in per-block connect timing persisted as tracker events.
    sync_timing: bool = False
    # Phase A script verification parallelism: per-transaction input verification only.
    par_script_verify: bool = True
    par_script_threads: int = os.cpu_count() or 1
    par_script_min_inputs: int = 2
    par_script_executor: str = "thread"

    @classmethod
    def from_env(cls) -> Settings:
        par_script_threads = max(1, _env_int("PAR_SCRIPT_THREADS", os.cpu_count() or 1))
        par_script_min_inputs = max(1, _env_int("PAR_SCRIPT_MIN_INPUTS", 2))
        par_script_executor = os.environ.get("PAR_SCRIPT_EXECUTOR", "thread").strip().lower()
        if par_script_executor not in {"thread", "process"}:
            par_script_executor = "thread"
        return cls(
            chain=os.environ.get("CHAIN", "testnet4"),
            data_dir=os.environ.get("DATA_DIR", "./data"),
            state_path=os.environ.get("STATE_PATH", os.environ.get("DB_PATH", "")),
            listen=_env_bool("LISTEN", False),
            p2p_port=_env_int("P2P_PORT", 0),
            peers=os.environ.get("PEERS", ""),
            log_level=os.environ.get("LOG_LEVEL", "info"),
            protocol_version=_env_int("PROTOCOL_VERSION", 70016),
            user_agent=os.environ.get("USER_AGENT", "/pybitnode:0.1.0/"),
            blocks_batch_size=_env_int("BLOCKS_BATCH_SIZE", 32),
            blocks_max_per_run=_env_int("BLOCKS_MAX_PER_RUN", 64),
            blocks_target_height=_env_int("BLOCKS_TARGET_HEIGHT", 0),
            parallel_block_downloads=_env_int("PARALLEL_BLOCK_DOWNLOADS", 0),
            max_outbound_peers=_env_int("MAX_OUTBOUND_PEERS", 3),
            ping_interval_seconds=float(os.environ.get("PING_INTERVAL_SECONDS", "1200")),
            peer_stale_seconds=float(os.environ.get("PEER_STALE_SECONDS", "5400")),
            min_relay_feerate_sat_vb=_env_int("MIN_RELAY_FEERATE_SAT_VB", 0),
            peer_ban_score_threshold=_env_int("PEER_BAN_SCORE_THRESHOLD", 100),
            peer_ban_decay_uptime_seconds=float(os.environ.get("PEER_BAN_DECAY_UPTIME_SECONDS", "300")),
            peer_ban_decay_amount=_env_int("PEER_BAN_DECAY_AMOUNT", 15),
            skip_getaddr=_env_bool("SKIP_GETADDR", False),
            sync_skip_headers=_env_bool("SYNC_SKIP_HEADERS", False),
            no_header_refresh=_env_bool("NO_HEADER_REFRESH", False),
            enable_orphan_pool=_env_bool("ENABLE_ORPHAN_POOL", False),
            mempool_max_count=_env_int("MEMPOOL_MAX_COUNT", 10_000),
            mempool_max_age_seconds=_env_int("MEMPOOL_MAX_AGE_SECONDS", 86_400),
            metrics_http_bind=(os.environ.get("METRICS_HTTP_BIND", "127.0.0.1") or "127.0.0.1").strip(),
            metrics_http_port=_env_int("METRICS_HTTP_PORT", 0),
            sync_timing=_env_bool("SYNC_TIMING", False),
            par_script_verify=_env_bool("PAR_SCRIPT_VERIFY", True),
            par_script_threads=par_script_threads,
            par_script_min_inputs=par_script_min_inputs,
            par_script_executor=par_script_executor,
        )

    def resolved_state_path(self) -> str:
        if self.state_path:
            return self.state_path
        if self.db_path:
            return self.db_path
        return f"{self.data_dir.rstrip('/')}/chainstate-rocksdb"

    def resolved_db_path(self) -> str:
        """Compatibility alias for callers not yet renamed to state_path."""
        return self.resolved_state_path()

    def blocks_dir(self) -> str:
        return f"{self.data_dir.rstrip('/')}/blocks"
