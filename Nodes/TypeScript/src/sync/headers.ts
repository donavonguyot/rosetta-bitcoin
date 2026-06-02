import { genesisHeaderFor } from "../chain/genesis.js";
import type { ChainParams } from "../chain/params.js";
import type { Settings } from "../config/settings.js";
import type { ProjectTracker } from "../db/tracker.js";
import { BlockHeaderCodec, type HeadersMessage } from "../messages/headers.js";
import type { PeerConnection } from "../p2p/peer.js";
import type { BlockHeader } from "../types/index.js";
import { HeaderValidationError, validateHeader } from "./validate.js";

export const HEADER_SYNC_NEAR_PEER_TIP = 2;

export function repairSyncState(tracker: ProjectTracker, chain: ChainParams): void {
  const row = tracker.dbQuery<{ height: number; block_hash: string }>(
    `SELECT height, block_hash FROM headers WHERE chain = ? ORDER BY height DESC LIMIT 1`,
    [chain.name],
  );
  if (!row) return;
  tracker.upsertSyncState(chain.name, {
    bestHeight: row.height,
    bestHash: row.block_hash,
    headerCount: tracker.headerCount(),
    syncStatus: "headers_syncing",
  });
}

export function ensureGenesis(tracker: ProjectTracker, chain: ChainParams): BlockHeader {
  const existing = tracker.getHeaderHash(chain.name, 0);
  const genesis = genesisHeaderFor(chain.name);
  const genesisHash = BlockHeaderCodec.blockHashHex(genesis);

  if (existing) {
    if (existing !== genesisHash && existing !== chain.genesisHash) {
      throw new HeaderValidationError(
        `Stored genesis hash ${existing} does not match chain genesis ${genesisHash}`,
      );
    }
    tracker.backfillGenesisHeaderBlob(chain.name, BlockHeaderCodec.serialize(genesis).toString("hex"));
    if (tracker.getValidatedHash(chain.name) === null) {
      tracker.setValidatedTip(chain.name, 0, genesisHash);
    }
    tracker.markWireCapability("headers.genesis", true, "code", "genesis header present in SQLite");
    return genesis;
  }

  tracker.recordHeader(chain.name, {
    height: 0,
    blockHash: genesisHash,
    prevHash: Buffer.alloc(32).toString("hex"),
    headerSerializedHex: BlockHeaderCodec.serialize(genesis).toString("hex"),
  });
  tracker.setValidatedTip(chain.name, 0, genesisHash);
  tracker.upsertSyncState(chain.name, {
    bestHeight: 0,
    bestHash: genesisHash,
    headerCount: tracker.headerCount(),
    syncStatus: "genesis_seeded",
  });
  tracker.logEvent("sync", "Genesis header seeded", "info", { hash: genesisHash });
  tracker.markWireCapability("headers.genesis", true, "code", "genesis header seeded");
  return genesis;
}

function genesisLocator(chain: ChainParams): Buffer[] {
  const genesis = genesisHeaderFor(chain.name);
  return [BlockHeaderCodec.blockHash(genesis)];
}

export function locatorHeights(tip: number): number[] {
  let cursor = tip;
  let step = 1;
  const heights = [tip];
  while (cursor > 0) {
    cursor = Math.max(cursor - step, 0);
    heights.push(cursor);
    step <<= 1;
  }
  return heights;
}

export function nextLocator(tracker: ProjectTracker, chain: ChainParams): Buffer[] {
  ensureGenesis(tracker, chain);
  const state = tracker.getSyncState(chain.name);
  const bestHeight = state?.bestHeight ?? 0;
  const hashes: Buffer[] = [];
  for (const height of locatorHeights(bestHeight)) {
    const blockHash = tracker.getHeaderHash(chain.name, height);
    if (blockHash) {
      hashes.push(Buffer.from(blockHash, "hex").reverse());
    }
  }
  if (hashes.length === 0) {
    return genesisLocator(chain);
  }
  tracker.markWireCapability("headers.locator", true, "code", `locator built from height ${bestHeight}`);
  return hashes;
}

export function persistHeaders(
  tracker: ProjectTracker,
  chain: ChainParams,
  message: HeadersMessage,
): [number, string, number] {
  ensureGenesis(tracker, chain);
  const state = tracker.getSyncState(chain.name) ?? {
    chain: chain.name,
    bestHeight: 0,
    bestHash: chain.genesisHash,
    headerCount: 0,
    syncStatus: "starting" as const,
    updatedAt: "",
  };
  let tipHeight = state.bestHeight;
  let tipHashHex = tracker.getHeaderHash(chain.name, tipHeight) ?? chain.genesisHash;
  let tipInternal = Buffer.from(tipHashHex, "hex").reverse();

  let stored = 0;
  for (const header of message.headers) {
    try {
      validateHeader(header, tipInternal);
      tracker.markWireCapability("headers.pow", true, "code", "header PoW validated");
      tracker.markWireCapability("headers.chain_link", true, "code", "header chain link validated");
    } catch (error) {
      const messageText = error instanceof Error ? error.message : String(error);
      tracker.logEvent(
        "sync",
        `Header rejected at height ${tipHeight + 1}: ${messageText}`,
        "warning",
      );
      break;
    }

    tipHeight += 1;
    const blockHash = BlockHeaderCodec.blockHashHex(header);
    const prevHash = Buffer.from(header.prevBlock).reverse().toString("hex");
    tracker.recordHeader(chain.name, {
      height: tipHeight,
      blockHash,
      prevHash,
      headerSerializedHex: BlockHeaderCodec.serialize(header).toString("hex"),
    });
    tipInternal = Buffer.from(BlockHeaderCodec.blockHash(header));
    stored += 1;
  }

  if (stored > 0) {
    tracker.upsertSyncState(chain.name, {
      bestHeight: tipHeight,
      bestHash: tracker.getHeaderHash(chain.name, tipHeight) ?? chain.genesisHash,
      headerCount: tracker.headerCount(),
      syncStatus: "headers_syncing",
    });
    tracker.markWireCapability(
      "headers.persist",
      true,
      stored > 0 ? "live" : "code",
      `stored ${stored} headers`,
    );
  }

  return [tipHeight, tracker.getHeaderHash(chain.name, tipHeight) ?? chain.genesisHash, stored];
}

