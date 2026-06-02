import type { ChainParams } from "../chain/params.js";
import { connectBlock, ConnectBlockError } from "../consensus/connect.js";
import type { ProjectTracker } from "../db/tracker.js";
import { broadcastWitnessBlockInv, type PeerConnection } from "../p2p/peer.js";
import type { BlockStore } from "../storage/blocks.js";
import { BlockValidationError, validateBlock } from "./validate.js";

const PARALLEL_CAP_ID = "blocks.parallel";

function expectedPrevHash(tracker: ProjectTracker, chain: string, height: number): Buffer | null {
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

function maybeMarkParallelSync(tracker: ProjectTracker, parallelDownloads: number): void {
  if (parallelDownloads <= 0) return;
  if (tracker.wireCapabilityMap()[PARALLEL_CAP_ID] === 1) return;
  tracker.markWireCapability(
    PARALLEL_CAP_ID,
    true,
    "code",
    "prototype parallel height + peer races",
  );
}

export async function syncBlocksBatch(
  peers: PeerConnection[],
  tracker: ProjectTracker,
  chain: ChainParams,
  blockStore: BlockStore,
  options: {
    batchSize: number;
    maxBlocks: number;
    parallelDownloads?: number;
  },
): Promise<number> {
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
            connectBlock(tracker, payload, {
              height: row.height,
              expectedPrev: row.expectedPrev,
              expectedHash: row.blockHashRev,
              chainName: chain.name,
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
          const stored = blockStore.write(payload);
          tracker.recordBlock(
            chain.name,
            row.height,
            row.blockHashHex,
            stored.fileName,
            stored.offset,
            stored.size,
          );
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
        connectBlock(tracker, payload, {
          height,
          expectedPrev,
          expectedHash: blockHash,
          chainName: chain.name,
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

      const stored = blockStore.write(payload);
      tracker.recordBlock(
        chain.name,
        height,
        blockHashHex,
        stored.fileName,
        stored.offset,
        stored.size,
      );
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

function downloadProgressHeight(tracker: ProjectTracker, chain: string): number {
  return Math.max(tracker.getValidatedHeight(chain), tracker.maxStoredBlockHeight(chain));
}

export async function syncBlocksToTip(
  peers: PeerConnection[],
  tracker: ProjectTracker,
  chain: ChainParams,
  blockStore: BlockStore,
  options: {
    batchSize?: number;
    maxBlocks?: number;
    targetHeight?: number;
    parallelDownloads?: number;
  } = {},
): Promise<number> {
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

    const downloaded = await syncBlocksBatch(peers, tracker, chain, blockStore, {
      batchSize: batchLimit,
      maxBlocks: maxBlocks > 0 ? batchLimit : 0,
      parallelDownloads,
    });
    if (downloaded === 0) break;
    total += downloaded;
  }
  return total;
}

export function validateStoredBlocks(
  tracker: ProjectTracker,
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
  tracker: ProjectTracker,
  blockStore: BlockStore,
  chain: ChainParams,
): Promise<{ connected: number; newHashes: Buffer[] }> {
  let connected = 0;
  const newHashes: Buffer[] = [];
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
    newHashes.push(blockHash);
    connected += 1;
  }
  return { connected, newHashes };
}

export function rebuildValidatedChain(
  tracker: ProjectTracker,
  blockStore: BlockStore,
  chain: ChainParams,
): number {
  tracker.resetValidatedChain(chain.name, chain.genesisHash);
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

export function repairValidatedIfAhead(
  tracker: ProjectTracker,
  blockStore: BlockStore,
  chain: ChainParams,
): number {
  const maxStored = tracker.maxStoredBlockHeight(chain.name);
  const validated = tracker.getValidatedHeight(chain.name);
  if (validated <= maxStored) return 0;
  return rebuildValidatedChain(tracker, blockStore, chain);
}

export { BlockValidationError, ConnectBlockError };
