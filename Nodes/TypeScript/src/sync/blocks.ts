import type { ChainParams } from "../chain/params.js";
import { connectBlock, ConnectBlockError } from "../consensus/connect.js";
import { connectBlockNative } from "../consensus/nativeConnect.js";
import type { NativeNodeState } from "../runtime/nodeState.js";
import { broadcastWitnessBlockInv, type PeerConnection } from "../p2p/peer.js";
import type { BlockStore } from "../storage/blocks.js";
import { BlockValidationError, validateBlock } from "./validate.js";

const PARALLEL_CAP_ID = "blocks.parallel";

interface BatchOptions {
  batchSize: number;
  maxBlocks: number;
  parallelDownloads?: number;
}

interface TipOptions {
  batchSize?: number;
  maxBlocks?: number;
  targetHeight?: number;
  parallelDownloads?: number;
}

function looksLikeBlockStore(value: unknown): value is BlockStore {
  return typeof value === "object" && value !== null && "read" in value && "write" in value;
}

function resolveBatchArgs(
  blockStoreOrOptions: BlockStore | BatchOptions,
  maybeOptions?: BatchOptions,
): { blockStore: BlockStore | null; options: BatchOptions } {
  if (looksLikeBlockStore(blockStoreOrOptions)) {
    if (maybeOptions === undefined) {
      throw new ConnectBlockError("block sync options missing");
    }
    return { blockStore: blockStoreOrOptions, options: maybeOptions };
  }
  return { blockStore: null, options: blockStoreOrOptions };
}

function resolveChainStoreArgs(
  blockStoreOrChain: BlockStore | ChainParams,
  maybeChain?: ChainParams,
): { blockStore: BlockStore | null; chain: ChainParams } {
  if (looksLikeBlockStore(blockStoreOrChain)) {
    if (maybeChain === undefined) {
      throw new ConnectBlockError("chain parameters missing");
    }
    return { blockStore: blockStoreOrChain, chain: maybeChain };
  }
  return { blockStore: null, chain: blockStoreOrChain };
}

function expectedPrevHash(tracker: NativeNodeState, chain: string, height: number): Buffer | null {
  const prevHex = tracker.getHeaderHash(chain, height - 1);
  if (!prevHex) return null;
  return Buffer.from(prevHex, "hex").reverse();
}

export async function requestBlockFromPeers(
  peers: PeerConnection[],
  blockHash: Buffer,
): Promise<[Buffer, PeerConnection] | null> {
  for (const peer of peers) {
    if (!peer.isConnected) continue;
    try {
      const payload = await peer.requestBlock(blockHash);
      if (payload !== null) {
        return [payload, peer];
      }
    } catch {
      continue;
    }
  }
  return null;
}

export async function requestBlockFromPeersParallel(
  peers: PeerConnection[],
  blockHash: Buffer,
): Promise<[Buffer, PeerConnection] | null> {
  const eligible = peers.filter((peer) => peer.isConnected);
  if (eligible.length === 0) return null;

  return new Promise<[Buffer, PeerConnection] | null>((resolve) => {
    let settled = false;
    let pending = eligible.length;

    const finish = (result: [Buffer, PeerConnection] | null) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };

    for (const peer of eligible) {
      peer
        .requestBlock(blockHash)
        .then((payload) => {
          if (payload !== null) {
            finish([payload, peer]);
            return;
          }
          pending -= 1;
          if (pending === 0) finish(null);
        })
        .catch(() => {
          pending -= 1;
          if (pending === 0 && !settled) finish(null);
        });
    }
  });
}

function maybeMarkParallelSync(tracker: NativeNodeState, parallelDownloads: number): void {
  if (parallelDownloads <= 0) return;
  if (tracker.wireCapabilityMap()[PARALLEL_CAP_ID] === 1) return;
  tracker.markWireCapability(
    PARALLEL_CAP_ID,
    true,
    "code",
    "prototype parallel height + peer races",
  );
}

