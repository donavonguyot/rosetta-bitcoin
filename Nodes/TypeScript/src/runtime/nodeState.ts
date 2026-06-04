import { BlockHeaderCodec } from "../messages/headers.js";
import type { BlockHeader } from "../types/index.js";
import type { ChainParams } from "../chain/params.js";
import { ChainstateSession } from "../chainstate/chainstateSession.js";
import type { ChainstateBlockIndexRecord, ChainstateSyncState } from "../chainstate/chainstate.js";
import type { UtxoUndoEntry } from "../consensus/connect.js";
import {
  checkpointStatus,
  fullNodeWireProgress,
  seedCapabilityRecords,
  type FullNodeWireProgress,
  type WireCheckpointStatus,
} from "../wire/capabilities.js";
import type { Settings } from "../config/settings.js";
import { PYTHON_NODE_DEFAULT_PEER, PYTHON_NODE_DEFAULT_PEER_PORT } from "../config/peers.js";

interface HeaderRow {
  block_hash: string;
  prev_hash: string;
  header_serialized_hex: string | null;
}

interface BlockRow {
  height: number;
  block_hash: string;
  file_number: number;
  file_offset: number;
  block_size: number;
}

interface PeerRow {
  id: number;
  host: string;
  port: number;
  status: string;
  last_seen_at: string;
}

interface PeerAddressRow {
  host: string;
  port: number;
  services: number;
  source: string;
  last_seen_at: string;
  ban_score: number;
}

