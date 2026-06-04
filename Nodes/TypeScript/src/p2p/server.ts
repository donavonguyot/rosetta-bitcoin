import { createServer, type Server, type Socket } from "node:net";

import type { ChainParams } from "../chain/params.js";
import type { Settings } from "../config/settings.js";
import type { NativeNodeState } from "../runtime/nodeState.js";
import { transactionTxid } from "../consensus/merkle.js";
import {
  FEEFILTER_MIN_VERSION,
  FeeFilterMessageCodec,
  feefilterWireSatKvbFromSettings,
} from "../messages/feeFilter.js";
import { MempoolRequestMessageCodec } from "../messages/mempoolQuery.js";
import {
  BlockMessageCodec,
  blockHashFromPayload,
} from "../messages/block.js";
import {
  GetHeadersMessageCodec,
  HeadersMessageCodec,
} from "../messages/headers.js";
import {
  BLOCK_INVENTORY_TYPES,
  GetDataMessageCodec,
  InvMessageCodec,
  MSG_BLOCK,
  MSG_WITNESS_BLOCK,
  MSG_WITNESS_TX,
  NotFoundMessageCodec,
  TX_INVENTORY_TYPES,
  type InventoryVector,
} from "../messages/inventory.js";
import {
  TransactionMessageCodec,
  transactionSerialize,
  type Transaction,
} from "../messages/transaction.js";
import type { Mempool } from "../mempool/mempool.js";
import type { BlockStore } from "../storage/blocks.js";
import { buildHeadersResponse } from "./headerServing.js";
import { BAN_HANDSHAKE_FAIL } from "./discovery.js";
import {
  PeerConnection,
  broadcastWitnessBlockInv,
  replyGetdataTxInventory,
  type RelayTxAcceptedFn,
} from "./peer.js";

function normalizePeerAddress(remote: Socket["remoteAddress"] | undefined, remotePort: number | undefined): [string, number] {
  if (!remote) return ["unknown", 0];
  return [remote, remotePort ?? 0];
}

export async function handleInboundGetdata(
  peer: PeerConnection,
  tracker: NativeNodeState,
  chain: ChainParams,
  blockStore: BlockStore,
  payload: Buffer,
  mempool: Mempool | null = null,
): Promise<void> {
  const gd = GetDataMessageCodec.deserialize(payload);
  const blockTypes = new Set<number>([MSG_BLOCK, MSG_WITNESS_BLOCK]);
  const blockIvs = gd.inventory.filter((iv) => blockTypes.has(iv.type));
  const rest = gd.inventory.filter((iv) => !blockTypes.has(iv.type));

  const notFoundBlocks: InventoryVector[] = [];
  let servedBlock = false;
  for (const iv of blockIvs) {
    const row = tracker.getStoredBlockForHashHex(chain.name, Buffer.from(iv.hash).reverse().toString("hex"));
    if (row === null) {
      notFoundBlocks.push(iv);
      continue;
    }
    try {
      const fileName = `blk${String(row.file_number).padStart(5, "0")}.dat`;
      const blockBytes = blockStore.read(fileName, Number(row.file_offset), Number(row.block_size));
      if (!blockHashFromPayload(blockBytes).equals(iv.hash)) {
        notFoundBlocks.push(iv);
        continue;
      }
      await peer.send(BlockMessageCodec.COMMAND, blockBytes);
      servedBlock = true;
    } catch {
      notFoundBlocks.push(iv);
    }
  }

  if (servedBlock) {
    tracker.markWireCapability(
      "serve.getdata.blocks",
      true,
      "live",
      "served MSG_BLOCK / MSG_WITNESS_BLOCK from BlockStore",
    );
  }

  if (notFoundBlocks.length > 0) {
    await peer.send(
      NotFoundMessageCodec.COMMAND,
      NotFoundMessageCodec.serialize({ inventory: notFoundBlocks }),
    );
  }

  const txItems = rest.filter((iv) => TX_INVENTORY_TYPES.has(iv.type));
  await replyGetdataTxInventory(peer, mempool, tracker, txItems);
}