async function connectDownloadedBlock(
  tracker: NativeNodeState,
  chain: ChainParams,
  payload: Buffer,
  options: {
    height: number;
    expectedPrev: Buffer;
    expectedHash: Buffer;
    blockHashHex: string;
    blockStore: BlockStore | null;
  },
): Promise<void> {
  if (tracker.session !== null) {
    await connectBlockNative(tracker.session, payload, {
      height: options.height,
      expectedPrev: options.expectedPrev,
      expectedHash: options.expectedHash,
      chainName: chain.name,
    });
    tracker.refreshValidatedTip(options.height, options.blockHashHex);
    const stored = await tracker.session.store.getBlock(chain.name, options.height);
    if (stored !== null) tracker.refreshBlockRecord(stored);
    return;
  }

  if (options.blockStore === null) {
    throw new ConnectBlockError("native session unavailable");
  }
  connectBlock(tracker, payload, {
    height: options.height,
    expectedPrev: options.expectedPrev,
    expectedHash: options.expectedHash,
    chainName: chain.name,
  });
  const stored = options.blockStore.write(payload);
  tracker.recordBlock(
    chain.name,
    options.height,
    options.blockHashHex,
    stored.fileName,
    stored.offset,
    stored.size,
  );
}

export async function syncBlocksBatch(
  peers: PeerConnection[],
  tracker: NativeNodeState,
  chain: ChainParams,
  blockStoreOrOptions: BlockStore | BatchOptions,
  maybeOptions?: BatchOptions,
): Promise<number> {
  const { blockStore, options } = resolveBatchArgs(blockStoreOrOptions, maybeOptions);
  if (peers.length === 0) return 0;

  const limit =
    options.maxBlocks === 0 ? options.batchSize : Math.min(options.batchSize, options.maxBlocks);
  const missing = tracker.listMissingBlockHeights(chain.name, limit);
  if (missing.length === 0) {
    tracker.upsertSyncState(chain.name, { syncStatus: "blocks_current" });
    return 0;
  }

  tracker.upsertSyncState(chain.name, { syncStatus: "blocks_syncing" });
  tracker.updatePhase(
    "phase2",
    "in_progress",
    `Downloading blocks (${tracker.blockCount(chain.name)} stored)`,
  );

  let downloaded = 0;
  const parallelDownloads = options.parallelDownloads ?? 0;

  if (parallelDownloads > 0) {
    const work: Array<[number, string, Buffer, Buffer]> = [];
    for (const height of missing) {
      if (options.maxBlocks > 0 && work.length >= options.maxBlocks) break;
      const blockHashHex = tracker.getHeaderHash(chain.name, height);
      if (!blockHashHex) continue;
      const blockHashRev = Buffer.from(blockHashHex, "hex").reverse();
      const expectedPrev = expectedPrevHash(tracker, chain.name, height);
      if (expectedPrev === null) continue;
      work.push([height, blockHashHex, blockHashRev, expectedPrev]);
    }

    if (work.length > 0) {
      maybeMarkParallelSync(tracker, parallelDownloads);

      const chunks: Array<typeof work> = [];
      for (let index = 0; index < work.length; index += parallelDownloads) {
        chunks.push(work.slice(index, index + parallelDownloads));
      }

      outer: for (const chunk of chunks) {
        const fetched = await Promise.all(
          chunk.map(async ([height, blockHashHex, blockHashRev, expectedPrev]) => {
            const outcome = await requestBlockFromPeersParallel(peers, blockHashRev);
            return { height, blockHashHex, blockHashRev, expectedPrev, outcome };
          }),
        );

        for (const row of fetched) {
          if (row.outcome === null) {
            tracker.logEvent("sync", "Block unavailable from peers", "warning", {
              height: row.height,
              block_hash: row.blockHashHex,
            });
            break outer;
          }
          const [payload, peer] = row.outcome;
          try {
            await connectDownloadedBlock(tracker, chain, payload, {
              height: row.height,
              expectedPrev: row.expectedPrev,
              expectedHash: row.blockHashRev,
              blockHashHex: row.blockHashHex,
              blockStore,
            });
            peer.markBlockDownloadCapabilities();
            await broadcastWitnessBlockInv(peers, row.blockHashRev, tracker);
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            tracker.logEvent("sync", "Rejected invalid block", "warning", {
              height: row.height,
              error: message,
            });
            break outer;
          }
          tracker.markWireCapability(
            "blocks.block.store",
            true,
            "live",
            `stored block height ${row.height}`,
          );
          downloaded += 1;
        }
      }
    }
  } else {
    for (const height of missing) {
      if (options.maxBlocks > 0 && downloaded >= options.maxBlocks) break;
      const blockHashHex = tracker.getHeaderHash(chain.name, height);
      if (!blockHashHex) continue;
      const blockHash = Buffer.from(blockHashHex, "hex").reverse();
      const expectedPrev = expectedPrevHash(tracker, chain.name, height);
      if (expectedPrev === null) continue;

      const result = await requestBlockFromPeers(peers, blockHash);
      if (result === null) {
        tracker.logEvent("sync", "Block unavailable from peers", "warning", {
          height,
          block_hash: blockHashHex,
        });
        break;
      }

      const [payload, peer] = result;
      try {
        await connectDownloadedBlock(tracker, chain, payload, {
          height,
          expectedPrev,
          expectedHash: blockHash,
          blockHashHex,
          blockStore,
        });
        peer.markBlockDownloadCapabilities();
        await broadcastWitnessBlockInv(peers, blockHash, tracker);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        tracker.logEvent("sync", "Rejected invalid block", "warning", {
          height,
          error: message,
        });
        break;
      }

      tracker.markWireCapability(
        "blocks.block.store",
        true,
        "live",
        `stored block height ${height}`,
      );
      downloaded += 1;
    }
  }

  if (downloaded > 0) {
    tracker.logEvent("sync", `Downloaded ${downloaded} blocks`, "info", {
      from_height: missing[0],
      to_height: missing[Math.min(downloaded, missing.length) - 1],
    });
    tracker.updatePhase(
      "phase2",
      "in_progress",
      `${tracker.blockCount(chain.name)} blocks stored, validated through height ${tracker.getValidatedHeight(chain.name)}`,
    );
  }

  if (tracker.listMissingBlockHeights(chain.name, 1).length === 0) {
    tracker.upsertSyncState(chain.name, { syncStatus: "blocks_current" });
  }

  return downloaded;
}