function utcNowIso(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function toDisplayHash(hashInternal: Buffer): string {
  return Buffer.from(hashInternal).reverse().toString("hex");
}

function blockFileName(fileNumber: number): string {
  return `blk${String(fileNumber).padStart(5, "0")}.dat`;
}

function readInt(raw: string | undefined): number {
  if (!raw) return 0;
  const parsed = Number.parseInt(raw, 10);
  return Number.isNaN(parsed) ? 0 : parsed;
}

export interface NativeNodeStateOptions {
  session?: ChainstateSession;
  chain?: ChainParams;
}

export class NativeNodeState {
  readonly session: ChainstateSession | null;
  private readonly chain: ChainParams | null;
  private readonly headers = new Map<number, HeaderRow>();
  private readonly blocks = new Map<number, BlockRow>();
  private readonly utxos = new Map<string, {
    txid: string;
    vout: number;
    height: number;
    value: number;
    scriptPubKey: Buffer;
    coinbase: boolean;
  }>();
  private readonly undo = new Map<number, UtxoUndoEntry[]>();
  private readonly meta = new Map<string, string>();
  private readonly events: Record<string, unknown>[] = [];
  private readonly peerRows = new Map<number, PeerRow>();
  private readonly peerAddresses = new Map<string, PeerAddressRow>();
  private readonly wire = new Map<string, { value: number; record: Record<string, unknown> }>();
  private pending: Promise<unknown>[] = [];
  private nextPeerId = 1;
  private syncStates = new Map<string, ChainstateSyncState & { updatedAt: string }>();
  private validatedHeight = 0;
  private validatedHash: string | null = null;

  constructor(_label = "memory", options: NativeNodeStateOptions = {}) {
    this.session = options.session ?? null;
    this.chain = options.chain ?? null;
    for (const record of seedCapabilityRecords()) {
      this.wire.set(record.id, { value: record.implemented ? 1 : 0, record: { ...record } });
    }
  }

  static async open(settings: Settings, chain: ChainParams, options: { acquireLock?: boolean } = {}): Promise<NativeNodeState> {
    const session = await ChainstateSession.openNative(settings.dataDir, chain, {
      acquireLock: options.acquireLock ?? false,
    });
    const state = new NativeNodeState(settings.dataDir, { session, chain });
    await state.loadFromStore(chain);
    return state;
  }

  private async loadFromStore(chain: ChainParams): Promise<void> {
    if (this.session === null) return;
    const store = this.session.store;
    const syncState = await store.getSyncState(chain.name);
    if (syncState !== null) {
      this.syncStates.set(chain.name, { ...syncState, updatedAt: store.metadata.updatedAt });
      for (let height = 0; height <= syncState.bestHeight; height += 1) {
        const blockHash = await store.getHeaderHash(chain.name, height);
        if (blockHash === null) continue;
        this.headers.set(height, {
          block_hash: blockHash,
          prev_hash: height === 0 ? Buffer.alloc(32).toString("hex") : this.headers.get(height - 1)?.block_hash ?? "",
          header_serialized_hex: await store.getHeaderSerializedHex(chain.name, height),
        });
      }
    }
    this.validatedHeight = await store.getValidatedHeight(chain.name);
    this.validatedHash = await store.getValidatedHash(chain.name);
    const maxStored = await store.maxStoredBlockHeight(chain.name);
    for (let height = 0; height <= maxStored; height += 1) {
      const record = await store.getBlock(chain.name, height);
      if (record === null) continue;
      this.blocks.set(height, this.blockRow(record));
    }
    await this.loadJsonMap("runtime_meta", this.meta);
    await this.loadPeerAddresses();
    await this.loadWire();
  }

  private async loadJsonMap(key: string, target: Map<string, string>): Promise<void> {
    if (this.session === null) return;
    const raw = await this.session.store.metadataValue(key);
    if (!raw) return;
    const parsed = JSON.parse(raw) as Record<string, string>;
    for (const [mapKey, value] of Object.entries(parsed)) {
      target.set(mapKey, String(value));
    }
  }

  private async loadPeerAddresses(): Promise<void> {
    if (this.session === null) return;
    const raw = await this.session.store.metadataValue("runtime_peer_addresses");
    if (!raw) return;
    const parsed = JSON.parse(raw) as PeerAddressRow[];
    for (const row of parsed) {
      this.peerAddresses.set(`${row.host}:${row.port}`, row);
    }
  }

  private async loadWire(): Promise<void> {
    if (this.session === null) return;
    const raw = await this.session.store.metadataValue("runtime_wire");
    if (!raw) return;
    const parsed = JSON.parse(raw) as Record<string, number>;
    for (const [id, value] of Object.entries(parsed)) {
      const existing = this.wire.get(id);
      if (existing) existing.value = value;
    }
  }

  private queue(promise: Promise<unknown>): void {
    this.pending.push(promise.catch((error) => {
      const message = error instanceof Error ? error.message : String(error);
      this.meta.set("last_error", message);
    }));
  }

  async flush(): Promise<void> {
    const pending = this.pending;
    this.pending = [];
    await Promise.all(pending);
  }

  async close(): Promise<void> {
    await this.flush();
    await this.session?.close();
  }

  withTransaction<T>(fn: () => T): T {
    const snapshot = {
      utxos: new Map(this.utxos),
      undo: new Map(this.undo),
      meta: new Map(this.meta),
      headers: new Map(this.headers),
      blocks: new Map(this.blocks),
      validatedHeight: this.validatedHeight,
      validatedHash: this.validatedHash,
    };
    try {
      return fn();
    } catch (error) {
      this.utxos.clear();
      for (const [key, value] of snapshot.utxos) this.utxos.set(key, value);
      this.undo.clear();
      for (const [key, value] of snapshot.undo) this.undo.set(key, value);
      this.meta.clear();
      for (const [key, value] of snapshot.meta) this.meta.set(key, value);
      this.headers.clear();
      for (const [key, value] of snapshot.headers) this.headers.set(key, value);
      this.blocks.clear();
      for (const [key, value] of snapshot.blocks) this.blocks.set(key, value);
      this.validatedHeight = snapshot.validatedHeight;
      this.validatedHash = snapshot.validatedHash;
      throw error;
    }
  }

  setMeta(key: string, value: string): void {
    this.meta.set(key, value);
    this.persistMeta();
  }

  getMeta(key: string): string | undefined {
    return this.meta.get(key);
  }

  private persistMeta(): void {
    if (this.session === null) return;
    this.queue(this.session.store.putMetadata("runtime_meta", JSON.stringify(Object.fromEntries(this.meta))));
  }

  upsertSyncState(chain: string, patch: Partial<ChainstateSyncState>): void {
    const existing = this.syncStates.get(chain);
    const next = {
      bestHeight: patch.bestHeight ?? existing?.bestHeight ?? 0,
      bestHash: patch.bestHash ?? existing?.bestHash ?? "",
      headerCount: patch.headerCount ?? existing?.headerCount ?? this.headerCount(chain),
      syncStatus: patch.syncStatus ?? existing?.syncStatus ?? "starting",
      updatedAt: utcNowIso(),
    };
    this.syncStates.set(chain, next);
    if (this.session !== null) {
      this.queue(this.session.store.upsertSyncState(chain, next));
    }
  }

  getSyncState(chain: string): (ChainstateSyncState & { updatedAt: string }) | null {
    return this.syncStates.get(chain) ?? null;
  }

  getSyncStateRow(chain: string): Record<string, unknown> {
    const state = this.getSyncState(chain);
    if (state === null) return {};
    return {
      chain,
      best_height: state.bestHeight,
      best_hash: state.bestHash,
      header_count: state.headerCount,
      sync_status: state.syncStatus,
      updated_at: state.updatedAt,
    };
  }

  updatePhase(_phase: string, _status: string, _notes: string): void {
    // Project phase tracking intentionally lives outside the TypeScript runtime.
  }

  listPhases(): Record<string, unknown>[] {
    return [];
  }

  logEvent(source: string, message: string, level = "info", details?: unknown): void {
    const event = {
      id: this.events.length + 1,
      category: source,
      level,
      message,
      details_json: details === undefined ? null : JSON.stringify(details),
      created_at: utcNowIso(),
    };
    this.events.unshift(event);
    if (this.events.length > 200) this.events.length = 200;
    if (this.session !== null) {
      this.queue(this.session.store.logEvent(source, message, level, event.details_json ?? undefined));
    }
  }

  recentEvents(limit = 20): Record<string, unknown>[] {
    return this.events.slice(0, limit);
  }

  getValidatedHeight(_chain: string): number {
    return Math.max(0, this.validatedHeight);
  }

  getValidatedHash(_chain: string): string | null {
    return this.validatedHash;
  }

  setValidatedTip(chain: string, height: number, blockHashOrHeader: string | BlockHeader): void {
    const blockHash = typeof blockHashOrHeader === "string"
      ? blockHashOrHeader
      : BlockHeaderCodec.blockHashHex(blockHashOrHeader);
    this.validatedHeight = height;
    this.validatedHash = blockHash;
    if (this.session !== null) {
      this.queue(this.session.store.setValidatedTip(chain, height, blockHash));
    }
  }

  resetValidatedChain(chain: string, genesisHash: string): void {
    this.utxos.clear();
    this.undo.clear();
    this.setValidatedTip(chain, 0, genesisHash);
  }

  replaceUtxoUndo(_chain: string, height: number, entries: UtxoUndoEntry[]): void {
    this.undo.set(height, entries);
  }

  takeUtxoUndo(_chain: string, height: number): UtxoUndoEntry[] {
    const entries = this.undo.get(height);
    if (!entries) throw new Error(`No UTXO undo journal for height ${height}`);
    this.undo.delete(height);
    return entries;
  }

  addUtxo(
    _chain: string,
    txid: Buffer,
    vout: number,
    options: { height: number; value: number; scriptPubKey: Buffer; coinbase: boolean },
  ): void {
    const displayTxid = toDisplayHash(txid);
    this.utxos.set(`${txid.toString("hex")}:${vout}`, {
      txid: displayTxid,
      vout,
      height: options.height,
      value: options.value,
      scriptPubKey: options.scriptPubKey,
      coinbase: options.coinbase,
    });
  }

  spendUtxo(_chain: string, txid: Buffer, vout: number): void {
    const key = `${txid.toString("hex")}:${vout}`;
    if (!this.utxos.delete(key)) {
      throw new Error(`UTXO not found: ${toDisplayHash(txid)}:${vout}`);
    }
  }

  getUtxo(_chain: string, txid: Buffer, vout: number): {
    txid: string;
    vout: number;
    height: number;
    value: number;
    scriptPubKey: Buffer;
    coinbase: boolean;
  } | null {
    return this.utxos.get(`${txid.toString("hex")}:${vout}`) ?? null;
  }

  deleteUtxosCreatedAtHeight(_chain: string, height: number): void {
    for (const [key, utxo] of this.utxos) {
      if (utxo.height === height) this.utxos.delete(key);
    }
  }

  utxoCount(_chain: string): number {
    return this.utxos.size;
  }

  headerCount(_chain?: string): number {
    return this.headers.size;
  }

  maxHeaderHeight(_chain?: string): number {
    let max = 0;
    for (const height of this.headers.keys()) {
      if (height > max) max = height;
    }
    return max;
  }

  getHeaderHash(_chain: string, height: number): string | null {
    return this.headers.get(height)?.block_hash ?? null;
  }

  lookupHeaderHeight(_chain: string, blockHashHex: string): number | null {
    for (const [height, row] of this.headers) {
      if (row.block_hash === blockHashHex) return height;
    }
    return null;
  }

  getHeaderRow(_chain: string, height: number): { block_hash: string; header_serialized_hex: string | null } | null {
    const row = this.headers.get(height);
    return row ? { block_hash: row.block_hash, header_serialized_hex: row.header_serialized_hex } : null;
  }

  recordHeader(chain: string, row: { height: number; blockHash: string; prevHash: string; headerSerializedHex?: string }): void {
    this.headers.set(row.height, {
      block_hash: row.blockHash,
      prev_hash: row.prevHash,
      header_serialized_hex: row.headerSerializedHex ?? null,
    });
    if (this.session !== null && row.headerSerializedHex) {
      this.queue(this.session.store.insertHeader(chain, {
        height: row.height,
        blockHash: row.blockHash,
        prevHash: row.prevHash,
        headerSerializedHex: row.headerSerializedHex,
      }));
    }
  }

  backfillGenesisHeaderBlob(_chain: string, headerSerializedHex: string): void {
    const row = this.headers.get(0);
    if (row) row.header_serialized_hex = headerSerializedHex;
  }

  blockCount(_chain?: string): number {
    return this.blocks.size;
  }

  hasBlock(_chain: string, height: number): boolean {
    return this.blocks.has(height);
  }

  listMissingBlockHeights(_chain: string, limit = 32): number[] {
    const out: number[] = [];
    for (const height of [...this.headers.keys()].sort((a, b) => a - b)) {
      if (height <= 0) continue;
      if (!this.blocks.has(height)) out.push(height);
      if (out.length >= limit) break;
    }
    return out;
  }

  recordBlock(chain: string, height: number, blockHash: string, fileName: string, fileOffset: number, blockSize: number): void {
    const match = /^blk(\d+)\.dat$/.exec(fileName);
    const fileNumber = match ? Number.parseInt(match[1]!, 10) : 0;
    const row = { height, block_hash: blockHash, file_number: fileNumber, file_offset: fileOffset, block_size: blockSize };
    this.blocks.set(height, row);
    if (this.session !== null) {
      this.queue(this.session.store.recordBlock(chain, {
        height,
        blockHash,
        fileNumber,
        fileOffset,
        blockSize,
      }));
    }
  }

  getBlock(_chain: string, height: number): Record<string, unknown> | null {
    const row = this.blocks.get(height);
    return row ? { ...row } : null;
  }

  getStoredBlockForHashHex(_chain: string, blockHashHex: string): Record<string, unknown> | null {
    const row = [...this.blocks.values()].find((candidate) => candidate.block_hash === blockHashHex);
    return row ? { ...row } : null;
  }

  maxStoredBlockHeight(_chain: string): number {
    let max = 0;
    for (const height of this.blocks.keys()) {
      if (height > max) max = height;
    }
    return max;
  }

  listStoredBlocks(_chain: string): BlockRow[] {
    return [...this.blocks.values()].sort((a, b) => a.height - b.height);
  }

  refreshBlockRecord(record: ChainstateBlockIndexRecord): void {
    this.blocks.set(record.height, this.blockRow(record));
  }

  refreshValidatedTip(height: number, blockHash: string): void {
    this.validatedHeight = height;
    this.validatedHash = blockHash;
  }

  private blockRow(record: ChainstateBlockIndexRecord): BlockRow {
    return {
      height: record.height,
      block_hash: record.blockHash,
      file_number: record.fileNumber,
      file_offset: record.fileOffset,
      block_size: record.blockSize,
    };
  }

  dbQuery<T extends Record<string, unknown>>(_sql: string, _params: Array<string | number> = []): T | null {
    const height = this.maxHeaderHeight();
    const row = this.headers.get(height);
    return row ? ({ height, block_hash: row.block_hash } as unknown as T) : null;
  }

  peerCount(): number {
    return this.peerRows.size;
  }

  connectedPeerCount(): number {
    return [...this.peerRows.values()].filter((row) => row.status === "connected").length;
  }

  recordPeerConnected(host: string, port: number, options: { direction?: string; services?: number; peerVersion?: number; userAgent?: string; startHeight?: number } = {}): number {
    const id = this.nextPeerId++;
    this.peerRows.set(id, { id, host, port, status: "connected", last_seen_at: utcNowIso() });
    this.recordPeerAddress(host, port, {
      ...(options.services === undefined ? {} : { services: options.services }),
      source: options.direction ?? "outbound",
    });
    this.logEvent("p2p", `Connected to ${host}:${port}`, "info", { peer_id: id, user_agent: options.userAgent ?? "" });
    return id;
  }

  recordPeerDisconnected(peerId: number, status = "disconnected"): void {
    const row = this.peerRows.get(peerId);
    if (row) this.peerRows.set(peerId, { ...row, status, last_seen_at: utcNowIso() });
  }

  touchPeer(peerId: number): void {
    const row = this.peerRows.get(peerId);
    if (row) this.peerRows.set(peerId, { ...row, last_seen_at: utcNowIso() });
  }

  incrementPeerBanScore(host: string, port: number, delta: number): number {
    const key = `${host}:${port}`;
    const row = this.peerAddresses.get(key) ?? {
      host,
      port,
      services: 0,
      source: "ban",
      last_seen_at: utcNowIso(),
      ban_score: 0,
    };
    row.ban_score += delta;
    row.last_seen_at = utcNowIso();
    this.peerAddresses.set(key, row);
    this.persistPeerAddresses();
    return row.ban_score;
  }

  getPeerEndpointBanScore(host: string, port: number): number {
    return this.peerAddresses.get(`${host}:${port}`)?.ban_score ?? 0;
  }

  recordPeerAddress(host: string, port: number, options: { services?: number | bigint; source?: string } = {}): void {
    if (host === PYTHON_NODE_DEFAULT_PEER && port === PYTHON_NODE_DEFAULT_PEER_PORT) return;
    const key = `${host}:${port}`;
    const existing = this.peerAddresses.get(key);
    const services = typeof options.services === "bigint" ? Number(options.services) : options.services;
    this.peerAddresses.set(key, {
      host,
      port,
      services: services ?? existing?.services ?? 0,
      source: options.source ?? existing?.source ?? "unknown",
      last_seen_at: utcNowIso(),
      ban_score: existing?.ban_score ?? 0,
    });
    this.persistPeerAddresses();
  }

  listPeerAddressEndpoints(limit = 32): Array<[string, number]> {
    return [...this.peerAddresses.values()]
      .sort((a, b) => a.ban_score - b.ban_score || b.last_seen_at.localeCompare(a.last_seen_at))
      .slice(0, limit)
      .map((row) => [row.host, row.port]);
  }

  private persistPeerAddresses(): void {
    if (this.session === null) return;
    this.queue(this.session.store.putMetadata("runtime_peer_addresses", JSON.stringify([...this.peerAddresses.values()])));
  }

  markWireCapability(capabilityId: string, ok: boolean, verifiedBy = "", notes = ""): void {
    const existing = this.wire.get(capabilityId) ?? { value: 0, record: { id: capabilityId } };
    existing.value = ok ? 1 : 0;
    existing.record = { ...existing.record, verifiedBy, notes };
    this.wire.set(capabilityId, existing);
    this.persistWire();
  }

  wireCapabilityMap(): Record<string, number> {
    return Object.fromEntries([...this.wire.entries()].map(([id, row]) => [id, row.value]));
  }

  listWireCapabilities(checkpoint?: string | boolean): Record<string, unknown>[] {
    return [...this.wire.entries()]
      .map(([capability_id, row]) => ({ capability_id, ...row.record, implemented: row.value }) as Record<string, unknown>)
      .filter((row) => typeof checkpoint !== "string" || row["checkpoint"] === checkpoint);
  }

  wireProgress(): { capabilities: Record<string, unknown>[]; checkpoints: Record<string, WireCheckpointStatus>; summary: FullNodeWireProgress } {
    const capabilities = this.wireCapabilityMap();
    return {
      capabilities: this.listWireCapabilities(),
      checkpoints: checkpointStatus(capabilities),
      summary: fullNodeWireProgress(capabilities),
    };
  }

  private persistWire(): void {
    if (this.session === null) return;
    this.queue(this.session.store.putMetadata("runtime_wire", JSON.stringify(this.wireCapabilityMap())));
  }

  summary(chain: string): Record<string, unknown> {
    const sync = this.getSyncStateRow(chain);
    const wire = this.wireProgress();
    return {
      chain,
      sync,
      header_count: this.headerCount(chain),
      block_count: this.blockCount(chain),
      validated_height: this.getValidatedHeight(chain),
      validated_hash: this.getValidatedHash(chain),
      utxo_count: this.session ? 0 : this.utxoCount(chain),
      peer_count: this.peerCount(),
      connected_peers: this.connectedPeerCount(),
      phases: [],
      wire: wire.summary,
      checkpoints: wire.checkpoints,
      recent_events: this.recentEvents(),
    };
  }

  async nativeUtxoCount(chain: string): Promise<number> {
    return this.session ? this.session.store.utxoCount(chain) : this.utxoCount(chain);
  }

  static legacySqliteArtifactName(): string {
    return ["tsbitnode", "db"].join(".");
  }
}
