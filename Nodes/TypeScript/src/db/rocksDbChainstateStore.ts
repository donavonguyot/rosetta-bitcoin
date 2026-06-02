import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { randomUUID } from "node:crypto";

import rocksdb, {
  type RocksDbBatchOperation,
  type RocksDbDatabase,
  type RocksDbIterator,
} from "rocksdb";

import {
  blockIndexKey,
  decodeBlockIndex,
  decodeHeader,
  decodeMetadataValue,
  decodeTip,
  decodeUndo,
  decodeUtxo,
  encodeBlockIndex,
  encodeHeader,
  encodeTip,
  encodeUndo,
  encodeUtxo,
  eventKey,
  headerKey,
  metadataKey,
  metadataValue,
  tipKey,
  undoKey,
  utxoKey,
  utxoPrefixKey,
} from "../storage/chainstateCodecV2.js";
import { BlockHeaderCodec } from "../messages/headers.js";
import type {
  ChainstateBlockCommit,
  ChainstateBlockIndexRecord,
  ChainstateCommitResult,
  ChainstateHeaderRecord,
  ChainstateMetadata,
  ChainstateStore,
  ChainstateStoredUtxo,
  ChainstateSyncState,
  ChainstateUndoEntry,
} from "./chainstate.js";

const require = createRequire(import.meta.url);
const rocksdbPackage = require("rocksdb/package.json") as { version?: string };

export const ROCKSDB_BACKEND_NAME = "rocksdb";
export const ROCKSDB_SCHEMA_VERSION = "2";
export const ROCKSDB_CODEC_VERSION = "2";

