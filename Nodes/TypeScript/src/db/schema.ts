export const SCHEMA_VERSION = 8;

export const DEFAULT_PHASES: readonly [string, string, string, string][] = [
  ["phase0", "Wire + handshake", "in_progress", "Message framing, version/verack, Docker scaffold"],
  ["phase1", "Header sync", "pending", "Block locator, header chain persistence"],
  ["phase2", "Block download", "pending", "Parallel getdata, raw block storage"],
  ["phase3", "Consensus validation", "pending", "PoW, merkle root, and script verification"],
  ["phase4", "Mempool + relay", "pending", "Tx admission and rebroadcast"],
  ["phase5", "Hardening", "pending", "Metrics, peer banning, optional BIP324"],
];

export function utcNowIso(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

export { seedWireCapabilities } from "../wire/capabilities.js";

/** DDL for the SQLite tracker — mirrors pybitnode/db/schema.py core tables. */
export const INIT_SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS meta (
  id INTEGER PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS project_phases (
  id INTEGER PRIMARY KEY,
  phase TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_state (
  id INTEGER PRIMARY KEY,
  chain TEXT NOT NULL UNIQUE,
  best_height INTEGER NOT NULL DEFAULT 0,
  best_hash TEXT NOT NULL DEFAULT '',
  header_count INTEGER NOT NULL DEFAULT 0,
  sync_status TEXT NOT NULL DEFAULT 'starting',
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS peers (
  id INTEGER PRIMARY KEY,
  host TEXT NOT NULL,
  port INTEGER NOT NULL,
  connected_at TEXT,
  disconnected_at TEXT,
  direction TEXT,
  services INTEGER,
  peer_version INTEGER,
  user_agent TEXT,
  start_height INTEGER,
  last_seen_at TEXT,
  ban_score INTEGER NOT NULL DEFAULT 0,
  status TEXT
);

CREATE INDEX IF NOT EXISTS idx_peers_host_port ON peers(host, port);

CREATE TABLE IF NOT EXISTS peer_addresses (
  id INTEGER PRIMARY KEY,
  host TEXT NOT NULL,
  port INTEGER NOT NULL,
  services INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  ban_score INTEGER NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_peer_addresses_host_port ON peer_addresses(host, port);

CREATE TABLE IF NOT EXISTS headers (
  id INTEGER PRIMARY KEY,
  chain TEXT NOT NULL,
  height INTEGER NOT NULL,
  block_hash TEXT NOT NULL,
  prev_hash TEXT NOT NULL,
  header_serialized_hex TEXT,
  UNIQUE(chain, height)
);

CREATE TABLE IF NOT EXISTS blocks (
  id INTEGER PRIMARY KEY,
  chain TEXT NOT NULL,
  height INTEGER NOT NULL,
  block_hash TEXT NOT NULL,
  file_number INTEGER NOT NULL,
  file_offset INTEGER NOT NULL,
  block_size INTEGER NOT NULL,
  UNIQUE(chain, height)
);

CREATE TABLE IF NOT EXISTS utxos (
  id INTEGER PRIMARY KEY,
  chain TEXT NOT NULL,
  txid TEXT NOT NULL,
  vout INTEGER NOT NULL,
  height INTEGER NOT NULL,
  value_sats INTEGER NOT NULL,
  script_pubkey_hex TEXT NOT NULL,
  UNIQUE(chain, txid, vout)
);

CREATE TABLE IF NOT EXISTS utxo_undo (
  id INTEGER PRIMARY KEY,
  chain TEXT NOT NULL,
  height INTEGER NOT NULL,
  txid TEXT NOT NULL,
  vout INTEGER NOT NULL,
  value_sats INTEGER NOT NULL,
  script_pubkey_hex TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS validated_tip (
  id INTEGER PRIMARY KEY,
  chain TEXT NOT NULL UNIQUE,
  height INTEGER NOT NULL DEFAULT -1,
  block_hash TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS wire_capabilities (
  id INTEGER PRIMARY KEY,
  capability_id TEXT NOT NULL UNIQUE,
  checkpoint TEXT NOT NULL,
  category TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  required INTEGER NOT NULL,
  implemented INTEGER NOT NULL DEFAULT 0,
  verified_by TEXT NOT NULL DEFAULT '',
  verified_at TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,
  message TEXT NOT NULL,
  level TEXT NOT NULL DEFAULT 'info',
  details_json TEXT,
  created_at TEXT NOT NULL
);
`;