function downloadProgressHeight(tracker: NativeNodeState, chain: string): number {
  return Math.max(tracker.getValidatedHeight(chain), tracker.maxStoredBlockHeight(chain));
}

export async function syncBlocksToTip(
  peers: PeerConnection[],
  tracker: NativeNodeState,
  chain: ChainParams,
  blockStoreOrOptions: BlockStore | TipOptions = {},
  maybeOptions?: TipOptions,
): Promise<number> {
  const blockStore = looksLikeBlockStore(blockStoreOrOptions) ? blockStoreOrOptions : null;
  const options = looksLikeBlockStore(blockStoreOrOptions) ? maybeOptions ?? {} : blockStoreOrOptions;
  const batchSize = options.batchSize ?? 32;
  const maxBlocks = options.maxBlocks ?? 0;
  const targetHeight = options.targetHeight ?? 0;
  const parallelDownloads = options.parallelDownloads ?? 0;

  let total = 0;
  while (true) {
    const progressHeight = downloadProgressHeight(tracker, chain.name);
    if (targetHeight > 0 && progressHeight >= targetHeight) break;

    let remaining = maxBlocks > 0 ? maxBlocks - total : batchSize;
    if (maxBlocks > 0 && remaining <= 0) break;

    let batchLimit = maxBlocks > 0 ? Math.min(batchSize, remaining) : batchSize;
    if (targetHeight > 0) {
      const heightsLeft = targetHeight - progressHeight;
      if (heightsLeft <= 0) break;
      batchLimit = Math.min(batchLimit, heightsLeft);
    }

    const batchOptions = {
      batchSize: batchLimit,
      maxBlocks: maxBlocks > 0 ? batchLimit : 0,
      parallelDownloads,
    };
    const downloaded = blockStore === null
      ? await syncBlocksBatch(peers, tracker, chain, batchOptions)
      : await syncBlocksBatch(peers, tracker, chain, blockStore, batchOptions);
    if (downloaded === 0) break;
    total += downloaded;
  }
  return total;
}

export function validateStoredBlocks(
  tracker: NativeNodeState,
  chain: string,
  blockStore: BlockStore,
): number {
  const rows = tracker.listStoredBlocks(chain);
  let validated = 0;
  for (const row of rows) {
    const expectedPrev = expectedPrevHash(tracker, chain, row.height);
    if (expectedPrev === null) continue;
    const fileName = `blk${String(row.file_number).padStart(5, "0")}.dat`;
    const payload = blockStore.read(fileName, row.file_offset, row.block_size);
    const blockHash = Buffer.from(row.block_hash, "hex").reverse();
    validateBlock(payload, { expectedPrev, expectedHash: blockHash });
    validated += 1;
  }
  return validated;
}

