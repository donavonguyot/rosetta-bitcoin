import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import { transactionTxid } from "../src/consensus/merkle.js";
import { transactionWtxid } from "../src/consensus/witness.js";
import { Settings } from "../src/config/settings.js";
import { ProjectTracker } from "../src/db/tracker.js";
import {
  FeeFilterMessageCodec,
  feefilterWireSatKvbFromSettings,
} from "../src/messages/feeFilter.js";
import { MSG_TX, MSG_WITNESS_TX } from "../src/messages/inventory.js";
import {
  TransactionMessageCodec,
  transactionIsCoinbase,
  type Transaction,
} from "../src/messages/transaction.js";
import {
  acceptTransaction,
  collectMissingPrevouts,
  estimateTxVirtualSizeScaffold,
  Mempool,
  OrphanPool,
  prevoutKey,
  transactionMeetsPeerFeefilter,
} from "../src/mempool/mempool.js";
import * as verifyModule from "../src/consensus/script/verify.js";
import {
  fundP2pkhUtxo,
  fundUtxo,
  sampleTx,
  signedParentChildChain,
  signedP2pkhRoundtrip,
  spendPrev,
  testPubkeySec1,
} from "./helpers/scriptHelpers.js";

function withTracker(run: (tracker: ProjectTracker, dir: string) => void): void {
  const dir = mkdtempSync(join(tmpdir(), "ts-mempool-"));
  try {
    const tracker = new ProjectTracker(join(dir, "mempool.db"));
    run(tracker, dir);
    tracker.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("mempool admission", () => {
  it("rejects invalid structure", () => {
    withTracker((tracker) => {
      const coinbase: Transaction = {
        version: 2,
        inputs: [
          {
            previousOutput: { hash: Buffer.alloc(32, 0), index: 0xffff_ffff },
            scriptSig: Buffer.from([0x03]),
            sequence: 0xffff_ffff,
          },
        ],
        outputs: [{ value: 1234, scriptPubKey: Buffer.from([0x51]) }],
        lockTime: 0,
        witness: [],
      };
      expect(transactionIsCoinbase(coinbase)).toBe(true);
      expect(acceptTransaction(coinbase, tracker)).toBe(false);

      const noInputs: Transaction = {
        version: 1,
        inputs: [],
        outputs: [{ value: 1, scriptPubKey: Buffer.from([0x51]) }],
        lockTime: 0,
        witness: [],
      };
      expect(acceptTransaction(noInputs, tracker)).toBe(false);

      const noOutputs: Transaction = {
        version: 1,
        inputs: [
          {
            previousOutput: { hash: Buffer.alloc(32, 0x01), index: 0 },
            scriptSig: Buffer.alloc(0),
            sequence: 0xffff_ffff,
          },
        ],
        outputs: [],
        lockTime: 0,
        witness: [],
      };
      expect(acceptTransaction(noOutputs, tracker)).toBe(false);
    });
  });

  it("accepts valid p2pkh spend", () => {
    withTracker((tracker) => {
      const prev = Buffer.alloc(32, 0x12);
      const inputValue = 1_234_568;
      const pubkey = testPubkeySec1();
      fundP2pkhUtxo(tracker, prev, pubkey, inputValue);
      const signed = signedP2pkhRoundtrip(1n, prev, inputValue, 50_000);
      expect(acceptTransaction(signed, tracker)).toBe(true);
    });
  });

  it("rejects duplicate prevouts within tx", () => {
    withTracker((tracker) => {
      const prev = Buffer.alloc(32, 0xda);
      const inputValue = 90_000;
      const pubkey = testPubkeySec1();
      fundP2pkhUtxo(tracker, prev, pubkey, inputValue);
      const signed = signedP2pkhRoundtrip(1n, prev, inputValue, 50_000);
      const dupTx: Transaction = {
        ...signed,
        inputs: [signed.inputs[0]!, signed.inputs[0]!],
      };
      expect(acceptTransaction(dupTx, tracker)).toBe(false);
    });
  });

  it("rejects mempool prevout conflict", () => {
    withTracker((tracker) => {
      const prev = Buffer.alloc(32, 0xdb);
      const inputValue = 400_000;
      const pubkey = testPubkeySec1();
      fundP2pkhUtxo(tracker, prev, pubkey, inputValue);
      const txA = signedP2pkhRoundtrip(1n, prev, inputValue, 300_000);
      const txB = signedP2pkhRoundtrip(1n, prev, inputValue, 250_000);
      const pool = new Mempool({ tracker: null });
      expect(acceptTransaction(txA, tracker)).toBe(true);
      pool.add(txA);
      expect(
        acceptTransaction(txB, tracker, { mempoolClaimedPrevouts: pool.claimedPrevoutsFrozen() }),
      ).toBe(false);
    });
  });

  it("enforces min relay feerate", () => {
    withTracker((tracker) => {
      const prev = Buffer.alloc(32, 0xcc);
      const inputValue = 500_000;
      const pubkey = testPubkeySec1();
      fundP2pkhUtxo(tracker, prev, pubkey, inputValue);
      const policies = Settings.fromEnv({ minRelayFeerateSatVb: 50 });
      const placeholder = signedP2pkhRoundtrip(1n, prev, inputValue, inputValue / 2);
      const vbytes = estimateTxVirtualSizeScaffold(placeholder);
      const requiredFee = 50 * vbytes;
      const stingyTx = signedP2pkhRoundtrip(1n, prev, inputValue, inputValue - (requiredFee - 1));
      expect(acceptTransaction(stingyTx, tracker, { settings: policies })).toBe(false);

      const okTx = signedP2pkhRoundtrip(1n, prev, inputValue, inputValue - requiredFee);
      expect(acceptTransaction(okTx, tracker, { settings: policies })).toBe(true);
    });
  });

  it("rejects negative fee after verification stub", () => {
    withTracker((tracker) => {
      const prev = Buffer.alloc(32, 0xcf);
      fundUtxo(tracker, prev, 10_000);
      const bogus: Transaction = {
        version: 1,
        inputs: [
          {
            previousOutput: { hash: prev, index: 0 },
            scriptSig: Buffer.from([0x42]),
            sequence: 0xffff_ffff,
          },
        ],
        outputs: [{ value: 10_501, scriptPubKey: Buffer.from([0x51]) }],
        lockTime: 0,
        witness: [],
      };
      vi.spyOn(verifyModule, "verifyTransactionInput").mockImplementation(() => {});
      expect(acceptTransaction(bogus, tracker)).toBe(false);
      const sane = { ...bogus, outputs: [{ value: 9000, scriptPubKey: Buffer.from([0x51]) }] };
      expect(acceptTransaction(sane, tracker)).toBe(true);
      vi.restoreAllMocks();
    });
  });

  it("logs tracker events on reject", () => {
    withTracker((tracker) => {
      acceptTransaction(sampleTx(), tracker);
      const events = tracker.recentEvents(5);
      expect(events.some((event) => event.message === "Rejected tx: unknown prevouts (not in effective UTXO view)")).toBe(
        true,
      );
    });
  });
});

describe("mempool pool", () => {
  it("add/remove roundtrip with tracker stats", () => {
    withTracker((tracker) => {
      const pool = new Mempool({ maxSizeBytes: 256 * 1024, tracker });
      const prev = Buffer.alloc(32, 0xaa);
      const inputValue = 2_500_000;
      const pubkey = testPubkeySec1();
      fundP2pkhUtxo(tracker, prev, pubkey, inputValue);
      const signed = signedP2pkhRoundtrip(1n, prev, inputValue, 100_000);
      const tid = transactionTxid(signed);
      expect(acceptTransaction(signed, tracker)).toBe(true);
      expect(pool.add(signed)).toBe(true);
      expect(pool.get(tid)).toBe(signed);
      expect(pool.totalSizeBytes()).toBeGreaterThan(0);
      expect(tracker.getMeta("mempool_tx_count")).toBe("1");
      expect(pool.remove(tid)).toBe(true);
      expect(pool.get(tid)).toBeNull();
      expect(pool.totalSizeBytes()).toBe(0);
    });
  });

  it("rejects duplicate", () => {
    const pool = new Mempool();
    const tx = sampleTx();
    expect(pool.add(tx)).toBe(true);
    expect(pool.add(tx)).toBe(false);
  });

  it("evicts oldest when over byte capacity", () => {
    const txSmall: Transaction = {
      version: 1,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0x01), index: 0 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xffff_ffff,
        },
      ],
      outputs: [{ value: 1, scriptPubKey: Buffer.alloc(0) }],
      lockTime: 0,
      witness: [],
    };
    const txOther: Transaction = {
      version: 1,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0x02), index: 0 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xffff_ffff,
        },
      ],
      outputs: [{ value: 1, scriptPubKey: Buffer.alloc(0) }],
      lockTime: 0,
      witness: [],
    };
    const oneSize = TransactionMessageCodec.serialize(txSmall).length;
    const pool = new Mempool({ maxSizeBytes: oneSize });
    const tidSmall = transactionTxid(txSmall);
    const tidOther = transactionTxid(txOther);
    expect(pool.add(txSmall)).toBe(true);
    expect(pool.add(txOther)).toBe(true);
    expect(pool.get(tidSmall)).toBeNull();
    expect(pool.get(tidOther)).toBe(txOther);
    expect(pool.totalSizeBytes()).toBeLessThanOrEqual(oneSize);
  });

  it("resolves witness vs tx inv hashes", () => {
    const pool = new Mempool();
    const tx: Transaction = {
      version: 2,
      inputs: [
        {
          previousOutput: { hash: Buffer.alloc(32, 0x11), index: 3 },
          scriptSig: Buffer.alloc(0),
          sequence: 0xffff_ffff,
        },
      ],
      outputs: [{ value: 555, scriptPubKey: Buffer.from([0x51]) }],
      lockTime: 0,
      witness: [[Buffer.from([0xaa, 0xbb])]],
    };
    expect(pool.add(tx)).toBe(true);
    const tid = transactionTxid(tx);
    const wid = transactionWtxid(tx);
    expect(tid.equals(wid)).toBe(false);
    expect(pool.getForInv(MSG_TX, tid)).toBe(tx);
    expect(pool.getForInv(MSG_WITNESS_TX, wid)).toBe(tx);
  });

  it("tracks claimed prevouts across add/remove", () => {
    withTracker((tracker) => {
      const pool = new Mempool({ tracker: null });
      const prev = Buffer.alloc(32, 0xdc);
      const inputValue = 800_000;
      const pubkey = testPubkeySec1();
      fundP2pkhUtxo(tracker, prev, pubkey, inputValue);
      const tx = signedP2pkhRoundtrip(1n, prev, inputValue, 750_000);
      expect(pool.add(tx)).toBe(true);
      expect(pool.claimedPrevoutsFrozen().has(prevoutKey(prev, 0))).toBe(true);
      expect(pool.remove(transactionTxid(tx))).toBe(true);
      expect(pool.claimedPrevoutsFrozen().has(prevoutKey(prev, 0))).toBe(false);
    });
  });

  it("throws on invalid constructor limits", () => {
    expect(() => new Mempool({ maxSizeBytes: 0 })).toThrow(/maxSizeBytes/);
    expect(() => new Mempool({ mempoolMaxCount: -1 })).toThrow(/mempoolMaxCount/);
  });
});