export function headersSyncDone(bestHeight: number, peerHeight: number, batchCount: number): boolean {
  if (batchCount === 0) return true;
  return peerHeight >= 0 && bestHeight >= peerHeight;
}

export function localHeaderTipHeight(tracker: ProjectTracker, chain: ChainParams): number {
  const state = tracker.getSyncState(chain.name);
  const bestState = state?.bestHeight ?? 0;
  return Math.max(bestState, tracker.maxHeaderHeight(chain.name));
}

export function requiredHeaderTipForBlockFollowup(
  tracker: ProjectTracker,
  chain: ChainParams,
  blocksTargetHeight: number,
): number {
  const missing = tracker.listMissingBlockHeights(chain.name, 1);
  const validated = tracker.getValidatedHeight(chain.name);
  let need = missing.length > 0 ? missing[0]! : validated + 1;

  const target = blocksTargetHeight || 0;
  if (target > 0) {
    need = Math.max(need, target);
  }
  return Math.max(need, validated + 1);
}

export function localHeadersCoverBlockFollowup(
  tracker: ProjectTracker,
  chain: ChainParams,
  blocksTargetHeight: number,
): boolean {
  const needThrough = requiredHeaderTipForBlockFollowup(tracker, chain, blocksTargetHeight);
  const tip = Math.max(localHeaderTipHeight(tracker, chain), tracker.maxHeaderHeight(chain.name));
  if (tip < needThrough) return false;
  return tracker.getHeaderHash(chain.name, needThrough) !== null;
}

function headersChainReadyForFullHandshake(
  tracker: ProjectTracker,
  chain: ChainParams,
): boolean {
  const state = tracker.getSyncState(chain.name);
  const status = state?.syncStatus ?? "starting";
  return status === "headers_current" || status === "running";
}

/** Version handshake start_height: validated tip during early sync; header tip once headers are current. */
export function resolveBootstrapStartHeight(
  tracker: ProjectTracker,
  chain: ChainParams,
  settings: Settings,
): number {
  const skipHeaderNetwork = settings.noHeaderRefresh || settings.syncSkipHeaders;
  if (skipHeaderNetwork || settings.simpleHandshake) {
    return tracker.getValidatedHeight(chain.name);
  }
  if (!headersChainReadyForFullHandshake(tracker, chain)) {
    return tracker.getValidatedHeight(chain.name);
  }
  return localHeaderTipHeight(tracker, chain);
}

export function shouldSkipHeaderDownload(
  tracker: ProjectTracker,
  chain: ChainParams,
  peerTipHeight: number,
): boolean {
  if (peerTipHeight < 0) return false;
  const tipLocal = localHeaderTipHeight(tracker, chain);
  return tipLocal >= peerTipHeight - HEADER_SYNC_NEAR_PEER_TIP;
}

export function markHeadersCurrent(tracker: ProjectTracker, chain: ChainParams): void {
  const state = tracker.getSyncState(chain.name);
  tracker.upsertSyncState(chain.name, {
    bestHeight: state?.bestHeight ?? 0,
    bestHash: state?.bestHash ?? chain.genesisHash,
    headerCount: tracker.headerCount(),
    syncStatus: "headers_current",
  });
  tracker.markWireCapability("headers.sync_to_tip", true, "live", "header chain at network tip");
  tracker.markWireCapability("headers.resume", true, "code", "resume header sync from SQLite");
}

export async function syncHeadersToTip(
  connection: PeerConnection,
  options: { peerHeight?: number } = {},
): Promise<number> {
  const chain = connection.chain;
  const tracker = connection.tracker;
  const targetHeight =
    options.peerHeight ??
    connection.remoteVersion?.startHeight ??
    -1;

  ensureGenesis(tracker, chain);

  if (shouldSkipHeaderDownload(tracker, chain, targetHeight)) {
    markHeadersCurrent(tracker, chain);
    return 0;
  }

  let totalStored = 0;

  while (true) {
    const state = tracker.getSyncState(chain.name);
    const bestHeight = state?.bestHeight ?? 0;
    const locator = nextLocator(tracker, chain);

    if (shouldSkipHeaderDownload(tracker, chain, targetHeight)) {
      markHeadersCurrent(tracker, chain);
      return totalStored;
    }

    const message = await connection.requestHeaders(locator);
    const batchCount = message.headers.length;

    if (headersSyncDone(bestHeight, targetHeight, batchCount)) {
      markHeadersCurrent(tracker, chain);
      break;
    }

    const [, , stored] = persistHeaders(tracker, chain, message);
    totalStored += stored;

    if (stored === 0) {
      markHeadersCurrent(tracker, chain);
      break;
    }

    const refreshed = tracker.getSyncState(chain.name);
    const updatedHeight = refreshed?.bestHeight ?? bestHeight;
    if (headersSyncDone(updatedHeight, targetHeight, batchCount)) {
      markHeadersCurrent(tracker, chain);
      break;
    }
  }

  return totalStored;
}
