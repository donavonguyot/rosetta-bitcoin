import { mkdtempSync, rmSync } from "node:fs";
import { Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { TESTNET4_GENESIS } from "../src/chain/genesis.js";
import { TESTNET4 } from "../src/chain/params.js";
import { Settings } from "../src/config/settings.js";
import { transactionWtxid } from "../src/consensus/witness.js";
import { ProjectTracker } from "../src/db/tracker.js";
import { BlockMessageCodec } from "../src/messages/block.js";
import {
  BlockHeaderCodec,
  GetHeadersMessageCodec,
  HeadersMessageCodec,
} from "../src/messages/headers.js";
import {
  GetDataMessageCodec,
  MSG_BLOCK,
  MSG_TX,
  MSG_WITNESS_BLOCK,
  MSG_WITNESS_TX,
  NotFoundMessageCodec,
} from "../src/messages/inventory.js";
import { TransactionMessageCodec, transactionDeserialize } from "../src/messages/transaction.js";
import { Mempool } from "../src/mempool/mempool.js";
import { BAN_HANDSHAKE_FAIL } from "../src/p2p/discovery.js";
import { PeerConnection } from "../src/p2p/peer.js";
import { buildHeadersResponse } from "../src/p2p/headerServing.js";
import {
  dispatchInboundMessage,
  handleInboundGetdata,
  serveInboundSession,
} from "../src/p2p/server.js";
import { BlockStore } from "../src/storage/blocks.js";
import { ensureGenesis } from "../src/sync/headers.js";

function height1BlockWire(genesisHeader = TESTNET4_GENESIS): [Buffer, ReturnType<typeof BlockHeaderCodec.blockHash>] {
  const header = {
    version: genesisHeader.version,
    prevBlock: BlockHeaderCodec.blockHash(genesisHeader),
    merkleRoot: Buffer.alloc(32, 0x12),
    timestamp: genesisHeader.timestamp + 600,
    bits: genesisHeader.bits,
    nonce: genesisHeader.nonce + 1,
  };
  const headerBytes = BlockHeaderCodec.serialize(header);
  return [Buffer.concat([headerBytes, Buffer.from([0x00])]), BlockHeaderCodec.blockHash(header)];
}

function peerConn(tracker: ProjectTracker): PeerConnection {
  const peer = new PeerConnection({
    host: "127.0.0.1",
    port: 49_200,
    chain: TESTNET4,
    tracker,
    protocolVersion: 70_016,
    userAgent: "/tsbitnode:test/",
  });
  peer.send = vi.fn(async () => undefined);
  return peer;
}

describe("inbound getheaders serving", () => {
  it("buildHeadersResponse returns headers after locator fork", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-gh-"));
    const tracker = new ProjectTracker(join(dir, "gh.db"));
    ensureGenesis(tracker, TESTNET4);
    const header = {
      version: TESTNET4_GENESIS.version,
      prevBlock: BlockHeaderCodec.blockHash(TESTNET4_GENESIS),
      merkleRoot: Buffer.alloc(32, 0x77),
      timestamp: TESTNET4_GENESIS.timestamp + 600,
      bits: TESTNET4_GENESIS.bits,
      nonce: TESTNET4_GENESIS.nonce + 2,
    };
    tracker.recordHeader(TESTNET4.name, {
      height: 1,
      blockHash: BlockHeaderCodec.blockHashHex(header),
      prevHash: TESTNET4.genesisHash,
      headerSerializedHex: BlockHeaderCodec.serialize(header).toString("hex"),
    });

    const reply = buildHeadersResponse(
      tracker,
      TESTNET4,
      {
        version: 70_016,
        locatorHashes: [BlockHeaderCodec.blockHash(TESTNET4_GENESIS)],
        hashStop: Buffer.alloc(32, 0),
      },
      null,
    );
    expect(reply.headers).toHaveLength(1);
    expect(BlockHeaderCodec.blockHashHex(reply.headers[0]!)).toBe(BlockHeaderCodec.blockHashHex(header));
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("dispatchInboundMessage marks serve.getheaders", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-dgh-"));
    const tracker = new ProjectTracker(join(dir, "dgh.db"));
    const genesis = ensureGenesis(tracker, TESTNET4);
    const h1 = {
      version: genesis.version,
      prevBlock: BlockHeaderCodec.blockHash(genesis),
      merkleRoot: Buffer.alloc(32, 0x77),
      timestamp: genesis.timestamp + 600,
      bits: genesis.bits,
      nonce: genesis.nonce + 2,
    };
    tracker.recordHeader(TESTNET4.name, {
      height: 1,
      blockHash: BlockHeaderCodec.blockHashHex(h1),
      prevHash: TESTNET4.genesisHash,
      headerSerializedHex: BlockHeaderCodec.serialize(h1).toString("hex"),
    });
    const blockStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
    const peer = peerConn(tracker);

    await dispatchInboundMessage(peer, {
      tracker,
      chain: TESTNET4,
      blockStore,
      command: GetHeadersMessageCodec.COMMAND,
      payload: GetHeadersMessageCodec.serialize({
        version: 70_016,
        locatorHashes: [BlockHeaderCodec.blockHash(genesis)],
        hashStop: Buffer.alloc(32, 0),
      }),
    });

    expect(peer.send).toHaveBeenCalledOnce();
    const [command, payload] = peer.send.mock.calls[0]!;
    expect(command).toBe(HeadersMessageCodec.COMMAND);
    const decoded = HeadersMessageCodec.deserialize(payload as Buffer);
    expect(decoded.headers).toHaveLength(1);
    expect(BlockHeaderCodec.blockHashHex(decoded.headers[0]!)).toBe(BlockHeaderCodec.blockHashHex(h1));
    expect(tracker.wireCapabilityMap()["serve.getheaders"]).toBe(1);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("inbound getdata block serving", () => {
  it("serves stored block bytes from BlockStore", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-gdb-"));
    const tracker = new ProjectTracker(join(dir, "gdb.db"));
    ensureGenesis(tracker, TESTNET4);
    const [payload, blockHash] = height1BlockWire();
    const blockStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
    const stored = blockStore.write(payload);
    tracker.recordHeader(TESTNET4.name, {
      height: 1,
      blockHash: Buffer.from(blockHash).reverse().toString("hex"),
      prevHash: TESTNET4.genesisHash,
      headerSerializedHex: BlockHeaderCodec.serialize(
        BlockHeaderCodec.deserialize(payload, 0)[0],
      ).toString("hex"),
    });
    tracker.recordBlock(
      TESTNET4.name,
      1,
      Buffer.from(blockHash).reverse().toString("hex"),
      stored.fileName,
      stored.offset,
      stored.size,
    );

    const peer = peerConn(tracker);
    await handleInboundGetdata(
      peer,
      tracker,
      TESTNET4,
      blockStore,
      GetDataMessageCodec.serialize({
        inventory: [{ type: MSG_BLOCK, hash: blockHash }],
      }),
    );

    expect(peer.send).toHaveBeenCalledOnce();
    const [command, wire] = peer.send.mock.calls[0]!;
    expect(command).toBe(BlockMessageCodec.COMMAND);
    expect(wire).toEqual(payload);
    expect(tracker.wireCapabilityMap()["serve.getdata.blocks"]).toBe(1);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns notfound for unknown witness block hash", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-gdnf-"));
    const tracker = new ProjectTracker(join(dir, "gdnf.db"));
    const blockStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
    const peer = peerConn(tracker);
    const want = { type: MSG_WITNESS_BLOCK, hash: Buffer.alloc(32, 0xaa) };

    await handleInboundGetdata(
      peer,
      tracker,
      TESTNET4,
      blockStore,
      GetDataMessageCodec.serialize({ inventory: [want] }),
    );

    expect(peer.send).toHaveBeenCalledOnce();
    const [command, payload] = peer.send.mock.calls[0]!;
    expect(command).toBe(NotFoundMessageCodec.COMMAND);
    expect(NotFoundMessageCodec.deserialize(payload as Buffer).inventory[0]!.hash.equals(want.hash)).toBe(true);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("does not send when inventory is empty", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-gd-empty-"));
    const tracker = new ProjectTracker(join(dir, "gd-empty.db"));
    const blockStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
    const peer = peerConn(tracker);

    await handleInboundGetdata(
      peer,
      tracker,
      TESTNET4,
      blockStore,
      GetDataMessageCodec.serialize({ inventory: [] }),
    );

    expect(peer.send).not.toHaveBeenCalled();
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns notfound when BlockStore read fails", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-gd-read-"));
    const tracker = new ProjectTracker(join(dir, "gd-read.db"));
    ensureGenesis(tracker, TESTNET4);
    const [payload, blockHash] = height1BlockWire();
    const blockStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
    const stored = blockStore.write(payload);
    tracker.recordHeader(TESTNET4.name, {
      height: 1,
      blockHash: Buffer.from(blockHash).reverse().toString("hex"),
      prevHash: TESTNET4.genesisHash,
      headerSerializedHex: BlockHeaderCodec.serialize(
        BlockHeaderCodec.deserialize(payload, 0)[0],
      ).toString("hex"),
    });
    tracker.recordBlock(
      TESTNET4.name,
      1,
      Buffer.from(blockHash).reverse().toString("hex"),
      stored.fileName,
      stored.offset,
      stored.size,
    );

    vi.spyOn(blockStore, "read").mockImplementation(() => {
      throw new Error("bad read");
    });

    const peer = peerConn(tracker);
    const iv = { type: MSG_BLOCK, hash: blockHash };
    await handleInboundGetdata(
      peer,
      tracker,
      TESTNET4,
      blockStore,
      GetDataMessageCodec.serialize({ inventory: [iv] }),
    );

    expect(peer.send).toHaveBeenCalledOnce();
    const [command, nfPayload] = peer.send.mock.calls[0]!;
    expect(command).toBe(NotFoundMessageCodec.COMMAND);
    expect(NotFoundMessageCodec.deserialize(nfPayload as Buffer).inventory[0]!.hash.equals(iv.hash)).toBe(true);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns notfound when requested hash does not match stored block", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-gd-mismatch-"));
    const tracker = new ProjectTracker(join(dir, "gd-mis.db"));
    ensureGenesis(tracker, TESTNET4);
    const [payload, blockHash] = height1BlockWire();
    const blockStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
    const stored = blockStore.write(payload);
    tracker.recordHeader(TESTNET4.name, {
      height: 1,
      blockHash: Buffer.from(blockHash).reverse().toString("hex"),
      prevHash: TESTNET4.genesisHash,
      headerSerializedHex: BlockHeaderCodec.serialize(
        BlockHeaderCodec.deserialize(payload, 0)[0],
      ).toString("hex"),
    });
    tracker.recordBlock(
      TESTNET4.name,
      1,
      Buffer.from(blockHash).reverse().toString("hex"),
      stored.fileName,
      stored.offset,
      stored.size,
    );

    const peer = peerConn(tracker);
    const wrongHash = Buffer.alloc(32, 0xfe);
    const iv = { type: MSG_WITNESS_BLOCK, hash: wrongHash };
    await handleInboundGetdata(
      peer,
      tracker,
      TESTNET4,
      blockStore,
      GetDataMessageCodec.serialize({ inventory: [iv] }),
    );

    expect(peer.send).toHaveBeenCalledOnce();
    const [command] = peer.send.mock.calls[0]!;
    expect(command).toBe(NotFoundMessageCodec.COMMAND);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("serves first block then notfound for missing second item", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-gd-mix-"));
    const tracker = new ProjectTracker(join(dir, "gd-mix.db"));
    ensureGenesis(tracker, TESTNET4);
    const [payload, blockHash] = height1BlockWire();
    const blockStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
    const stored = blockStore.write(payload);
    tracker.recordHeader(TESTNET4.name, {
      height: 1,
      blockHash: Buffer.from(blockHash).reverse().toString("hex"),
      prevHash: TESTNET4.genesisHash,
      headerSerializedHex: BlockHeaderCodec.serialize(
        BlockHeaderCodec.deserialize(payload, 0)[0],
      ).toString("hex"),
    });
    tracker.recordBlock(
      TESTNET4.name,
      1,
      Buffer.from(blockHash).reverse().toString("hex"),
      stored.fileName,
      stored.offset,
      stored.size,
    );

    const peer = peerConn(tracker);
    const missing = { type: MSG_BLOCK, hash: Buffer.alloc(32, 0xbb) };
    const good = { type: MSG_BLOCK, hash: blockHash };
    await handleInboundGetdata(
      peer,
      tracker,
      TESTNET4,
      blockStore,
      GetDataMessageCodec.serialize({ inventory: [missing, good] }),
    );

    expect(peer.send).toHaveBeenCalledTimes(2);
    expect(peer.send.mock.calls[0]![0]).toBe(BlockMessageCodec.COMMAND);
    expect(peer.send.mock.calls[0]![1]).toEqual(payload);
    expect(peer.send.mock.calls[1]![0]).toBe(NotFoundMessageCodec.COMMAND);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns notfound for tx without mempool", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-gd-ntx-"));
    const tracker = new ProjectTracker(join(dir, "gd-ntx.db"));
    const blockStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
    const peer = peerConn(tracker);
    const want = { type: MSG_TX, hash: Buffer.alloc(32, 0xaa) };

    await handleInboundGetdata(
      peer,
      tracker,
      TESTNET4,
      blockStore,
      GetDataMessageCodec.serialize({ inventory: [want] }),
    );

    expect(peer.send).toHaveBeenCalledOnce();
    expect(peer.send.mock.calls[0]![0]).toBe(NotFoundMessageCodec.COMMAND);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("serves witness tx from mempool with witness serialization", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-gd-wtx-"));
    const tracker = new ProjectTracker(join(dir, "gd-wtx.db"));
    const pool = new Mempool();
    const tx = {
      version: 2,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0xde), index: 2 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xffff_ffff,
        },
      ],
      outputs: [{ value: 4321, scriptPubKey: Buffer.from([0x51]) }],
      lockTime: 0,
      witness: [[Buffer.from([0xca, 0xfe])]],
    };
    expect(pool.add(tx)).toBe(true);
    const wtxid = transactionWtxid(tx);

    const blockStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
    const peer = peerConn(tracker);
    peer.mempool = pool;
    const want = { type: MSG_WITNESS_TX, hash: wtxid };
    await handleInboundGetdata(
      peer,
      tracker,
      TESTNET4,
      blockStore,
      GetDataMessageCodec.serialize({ inventory: [want] }),
      pool,
    );

    const txCalls = peer.send.mock.calls.filter(([command]) => command === TransactionMessageCodec.COMMAND);
    expect(txCalls).toHaveLength(1);
    const wire = txCalls[0]![1] as Buffer;
    const [got, consumed] = transactionDeserialize(wire, 0);
    expect(consumed).toBe(wire.length);
    expect(got.witness).toEqual([[Buffer.from([0xca, 0xfe])]]);
    expect(tracker.wireCapabilityMap()["serve.getdata.txs"]).toBe(1);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("serveInboundSession", () => {
  it("dispatches mocked getheaders over inbound session", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-sess-gh-"));
    const tracker = new ProjectTracker(join(dir, "sess.db"));
    const genesis = ensureGenesis(tracker, TESTNET4);
    const h1 = {
      version: genesis.version,
      prevBlock: BlockHeaderCodec.blockHash(genesis),
      merkleRoot: Buffer.alloc(32, 0x99),
      timestamp: genesis.timestamp + 601,
      bits: genesis.bits,
      nonce: genesis.nonce + 3,
    };
    tracker.recordHeader(TESTNET4.name, {
      height: 1,
      blockHash: BlockHeaderCodec.blockHashHex(h1),
      prevHash: TESTNET4.genesisHash,
      headerSerializedHex: BlockHeaderCodec.serialize(h1).toString("hex"),
    });

    const mockSend = vi.fn(async () => undefined);
    vi.spyOn(PeerConnection.prototype, "acceptInbound").mockResolvedValue(undefined);
    vi.spyOn(PeerConnection.prototype, "send").mockImplementation(mockSend);
    vi.spyOn(PeerConnection.prototype, "consumeMessages").mockImplementation(async (onMessage) => {
      await onMessage(
        GetHeadersMessageCodec.COMMAND,
        GetHeadersMessageCodec.serialize({
          version: 70_016,
          locatorHashes: [BlockHeaderCodec.blockHash(genesis)],
          hashStop: Buffer.alloc(32, 0),
        }),
      );
    });
    vi.spyOn(PeerConnection.prototype, "close").mockResolvedValue(undefined);

    const socket = new Socket();
    Object.defineProperty(socket, "remoteAddress", { value: "192.168.1.88" });
    Object.defineProperty(socket, "remotePort", { value: 50_012 });

    await serveInboundSession(socket, {
      chain: TESTNET4,
      tracker,
      settings: Settings.fromEnv(),
      blockStore: new BlockStore(join(dir, "sbin"), TESTNET4.magic),
      mempool: null,
    });

    expect(mockSend).toHaveBeenCalledOnce();
    const [command, payload] = mockSend.mock.calls[0]!;
    expect(command).toBe(HeadersMessageCodec.COMMAND);
    const decoded = HeadersMessageCodec.deserialize(payload as Buffer);
    expect(decoded.headers).toHaveLength(1);
    expect(BlockHeaderCodec.blockHashHex(decoded.headers[0]!)).toBe(BlockHeaderCodec.blockHashHex(h1));

    vi.restoreAllMocks();
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("increments ban score when inbound handshake fails for known endpoint", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-sess-ban-"));
    const tracker = new ProjectTracker(join(dir, "sess-ban.db"));
    const spy = vi.spyOn(tracker, "incrementPeerBanScore");

    vi.spyOn(PeerConnection.prototype, "acceptInbound").mockRejectedValue(new Error("handshake failed"));
    vi.spyOn(PeerConnection.prototype, "close").mockResolvedValue(undefined);

    const socket = new Socket();
    Object.defineProperty(socket, "remoteAddress", { value: "10.9.9.9" });
    Object.defineProperty(socket, "remotePort", { value: 8333 });

    await serveInboundSession(socket, {
      chain: TESTNET4,
      tracker,
      settings: Settings.fromEnv(),
      blockStore: new BlockStore(join(dir, "sbin2"), TESTNET4.magic),
      mempool: null,
    });

    expect(spy).toHaveBeenCalledOnce();
    expect(spy.mock.calls[0]).toEqual(["10.9.9.9", 8333, BAN_HANDSHAKE_FAIL]);

    vi.restoreAllMocks();
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("cp6 capability marking", () => {
  it("marks all cp6 required capabilities when exercised", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-cp6-"));
    const tracker = new ProjectTracker(join(dir, "cp6.db"));
    tracker.markWireCapability("serve.getheaders", true, "unit", "mock");
    tracker.markWireCapability("serve.getdata.blocks", true, "unit", "mock");
    tracker.markWireCapability("serve.getdata.txs", true, "unit", "mock");
    tracker.markWireCapability("serve.inv.blocks", true, "unit", "mock");
    const caps = tracker.wireCapabilityMap();
    for (const id of ["serve.getheaders", "serve.getdata.blocks", "serve.getdata.txs", "serve.inv.blocks"]) {
      expect(caps[id]).toBe(1);
    }
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });
});
