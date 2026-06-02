import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import { ProjectTracker } from "../src/db/tracker.js";
import {
  AddrMessageCodec,
  GetAddrMessageCodec,
} from "../src/messages/address.js";
import { NODE_NETWORK, type NetworkAddress } from "../src/messages/handshake.js";
import { mergePeerCandidates } from "../src/p2p/discovery.js";

describe("address messages", () => {
  it("serializes getaddr as empty payload", () => {
    expect(GetAddrMessageCodec.serialize()).toEqual(Buffer.alloc(0));
  });

  it("round-trips addr message serialization", () => {
    const address: NetworkAddress = {
      services: BigInt(NODE_NETWORK),
      ip: "203.0.113.10",
      port: 48_333,
    };
    const payload = AddrMessageCodec.serialize({ addresses: [address] });
    const restored = AddrMessageCodec.deserialize(payload);
    expect(restored.addresses).toHaveLength(1);
    expect(restored.addresses[0]?.ip).toBe("203.0.113.10");
    expect(restored.addresses[0]?.port).toBe(48_333);
  });
});

describe("peer address tracker", () => {
  it("records and lists peer addresses", () => {
    const dir = mkdtempSync(join(tmpdir(), "tsbitnode-addr-"));
    const tracker = new ProjectTracker(join(dir, "peers.db"));
    tracker.recordPeerAddress("203.0.113.10", 48_333, { services: 1, source: "getaddr" });
    tracker.recordPeerAddress("198.51.100.4", 48_333, { source: "addr" });
    const endpoints = tracker.listPeerAddressEndpoints(10);
    expect(endpoints).toContainEqual(["203.0.113.10", 48_333]);
    expect(endpoints).toContainEqual(["198.51.100.4", 48_333]);
    tracker.close();
  });

  it("excludes the PythonNode default peer from storage", () => {
    const dir = mkdtempSync(join(tmpdir(), "tsbitnode-addr-exclude-"));
    const tracker = new ProjectTracker(join(dir, "peers.db"));
    tracker.recordPeerAddress("89.167.10.150", 48_333, { source: "getaddr" });
    tracker.recordPeerAddress("203.0.113.10", 48_333, { source: "getaddr" });
    const endpoints = tracker.listPeerAddressEndpoints(10);
    expect(endpoints).not.toContainEqual(["89.167.10.150", 48_333]);
    expect(endpoints).toContainEqual(["203.0.113.10", 48_333]);
    tracker.close();
  });
});

describe("mergePeerCandidates", () => {
  it("prefers manual peers and deduplicates candidates", () => {
    const merged = mergePeerCandidates(TESTNET4, {
      manual: [["203.0.113.1", 48_333]],
      stored: [
        ["203.0.113.1", 48_333],
        ["203.0.113.2", 48_333],
      ],
      discovered: [["127.0.0.1", 48_333]],
      seeds: [["203.0.113.3", 48_333]],
    });
    expect(merged).toEqual([
      ["203.0.113.1", 48_333],
      ["203.0.113.2", 48_333],
      ["203.0.113.3", 48_333],
    ]);
  });
});
