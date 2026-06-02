defmodule Exbitnode.Db.Schema do
  @moduledoc false

  @schema_version 1
  @node_version "0.1.0"

  def schema_version, do: @schema_version
  def node_version, do: @node_version

  def init_schema_sql do
    """
    CREATE TABLE IF NOT EXISTS meta (
      id INTEGER PRIMARY KEY,
      key TEXT NOT NULL UNIQUE,
      value TEXT NOT NULL
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
      direction TEXT,
      services INTEGER,
      peer_version INTEGER,
      user_agent TEXT,
      start_height INTEGER
    );

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
      coinbase INTEGER NOT NULL DEFAULT 0,
      UNIQUE(chain, txid, vout)
    );

    CREATE TABLE IF NOT EXISTS utxo_undo (
      id INTEGER PRIMARY KEY,
      chain TEXT NOT NULL,
      height INTEGER NOT NULL,
      txid TEXT NOT NULL,
      vout INTEGER NOT NULL,
      value_sats INTEGER NOT NULL,
      script_pubkey_hex TEXT NOT NULL,
      utxo_height INTEGER NOT NULL DEFAULT 0,
      coinbase INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS validated_tip (
      id INTEGER PRIMARY KEY,
      chain TEXT NOT NULL UNIQUE,
      height INTEGER NOT NULL DEFAULT -1,
      block_hash TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY,
      category TEXT NOT NULL,
      message TEXT NOT NULL,
      severity TEXT NOT NULL DEFAULT 'info',
      details_json TEXT,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS blockers (
      id INTEGER PRIMARY KEY,
      chain TEXT NOT NULL,
      height INTEGER NOT NULL,
      block_hash TEXT NOT NULL,
      txid TEXT,
      input_index INTEGER,
      spent_script_pubkey_hex TEXT,
      failure TEXT NOT NULL,
      missing_rule TEXT NOT NULL,
      python_fix TEXT,
      test_fixture TEXT,
      follower_notes TEXT,
      created_at TEXT NOT NULL
    );
    """
  end

  def utc_now_iso do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