function utcNowIso(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function isNotFound(error: Error | null): boolean {
  if (error === null) return false;
  const maybe = error as Error & { notFound?: boolean; code?: string };
  return maybe.notFound === true || maybe.code === "LEVEL_NOT_FOUND" || /notfound/i.test(error.message);
}

function callbackVoid(fn: (callback: (error?: Error | null) => void) => void): Promise<void> {
  return new Promise((resolvePromise, reject) => {
    fn((error) => {
      if (error) reject(error);
      else resolvePromise();
    });
  });
}

function keyPrefixForHeightKey(fullHeightZeroKey: Buffer): Buffer {
  return fullHeightZeroKey.subarray(0, fullHeightZeroKey.length - 4);
}

function hex32(value: string, label: string): Buffer {
  const out = Buffer.from(value, "hex");
  if (out.length !== 32) {
    throw new RangeError(`${label} must be 32-byte hex`);
  }
  return out;
}

function syncStateKey(chain: string): Buffer {
  return metadataKey(`sync_state:${chain}`);
}

function jsonValue(value: unknown): Buffer {
  return Buffer.from(JSON.stringify(value), "utf8");
}

function parseJson<T>(value: Buffer): T {
  return JSON.parse(value.toString("utf8")) as T;
}

function encodeStoredUtxo(utxo: ChainstateStoredUtxo): Buffer {
  return encodeUtxo({
    height: utxo.height,
    valueSats: utxo.value,
    scriptPubkey: utxo.scriptPubKey,
    coinbase: utxo.coinbase,
  });
}

function decodeStoredUtxo(txid: string, vout: number, value: Buffer): ChainstateStoredUtxo {
  const decoded = decodeUtxo(value);
  return {
    txid,
    vout,
    height: decoded.height,
    value: decoded.valueSats,
    scriptPubKey: decoded.scriptPubkey,
    coinbase: decoded.coinbase,
  };
}

function decodeUndoEntry(entry: {
  txidInternal: Buffer;
  vout: number;
  height: number;
  valueSats: bigint;
  scriptPubkey: Buffer;
  coinbase: boolean;
}): ChainstateUndoEntry {
  return {
    txid: entry.txidInternal.toString("hex"),
    vout: entry.vout,
    height: entry.height,
    value: entry.valueSats,
    scriptPubKey: entry.scriptPubkey,
    coinbase: entry.coinbase,
  };
}

export class RocksDbChainstateStore implements ChainstateStore {
  private readonly db: RocksDbDatabase;
  private currentMetadata: ChainstateMetadata;

  private constructor(
    private readonly path: string,
    private readonly chain: string,
    db: RocksDbDatabase,
    metadata: ChainstateMetadata,
  ) {
    this.db = db;
    this.currentMetadata = metadata;
  }

  static async open(path: string, chain: string): Promise<RocksDbChainstateStore> {
    const resolved = resolve(path);
    mkdirSync(resolved, { recursive: true });
    const db = rocksdb(resolved);
    await callbackVoid((callback) => db.open({ createIfMissing: true }, callback));
    const existing = await RocksDbChainstateStore.readMetadataFromDb(db, chain, resolved);
    const store = new RocksDbChainstateStore(resolved, chain, db, existing);
    await store.writeMetadata(existing);
    return store;
  }

  get metadata(): ChainstateMetadata {
    return this.currentMetadata;
  }

  async close(): Promise<void> {
    await callbackVoid((callback) => this.db.close(callback));
  }

  async metadataValue(key: string): Promise<string | null> {
    const value = await this.get(metadataKey(key));
    return value === null ? null : decodeMetadataValue(value);
  }

  async putMetadata(key: string, value: string): Promise<void> {
    await this.put(metadataKey(key), metadataValue(value));
  }

  async getValidatedHeight(chain: string): Promise<number> {
    return (await this.readTip(chain)).height;
  }

  async getValidatedHash(chain: string): Promise<string | null> {
    const tip = await this.readTip(chain);
    return tip.blockHash === "" ? null : tip.blockHash;
  }

  async setValidatedTip(chain: string, height: number, blockHash: string): Promise<void> {
    const updatedAt = utcNowIso();
    await this.batch([
      { type: "put", key: tipKey(chain), value: encodeTip({ height, blockHashInternal: hex32(blockHash, "block_hash") }) },
      { type: "put", key: metadataKey("tip_height"), value: metadataValue(String(height)) },
      { type: "put", key: metadataKey("tip_hash"), value: metadataValue(blockHash) },
      { type: "put", key: metadataKey("updated_at"), value: metadataValue(updatedAt) },
    ]);
    this.currentMetadata = { ...this.currentMetadata, tipHeight: height, tipHash: blockHash, updatedAt };
  }

  async getSyncState(chain: string): Promise<ChainstateSyncState | null> {
    const value = await this.get(syncStateKey(chain));
    return value === null ? null : parseJson<ChainstateSyncState>(value);
  }

  async upsertSyncState(chain: string, patch: Partial<ChainstateSyncState>): Promise<void> {
    const existing = await this.getSyncState(chain);
    const next: ChainstateSyncState = {
      bestHeight: patch.bestHeight ?? existing?.bestHeight ?? 0,
      bestHash: patch.bestHash ?? existing?.bestHash ?? "",
      headerCount: patch.headerCount ?? existing?.headerCount ?? (await this.headerCount(chain)),
      syncStatus: patch.syncStatus ?? existing?.syncStatus ?? "starting",
    };
    await this.put(syncStateKey(chain), jsonValue(next));
  }

  async insertHeader(chain: string, record: ChainstateHeaderRecord): Promise<void> {
    await this.put(headerKey(chain, record.height), encodeHeader(Buffer.from(record.headerSerializedHex, "hex")));
    await this.upsertSyncState(chain, {
      bestHeight: record.height,
      bestHash: record.blockHash,
      headerCount: await this.headerCount(chain),
    });
  }

  async getHeaderHash(chain: string, height: number): Promise<string | null> {
    const value = await this.get(headerKey(chain, height));
    if (value === null) return null;
    const header = decodeHeader(value);
    const [decoded] = BlockHeaderCodec.deserialize(header);
    return BlockHeaderCodec.blockHashHex(decoded);
  }

  async getHeaderSerializedHex(chain: string, height: number): Promise<string | null> {
    const value = await this.get(headerKey(chain, height));
    return value === null ? null : decodeHeader(value).toString("hex");
  }

  async headerCount(chain: string): Promise<number> {
    return this.countPrefix(keyPrefixForHeightKey(headerKey(chain, 0)));
  }

  async recordBlock(chain: string, record: ChainstateBlockIndexRecord): Promise<void> {
    await this.put(
      blockIndexKey(chain, record.height),
      encodeBlockIndex({
        blockHashInternal: hex32(record.blockHash, "block_hash"),
        fileNumber: record.fileNumber,
        fileOffset: record.fileOffset,
        blockSize: record.blockSize,
      }),
    );
  }

  async getBlock(chain: string, height: number): Promise<ChainstateBlockIndexRecord | null> {
    const value = await this.get(blockIndexKey(chain, height));
    if (value === null) return null;
    const decoded = decodeBlockIndex(value);
    return {
      height,
      blockHash: decoded.blockHashInternal.toString("hex"),
      fileNumber: decoded.fileNumber,
      fileOffset: decoded.fileOffset,
      blockSize: decoded.blockSize,
    };
  }

  async blockCount(chain: string): Promise<number> {
    return this.countPrefix(keyPrefixForHeightKey(blockIndexKey(chain, 0)));
  }

  async maxStoredBlockHeight(chain: string): Promise<number> {
    return this.maxHeightForPrefix(keyPrefixForHeightKey(blockIndexKey(chain, 0)));
  }

  async getUtxo(chain: string, txid: string, vout: number): Promise<ChainstateStoredUtxo | null> {
    const value = await this.get(utxoKey(chain, hex32(txid, "txid"), vout));
    return value === null ? null : decodeStoredUtxo(txid, vout, value);
  }

  async commitBlock(commit: ChainstateBlockCommit): Promise<ChainstateCommitResult> {
    const updatedAt = utcNowIso();
    const operations: RocksDbBatchOperation[] = [];
    for (const outpoint of commit.spentOutpoints) {
      operations.push({ type: "del", key: utxoKey(commit.chain, hex32(outpoint.txid, "spent txid"), outpoint.vout) });
    }
    for (const utxo of commit.createdUtxos) {
      operations.push({
        type: "put",
        key: utxoKey(commit.chain, hex32(utxo.txid, "created txid"), utxo.vout),
        value: encodeStoredUtxo(utxo),
      });
    }
    operations.push({
      type: "put",
      key: undoKey(commit.chain, commit.height),
      value: encodeUndo(
        commit.undoEntries.map((entry) => ({
          txidInternal: hex32(entry.txid, "undo txid"),
          vout: entry.vout,
          height: entry.height,
          valueSats: entry.value,
          scriptPubkey: entry.scriptPubKey,
          coinbase: entry.coinbase,
        })),
      ),
    });
    operations.push({
      type: "put",
      key: tipKey(commit.chain),
      value: encodeTip({ height: commit.height, blockHashInternal: hex32(commit.blockHash, "block_hash") }),
    });
    operations.push({ type: "put", key: metadataKey("tip_height"), value: metadataValue(String(commit.height)) });
    operations.push({ type: "put", key: metadataKey("tip_hash"), value: metadataValue(commit.blockHash) });
    operations.push({ type: "put", key: metadataKey("updated_at"), value: metadataValue(updatedAt) });
    await this.batch(operations);
    this.currentMetadata = {
      ...this.currentMetadata,
      tipHeight: commit.height,
      tipHash: commit.blockHash,
      updatedAt,
    };
    return {
      height: commit.height,
      blockHash: commit.blockHash,
      createdUtxos: commit.createdUtxos.length,
      spentOutpoints: commit.spentOutpoints.length,
    };
  }

  async readUndo(chain: string, height: number): Promise<ChainstateUndoEntry[]> {
    const value = await this.get(undoKey(chain, height));
    return value === null ? [] : decodeUndo(value).map(decodeUndoEntry);
  }

  async utxoCount(chain: string): Promise<number> {
    return this.countPrefix(utxoPrefixKey(chain));
  }

  async logEvent(category: string, message: string, severity = "info", detailsJson: string | undefined = undefined): Promise<void> {
    const id = `${Date.now()}-${process.hrtime.bigint()}`;
    await this.put(eventKey(id), jsonValue({ category, message, severity, detailsJson, createdAt: utcNowIso() }));
  }

  private static async readMetadataFromDb(
    db: RocksDbDatabase,
    chain: string,
    path: string,
  ): Promise<ChainstateMetadata> {
    const get = (key: string): Promise<string | null> =>
      new Promise((resolvePromise, reject) => {
        db.get(metadataKey(key), {}, (error, value) => {
          if (isNotFound(error)) resolvePromise(null);
          else if (error) reject(error);
          else resolvePromise(value ? decodeMetadataValue(value) : null);
        });
      });
    const now = utcNowIso();
    const generationId = (await get("generation_id")) ?? `ts-rocksdb-${randomUUID()}`;
    const createdAt = (await get("created_at")) ?? now;
    return {
      backendName: ROCKSDB_BACKEND_NAME,
      backendVersion: rocksdbPackage.version ?? "unknown",
      schemaVersion: ROCKSDB_SCHEMA_VERSION,
      codecVersion: ROCKSDB_CODEC_VERSION,
      chain,
      generationId,
      status: (await get("status")) ?? "usable",
      tipHeight: Number.parseInt((await get("tip_height")) ?? "-1", 10),
      tipHash: (await get("tip_hash")) ?? "",
      createdAt,
      updatedAt: (await get("updated_at")) ?? createdAt,
    };
  }

  private async writeMetadata(metadata: ChainstateMetadata): Promise<void> {
    await this.batch([
      { type: "put", key: metadataKey("backend_name"), value: metadataValue(metadata.backendName) },
      { type: "put", key: metadataKey("backend_version"), value: metadataValue(metadata.backendVersion) },
      { type: "put", key: metadataKey("schema_version"), value: metadataValue(metadata.schemaVersion) },
      { type: "put", key: metadataKey("codec_version"), value: metadataValue(metadata.codecVersion) },
      { type: "put", key: metadataKey("chain"), value: metadataValue(metadata.chain) },
      { type: "put", key: metadataKey("generation_id"), value: metadataValue(metadata.generationId) },
      { type: "put", key: metadataKey("status"), value: metadataValue(metadata.status) },
      { type: "put", key: metadataKey("tip_height"), value: metadataValue(String(metadata.tipHeight)) },
      { type: "put", key: metadataKey("tip_hash"), value: metadataValue(metadata.tipHash) },
      { type: "put", key: metadataKey("created_at"), value: metadataValue(metadata.createdAt) },
      { type: "put", key: metadataKey("updated_at"), value: metadataValue(metadata.updatedAt) },
    ]);
  }

  private async readTip(chain: string): Promise<{ height: number; blockHash: string }> {
    const value = await this.get(tipKey(chain));
    if (value !== null) {
      const tip = decodeTip(value);
      return { height: tip.height, blockHash: tip.blockHashInternal.toString("hex") };
    }
    return { height: this.currentMetadata.tipHeight, blockHash: this.currentMetadata.tipHash };
  }

  private get(key: Buffer): Promise<Buffer | null> {
    return new Promise((resolvePromise, reject) => {
      this.db.get(key, {}, (error, value) => {
        if (isNotFound(error)) resolvePromise(null);
        else if (error) reject(error);
        else resolvePromise(value ?? null);
      });
    });
  }

  private put(key: Buffer, value: Buffer): Promise<void> {
    return callbackVoid((callback) => this.db.put(key, value, {}, callback));
  }

  private batch(operations: readonly RocksDbBatchOperation[]): Promise<void> {
    return callbackVoid((callback) => this.db.batch(operations, {}, callback));
  }

  private iterator(): RocksDbIterator {
    return this.db.iterator({ keyAsBuffer: true, valueAsBuffer: true });
  }

  private async countPrefix(prefix: Buffer): Promise<number> {
    let count = 0;
    await this.forEachKey((key) => {
      if (key.subarray(0, prefix.length).equals(prefix)) count += 1;
    });
    return count;
  }

  private async maxHeightForPrefix(prefix: Buffer): Promise<number> {
    let max = 0;
    await this.forEachKey((key) => {
      if (key.subarray(0, prefix.length).equals(prefix) && key.length >= prefix.length + 4) {
        max = Math.max(max, key.readUInt32BE(prefix.length));
      }
    });
    return max;
  }

  private async forEachKey(fn: (key: Buffer) => void): Promise<void> {
    const iterator = this.iterator();
    try {
      while (true) {
        const key = await new Promise<Buffer | null>((resolvePromise, reject) => {
          iterator.next((error, nextKey) => {
            if (error) reject(error);
            else resolvePromise(nextKey ?? null);
          });
        });
        if (key === null) break;
        fn(key);
      }
    } finally {
      await callbackVoid((callback) => iterator.end(callback));
    }
  }
}