describe("orphan pool", () => {
  it("queues child until parent arrives", () => {
    withTracker((tracker) => {
      const prevA = Buffer.alloc(32, 0xf3);
      const parentAmt = 400_000;
      const pubkey = testPubkeySec1();
      fundP2pkhUtxo(tracker, prevA, pubkey, parentAmt);
      const [parent, child] = signedParentChildChain({
        prevCoin: prevA,
        coinAmt: parentAmt,
        parentToChildValue: 300_000,
        childRemainderValue: 290_000,
        privateKey: 1n,
        pubkey,
      });
      const orphans = new OrphanPool();
      const policies = Settings.fromEnv({ enableOrphanPool: true });
      const pool = new Mempool({ tracker, orphanPool: orphans, settings: policies });

      expect(
        acceptTransaction(child, tracker, {
          settings: policies,
          orphanPool: orphans,
          deferOrphans: true,
          mempoolClaimedPrevouts: pool.claimedPrevoutsFrozen(),
        }),
      ).toBe(false);
      expect(pool.claimedPrevoutsFrozen().size).toBe(0);
      expect(orphans.contains(transactionTxid(child))).toBe(true);

      expect(acceptTransaction(parent, tracker, { settings: policies, mempoolClaimedPrevouts: pool.claimedPrevoutsFrozen() })).toBe(true);
      expect(pool.add(parent)).toBe(true);

      expect(orphans.length).toBe(0);
      expect(pool.get(transactionTxid(parent))).toBe(parent);
      expect(pool.get(transactionTxid(child))).toBe(child);
    });
  });

  it("respects orphan transaction limit", () => {
    withTracker((tracker) => {
      const policies = Settings.fromEnv({ enableOrphanPool: true });
      const orphans = new OrphanPool({ maxTransactions: 1, maxSizeBytes: 256 * 1024 });
      const solo = (which: number): Transaction => ({
        version: 2,
        inputs: [
          {
            previousOutput: { hash: Buffer.alloc(32, which), index: 0 },
            scriptSig: Buffer.alloc(0),
            sequence: 0xffff_ffff,
          },
        ],
        outputs: [{ value: 1, scriptPubKey: Buffer.from([0x51]) }],
        lockTime: 0,
        witness: [],
      });
      const t1 = solo(0xfc);
      const t2 = solo(0xfd);
      expect(
        acceptTransaction(t1, tracker, { settings: policies, orphanPool: orphans, deferOrphans: true }),
      ).toBe(false);
      expect(orphans.contains(transactionTxid(t1))).toBe(true);
      expect(
        acceptTransaction(t2, tracker, { settings: policies, orphanPool: orphans, deferOrphans: true }),
      ).toBe(false);
      expect(orphans.contains(transactionTxid(t1))).toBe(true);
      expect(orphans.contains(transactionTxid(t2))).toBe(false);
    });
  });
});