export async function dispatchInboundMessage(
  peer: PeerConnection,
  options: {
    tracker: NativeNodeState;
    chain: ChainParams;
    blockStore: BlockStore;
    mempool?: Mempool | null;
    command: string;
    payload: Buffer;
  },
): Promise<void> {
  const { tracker, chain, blockStore, mempool = null, command, payload } = options;

  if (command === GetHeadersMessageCodec.COMMAND) {
    const msg = GetHeadersMessageCodec.deserialize(payload);
    const reply = buildHeadersResponse(tracker, chain, msg, blockStore);
    await peer.send(HeadersMessageCodec.COMMAND, HeadersMessageCodec.serialize(reply));
    tracker.markWireCapability(
      "serve.getheaders",
      true,
      "live",
      `answered getheaders with ${reply.headers.length} headers`,
    );
    return;
  }

  if (command === GetDataMessageCodec.COMMAND) {
    await handleInboundGetdata(peer, tracker, chain, blockStore, payload, mempool);
    return;
  }

  await peer.dispatch(command, payload);
}

export async function serveInboundSession(
  socket: Socket,
  options: {
    chain: ChainParams;
    tracker: NativeNodeState;
    settings: Settings;
    blockStore?: BlockStore;
    mempool?: Mempool | null;
    relayTxAccepted?: RelayTxAcceptedFn | null;
  },
): Promise<void> {
  const { chain, tracker, settings, mempool = null, relayTxAccepted = null } = options;
  const blockStore = options.blockStore ?? tracker.session?.blockStore;
  if (!blockStore) {
    throw new Error("native block store unavailable");
  }
  const [host, port] = normalizePeerAddress(socket.remoteAddress, socket.remotePort);
  const state = tracker.getSyncState(chain.name);
  const peer = new PeerConnection({
    host,
    port,
    chain,
    tracker,
    protocolVersion: settings.protocolVersion,
    userAgent: settings.userAgent,
    startHeight: state?.bestHeight ?? 0,
    settings,
    pingIntervalSeconds: settings.pingIntervalSeconds,
    peerStaleSeconds: settings.peerStaleSeconds,
    mempool,
    relayTxAccepted,
  });
  peer.attachSocket(socket);

  try {
    await peer.acceptInbound();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    tracker.logEvent("p2p", `Inbound handshake failed from ${host}:${port}: ${message}`, "warning", {
      host,
      port,
    });
    if (host !== "unknown" && port > 0) {
      tracker.incrementPeerBanScore(host, port, BAN_HANDSHAKE_FAIL);
    }
    await peer.close();
    return;
  }

  try {
    await peer.consumeMessages(async (command, payload) => {
      await dispatchInboundMessage(peer, {
        tracker,
        chain,
        blockStore,
        mempool,
        command,
        payload,
      });
    });
  } finally {
    await peer.close();
  }
}

export function serveInbound(options: {
  chain: ChainParams;
  tracker: NativeNodeState;
  settings: Settings;
  blockStore?: BlockStore;
  mempool?: Mempool | null;
  relayTxAccepted?: RelayTxAcceptedFn | null;
}): Promise<Server> {
  const { chain, tracker, settings, mempool = null, relayTxAccepted = null } = options;
  const blockStore = options.blockStore ?? tracker.session?.blockStore;
  if (!blockStore) {
    return Promise.reject(new Error("native block store unavailable"));
  }
  const bindPort = settings.p2pPort || chain.defaultPort;
  const bindHost = "0.0.0.0";

  return new Promise((resolve, reject) => {
    const server = createServer((socket) => {
      const [host, port] = normalizePeerAddress(socket.remoteAddress, socket.remotePort);
      tracker.logEvent("node", `Inbound connection from ${host}:${port}`, "info");
      void serveInboundSession(socket, {
        chain,
        tracker,
        settings,
        blockStore,
        mempool,
        relayTxAccepted,
      });
    });

    server.once("error", reject);
    server.listen(bindPort, bindHost, () => {
      tracker.logEvent("node", `Inbound TCP listening on ${bindHost}:${bindPort}`, "info", {
        listen: settings.listen,
      });
      tracker.markWireCapability(
        "transport.inbound",
        true,
        "live",
        "TCP listener accepting peers",
      );
      resolve(server);
    });
  });
}

export { broadcastWitnessBlockInv };
