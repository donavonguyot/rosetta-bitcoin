import type { ChainParams } from "../chain/params.js";
import { genesisHeaderFor } from "../chain/genesis.js";
import type { ProjectTracker } from "../db/tracker.js";
import { BlockHeaderCodec, HEADER_SIZE, type GetHeadersMessage } from "../messages/headers.js";
import type { BlockStore } from "../storage/blocks.js";
import type { BlockHeader } from "../types/index.js";

export const HEADER_BATCH_MAX = 2000;

function findCommonForkHeight(tracker: ProjectTracker, chain: string, locatorHashes: Buffer[]): number {
  for (const internalHash of locatorHashes) {
    const display = Buffer.from(internalHash).reverse().toString("hex");
    const height = tracker.lookupHeaderHeight(chain, display);
    if (height !== null) {
      return height;
    }
  }
  return -1;
}

function resolveHeaderRecord(
  tracker: ProjectTracker,
  chain: ChainParams,
  height: number,
  blockStore: BlockStore | null,
): BlockHeader | null {
  const row = tracker.getHeaderRow(chain.name, height);
  if (!row) return null;
  const storedHashHex = row.block_hash;

  const serializedHex = row.header_serialized_hex ?? "";
  if (serializedHex) {
    const blob = Buffer.from(serializedHex, "hex");
    if (blob.length !== HEADER_SIZE) return null;
    const [headerObj, consumed] = BlockHeaderCodec.deserialize(blob, 0);
    if (consumed !== HEADER_SIZE) return null;
    if (BlockHeaderCodec.blockHashHex(headerObj) !== storedHashHex) return null;
    return headerObj;
  }

  if (height === 0) {
    const genesis = genesisHeaderFor(chain.name);
    if (storedHashHex === BlockHeaderCodec.blockHashHex(genesis)) {
      return genesis;
    }
    return null;
  }

  const blockRow = tracker.getBlock(chain.name, height);
  if (blockStore === null || blockRow === null) return null;
  try {
    const fileName = `blk${String(blockRow.file_number).padStart(5, "0")}.dat`;
    const raw = blockStore.read(fileName, Number(blockRow.file_offset), Number(blockRow.block_size));
    const [headerObj, consumed] = BlockHeaderCodec.deserialize(raw, 0);
    if (consumed !== HEADER_SIZE) return null;
    if (BlockHeaderCodec.blockHashHex(headerObj) !== storedHashHex) return null;
    return headerObj;
  } catch {
    return null;
  }
}

export function buildHeadersResponse(
  tracker: ProjectTracker,
  chain: ChainParams,
  message: GetHeadersMessage,
  blockStore: BlockStore | null = null,
): { headers: BlockHeader[] } {
  const zeroStop = message.hashStop.equals(Buffer.alloc(32, 0));

  if (message.locatorHashes.length === 0) {
    if (zeroStop) {
      return { headers: [] };
    }
    const stopHex = Buffer.from(message.hashStop).reverse().toString("hex");
    const stopHeight = tracker.lookupHeaderHeight(chain.name, stopHex);
    if (stopHeight === null) {
      return { headers: [] };
    }
    const resolvedStop = resolveHeaderRecord(tracker, chain, stopHeight, blockStore);
    if (resolvedStop === null || !BlockHeaderCodec.blockHash(resolvedStop).equals(message.hashStop)) {
      return { headers: [] };
    }
    return { headers: [resolvedStop] };
  }

  const forkHeight = findCommonForkHeight(tracker, chain.name, message.locatorHashes);
  const start = Math.max(forkHeight + 1, 0);
  const tip = tracker.maxHeaderHeight(chain.name);
  const explicitStopHash = zeroStop ? null : message.hashStop;
  if (explicitStopHash !== null) {
    const stopHeight = tracker.lookupHeaderHeight(
      chain.name,
      Buffer.from(explicitStopHash).reverse().toString("hex"),
    );
    if (stopHeight !== null && stopHeight < start) {
      return { headers: [] };
    }
  }

  const gathered: BlockHeader[] = [];
  for (let height = start; height <= tip; height += 1) {
    if (gathered.length >= HEADER_BATCH_MAX) break;
    const resolved = resolveHeaderRecord(tracker, chain, height, blockStore);
    if (resolved === null) break;
    gathered.push(resolved);
    if (explicitStopHash !== null && BlockHeaderCodec.blockHash(resolved).equals(explicitStopHash)) {
      break;
    }
  }

  return { headers: gathered };
}