describe("collectMissingPrevouts", () => {
  it("resolves overlay-only prevouts", () => {
    withTracker((tracker) => {
      const parent: Transaction = {
        version: 2,
        inputs: [
          {
            previousOutput: { hash: Buffer.alloc(32, 0xea), index: 2 },
            scriptSig: Buffer.alloc(0),
            sequence: 0xffff_ffff,
          },
        ],
        outputs: [
          { value: 777, scriptPubKey: Buffer.from([0xaa, 0xbb]) },
          { value: 333, scriptPubKey: Buffer.from([0xcc]) },
        ],
        lockTime: 0,
        witness: [],
      };
      const overlayTid = transactionTxid(parent);
      const spender: Transaction = {
        version: 2,
        inputs: [
          {
            previousOutput: { hash: overlayTid, index: 1 },
            scriptSig: Buffer.alloc(0),
            sequence: 0xffff_ffff,
          },
        ],
        outputs: [{ value: 222, scriptPubKey: Buffer.from([0x51]) }],
        lockTime: 0,
        witness: [],
      };
      expect(collectMissingPrevouts(spender, tracker)?.has(prevoutKey(overlayTid, 1))).toBe(true);
      const overlay = new Map([
        [
          prevoutKey(overlayTid, 1),
          { value: parent.outputs[1]!.value, scriptPubKeyHex: parent.outputs[1]!.scriptPubKey.toString("hex") },
        ],
      ]);
      expect(collectMissingPrevouts(spender, tracker, { mempoolUtxoOverlay: overlay })?.size).toBe(0);
    });
  });
});