export async function connectStoredBlocks(
  tracker: NativeNodeState,
  blockStoreOrChain: BlockStore | ChainParams,
  maybeChain?: ChainParams,
): Promise<{ connected: number; newHashes: Buffer[] }> {
  const { blockStore, chain } = resolveChainStoreArgs(blockStoreOrChain, maybeChain);
  let connected = 0;
  const newHashes: Buffer[] = [];
  while (true) {
    const height = tracker.getValidatedHeight(chain.name) + 1;
    const row = tracker.getBlock(chain.name, height);
    if (!row) break;
    const expectedPrev = expectedPrevHash(tracker, chain.name, height);
    if (expectedPrev === null) break;
    const fileName = `blk${String(row.file_number).padStart(5, "0")}.dat`;
    const sourceBlockStore = tracker.session?.blockStore ?? blockStore;
    if (sourceBlockStore === null) throw new ConnectBlockError("native session unavailable");
    const payload = sourceBlockStore.read(fileName, Number(row.file_offset), Number(row.block_size));
    const blockHash = Buffer.from(String(row.block_hash), "hex").reverse();
    if (tracker.session !== null) {
      await connectBlockNative(tracker.session, payload, {
        height,
        expectedPrev,
        expectedHash: blockHash,
        chainName: chain.name,
      });
      tracker.refreshValidatedTip(height, String(row.block_hash));
      const stored = await tracker.session.store.getBlock(chain.name, height);
      if (stored !== null) tracker.refreshBlockRecord(stored);
    } else {
      connectBlock(tracker, payload, {
        height,
        expectedPrev,
        expectedHash: blockHash,
        chainName: chain.name,
      });
    }
    newHashes.push(blockHash);
    connected += 1;
  }
  return { connected, newHashes };
}

export function rebuildValidatedChain(
  tracker: NativeNodeState,
  blockStoreOrChain: BlockStore | ChainParams,
  maybeChain?: ChainParams,
): number | Promise<number> {
  const { blockStore, chain } = resolveChainStoreArgs(blockStoreOrChain, maybeChain);
  tracker.resetValidatedChain(chain.name, chain.genesisHash);

  if (tracker.session === null) {
    if (blockStore === null) throw new ConnectBlockError("native session unavailable");
    let total = 0;
    while (true) {
      const height = tracker.getValidatedHeight(chain.name) + 1;
      const row = tracker.getBlock(chain.name, height);
      if (!row) break;
      const expectedPrev = expectedPrevHash(tracker, chain.name, height);
      if (expectedPrev === null) break;
      const fileName = `blk${String(row.file_number).padStart(5, "0")}.dat`;
      const payload = blockStore.read(fileName, Number(row.file_offset), Number(row.block_size));
      const blockHash = Buffer.from(String(row.block_hash), "hex").reverse();
      connectBlock(tracker, payload, {
        height,
        expectedPrev,
        expectedHash: blockHash,
        chainName: chain.name,
      });
      total += 1;
    }
    return total;
  }

  return rebuildNativeValidatedChain(tracker, chain);
}

async function rebuildNativeValidatedChain(
  tracker: NativeNodeState,
  chain: ChainParams,
): Promise<number> {
  let total = 0;
  while (true) {
    const height = tracker.getValidatedHeight(chain.name) + 1;
    const row = tracker.getBlock(chain.name, height);
    if (!row) break;
    const expectedPrev = expectedPrevHash(tracker, chain.name, height);
    if (expectedPrev === null) break;
    if (tracker.session === null) throw new ConnectBlockError("native session unavailable");
    const fileName = `blk${String(row.file_number).padStart(5, "0")}.dat`;
    const payload = tracker.session.blockStore.read(fileName, Number(row.file_offset), Number(row.block_size));
    const blockHash = Buffer.from(String(row.block_hash), "hex").reverse();
    await connectBlockNative(tracker.session, payload, {
      height,
      expectedPrev,
      expectedHash: blockHash,
      chainName: chain.name,
    });
    tracker.refreshValidatedTip(height, String(row.block_hash));
    total += 1;
  }
  return total;
}

export function repairValidatedIfAhead(
  tracker: NativeNodeState,
  blockStoreOrChain: BlockStore | ChainParams,
  maybeChain?: ChainParams,
): number | Promise<number> {
  const { chain } = resolveChainStoreArgs(blockStoreOrChain, maybeChain);
  const maxStored = tracker.maxStoredBlockHeight(chain.name);
  const validated = tracker.getValidatedHeight(chain.name);
  if (validated <= maxStored) return 0;
  return rebuildValidatedChain(tracker, blockStoreOrChain, maybeChain);
}

export { BlockValidationError, ConnectBlockError };
