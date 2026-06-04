import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import { NativeNodeState } from "../src/runtime/nodeState.js";
import {
  bitcoinShortTransactionId,
  BlockTxnMessageCodec,
  CompactBlockMessageCodec,
  completeCompactWithBlockTransactions,
  GetBlockTxnMessageCodec,
  mempoolShortIdTransactionMap,
  missingIndexesForGetblocktxn,
  reconstructCompactBlockWire,
  reconstructCompactTransactions,
  tryReconstructCompactBlock,
  type CompactBlockMessage,
  type PrefilledTransaction,
} from "../src/messages/compactBlock.js";
import { BlockHeaderCodec } from "../src/messages/headers.js";
import { RejectMessageCodec } from "../src/messages/reject.js";
import { SENDCMPCT_VERSION, SendCmpctMessageCodec } from "../src/messages/sendCmpct.js";
import type { BlockHeader } from "../src/types/index.js";
import type { Transaction } from "../src/messages/transaction.js";
import { Mempool } from "../src/mempool/mempool.js";
import { PeerConnection } from "../src/p2p/peer.js";

function minimalCoinbase(): Transaction {
  return {
    version: 2,
    inputs: [
      {
        previousOutput: { hash: Buffer.alloc(32, 0), index: 0xffff_ffff },
        scriptSig: Buffer.from([0x02, 0x02, 0x02, 0x02, 0x02]),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: 3_125_000_000, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
}

function minimalSpend(): Transaction {
  return {
    version: 2,
    inputs: [
      {
        previousOutput: { hash: Buffer.alloc(32, 0xab), index: 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
    ],
    outputs: [{ value: 1000, scriptPubKey: Buffer.from([0x00]) }],
    lockTime: 0,
    witness: [],
  };
}

function dummyHeader(): BlockHeader {
  return {
    version: 536_870_912,
    prevBlock: Buffer.alloc(32, 0x01),
    merkleRoot: Buffer.alloc(32, 0x02),
    timestamp: 1_700_000_000,
    bits: 0x1d00_ffff,
    nonce: 0,
  };
}

function txEqual(a: Transaction, b: Transaction): boolean {
  return CompactBlockMessageCodec.serialize({
    header: dummyHeader(),
    shortIdNonce: 0,
    shortids: [],
    prefilled: [{ index: 0, tx: a }],
  }).equals(
    CompactBlockMessageCodec.serialize({
      header: dummyHeader(),
      shortIdNonce: 0,
      shortids: [],
      prefilled: [{ index: 0, tx: b }],
    }),
  );
}

describe("sendcmpct codec", () => {
  it("round-trips low-bandwidth negotiation", () => {
    const msg = { announce: false, version: SENDCMPCT_VERSION };
    expect(SendCmpctMessageCodec.deserialize(SendCmpctMessageCodec.serialize(msg))).toEqual(msg);
  });
});

describe("reject codec", () => {
  it("round-trips reject payload", () => {
    const msg = {
      message: "tx",
      ccode: 0x10,
      reason: "invalid",
      data: Buffer.from([0x01, 0x02]),
    };
    expect(RejectMessageCodec.deserialize(RejectMessageCodec.serialize(msg))).toEqual(msg);
  });
});

describe("compact block codecs", () => {
  it("round-trips cmpctblock with shortids and prefilled txs", () => {
    const header = dummyHeader();
    const shortIdNonce = 0xaabb_ccdd_1122_3344;
    const shortids = [Buffer.alloc(6, 0x01), Buffer.alloc(6, 0x02)];
    const cb = minimalCoinbase();
    const spend = minimalSpend();
    const msg: CompactBlockMessage = {
      header,
      shortIdNonce,
      shortids,
      prefilled: [
        { index: 0, tx: cb },
        { index: 2, tx: spend },
      ],
    };
    const restored = CompactBlockMessageCodec.deserialize(CompactBlockMessageCodec.serialize(msg));
    expect(restored.header).toEqual(header);
    expect(restored.shortIdNonce).toBe(shortIdNonce);
    expect(restored.shortids.map((sid) => sid.toString("hex"))).toEqual(shortids.map((sid) => sid.toString("hex")));
    expect(restored.prefilled).toHaveLength(2);
    expect(restored.prefilled[0]!.index).toBe(0);
    expect(restored.prefilled[1]!.index).toBe(2);
    expect(txEqual(restored.prefilled[0]!.tx, cb)).toBe(true);
    expect(txEqual(restored.prefilled[1]!.tx, spend)).toBe(true);
  });

  it("rejects truncated shortid region", () => {
    const msg: CompactBlockMessage = {
      header: dummyHeader(),
      shortIdNonce: 0,
      shortids: [Buffer.alloc(6, 0x01)],
      prefilled: [{ index: 0, tx: minimalCoinbase() }],
    };
    const raw = CompactBlockMessageCodec.serialize(msg).subarray(0, -1);
    expect(() => CompactBlockMessageCodec.deserialize(raw)).toThrow();
  });

  it("round-trips getblocktxn", () => {
    const blockHash = Buffer.alloc(32, 0xcc);
    const msg = { blockHash, txnIndexes: [0, 2, 5] };
    expect(GetBlockTxnMessageCodec.deserialize(GetBlockTxnMessageCodec.serialize(msg))).toEqual(msg);
  });

  it("round-trips blocktxn", () => {
    const blockHash = Buffer.alloc(32, 0xdd);
    const txs = [minimalCoinbase(), minimalSpend()];
    const msg = { blockHash, transactions: txs };
    const restored = BlockTxnMessageCodec.deserialize(BlockTxnMessageCodec.serialize(msg));
    expect(restored.transactions).toHaveLength(2);
    expect(txEqual(restored.transactions[0]!, txs[0]!)).toBe(true);
    expect(txEqual(restored.transactions[1]!, txs[1]!)).toBe(true);
  });

  it("computes missing indexes for getblocktxn", () => {
    const header = dummyHeader();
    const nonce = 90_909;
    const coinbase = minimalCoinbase();
    const spend = minimalSpend();
    const sid = bitcoinShortTransactionId(header, nonce, spend);
    const compact: CompactBlockMessage = {
      header,
      shortIdNonce: nonce,
      shortids: [sid],
      prefilled: [{ index: 0, tx: coinbase }],
    };
    const poolMapOnlySpend = mempoolShortIdTransactionMap(compact, [spend]);
    expect(missingIndexesForGetblocktxn(compact, poolMapOnlySpend!)).toEqual([]);
    expect(missingIndexesForGetblocktxn(compact, new Map())).toEqual([1]);
  });

  it("merges blocktxn replies into compact reconstruction", () => {
    const header = dummyHeader();
    const nonce = 71_717;
    const coinbase = minimalCoinbase();
    const spend = minimalSpend();
    const sid = bitcoinShortTransactionId(header, nonce, spend);
    const compact: CompactBlockMessage = {
      header,
      shortIdNonce: nonce,
      shortids: [sid],
      prefilled: [{ index: 0, tx: coinbase }],
    };
    const merged = mempoolShortIdTransactionMap(compact, []);
    expect(merged).not.toBeNull();
    const txs = completeCompactWithBlockTransactions(compact, merged!, [1], [spend]);
    expect(txs?.map((tx, index) => (index === 0 ? txEqual(tx, coinbase) : txEqual(tx, spend)))).toEqual([
      true,
      true,
    ]);
  });

  it("reconstructs compact block wire from short id map", () => {
    const header = dummyHeader();
    const nonce = 1234;
    const coinbase = minimalCoinbase();
    const spend = minimalSpend();
    const sid = bitcoinShortTransactionId(header, nonce, spend);
    const compact: CompactBlockMessage = {
      header,
      shortIdNonce: nonce,
      shortids: [sid],
      prefilled: [{ index: 0, tx: coinbase }],
    };
    const wire = reconstructCompactBlockWire(compact, new Map([[sid.toString("hex"), spend]]));
    const [parsedHeader] = BlockHeaderCodec.deserialize(wire, 0);
    expect(parsedHeader).toEqual(header);
    const txs = reconstructCompactTransactions(compact, new Map([[sid.toString("hex"), spend]]));
    expect(tryReconstructCompactBlock(compact, [spend])).toEqual(txs);
  });
});

describe("PeerConnection compact block dispatch", () => {
  it("marks cmpctblock capability on parse-only dispatch", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-cmpct-parse-"));
    const tracker = new NativeNodeState(join(dir, "cmpct.stateDir"));
    const peer = new PeerConnection({
      host: "127.0.0.1",
      port: 48_333,
      chain: TESTNET4,
      tracker,
      protocolVersion: 70_016,
      userAgent: "/tsbitnode:test/",
    });
    const msg: CompactBlockMessage = {
      header: dummyHeader(),
      shortIdNonce: 123,
      shortids: [Buffer.alloc(6, 0xcc)],
      prefilled: [{ index: 0, tx: minimalCoinbase() }],
    };
    await peer.dispatch(CompactBlockMessageCodec.COMMAND, CompactBlockMessageCodec.serialize(msg));
    expect(tracker.wireCapabilityMap()["ext.cmpctblock"]).toBe(1);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("reconstructs cmpctblock from mempool short ids", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-cmpct-mx-"));
    const tracker = new NativeNodeState(join(dir, "cmpct-mx.stateDir"));
    const header = dummyHeader();
    const nonce = 771_771;
    const coinbase = minimalCoinbase();
    const spend = minimalSpend();
    const sid = bitcoinShortTransactionId(header, nonce, spend);
    const pool = new Mempool();
    pool.add(spend);
    const peer = new PeerConnection({
      host: "127.0.0.1",
      port: 48_333,
      chain: TESTNET4,
      tracker,
      protocolVersion: 70_016,
      userAgent: "/tsbitnode:test/",
      mempool: pool,
    });
    peer.send = vi.fn(async () => undefined);
    const msg: CompactBlockMessage = {
      header,
      shortIdNonce: nonce,
      shortids: [sid],
      prefilled: [{ index: 0, tx: coinbase }],
    };
    await peer.dispatch(CompactBlockMessageCodec.COMMAND, CompactBlockMessageCodec.serialize(msg));
    expect(peer.send).not.toHaveBeenCalled();
    const caps = tracker.listWireCapabilities().find((row) => row.capability_id === "ext.cmpctblock");
    expect(caps?.implemented).toBe(1);
    expect(caps?.notes?.toLowerCase()).toContain("reconstructed");
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("sends getblocktxn then accepts blocktxn", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-cmpct-gettxn-"));
    const tracker = new NativeNodeState(join(dir, "cmpct-gettxn.stateDir"));
    const header = dummyHeader();
    const nonce = 424_242;
    const coinbase = minimalCoinbase();
    const spend = minimalSpend();
    const sid = bitcoinShortTransactionId(header, nonce, spend);
    const peer = new PeerConnection({
      host: "127.0.0.1",
      port: 48_333,
      chain: TESTNET4,
      tracker,
      protocolVersion: 70_016,
      userAgent: "/tsbitnode:test/",
      mempool: new Mempool(),
    });
    peer.send = vi.fn(async () => undefined);
    const msg: CompactBlockMessage = {
      header,
      shortIdNonce: nonce,
      shortids: [sid],
      prefilled: [{ index: 0, tx: coinbase }],
    };
    await peer.dispatch(CompactBlockMessageCodec.COMMAND, CompactBlockMessageCodec.serialize(msg));

    expect(peer.send).toHaveBeenCalled();
    const [gbCommand, gbPayload] = peer.send.mock.calls.at(-1)!;
    expect(gbCommand).toBe(GetBlockTxnMessageCodec.COMMAND);
    const outbound = GetBlockTxnMessageCodec.deserialize(gbPayload as Buffer);
    expect(outbound.txnIndexes).toEqual([1]);
    expect(outbound.blockHash.equals(BlockHeaderCodec.blockHash(header))).toBe(true);
    expect(tracker.wireCapabilityMap()["ext.getblocktxn"]).toBe(1);

    const reply = BlockTxnMessageCodec.serialize({
      blockHash: BlockHeaderCodec.blockHash(header),
      transactions: [spend],
    });
    await peer.dispatch(BlockTxnMessageCodec.COMMAND, reply);
    const notes = tracker
      .listWireCapabilities()
      .filter((row) => row.capability_id === "ext.cmpctblock")
      .map((row) => row.notes ?? "");
    expect(notes.some((note) => note.toLowerCase().includes("blocktxn"))).toBe(true);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("parses inbound reject", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-reject-"));
    const tracker = new NativeNodeState(join(dir, "reject.stateDir"));
    const peer = new PeerConnection({
      host: "127.0.0.1",
      port: 48_333,
      chain: TESTNET4,
      tracker,
      protocolVersion: 70_016,
      userAgent: "/tsbitnode:test/",
    });
    await peer.dispatch(
      RejectMessageCodec.COMMAND,
      RejectMessageCodec.serialize({
        message: "tx",
        ccode: 0x10,
        reason: "bad-tx",
        data: Buffer.alloc(0),
      }),
    );
    expect(tracker.wireCapabilityMap()["ext.reject"]).toBe(1);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });
});
