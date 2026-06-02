import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import { transactionWtxid } from "../src/consensus/witness.js";
import { Settings } from "../src/config/settings.js";
import { ProjectTracker } from "../src/db/tracker.js";
import { FeeFilterMessageCodec } from "../src/messages/feeFilter.js";
import {
  GetDataMessageCodec,
  InvMessageCodec,
  MSG_WITNESS_TX,
  type InventoryVector,
} from "../src/messages/inventory.js";
import { sampleTx, fundUtxo } from "./helpers/scriptHelpers.js";
import { Mempool } from "../src/mempool/mempool.js";
import { PeerManager } from "../src/p2p/manager.js";
import {
  PeerConnection,
  txInventoryNeedGetdata,
} from "../src/p2p/peer.js";

class RelayPeerStub {
  peerFeeFilterSatKvb: number | null = null;
  send = vi.fn(async () => undefined);
  private connected = true;

  get isConnected(): boolean {
    return this.connected;
  }
}

describe("tx inventory helpers", () => {
  it("returns all hashes when mempool is empty", () => {
    const items: InventoryVector[] = [{ type: MSG_WITNESS_TX, hash: Buffer.alloc(32, 0x99) }];
    expect(txInventoryNeedGetdata(items, new Mempool())).toEqual(items);
  });

  it("skips hashes already in mempool", () => {
    const pool = new Mempool();
    const tx = sampleTx();
    expect(pool.add(tx)).toBe(true);
    const wtxid = transactionWtxid(tx);
    const items: InventoryVector[] = [{ type: MSG_WITNESS_TX, hash: wtxid }];
    expect(txInventoryNeedGetdata(items, pool)).toEqual([]);
  });
});

describe("PeerConnection tx relay dispatch", () => {
  it("sends getdata for missing witness tx inv", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-inv-tx-"));
    const tracker = new ProjectTracker(join(dir, "inv.db"));
    const pool = new Mempool();
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

    const invHash = Buffer.alloc(32, 0x33);
    await peer.dispatch(
      InvMessageCodec.COMMAND,
      InvMessageCodec.serialize({
        inventory: [{ type: MSG_WITNESS_TX, hash: invHash }],
      }),
    );

    expect(peer.send).toHaveBeenCalled();
    const [command, payload] = peer.send.mock.calls.at(-1)!;
    expect(command).toBe(GetDataMessageCodec.COMMAND);
    const gd = GetDataMessageCodec.deserialize(payload as Buffer);
    expect(gd.inventory).toHaveLength(1);
    expect(gd.inventory[0]!.type).toBe(MSG_WITNESS_TX);
    expect(gd.inventory[0]!.hash.equals(invHash)).toBe(true);
    expect(tracker.wireCapabilityMap()["tx.getdata.send"]).toBe(1);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("stores peer feefilter from wire message", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-feefilter-"));
    const tracker = new ProjectTracker(join(dir, "ff.db"));
    const peer = new PeerConnection({
      host: "127.0.0.1",
      port: 48_333,
      chain: TESTNET4,
      tracker,
      protocolVersion: 70_016,
      userAgent: "/tsbitnode:test/",
    });
    peer.send = vi.fn(async () => undefined);

    await peer.dispatch(FeeFilterMessageCodec.COMMAND, FeeFilterMessageCodec.serialize(2500));
    expect(peer.peerFeeFilterSatKvb).toBe(2500);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("PeerManager.relayAcceptedTransaction", () => {
  it("relays inv to peers except source", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-relay-mgr-"));
    const tracker = new ProjectTracker(join(dir, "relay.db"));
    const mgr = new PeerManager(TESTNET4, tracker, Settings.fromEnv());
    const source = new RelayPeerStub() as unknown as PeerConnection;
    const sink = new RelayPeerStub() as unknown as PeerConnection;
    mgr.connections.push(source, sink);

    const tx = sampleTx();
    await mgr.relayAcceptedTransaction(tx, source);

    expect(source.send).not.toHaveBeenCalled();
    expect(sink.send).toHaveBeenCalledOnce();
    const [command, payload] = sink.send.mock.calls[0]!;
    expect(command).toBe(InvMessageCodec.COMMAND);
    const inv = InvMessageCodec.deserialize(payload as Buffer);
    expect(inv.inventory[0]!.type).toBe(MSG_WITNESS_TX);
    expect(inv.inventory[0]!.hash.equals(transactionWtxid(tx))).toBe(true);
    expect(tracker.wireCapabilityMap()["tx.inv.send"]).toBe(1);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("skips peers whose feefilter exceeds transaction feerate", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-relay-ff-"));
    const tracker = new ProjectTracker(join(dir, "relay-ff.db"));
    const mgr = new PeerManager(TESTNET4, tracker, Settings.fromEnv());
    const source = new RelayPeerStub() as unknown as PeerConnection;
    const sink = new RelayPeerStub() as unknown as PeerConnection;
    sink.peerFeeFilterSatKvb = 1_000_000;
    mgr.connections.push(source, sink);

    const prev = Buffer.alloc(32, 0x44);
    fundUtxo(tracker, prev, 10_000);
    const tx = sampleTx(prev);
    await mgr.relayAcceptedTransaction(tx, source);

    expect(sink.send).not.toHaveBeenCalled();
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });
});