describe("feefilter helpers", () => {
  it("round-trips feefilter wire codec", () => {
    const payload = FeeFilterMessageCodec.serialize(12_345);
    expect(FeeFilterMessageCodec.deserialize(payload)).toBe(12_345);
    expect(() => FeeFilterMessageCodec.deserialize(Buffer.from([0x01]))).toThrow(/8 bytes/);
  });

  it("maps settings min relay to wire sat/kvb", () => {
    expect(feefilterWireSatKvbFromSettings(Settings.fromEnv({ minRelayFeerateSatVb: 3 }))).toBe(3000);
  });

  it("evaluates peer feefilter against known fees", () => {
    withTracker((tracker) => {
      const prev = Buffer.alloc(32, 0xff);
      const inputValue = 700_000;
      fundUtxo(tracker, prev, inputValue);
      const placeholder = spendPrev(prev, inputValue / 2);
      const vbytes = estimateTxVirtualSizeScaffold(placeholder);
      const peerFilterSatKvb = 100 * 1000;
      const stingyFee = Math.floor((peerFilterSatKvb * vbytes) / 1000) - 1;
      const stingyTx = spendPrev(prev, inputValue - stingyFee);
      expect(transactionMeetsPeerFeefilter(stingyTx, tracker, peerFilterSatKvb, TESTNET4.name)).toBe(false);
      const tightFee = Math.ceil((peerFilterSatKvb * vbytes) / 1000);
      const okTx = spendPrev(prev, inputValue - tightFee);
      expect(transactionMeetsPeerFeefilter(okTx, tracker, peerFilterSatKvb, TESTNET4.name)).toBe(true);
      expect(transactionMeetsPeerFeefilter(spendPrev(prev, inputValue - 10), tracker, null, TESTNET4.name)).toBe(true);
    });
  });
});

describe("cp5 wire codecs", () => {
  it("marks transaction message codec capability", () => {
    withTracker((tracker) => {
      const tx = sampleTx();
      const payload = TransactionMessageCodec.serialize(tx);
      const restored = TransactionMessageCodec.deserialize(payload);
      expect(restored.version).toBe(tx.version);
      tracker.markWireCapability("tx.tx.recv", true, "unit", "transaction codec roundtrip");
      expect(tracker.wireCapabilityMap()["tx.tx.recv"]).toBe(1);
    });
  });

  it("marks feefilter codec capability", () => {
    withTracker((tracker) => {
      const payload = FeeFilterMessageCodec.serialize(42_500);
      expect(FeeFilterMessageCodec.deserialize(payload)).toBe(42_500);
      tracker.markWireCapability("tx.feefilter", true, "unit", "feefilter codec roundtrip");
      expect(tracker.wireCapabilityMap()["tx.feefilter"]).toBe(1);
    });
  });
});
