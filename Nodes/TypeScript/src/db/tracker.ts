import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

import type { ChainParams } from "../chain/params.js";
import { PYTHON_NODE_DEFAULT_PEER } from "../config/peers.js";
import type { UtxoUndoEntry } from "../consensus/connect.js";
import { BlockHeaderCodec } from "../messages/headers.js";
import type { BlockHeader } from "../types/index.js";
import type { SyncState, SyncStatus, VerifiedBy } from "../types/index.js";
import { hostPortIsWellFormedEndpoint } from "../endpointParse.js";
import {
  CAPABILITIES_BY_ID,
  checkpointStatus,
  fullNodeWireProgress,
  seedWireCapabilities as upsertWireCapabilities,
  type FullNodeWireProgress,
  type WireCheckpointStatus,
} from "../wire/capabilities.js";
import { DEFAULT_PHASES, INIT_SCHEMA_SQL, SCHEMA_VERSION, utcNowIso } from "./schema.js";

export interface TrackerSummary {
  chain: string;
  sync: Record<string, unknown>;
  header_count: number;
  block_count: number;
  validated_height: number;
  validated_hash: string | null;
  utxo_count: number;
  peer_count: number;
  connected_peers: number;
  phases: Record<string, unknown>[];
  wire: FullNodeWireProgress;
  checkpoints: Record<string, WireCheckpointStatus>;
  recent_events: Record<string, unknown>[];
}

export interface WireProgress {
  capabilities: Record<string, unknown>[];
  checkpoints: Record<string, WireCheckpointStatus>;
  summary: FullNodeWireProgress;
}

export class ProjectTracker {
  private readonly db: DatabaseSync;

  constructor(dbPath: string) {
    mkdirSync(dirname(dbPath), { recursive: true });
    this.db = new DatabaseSync(dbPath);
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec(INIT_SCHEMA_SQL);
    this.ensureWireCapabilitiesColumns();
    this.ensurePeerAddressesTable();
    this.ensureUtxoSchema();
    this.ensureMeta();
    this.ensurePhases();
    this.seedWireCapabilities();
  }

  close(): void {
    this.db.close();
  }

