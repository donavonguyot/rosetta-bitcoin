import { connect, type Socket } from "node:net";

import type { ChainParams } from "../chain/params.js";
import { Settings } from "../config/settings.js";
import type { NativeNodeState } from "../runtime/nodeState.js";
import { transactionTxid } from "../consensus/merkle.js";
import {
  buildVersionMessage,
  deserializePing,
  deserializeVersion,
  NODE_NETWORK,
  NODE_WITNESS,
  NetworkAddress,
  PING_COMMAND,
  PONG_COMMAND,
  SENDHEADERS_COMMAND,
  serializePing,
  serializePong,
  serializeSendHeaders,
  serializeVerAck,
  serializeVersion,
  VERACK_COMMAND,
  VERSION_COMMAND,
  type VersionMessage,
} from "../messages/handshake.js";
import {
  AddrMessageCodec,
  GetAddrMessageCodec,
} from "../messages/address.js";
import {
  FEEFILTER_MIN_VERSION,
  FeeFilterMessageCodec,
  feefilterWireSatKvbFromSettings,
} from "../messages/feeFilter.js";
import { MempoolRequestMessageCodec } from "../messages/mempoolQuery.js";
import {
  GetHeadersMessageCodec,
  HeadersMessageCodec,
  type HeadersMessage,
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
import { BlockMessageCodec, blockHashFromPayload } from "../messages/block.js";
import {
  BlockTxnMessageCodec,
  CompactBlockMessageCodec,
  completeCompactWithBlockTransactions,
  compactBlockHash,
  compactBlockHashHex,
  GetBlockTxnMessageCodec,
  mempoolShortIdTransactionMap,
  missingIndexesForGetblocktxn,
  reconstructCompactTransactions,
  type CompactBlockMessage,
} from "../messages/compactBlock.js";
import { RejectMessageCodec } from "../messages/reject.js";
import {
  TransactionMessageCodec,
  transactionSerialize,
  type Transaction,
} from "../messages/transaction.js";
import type { Mempool } from "../mempool/mempool.js";
import { syncHeadersToTip } from "../sync/headers.js";
import { buildHeadersResponse } from "./headerServing.js";
import { buildMessage, HEADER_SIZE, parseHeader, verifyChecksum } from "../wire/frame.js";

export const MAX_GETDATA_TX_BATCH = 1024;

export type RelayTxAcceptedFn = (tx: Transaction, source: PeerConnection) => Promise<void>;

interface PendingCompactBlockTxnRecovery {
  compact: CompactBlockMessage;
  poolShortidMap: Map<string, Transaction>;
  txnIndexesSorted: number[];
}

export interface PeerConnectionOptions {
  host: string;
  port: number;
  chain: ChainParams;
  tracker: NativeNodeState;
  protocolVersion: number;
  userAgent: string;
  startHeight?: number;
  settings?: Settings;
  pingIntervalSeconds?: number;
  peerStaleSeconds?: number;
  mempool?: Mempool | null;
  relayTxAccepted?: RelayTxAcceptedFn | null;
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, label: string): Promise<T> {
  if (timeoutMs <= 0) {
    return Promise.reject(new Error(`Timed out waiting for ${label}`));
  }
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${label}`)), timeoutMs);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

function socketRead(socket: Socket, timeoutMs: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const onData = (chunk: Buffer) => {
      cleanup();
      resolve(chunk);
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const onEnd = () => {
      cleanup();
      reject(new Error("Peer closed connection"));
    };
    const onTimeout = () => {
      cleanup();
      reject(new Error("Peer read timeout"));
    };
    const cleanup = () => {
      clearTimeout(timer);
      socket.off("data", onData);
      socket.off("error", onError);
      socket.off("end", onEnd);
      socket.off("timeout", onTimeout);
    };
    const timer = setTimeout(onTimeout, timeoutMs);
    socket.once("data", onData);
    socket.once("error", onError);
    socket.once("end", onEnd);
    socket.once("timeout", onTimeout);
  });
}

export function txInventoryNeedGetdata(
  items: InventoryVector[],
  mempool: Mempool | null,
): InventoryVector[] {
  if (mempool === null) {
    return [...items];
  }
  return items.filter((item) => mempool.getForInv(item.type, item.hash) === null);
}

export async function replyGetdataTxInventory(
  peer: PeerConnection,
  mempool: Mempool | null,
  tracker: NativeNodeState,
  inventory: InventoryVector[],
): Promise<void> {
  if (inventory.length === 0) {
    return;
  }
  const notFound: InventoryVector[] = [];
  let served = false;
  for (const iv of inventory) {
    const tx = mempool?.getForInv(iv.type, iv.hash) ?? null;
    if (tx === null) {
      notFound.push(iv);
      continue;
    }
    const includeWitness = iv.type === MSG_WITNESS_TX;
    await peer.send("tx", transactionSerialize(tx, { includeWitness }));
    served = true;
  }

  if (served) {
    tracker.markWireCapability(
      "serve.getdata.txs",
      true,
      "live",
      "served mempool tx over getdata (MSG_TX or MSG_WITNESS_TX)",
    );
  }
  if (notFound.length > 0) {
    await peer.send(
      NotFoundMessageCodec.COMMAND,
      NotFoundMessageCodec.serialize({ inventory: notFound }),
    );
  }
}

export async function broadcastWitnessBlockInv(
  peers: PeerConnection[],
  blockHash: Buffer,
  tracker: NativeNodeState,
): Promise<void> {
  const payload = InvMessageCodec.serialize({
    inventory: [{ type: MSG_WITNESS_BLOCK, hash: blockHash }],
  });
  let sent = false;
  for (const peer of peers) {
    if (!peer.isConnected) continue;
    try {
      await peer.send(InvMessageCodec.COMMAND, payload);
      sent = true;
    } catch {
      // Best-effort inv broadcast; do not fail block connect on relay errors.
    }
  }
  if (sent) {
    tracker.markWireCapability(
      "serve.inv.blocks",
      true,
      "live",
      "broadcast MSG_WITNESS_BLOCK inv on tip advance",
    );
  }
}

/** Outbound P2P: deferred advanced negotiation and honest start_height during sync. */
export class PeerConnection {
  readonly host: string;
  readonly port: number;
  readonly chain: ChainParams;
  readonly tracker: NativeNodeState;
  readonly protocolVersion: number;
  readonly userAgent: string;
  readonly startHeight: number;
  readonly settings: Settings;
  readonly pingIntervalSeconds: number;
  readonly peerStaleSeconds: number;

  mempool: Mempool | null;
  relayTxAccepted: RelayTxAcceptedFn | null;

  remoteVersion: VersionMessage | null = null;
  peerFeeFilterSatKvb: number | null = null;
  peerId = 0;

  private socket: Socket | null = null;
  private buffer = Buffer.alloc(0);
  private running = false;
  private lastActivity = 0;
  private lastPing = 0;
  private requestChain: Promise<void> = Promise.resolve();
  private pendingCompactRecovery: PendingCompactBlockTxnRecovery | null = null;
  private advancedNegotiationComplete = false;

  constructor(options: PeerConnectionOptions) {
    this.host = options.host;
    this.port = options.port;
    this.chain = options.chain;
    this.tracker = options.tracker;
    this.protocolVersion = options.protocolVersion;
    this.userAgent = options.userAgent;
    this.startHeight = options.startHeight ?? 0;
    this.settings = options.settings ?? Settings.fromEnv();
    this.pingIntervalSeconds = options.pingIntervalSeconds ?? 1200;
    this.peerStaleSeconds = options.peerStaleSeconds ?? 5400;
    this.mempool = options.mempool ?? null;
    this.relayTxAccepted = options.relayTxAccepted ?? null;
  }

  get isConnected(): boolean {
    return this.socket !== null && !this.socket.destroyed && this.socket.writable;
  }

  attachSocket(socket: Socket): void {
    const now = Date.now();
    socket.setNoDelay(true);
    this.lastActivity = now;
    this.lastPing = now;
    this.socket = socket;
  }

  async connect(): Promise<void> {
    const now = Date.now();
    this.lastActivity = now;
    this.lastPing = now;
    this.pendingCompactRecovery = null;
    this.socket = await this.openTcp();
    await this.handshakeAsInitiator();
    this.peerId = this.tracker.recordPeerConnected(
      this.host,
      this.port,
      {
        services: Number(this.remoteVersion?.services ?? 0n),
        peerVersion: this.remoteVersion?.version ?? 0,
        userAgent: this.remoteVersion?.userAgent ?? "",
        startHeight: this.remoteVersion?.startHeight ?? 0,
      },
    );
    this.markHandshakeCapabilities();
  }

  async acceptInbound(): Promise<void> {
    this.pendingCompactRecovery = null;
    await this.handshakeAsResponder();
    this.peerId = this.tracker.recordPeerConnected(
      this.host,
      this.port,
      {
        direction: "inbound",
        services: Number(this.remoteVersion?.services ?? 0n),
        peerVersion: this.remoteVersion?.version ?? 0,
        userAgent: this.remoteVersion?.userAgent ?? "",
        startHeight: this.remoteVersion?.startHeight ?? 0,
      },
    );
    this.markHandshakeCapabilities();
  }

  async discoverPeers(): Promise<void> {
    try {
      await this.send(GetAddrMessageCodec.COMMAND, GetAddrMessageCodec.serialize());
      this.tracker.markWireCapability(
        "discovery.getaddr",
        true,
        "live",
        `sent getaddr to ${this.host}:${this.port}`,
      );
      let payload: Buffer;
      try {
        payload = await this.readUntilCommand(AddrMessageCodec.COMMAND, 4);
      } catch {
        return;
      }
      let message;
      try {
        message = AddrMessageCodec.deserialize(payload);
      } catch {
        return;
      }
      for (const address of message.addresses) {
        this.tracker.recordPeerAddress(address.ip, address.port, {
          services: address.services,
          source: "getaddr",
        });
      }
      if (message.addresses.length > 0) {
        this.tracker.markWireCapability(
          "discovery.addr.recv",
          true,
          "live",
          `received addr with ${message.addresses.length} entries from ${this.host}:${this.port}`,
        );
      }
    } catch {
      // Best-effort discovery; keep peer connected for sync.
    }
  }

  async requestHeaders(locator: Buffer[], hashStop: Buffer = Buffer.alloc(32, 0)): Promise<HeadersMessage> {
    const msg = {
      version: this.protocolVersion,
      locatorHashes: locator,
      hashStop,
    };
    await this.send(GetHeadersMessageCodec.COMMAND, GetHeadersMessageCodec.serialize(msg));
    this.tracker.markWireCapability(
      "headers.getheaders.send",
      true,
      "live",
      `sent getheaders to ${this.host}:${this.port}`,
    );
    const payload = await this.readUntilCommand(HeadersMessageCodec.COMMAND, 120);
    this.tracker.markWireCapability(
      "headers.headers.recv",
      true,
      "live",
      `received headers from ${this.host}:${this.port}`,
    );
    return HeadersMessageCodec.deserialize(payload);
  }

  async syncHeaders(options: { stopHeight?: number } = {}): Promise<number> {
    const stored = await syncHeadersToTip(
      this,
      options.stopHeight === undefined ? {} : { stopHeight: options.stopHeight },
    );
    if (stored > 0) {
      const state = this.tracker.getSyncState(this.chain.name);
      this.tracker.logEvent(
        "sync",
        `Header sync stored ${stored} headers (tip height ${state?.bestHeight ?? 0})`,
        "info",
        { host: this.host, port: this.port },
      );
    }
    return stored;
  }

  async requestBlock(blockHash: Buffer, timeoutSeconds = 120): Promise<Buffer | null> {
    let result: Buffer | null = null;
    const run = this.requestChain.then(async () => {
      for (const invType of [MSG_WITNESS_BLOCK, MSG_BLOCK]) {
        const payload = await this.requestBlockOnce(blockHash, invType, timeoutSeconds);
        if (payload !== null) {
          result = payload;
          return;
        }
      }
    });
    this.requestChain = run.then(
      () => undefined,
      () => undefined,
    );
    await run;
    return result;
  }

  async requestBlocks(blockHashes: Buffer[], timeoutSeconds = 120): Promise<Array<Buffer | null>> {
    const result: Array<Buffer | null> = new Array(blockHashes.length).fill(null);
    const run = this.requestChain.then(async () => {
      for (const invType of [MSG_WITNESS_BLOCK, MSG_BLOCK]) {
        const pending: Buffer[] = [];
        const pendingIndexes: number[] = [];
        for (let index = 0; index < blockHashes.length; index += 1) {
          if (result[index] !== null) continue;
          pending.push(blockHashes[index]!);
          pendingIndexes.push(index);
        }
        if (pending.length === 0) return;
        const payloads = await this.requestBlocksOnce(pending, invType, timeoutSeconds);
        for (let index = 0; index < payloads.length; index += 1) {
          const payload = payloads[index];
          if (payload !== null && payload !== undefined) {
            result[pendingIndexes[index]!] = payload;
          }
        }
      }
    });
    this.requestChain = run.then(
      () => undefined,
      () => undefined,
    );
    await run;
    return result;
  }

  markBlockDownloadCapabilities(): void {
    this.tracker.markWireCapability(
      "blocks.getdata.send",
      true,
      "live",
      `sent getdata to ${this.host}:${this.port}`,
    );
    this.tracker.markWireCapability(
      "blocks.block.recv",
      true,
      "live",
      `received block from ${this.host}:${this.port}`,
    );
  }

  private async requestBlockOnce(
    blockHash: Buffer,
    invType: number,
    timeoutSeconds: number,
  ): Promise<Buffer | null> {
    const inv: InventoryVector = { type: invType, hash: blockHash };
    const getdata = { inventory: [inv] };
    await this.send(GetDataMessageCodec.COMMAND, GetDataMessageCodec.serialize(getdata));
    this.tracker.markWireCapability(
      "blocks.getdata.send",
      true,
      "live",
      `sent getdata to ${this.host}:${this.port}`,
    );

    const deadline = Date.now() + timeoutSeconds * 1000;
    while (Date.now() < deadline) {
      const remainingMs = deadline - Date.now();
      const [command, payload] = await withTimeout(
        this.readMessage(remainingMs / 1000),
        remainingMs,
        BlockMessageCodec.COMMAND,
      );
      this.touchActivity();
      if (command === BlockMessageCodec.COMMAND) {
        const receivedHash = blockHashFromPayload(payload);
        if (!receivedHash.equals(blockHash)) {
          this.tracker.logEvent("sync", "Block hash mismatch on download", "warning", {
            expected: Buffer.from(blockHash).reverse().toString("hex"),
            received: Buffer.from(receivedHash).reverse().toString("hex"),
          });
          return null;
        }
        this.tracker.markWireCapability(
          "blocks.block.recv",
          true,
          "live",
          `received block from ${this.host}:${this.port}`,
        );
        return payload;
      }
      if (command === NotFoundMessageCodec.COMMAND) {
        const missing = NotFoundMessageCodec.deserialize(payload);
        if (missing.inventory.some((item) => item.hash.equals(blockHash))) {
          this.tracker.markWireCapability(
            "blocks.notfound",
            true,
            "live",
            `peer returned notfound for block at ${this.host}:${this.port}`,
          );
          this.tracker.logEvent("sync", "Peer returned notfound for block", "warning", {
            hash: Buffer.from(blockHash).reverse().toString("hex"),
            host: this.host,
            inv_type: invType,
          });
          return null;
        }
        continue;
      }
      if (command === GetHeadersMessageCodec.COMMAND) {
        continue;
      }
      if (command === PING_COMMAND) {
        const nonce = deserializePing(payload);
        await this.send(PONG_COMMAND, serializePong(nonce));
        continue;
      }
      await this.dispatch(command, payload);
    }
    return null;
  }

  private async requestBlocksOnce(
    blockHashes: Buffer[],
    invType: number,
    timeoutSeconds: number,
  ): Promise<Array<Buffer | null>> {
    const result: Array<Buffer | null> = new Array(blockHashes.length).fill(null);
    const pending = new Set(blockHashes.map((_, index) => index));
    const inventory = blockHashes.map((hash): InventoryVector => ({ type: invType, hash }));

    await this.send(GetDataMessageCodec.COMMAND, GetDataMessageCodec.serialize({ inventory }));
    this.tracker.markWireCapability(
      "blocks.getdata.send",
      true,
      "live",
      `sent getdata batch=${inventory.length} to ${this.host}:${this.port}`,
    );

    const deadline = Date.now() + timeoutSeconds * 1000;
    while (pending.size > 0 && Date.now() < deadline) {
      const remainingMs = deadline - Date.now();
      const [command, payload] = await withTimeout(
        this.readMessage(remainingMs / 1000),
        remainingMs,
        BlockMessageCodec.COMMAND,
      );
      this.touchActivity();
      if (command === BlockMessageCodec.COMMAND) {
        const receivedHash = blockHashFromPayload(payload);
        const index = blockHashes.findIndex((hash, candidateIndex) =>
          pending.has(candidateIndex) && hash.equals(receivedHash),
        );
        if (index === -1) {
          this.tracker.logEvent("sync", "Unexpected block hash in batched download", "warning", {
            received: Buffer.from(receivedHash).reverse().toString("hex"),
          });
          continue;
        }
        result[index] = payload;
        pending.delete(index);
        this.tracker.markWireCapability(
          "blocks.block.recv",
          true,
          "live",
          `received block from ${this.host}:${this.port}`,
        );
        continue;
      }
      if (command === NotFoundMessageCodec.COMMAND) {
        const missing = NotFoundMessageCodec.deserialize(payload);
        for (const item of missing.inventory) {
          const index = blockHashes.findIndex((hash, candidateIndex) =>
            pending.has(candidateIndex) && hash.equals(item.hash),
          );
          if (index !== -1) {
            pending.delete(index);
            this.tracker.markWireCapability(
              "blocks.notfound",
              true,
              "live",
              `peer returned notfound for block at ${this.host}:${this.port}`,
            );
          }
        }
        continue;
      }
      if (command === GetHeadersMessageCodec.COMMAND) {
        continue;
      }
      if (command === PING_COMMAND) {
        const nonce = deserializePing(payload);
        await this.send(PONG_COMMAND, serializePong(nonce));
        continue;
      }
      await this.dispatch(command, payload);
    }
    return result;
  }

  async close(): Promise<void> {
    this.running = false;
    if (this.socket && !this.socket.destroyed) {
      this.socket.destroy();
    }
    this.socket = null;
    if (this.peerId) {
      this.tracker.recordPeerDisconnected(this.peerId);
      this.peerId = 0;
    }
  }

  async send(command: string, payload: Buffer = Buffer.alloc(0)): Promise<void> {
    const socket = this.socket;
    if (!socket || socket.destroyed) {
      throw new Error("Peer is not connected");
    }
    const frame = buildMessage(this.chain.magic, command, payload);
    await new Promise<void>((resolve, reject) => {
      socket.write(frame, (error) => (error ? reject(error) : resolve()));
    });
    this.tracker.logEvent("p2p", `Sent ${command}`, "info", { host: this.host, port: this.port });
  }

  async readMessage(timeoutSeconds = 60): Promise<[string, Buffer]> {
    const timeoutMs = Math.max(1, Math.floor(timeoutSeconds * 1000));
    while (true) {
      if (this.buffer.length >= HEADER_SIZE) {
        const header = parseHeader(this.buffer.subarray(0, HEADER_SIZE));
        const total = HEADER_SIZE + header.length;
        if (this.buffer.length >= total) {
          const frame = this.buffer.subarray(0, total);
          this.buffer = this.buffer.subarray(total);
          const payload = frame.subarray(HEADER_SIZE);
          if (!header.magic.equals(this.chain.magic)) {
            throw new Error(`Unexpected network magic ${header.magic.toString("hex")}`);
          }
          if (!verifyChecksum(payload, header.checksum)) {
            throw new Error(`Checksum mismatch for ${header.command}`);
          }
          return [header.command, payload];
        }
      }

      const socket = this.socket;
      if (!socket || socket.destroyed) {
        throw new Error("Peer closed connection");
      }
      const chunk = await socketRead(socket, timeoutMs);
      if (chunk.length === 0) {
        throw new Error("Peer closed connection");
      }
      this.buffer = Buffer.concat([this.buffer, chunk]);
    }
  }

  async consumeMessages(onMessage: (command: string, payload: Buffer) => Promise<void>): Promise<void> {
    this.running = true;
    while (this.running) {
      try {
        const [command, payload] = await this.readMessage(30);
        this.touchActivity();
        await onMessage(command, payload);
      } catch (error) {
        if (!this.running) return;
        const message = error instanceof Error ? error.message : String(error);
        if (message.includes("Timed out") || message.includes("timeout")) {
          await this.keepaliveTick();
          continue;
        }
        throw error;
      }
    }
  }

  async run(): Promise<void> {
    await this.consumeMessages(async (command, payload) => this.dispatch(command, payload));
  }

  private openTcp(): Promise<Socket> {
    return new Promise((resolve, reject) => {
      const socket = connect(
        { host: this.host, port: this.port, timeout: 30_000 },
        () => {
          socket.setNoDelay(true);
          resolve(socket);
        },
      );
      socket.once("error", reject);
    });
  }

  private skipSendHeaders(): boolean {
    return Boolean(this.settings.noHeaderRefresh || this.settings.syncSkipHeaders);
  }

  private deferAdvancedNegotiation(): boolean {
    // Deferred advanced negotiation: initial sync stays on the simple
    // version/verack/sendheaders path until headers are current. Relay-oriented
    // messages such as feefilter and mempool can make a lagging node look more
    // capable than its validated chainstate. See Nodes/Shared/CODE_DOCUMENTATION.md.
    if (this.settings.simpleHandshake) {
      return true;
    }
    if (this.skipSendHeaders()) {
      return true;
    }
    const state = this.tracker.getSyncState(this.chain.name);
    const status = state?.syncStatus ?? "starting";
    return status !== "headers_current" && status !== "running";
  }

  async runAdvancedNegotiation(outbound: boolean): Promise<void> {
    if (this.advancedNegotiationComplete) {
      return;
    }
    const remote = this.remoteVersion;
    const relayOn = remote === null || remote.relay;

    // BIP152 sendcmpct and BIP339 wtxidrelay are intentionally omitted until wired end-to-end.

    if (outbound && remote && remote.version >= FEEFILTER_MIN_VERSION) {
      const wireKvb = feefilterWireSatKvbFromSettings(this.settings);
      await this.send(FeeFilterMessageCodec.COMMAND, FeeFilterMessageCodec.serialize(wireKvb));
      this.tracker.markWireCapability(
        "tx.feefilter",
        true,
        "live",
        `sent outbound feefilter (${wireKvb} sat/kvB)`,
      );
    }

    if (relayOn) {
      await this.send(MempoolRequestMessageCodec.COMMAND, MempoolRequestMessageCodec.serialize());
      this.tracker.markWireCapability(
        "tx.mempool",
        true,
        "live",
        "sent mempool command (BIP35)",
      );
    }

    this.advancedNegotiationComplete = true;
  }

  async postVerackNegotiation(outbound: boolean): Promise<void> {
    if (outbound && this.deferAdvancedNegotiation()) {
      return;
    }
    await this.runAdvancedNegotiation(outbound);
  }

  async completeDeferredHandshake(): Promise<void> {
    // Called only after the caller has established that deferred advanced
    // negotiation is safe for this runtime mode. Batch sync paths keep it
    // deferred; live LISTEN mode may complete it after headers_current.
    if (this.advancedNegotiationComplete || !this.isConnected) {
      return;
    }
    await this.runAdvancedNegotiation(true);
  }

  async handshakeAsInitiator(): Promise<void> {
    // Simple path: version/verack/(sendheaders); relay messages deferred until headers_current.
    const recvAddr: NetworkAddress = {
      services: BigInt(NODE_NETWORK | NODE_WITNESS),
      ip: "0.0.0.0",
      port: 0,
    };
    const fromAddr: NetworkAddress = {
      services: BigInt(NODE_NETWORK | NODE_WITNESS),
      ip: "0.0.0.0",
      port: 0,
    };
    const version = buildVersionMessage({
      protocolVersion: this.protocolVersion,
      services: BigInt(NODE_NETWORK | NODE_WITNESS),
      addrRecv: recvAddr,
      addrFrom: fromAddr,
      userAgent: this.userAgent,
      startHeight: this.startHeight,
    });
    await this.send(VERSION_COMMAND, serializeVersion(version));
    await this.readUntilCommand(VERSION_COMMAND);
    await this.send(VERACK_COMMAND, serializeVerAck());
    await this.readUntilCommand(VERACK_COMMAND);
    if (!this.skipSendHeaders()) {
      await this.send(SENDHEADERS_COMMAND, serializeSendHeaders());
    }
    await this.postVerackNegotiation(true);
    this.tracker.logEvent(
      "p2p",
      `Handshake complete with ${this.host}:${this.port}`,
      "info",
      { userAgent: this.remoteVersion?.userAgent ?? "?" },
    );
  }

  async handshakeAsResponder(): Promise<void> {
    const recvAddr: NetworkAddress = {
      services: BigInt(NODE_NETWORK | NODE_WITNESS),
      ip: "0.0.0.0",
      port: 0,
    };
    const fromAddr: NetworkAddress = {
      services: BigInt(NODE_NETWORK | NODE_WITNESS),
      ip: "0.0.0.0",
      port: 0,
    };
    await this.readUntilCommand(VERSION_COMMAND);
    const version = buildVersionMessage({
      protocolVersion: this.protocolVersion,
      services: BigInt(NODE_NETWORK | NODE_WITNESS),
      addrRecv: recvAddr,
      addrFrom: fromAddr,
      userAgent: this.userAgent,
      startHeight: this.startHeight,
    });
    await this.send(VERSION_COMMAND, serializeVersion(version));
    await this.send(VERACK_COMMAND, serializeVerAck());
    await this.readUntilCommand(VERACK_COMMAND);
    await this.send(SENDHEADERS_COMMAND, serializeSendHeaders());
    await this.postVerackNegotiation(false);
    this.tracker.logEvent(
      "p2p",
      `Inbound handshake complete with ${this.host}:${this.port}`,
      "info",
      { userAgent: this.remoteVersion?.userAgent ?? "?" },
    );
  }

  private async readUntilCommand(command: string, timeoutSeconds = 30): Promise<Buffer> {
    const deadline = Date.now() + timeoutSeconds * 1000;
    while (true) {
      const remainingMs = deadline - Date.now();
      if (remainingMs <= 0) {
        throw new Error(`Timed out waiting for ${JSON.stringify(command)}`);
      }
      const [msgCommand, payload] = await withTimeout(
        this.readMessage(remainingMs / 1000),
        remainingMs,
        command,
      );
      this.touchActivity();
      if (msgCommand === command) {
        if (command === VERSION_COMMAND) {
          this.remoteVersion = deserializeVersion(payload);
        }
        return payload;
      }
      await this.dispatch(msgCommand, payload);
    }
  }

  async dispatch(command: string, payload: Buffer): Promise<void> {
    this.tracker.logEvent("p2p", `Received ${command}`, "info", {
      host: this.host,
      port: this.port,
      length: payload.length,
    });
    if (command === PING_COMMAND) {
      const nonce = deserializePing(payload);
      await this.send(PONG_COMMAND, serializePong(nonce));
    } else if (command === FeeFilterMessageCodec.COMMAND) {
      if (payload.length !== 8) {
        this.tracker.logEvent("p2p", "Malformed feefilter payload length", "warning", {
          host: this.host,
          port: this.port,
        });
        return;
      }
      try {
        this.peerFeeFilterSatKvb = FeeFilterMessageCodec.deserialize(payload);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.tracker.logEvent("p2p", `Malformed feefilter: ${message}`, "warning", {
          host: this.host,
          port: this.port,
        });
        return;
      }
      this.tracker.logEvent("p2p", "Peer feefilter received", "debug", {
        host: this.host,
        port: this.port,
        feerate_sat_kvb: this.peerFeeFilterSatKvb,
      });
    } else if (command === VERSION_COMMAND) {
      this.remoteVersion = deserializeVersion(payload);
    } else if (command === AddrMessageCodec.COMMAND) {
      const message = AddrMessageCodec.deserialize(payload);
      for (const address of message.addresses) {
        this.tracker.recordPeerAddress(address.ip, address.port, {
          services: address.services,
          source: "addr",
        });
      }
      if (message.addresses.length > 0) {
        this.tracker.markWireCapability(
          "discovery.addr.recv",
          true,
          "live",
          `received unsolicited addr with ${message.addresses.length} entries from ${this.host}:${this.port}`,
        );
      }
    } else if (command === InvMessageCodec.COMMAND) {
      const inv = InvMessageCodec.deserialize(payload);
      const txItems = inv.inventory.filter((item) => TX_INVENTORY_TYPES.has(item.type));
      if (txItems.length > 0) {
        this.tracker.markWireCapability(
          "tx.inv.recv",
          true,
          "live",
          "parsed inv with transaction vectors",
        );
        const todo = txInventoryNeedGetdata(txItems, this.mempool);
        if (todo.length > 0) {
          for (let index = 0; index < todo.length; index += MAX_GETDATA_TX_BATCH) {
            const chunk = todo.slice(index, index + MAX_GETDATA_TX_BATCH);
            await this.send(
              GetDataMessageCodec.COMMAND,
              GetDataMessageCodec.serialize({ inventory: chunk }),
            );
          }
          this.tracker.markWireCapability(
            "tx.getdata.send",
            true,
            "live",
            "getdata for tx inv hashes not yet in mempool",
          );
        }
      }
      if (inv.inventory.some((item) => BLOCK_INVENTORY_TYPES.has(item.type))) {
        this.tracker.logEvent("sync", "Block inv received", "info", {
          host: this.host,
          port: this.port,
          count: inv.inventory.length,
        });
      }
    } else if (command === GetHeadersMessageCodec.COMMAND) {
      const msg = GetHeadersMessageCodec.deserialize(payload);
      const reply = buildHeadersResponse(this.tracker, this.chain, msg, null);
      await this.send(HeadersMessageCodec.COMMAND, HeadersMessageCodec.serialize(reply));
      this.tracker.markWireCapability(
        "serve.getheaders",
        true,
        "live",
        `answered inbound getheaders with ${reply.headers.length} headers`,
      );
    } else if (command === TransactionMessageCodec.COMMAND) {
      let tx: Transaction;
      try {
        tx = TransactionMessageCodec.deserialize(payload);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.tracker.logEvent("p2p", `Malformed tx message: ${message}`, "warning", {
          host: this.host,
          port: this.port,
        });
        return;
      }
      this.tracker.markWireCapability("tx.tx.recv", true, "live", "deserialized inbound tx");
      if (this.mempool === null) {
        return;
      }
      const peerEndpoint = `${this.host}:${this.port}`;
      if (
        this.mempool.acceptTransaction(tx, {
          settings: this.settings,
          peerHost: peerEndpoint,
        })
      ) {
        this.tracker.logEvent("mempool", "Accepted incoming transaction", "info", {
          peer: peerEndpoint,
          txid: Buffer.from(transactionTxid(tx)).reverse().toString("hex"),
        });
        if (this.relayTxAccepted !== null) {
          await this.relayTxAccepted(tx, this);
        }
      } else {
        this.tracker.logEvent("mempool", "Transaction not pooled (duplicate or capacity)", "debug", {
          peer: peerEndpoint,
          txid: Buffer.from(transactionTxid(tx)).reverse().toString("hex"),
        });
      }
    } else if (command === GetDataMessageCodec.COMMAND) {
      const gd = GetDataMessageCodec.deserialize(payload);
      const pendingTx = gd.inventory.filter((item) => TX_INVENTORY_TYPES.has(item.type));
      await replyGetdataTxInventory(this, this.mempool, this.tracker, pendingTx);
    } else if (command === CompactBlockMessageCodec.COMMAND) {
      await this.dispatchCompactBlock(payload);
    } else if (command === BlockTxnMessageCodec.COMMAND) {
      await this.dispatchBlockTxn(payload);
    } else if (command === RejectMessageCodec.COMMAND) {
      await this.dispatchReject(payload);
    }
  }

  private async dispatchCompactBlock(payload: Buffer): Promise<void> {
    let compact: CompactBlockMessage;
    try {
      compact = CompactBlockMessageCodec.deserialize(payload);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.tracker.logEvent("p2p", `Malformed cmpctblock: ${message}`, "warning", {
        host: this.host,
        port: this.port,
      });
      return;
    }

    this.pendingCompactRecovery = null;
    const blockHashHex = compactBlockHashHex(compact);
    const pool = this.mempool;
    let mapped: Map<string, Transaction> | null = null;
    if (pool !== null) {
      mapped = mempoolShortIdTransactionMap(compact, pool.iterPooledTransactions());
    }

    let filled: Transaction[] | null = null;
    let awaitingBlocktxn = false;

    if (mapped !== null) {
      const miss = missingIndexesForGetblocktxn(compact, mapped);
      if (miss === null) {
        this.tracker.logEvent("p2p", "Malformed cmpctblock layout", "warning", {
          host: this.host,
          port: this.port,
          block_hash: blockHashHex,
        });
      } else if (miss.length > 0) {
        const req = [...miss].sort((a, b) => a - b);
        await this.send(
          GetBlockTxnMessageCodec.COMMAND,
          GetBlockTxnMessageCodec.serialize({
            blockHash: compactBlockHash(compact),
            txnIndexes: req,
          }),
        );
        this.pendingCompactRecovery = {
          compact,
          poolShortidMap: mapped,
          txnIndexesSorted: req,
        };
        awaitingBlocktxn = true;
        this.tracker.logEvent("p2p", "cmpctblock missing pooled txs — sent getblocktxn", "debug", {
          host: this.host,
          port: this.port,
          block_hash: blockHashHex,
          indexes_requested: req,
        });
        this.tracker.markWireCapability(
          "ext.getblocktxn",
          true,
          "live",
          "outbound getblocktxn for missing BIP152 short ids after cmpctblock",
        );
      } else {
        try {
          filled = reconstructCompactTransactions(compact, mapped);
        } catch {
          filled = null;
        }
      }
    }

    if (filled !== null) {
      this.tracker.logEvent("p2p", "Compact block reconstructed from mempool", "debug", {
        host: this.host,
        port: this.port,
        block_hash: blockHashHex,
        tx_count: filled.length,
      });
      this.tracker.markWireCapability(
        "ext.cmpctblock",
        true,
        "live",
        "reconstructed inbound cmpctblock from mempool (BIP152 wtxid short ids)",
      );
    } else if (awaitingBlocktxn) {
      this.tracker.markWireCapability(
        "ext.cmpctblock",
        true,
        "live",
        "parsed inbound cmpctblock awaiting blocktxn via getblocktxn",
      );
    } else {
      this.tracker.logEvent("p2p", "Compact block (cmpctblock) parsed", "info", {
        host: this.host,
        port: this.port,
        block_hash: blockHashHex,
        short_id_nonce: compact.shortIdNonce,
        shortid_count: compact.shortids.length,
        prefilled_count: compact.prefilled.length,
      });
      this.tracker.logEvent(
        "p2p",
        "cmpctblock not fully reconstructed (no pooled map or mempool misses)",
        "debug",
        { host: this.host, port: this.port },
      );
      this.tracker.markWireCapability(
        "ext.cmpctblock",
        true,
        "live",
        "parsed inbound cmpctblock (partial / no pool iterator or mempool misses)",
      );
    }
  }

  private async dispatchBlockTxn(payload: Buffer): Promise<void> {
    const pending = this.pendingCompactRecovery;
    let blocktxn;
    try {
      blocktxn = BlockTxnMessageCodec.deserialize(payload);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.tracker.logEvent("p2p", `Malformed blocktxn: ${message}`, "warning", {
        host: this.host,
        port: this.port,
      });
      return;
    }

    if (pending === null || !blocktxn.blockHash.equals(compactBlockHash(pending.compact))) {
      this.tracker.logEvent("p2p", "blocktxn ignored (no pending recovery or mismatched hash)", "debug", {
        host: this.host,
        port: this.port,
      });
      return;
    }

    this.pendingCompactRecovery = null;
    const merged = completeCompactWithBlockTransactions(
      pending.compact,
      pending.poolShortidMap,
      pending.txnIndexesSorted,
      blocktxn.transactions,
    );
    if (merged === null) {
      this.tracker.logEvent("p2p", "blocktxn did not complete compact reconstruction", "warning", {
        host: this.host,
        port: this.port,
        block_hash: compactBlockHashHex(pending.compact),
      });
      return;
    }

    this.tracker.logEvent("p2p", "Compact block reconstructed after blocktxn", "debug", {
      host: this.host,
      port: this.port,
      block_hash: compactBlockHashHex(pending.compact),
      tx_count: merged.length,
    });
    this.tracker.markWireCapability(
      "ext.cmpctblock",
      true,
      "live",
      "reconstructed inbound cmpctblock after getblocktxn + blocktxn (BIP152)",
    );
  }

  private async dispatchReject(payload: Buffer): Promise<void> {
    let reject;
    try {
      reject = RejectMessageCodec.deserialize(payload);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.tracker.logEvent("p2p", `Malformed reject: ${message}`, "warning", {
        host: this.host,
        port: this.port,
      });
      return;
    }

    this.tracker.logEvent("p2p", "Peer reject received", "warning", {
      host: this.host,
      port: this.port,
      rejected_command: reject.message,
      ccode: reject.ccode,
      reason: reject.reason,
      data_bytes: reject.data.length,
      data_prefix_hex: reject.data.subarray(0, 32).toString("hex"),
    });
    this.tracker.markWireCapability(
      "ext.reject",
      true,
      "live",
      "parsed inbound reject (BIP61-style)",
    );
  }

  private touchActivity(): void {
    this.lastActivity = Date.now();
    if (this.peerId) {
      this.tracker.touchPeer(this.peerId);
    }
  }

  private async keepaliveTick(): Promise<void> {
    const now = Date.now();
    if (now - this.lastActivity > this.peerStaleSeconds * 1000) {
      throw new Error("Peer stale");
    }
    if (now - this.lastPing >= this.pingIntervalSeconds * 1000) {
      this.lastPing = now;
      const nonce = BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER));
      await this.send(PING_COMMAND, serializePing(nonce));
    }
  }

  private markHandshakeCapabilities(): void {
    const caps = [
      "transport.outbound",
      "handshake.version.send",
      "handshake.version.recv",
      "handshake.verack.send",
      "handshake.verack.recv",
      "handshake.services",
    ] as const;
    for (const cap of caps) {
      this.tracker.markWireCapability(cap, true, "live", `handshake with ${this.host}:${this.port}`);
    }
    if (!this.skipSendHeaders()) {
      this.tracker.markWireCapability(
        "handshake.sendheaders",
        true,
        "live",
        `sent sendheaders to ${this.host}:${this.port}`,
      );
    }
  }
}