  withTransaction<T>(fn: () => T): T {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const result = fn();
      this.db.exec("COMMIT");
      return result;
    } catch (error) {
      try {
        this.db.exec("ROLLBACK");
      } catch {
        // ignore rollback failures
      }
      throw error;
    }
  }

  setMeta(key: string, value: string): void {
    this.db
      .prepare(
        `INSERT INTO meta(key, value) VALUES(?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
      )
      .run(key, value);
  }

  getMeta(key: string): string | undefined {
    const row = this.db.prepare(`SELECT value FROM meta WHERE key = ?`).get(key) as
      | { value: string }
      | undefined;
    return row?.value;
  }

  upsertSyncState(chain: string, patch: Partial<Omit<SyncState, "chain">> = {}): void {
    const now = utcNowIso();
    const existing = this.getSyncState(chain);
    const next: SyncState = {
      chain,
      bestHeight: patch.bestHeight ?? existing?.bestHeight ?? 0,
      bestHash: patch.bestHash ?? existing?.bestHash ?? "",
      headerCount: patch.headerCount ?? existing?.headerCount ?? 0,
      syncStatus: patch.syncStatus ?? existing?.syncStatus ?? "starting",
      updatedAt: now,
    };
    this.db
      .prepare(
        `INSERT INTO sync_state(chain, best_height, best_hash, header_count, sync_status, updated_at)
         VALUES(?, ?, ?, ?, ?, ?)
         ON CONFLICT(chain) DO UPDATE SET
           best_height = excluded.best_height,
           best_hash = excluded.best_hash,
           header_count = excluded.header_count,
           sync_status = excluded.sync_status,
           updated_at = excluded.updated_at`,
      )
      .run(
        next.chain,
        next.bestHeight,
        next.bestHash,
        next.headerCount,
        next.syncStatus,
        next.updatedAt,
      );
  }

  getSyncState(chain: string): SyncState | null {
    const row = this.db
      .prepare(
        `SELECT chain, best_height, best_hash, header_count, sync_status, updated_at
         FROM sync_state WHERE chain = ?`,
      )
      .get(chain) as
      | {
          chain: string;
          best_height: number;
          best_hash: string;
          header_count: number;
          sync_status: SyncStatus;
          updated_at: string;
        }
      | undefined;
    if (!row) return null;
    return {
      chain: row.chain,
      bestHeight: row.best_height,
      bestHash: row.best_hash,
      headerCount: row.header_count,
      syncStatus: row.sync_status,
      updatedAt: row.updated_at,
    };
  }

  getSyncStateRow(chain: string): Record<string, unknown> {
    const row = this.db.prepare(`SELECT * FROM sync_state WHERE chain = ?`).get(chain) as
      | Record<string, unknown>
      | undefined;
    return row ?? {};
  }

  updatePhase(phase: string, status: string, notes: string): void {
    const rows = this.db
      .prepare(`SELECT id FROM project_phases WHERE phase = ?`)
      .all(phase) as Array<{ id: number }>;
    if (rows.length === 0) {
      throw new Error(`Unknown phase ${JSON.stringify(phase)}`);
    }
    this.db
      .prepare(`UPDATE project_phases SET status = ?, notes = ?, updated_at = ? WHERE phase = ?`)
      .run(status, notes, utcNowIso(), phase);
  }

  listPhases(): Record<string, unknown>[] {
    return this.db
      .prepare(`SELECT * FROM project_phases ORDER BY id`)
      .all() as Record<string, unknown>[];
  }

  logEvent(source: string, message: string, level = "info", details?: unknown): void {
    this.db
      .prepare(
        `INSERT INTO events(source, message, level, details_json, created_at)
         VALUES(?, ?, ?, ?, ?)`,
      )
      .run(source, message, level, details ? JSON.stringify(details) : null, utcNowIso());
  }

  recentEvents(limit = 20): Record<string, unknown>[] {
    return this.db
      .prepare(
        `SELECT id, source AS category, level, message, details_json, created_at
         FROM events ORDER BY id DESC LIMIT ?`,
      )
      .all(limit) as Record<string, unknown>[];
  }

  getValidatedHeight(chain: string): number {
    const row = this.db
      .prepare(`SELECT height FROM validated_tip WHERE chain = ?`)
      .get(chain) as { height: number } | undefined;
    return row?.height ?? 0;
  }

  getValidatedHash(chain: string): string | null {
    const row = this.db
      .prepare(`SELECT block_hash FROM validated_tip WHERE chain = ?`)
      .get(chain) as { block_hash: string } | undefined;
    if (!row?.block_hash) return null;
    return row.block_hash;
  }

  setValidatedTip(chain: string, height: number, blockHashOrHeader: string | BlockHeader): void {
    const blockHash =
      typeof blockHashOrHeader === "string"
        ? blockHashOrHeader
        : BlockHeaderCodec.blockHashHex(blockHashOrHeader);
    this.db
      .prepare(
        `INSERT INTO validated_tip(chain, height, block_hash, updated_at)
         VALUES(?, ?, ?, ?)
         ON CONFLICT(chain) DO UPDATE SET
           height = excluded.height,
           block_hash = excluded.block_hash,
           updated_at = excluded.updated_at`,
      )
      .run(chain, height, blockHash, utcNowIso());
  }

  resetValidatedChain(chain: string, genesisHash: string): void {
    this.db.prepare(`DELETE FROM utxos WHERE chain = ?`).run(chain);
    this.db.prepare(`DELETE FROM utxo_undo WHERE chain = ?`).run(chain);
    this.setValidatedTip(chain, 0, genesisHash);
  }

  replaceUtxoUndo(chain: string, height: number, entries: UtxoUndoEntry[]): void {
    this.db.prepare(`DELETE FROM utxo_undo WHERE chain = ? AND height = ?`).run(chain, height);
    const payload = entries.map((entry) => ({
      txid: entry.txid,
      vout: entry.vout,
      height: entry.height,
      value: entry.value,
      script_pubkey: entry.scriptPubKey.toString("hex"),
      coinbase: entry.coinbase ? 1 : 0,
    }));
    this.db
      .prepare(
        `INSERT INTO utxo_undo(chain, height, txid, vout, value_sats, script_pubkey_hex, utxo_height, coinbase, entries_json)
         VALUES(?, ?, '', -1, 0, '', 0, 0, ?)`,
      )
      .run(chain, height, JSON.stringify(payload));
  }

  takeUtxoUndo(chain: string, height: number): UtxoUndoEntry[] {
    const row = this.db
      .prepare(
        `SELECT entries_json FROM utxo_undo WHERE chain = ? AND height = ? LIMIT 1`,
      )
      .get(chain, height) as { entries_json: string | null } | undefined;
    if (!row) {
      throw new Error(`No UTXO undo journal for ${chain} height ${height}`);
    }
    this.db.prepare(`DELETE FROM utxo_undo WHERE chain = ? AND height = ?`).run(chain, height);
    const raw = row.entries_json ?? "[]";
    const payload = JSON.parse(raw) as Array<{
      txid: string;
      vout: number;
      height: number;
      value: number;
      script_pubkey: string;
      coinbase: number | boolean;
    }>;
    return payload.map((entry) => ({
      txid: entry.txid,
      vout: entry.vout,
      height: entry.height,
      value: entry.value,
      scriptPubKey: Buffer.from(entry.script_pubkey, "hex"),
      coinbase: entry.coinbase === 1 || entry.coinbase === true,
    }));
  }

  deleteUtxosCreatedAtHeight(chain: string, height: number): void {
    this.db.prepare(`DELETE FROM utxos WHERE chain = ? AND height = ?`).run(chain, height);
  }

  addUtxo(
    chain: string,
    txid: Buffer,
    vout: number,
    options: {
      height: number;
      value: number;
      scriptPubKey: Buffer;
      coinbase: boolean;
    },
  ): void {
    this.db
      .prepare(
        `INSERT INTO utxos(
           chain, txid, vout, height, value_sats, script_pubkey_hex, coinbase
         ) VALUES(?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        chain,
        Buffer.from(txid).reverse().toString("hex"),
        vout,
        options.height,
        options.value,
        options.scriptPubKey.toString("hex"),
        options.coinbase ? 1 : 0,
      );
  }

  spendUtxo(chain: string, txid: Buffer, vout: number): void {
    const row = this.db
      .prepare(`SELECT id FROM utxos WHERE chain = ? AND txid = ? AND vout = ? LIMIT 1`)
      .get(chain, Buffer.from(txid).reverse().toString("hex"), vout) as { id: number } | undefined;
    if (!row) {
      throw new Error(`UTXO not found: ${Buffer.from(txid).reverse().toString("hex")}:${vout}`);
    }
    this.db.prepare(`DELETE FROM utxos WHERE id = ?`).run(row.id);
  }

  getUtxo(
    chain: string,
    txid: Buffer,
    vout: number,
  ): {
    txid: string;
    vout: number;
    height: number;
    value: number;
    scriptPubKey: Buffer;
    coinbase: boolean;
  } | null {
    const row = this.db
      .prepare(
        `SELECT txid, vout, height, value_sats, script_pubkey_hex, coinbase
         FROM utxos WHERE chain = ? AND txid = ? AND vout = ? LIMIT 1`,
      )
      .get(chain, Buffer.from(txid).reverse().toString("hex"), vout) as
      | {
          txid: string;
          vout: number;
          height: number;
          value_sats: number;
          script_pubkey_hex: string;
          coinbase: number;
        }
      | undefined;
    if (!row) return null;
    return {
      txid: row.txid,
      vout: row.vout,
      height: row.height,
      value: row.value_sats,
      scriptPubKey: Buffer.from(row.script_pubkey_hex, "hex"),
      coinbase: row.coinbase === 1,
    };
  }

  headerCount(_chain?: string): number {
    const row = this.db.prepare(`SELECT COUNT(*) AS count FROM headers`).get() as { count: number };
    return row.count;
  }

  blockCount(chain?: string): number {
    if (chain) {
      const row = this.db
        .prepare(`SELECT COUNT(*) AS count FROM blocks WHERE chain = ?`)
        .get(chain) as { count: number };
      return row.count;
    }
    const row = this.db.prepare(`SELECT COUNT(*) AS count FROM blocks`).get() as { count: number };
    return row.count;
  }

  hasBlock(chain: string, height: number): boolean {
    const row = this.db
      .prepare(`SELECT 1 AS ok FROM blocks WHERE chain = ? AND height = ? LIMIT 1`)
      .get(chain, height) as { ok: number } | undefined;
    return row !== undefined;
  }

  listMissingBlockHeights(chain: string, limit = 32): number[] {
    const rows = this.db
      .prepare(
        `SELECT h.height
         FROM headers h
         LEFT JOIN blocks b ON b.chain = h.chain AND b.height = h.height
         WHERE h.chain = ? AND h.height > 0 AND b.height IS NULL
         ORDER BY h.height
         LIMIT ?`,
      )
      .all(chain, limit) as Array<{ height: number }>;
    return rows.map((row) => row.height);
  }

  recordBlock(
    chain: string,
    height: number,
    blockHash: string,
    fileName: string,
    fileOffset: number,
    blockSize: number,
  ): void {
    const match = /^blk(\d+)\.dat$/.exec(fileName);
    const fileNumber = match ? Number.parseInt(match[1]!, 10) : 0;
    this.db
      .prepare(
        `INSERT OR IGNORE INTO blocks(
           chain, height, block_hash, file_number, file_offset, block_size
         ) VALUES(?, ?, ?, ?, ?, ?)`,
      )
      .run(chain, height, blockHash, fileNumber, fileOffset, blockSize);
  }

  getBlock(chain: string, height: number): Record<string, unknown> | null {
    const row = this.db
      .prepare(`SELECT * FROM blocks WHERE chain = ? AND height = ?`)
      .get(chain, height) as Record<string, unknown> | undefined;
    return row ?? null;
  }

  getStoredBlockForHashHex(chain: string, blockHashHex: string): Record<string, unknown> | null {
    const row = this.db
      .prepare(`SELECT * FROM blocks WHERE chain = ? AND block_hash = ?`)
      .get(chain, blockHashHex) as Record<string, unknown> | undefined;
    return row ?? null;
  }

  maxStoredBlockHeight(chain: string): number {
    const row = this.db
      .prepare(`SELECT MAX(height) AS height FROM blocks WHERE chain = ?`)
      .get(chain) as { height: number | null } | undefined;
    return row?.height ?? 0;
  }

  listStoredBlocks(chain: string): Array<{
    height: number;
    block_hash: string;
    file_number: number;
    file_offset: number;
    block_size: number;
  }> {
    return this.db
      .prepare(
        `SELECT height, block_hash, file_number, file_offset, block_size
         FROM blocks WHERE chain = ? ORDER BY height`,
      )
      .all(chain) as Array<{
      height: number;
      block_hash: string;
      file_number: number;
      file_offset: number;
      block_size: number;
    }>;
  }

  utxoCount(chain: string): number {
    const row = this.db
      .prepare(`SELECT COUNT(*) AS count FROM utxos WHERE chain = ?`)
      .get(chain) as { count: number };
    return row.count;
  }

  maxHeaderHeight(chain?: string): number {
    if (chain) {
      const row = this.db
        .prepare(`SELECT MAX(height) AS h FROM headers WHERE chain = ?`)
        .get(chain) as { h: number | null } | undefined;
      return row?.h ?? 0;
    }
    const row = this.db.prepare(`SELECT MAX(height) AS h FROM headers`).get() as
      | { h: number | null }
      | undefined;
    return row?.h ?? 0;
  }

  getHeaderHash(chain: string, height: number): string | null {
    const row = this.db
      .prepare(`SELECT block_hash FROM headers WHERE chain = ? AND height = ?`)
      .get(chain, height) as { block_hash: string } | undefined;
    return row?.block_hash ?? null;
  }

  lookupHeaderHeight(chain: string, blockHashHex: string): number | null {
    const row = this.db
      .prepare(`SELECT height FROM headers WHERE chain = ? AND block_hash = ?`)
      .get(chain, blockHashHex) as { height: number } | undefined;
    return row?.height ?? null;
  }

  getHeaderRow(
    chain: string,
    height: number,
  ): { block_hash: string; header_serialized_hex: string | null } | null {
    const row = this.db
      .prepare(`SELECT block_hash, header_serialized_hex FROM headers WHERE chain = ? AND height = ?`)
      .get(chain, height) as { block_hash: string; header_serialized_hex: string | null } | undefined;
    return row ?? null;
  }

  recordHeader(
    chain: string,
    row: {
      height: number;
      blockHash: string;
      prevHash: string;
      headerSerializedHex?: string;
    },
  ): void {
    this.db
      .prepare(
        `INSERT OR IGNORE INTO headers(chain, height, block_hash, prev_hash, header_serialized_hex)
         VALUES(?, ?, ?, ?, ?)`,
      )
      .run(
        chain,
        row.height,
        row.blockHash,
        row.prevHash,
        row.headerSerializedHex ?? null,
      );
  }

  backfillGenesisHeaderBlob(chain: string, headerSerializedHex: string): void {
    this.db
      .prepare(
        `UPDATE headers
         SET header_serialized_hex = ?
         WHERE chain = ? AND height = 0
           AND (header_serialized_hex IS NULL OR header_serialized_hex = '')`,
      )
      .run(headerSerializedHex, chain);
  }

  dbQuery<T extends Record<string, unknown>>(sql: string, params: Array<string | number> = []): T | null {
    const row = this.db.prepare(sql).get(...params) as T | undefined;
    return row ?? null;
  }

  peerCount(): number {
    const row = this.db.prepare(`SELECT COUNT(*) AS count FROM peers`).get() as { count: number };
    return row.count;
  }

  connectedPeerCount(): number {
    const row = this.db
      .prepare(`SELECT COUNT(*) AS count FROM peers WHERE status = 'connected'`)
      .get() as { count: number };
    return row.count;
  }

  recordPeerConnected(
    host: string,
    port: number,
    options: {
      direction?: string;
      services?: number;
      peerVersion?: number;
      userAgent?: string;
      startHeight?: number;
    } = {},
  ): number {
    const now = utcNowIso();
    this.db
      .prepare(
        `INSERT INTO peers(
           host, port, connected_at, disconnected_at, direction, services,
           peer_version, user_agent, start_height, last_seen_at, ban_score, status
         ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'connected')`,
      )
      .run(
        host,
        port,
        now,
        "",
        options.direction ?? "outbound",
        options.services ?? 0,
        options.peerVersion ?? 0,
        options.userAgent ?? "",
        options.startHeight ?? 0,
        now,
      );
    const row = this.db.prepare(`SELECT last_insert_rowid() AS id`).get() as { id: number };
    this.logEvent("p2p", `Connected to ${host}:${port}`, "info", {
      peer_id: row.id,
      user_agent: options.userAgent ?? "",
    });
    return row.id;
  }

  recordPeerDisconnected(peerId: number, status = "disconnected"): void {
    this.db
      .prepare(`UPDATE peers SET disconnected_at = ?, status = ? WHERE id = ?`)
      .run(utcNowIso(), status, peerId);
  }

  touchPeer(peerId: number): void {
    this.db
      .prepare(`UPDATE peers SET last_seen_at = ? WHERE id = ?`)
      .run(utcNowIso(), peerId);
  }

  incrementPeerBanScore(host: string, port: number, delta: number): number {
    if (delta === 0) {
      return this.getPeerEndpointBanScore(host, port);
    }
    const now = utcNowIso();
    const endpoint = this.db
      .prepare(`SELECT id, ban_score FROM peer_addresses WHERE host = ? AND port = ? LIMIT 1`)
      .get(host, port) as { id: number; ban_score: number } | undefined;
    let endpointScore: number;
    if (endpoint) {
      endpointScore = endpoint.ban_score + delta;
      this.db
        .prepare(`UPDATE peer_addresses SET ban_score = ?, last_seen_at = ? WHERE id = ?`)
        .run(endpointScore, now, endpoint.id);
    } else {
      endpointScore = delta;
      this.db
        .prepare(
          `INSERT INTO peer_addresses(host, port, services, source, last_seen_at, ban_score)
           VALUES(?, ?, 0, 'ban', ?, ?)`,
        )
        .run(host, port, now, endpointScore);
    }

    const existing = this.db
      .prepare(`SELECT id, ban_score FROM peers WHERE host = ? AND port = ? ORDER BY id DESC LIMIT 1`)
      .get(host, port) as { id: number; ban_score: number } | undefined;
    if (existing) {
      const next = existing.ban_score + delta;
      this.db
        .prepare(`UPDATE peers SET ban_score = ?, last_seen_at = ? WHERE id = ?`)
        .run(next, now, existing.id);
      return next;
    }
    this.db
      .prepare(
        `INSERT INTO peers(host, port, connected_at, disconnected_at, ban_score, status, last_seen_at)
         VALUES(?, ?, '', '', ?, 'banned_candidate', ?)`,
      )
      .run(host, port, delta, now);
    return delta;
  }

  recordPeerAddress(
    host: string,
    port: number,
    options: { services?: number | bigint; source?: string } = {},
  ): void {
    if (host === PYTHON_NODE_DEFAULT_PEER) {
      return;
    }
    let services = options.services ?? 0;
    if (typeof services === "bigint") {
      services = Number(services);
    }
    if (services >= 2 ** 63) {
      services -= 2 ** 64;
    }
    const source = options.source ?? "addr";
    if (!hostPortIsWellFormedEndpoint(host, port)) {
      this.logEvent("p2p", "Skipped malformed peer address", "warning", { host, port, source });
      return;
    }
    const now = utcNowIso();
    const existing = this.db
      .prepare(`SELECT id, ban_score FROM peer_addresses WHERE host = ? AND port = ? LIMIT 1`)
      .get(host, port) as { id: number; ban_score: number } | undefined;
    if (existing) {
      this.db
        .prepare(
          `UPDATE peer_addresses
           SET services = ?, source = ?, last_seen_at = ?
           WHERE id = ?`,
        )
        .run(services, source, now, existing.id);
      return;
    }
    this.db
      .prepare(
        `INSERT INTO peer_addresses(host, port, services, source, last_seen_at, ban_score)
         VALUES(?, ?, ?, ?, ?, 0)`,
      )
      .run(host, port, services, source, now);
  }

  getPeerEndpointBanScore(host: string, port: number): number {
    const row = this.db
      .prepare(`SELECT ban_score FROM peer_addresses WHERE host = ? AND port = ? LIMIT 1`)
      .get(host, port) as { ban_score: number } | undefined;
    return row?.ban_score ?? 0;
  }

  listPeerAddressEndpoints(limit = 32): Array<[string, number]> {
    const rows = this.db
      .prepare(
        `SELECT host, port FROM peer_addresses ORDER BY last_seen_at DESC LIMIT ?`,
      )
      .all(limit * 8) as Array<{ host: string; port: number }>;
    const out: Array<[string, number]> = [];
    for (const row of rows) {
      if (!hostPortIsWellFormedEndpoint(row.host, row.port)) {
        continue;
      }
      if (row.host === PYTHON_NODE_DEFAULT_PEER) {
        continue;
      }
      out.push([row.host, row.port]);
      if (out.length >= limit) {
        break;
      }
    }
    return out;
  }

  markWireCapability(
    capabilityId: string,
    implemented: boolean,
    verifiedBy: VerifiedBy = "live",
    notes = "",
  ): void {
    if (!(capabilityId in CAPABILITIES_BY_ID)) {
      throw new Error(`Unknown wire capability ${JSON.stringify(capabilityId)}`);
    }
    const now = utcNowIso();
    this.db
      .prepare(
        `UPDATE wire_capabilities
         SET implemented = ?, verified_by = ?, verified_at = ?, notes = ?
         WHERE capability_id = ?`,
      )
      .run(
        implemented ? 1 : 0,
        implemented ? verifiedBy : "",
        implemented ? now : "",
        notes,
        capabilityId,
      );
  }

  wireCapabilityMap(): Record<string, number> {
    const rows = this.db
      .prepare(`SELECT capability_id, implemented FROM wire_capabilities`)
      .all() as Array<{ capability_id: string; implemented: number }>;
    const map: Record<string, number> = {};
    for (const row of rows) {
      map[row.capability_id] = row.implemented;
    }
    return map;
  }

  listWireCapabilities(checkpoint?: string): Record<string, unknown>[] {
    if (checkpoint) {
      return this.db
        .prepare(
          `SELECT * FROM wire_capabilities WHERE checkpoint = ? ORDER BY capability_id`,
        )
        .all(checkpoint) as Record<string, unknown>[];
    }
    return this.db
      .prepare(`SELECT * FROM wire_capabilities ORDER BY checkpoint, capability_id`)
      .all() as Record<string, unknown>[];
  }

  wireProgress(): WireProgress {
    const capMap = this.wireCapabilityMap();
    return {
      capabilities: this.listWireCapabilities(),
      checkpoints: checkpointStatus(capMap),
      summary: fullNodeWireProgress(capMap),
    };
  }

  checkpointStatus(): Record<string, WireCheckpointStatus> {
    return checkpointStatus(this.wireCapabilityMap());
  }

  fullNodeWireProgress(): FullNodeWireProgress {
    return fullNodeWireProgress(this.wireCapabilityMap());
  }

  summary(chain: string): TrackerSummary {
    const wire = this.wireProgress();
    return {
      chain,
      sync: this.getSyncStateRow(chain),
      header_count: this.headerCount(),
      block_count: this.blockCount(),
      validated_height: this.getValidatedHeight(chain),
      validated_hash: this.getValidatedHash(chain),
      utxo_count: this.utxoCount(chain),
      peer_count: this.peerCount(),
      connected_peers: this.connectedPeerCount(),
      phases: this.listPhases(),
      wire: wire.summary,
      checkpoints: wire.checkpoints,
      recent_events: this.recentEvents(5),
    };
  }

  ensureGenesis(chain: ChainParams): void {
    // Delegated to sync/headers.ensureGenesis for validation and capability tracking.
    const existing = this.getHeaderHash(chain.name, 0);
    if (existing) {
      if (this.getValidatedHash(chain.name) === null) {
        this.setValidatedTip(chain.name, 0, chain.genesisHash);
      }
      return;
    }
    this.recordHeader(chain.name, {
      height: 0,
      blockHash: chain.genesisHash,
      prevHash: Buffer.alloc(32).toString("hex"),
    });
    this.setValidatedTip(chain.name, 0, chain.genesisHash);
    this.upsertSyncState(chain.name, {
      bestHeight: 0,
      bestHash: chain.genesisHash,
      headerCount: 1,
      syncStatus: "starting",
    });
  }

  private ensureUtxoSchema(): void {
    const utxoColumns = this.db.prepare(`PRAGMA table_info(utxos)`).all() as Array<{ name: string }>;
    const utxoNames = new Set(utxoColumns.map((row) => row.name));
    if (!utxoNames.has("coinbase")) {
      this.db.exec(`ALTER TABLE utxos ADD COLUMN coinbase INTEGER NOT NULL DEFAULT 0`);
    }

    const undoColumns = this.db.prepare(`PRAGMA table_info(utxo_undo)`).all() as Array<{ name: string }>;
    const undoNames = new Set(undoColumns.map((row) => row.name));
    if (!undoNames.has("utxo_height")) {
      this.db.exec(`ALTER TABLE utxo_undo ADD COLUMN utxo_height INTEGER NOT NULL DEFAULT 0`);
    }
    if (!undoNames.has("coinbase")) {
      this.db.exec(`ALTER TABLE utxo_undo ADD COLUMN coinbase INTEGER NOT NULL DEFAULT 0`);
    }
    if (!undoNames.has("entries_json")) {
      this.db.exec(`ALTER TABLE utxo_undo ADD COLUMN entries_json TEXT`);
    }
    this.db.exec(
      `CREATE UNIQUE INDEX IF NOT EXISTS idx_utxo_undo_chain_height ON utxo_undo(chain, height)`,
    );
  }

  private ensureMeta(): void {
    this.setMeta("schema_version", String(SCHEMA_VERSION));
  }

  private ensurePhases(): void {
    const insert = this.db.prepare(
      `INSERT OR IGNORE INTO project_phases(phase, title, status, notes, updated_at)
       VALUES(?, ?, ?, ?, ?)`,
    );
    const now = utcNowIso();
    for (const [phase, title, status, notes] of DEFAULT_PHASES) {
      insert.run(phase, title, status, notes, now);
    }
  }

  private ensurePeerAddressesTable(): void {
    this.db.exec(`
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
    `);
    const rows = this.db.prepare(`PRAGMA table_info(peer_addresses)`).all() as Array<{ name: string }>;
    const columns = new Set(rows.map((row) => row.name));
    if (!columns.has("ban_score")) {
      this.db.exec(`ALTER TABLE peer_addresses ADD COLUMN ban_score INTEGER NOT NULL DEFAULT 0`);
    }
  }

  private ensureWireCapabilitiesColumns(): void {
    const rows = this.db.prepare(`PRAGMA table_info(wire_capabilities)`).all() as Array<{
      name: string;
    }>;
    const columns = new Set(rows.map((row) => row.name));
    if (!columns.has("verified_at")) {
      this.db.exec(`ALTER TABLE wire_capabilities ADD COLUMN verified_at TEXT NOT NULL DEFAULT ''`);
    }
    if (columns.has("updated_at")) {
      // Legacy column from earlier schema; harmless if present.
    }
    if (!columns.has("verified_by")) {
      this.db.exec(`ALTER TABLE wire_capabilities ADD COLUMN verified_by TEXT NOT NULL DEFAULT ''`);
    }
  }

  seedWireCapabilities(): void {
    upsertWireCapabilities(this.db);
  }
}
