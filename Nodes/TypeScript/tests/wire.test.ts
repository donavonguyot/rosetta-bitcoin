import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { getChain, TESTNET4 } from "../src/chain/params.js";
import { NativeNodeState } from "../src/runtime/nodeState.js";
import { splitManualPeerList } from "../src/endpointParse.js";
import {
  CAPABILITIES,
  CHECKPOINTS,
  checkpointStatus,
  fullNodeWireProgress,
} from "../src/wire/capabilities.js";
import { buildMessage, parseHeader, verifyChecksum } from "../src/wire/frame.js";
import { messageChecksum, readCompactSize, writeCompactSize } from "../src/wire/serialize.js";

describe("chain params", () => {
  it("resolves testnet4", () => {
    const chain = getChain("testnet4");
    expect(chain.name).toBe("testnet4");
    expect(chain.defaultPort).toBe(48_333);
    expect(chain.genesisHash).toHaveLength(64);
  });

  it("matches pybitnode testnet4 magic", () => {
    expect(TESTNET4.magic.toString("hex")).toBe("1c163f28");
  });
});

describe("wire framing", () => {
  it("round-trips message headers", () => {
    const magic = TESTNET4.magic;
    const payload = Buffer.from("payload");
    const framed = buildMessage(magic, "version", payload);
    const header = parseHeader(framed);
    expect(header.command).toBe("version");
    expect(header.length).toBe(payload.length);
    expect(verifyChecksum(payload, header.checksum)).toBe(true);
    expect(messageChecksum(payload)).toEqual(header.checksum);
  });

  it("round-trips compact-size encoding", () => {
    for (const value of [0, 12, 252, 0xfd, 0xffff, 0x1_0000, 0xffff_ffff]) {
      const encoded = writeCompactSize(value);
      const [decoded, offset] = readCompactSize(encoded, 0);
      expect(decoded).toBe(value);
      expect(offset).toBe(encoded.length);
    }
  });
});

describe("endpoint parse", () => {
  it("parses host:port pairs", () => {
    expect(splitManualPeerList("127.0.0.1:8333,example.com", 48_333)).toEqual([
      ["127.0.0.1", 8333],
      ["example.com", 48_333],
    ]);
  });
});

describe("wire capability registry", () => {
  it("defines 53 total capabilities with 43 required and 9 checkpoints", () => {
    expect(CAPABILITIES).toHaveLength(53);
    expect(CAPABILITIES.filter((cap) => cap.required)).toHaveLength(43);
    expect(CHECKPOINTS).toHaveLength(9);
  });

  it("uses binary implemented/required flags", () => {
    for (const cap of CAPABILITIES) {
      expect(typeof cap.implemented).toBe("boolean");
      expect(typeof cap.required).toBe("boolean");
    }
  });

  it("passes all checkpoints when every capability is implemented", () => {
    const capMap = Object.fromEntries(CAPABILITIES.map((cap) => [cap.id, 1]));
    const statuses = checkpointStatus(capMap);
    expect(Object.values(statuses).every((cp) => cp.required_pass)).toBe(true);
  });

  it("matches Python checkpoint_status math for seeded defaults", () => {
    const capMap = Object.fromEntries(
      CAPABILITIES.map((cap) => [cap.id, cap.implemented ? 1 : 0]),
    );
    const statuses = checkpointStatus(capMap);
    expect(statuses.cp6_serving.required_total).toBe(4);
    expect(statuses.cp6_serving.required_done).toBe(0);
    expect(statuses.cp6_serving.required_pass).toBe(false);
    expect(statuses.cp8_extensions.required_pass).toBe(true);
    expect(statuses.cp8_extensions.optional_total).toBe(4);
    expect(statuses.cp8_extensions.optional_done).toBe(3);
  });

  it("computes full_node_wire_ready from required capabilities only", () => {
    const defaults = Object.fromEntries(
      CAPABILITIES.map((cap) => [cap.id, cap.implemented ? 1 : 0]),
    );
    const progress = fullNodeWireProgress(defaults);
    expect(progress.required_total).toBe(43);
    expect(progress.checkpoints_total).toBe(9);
    expect(progress.required_done).toBeLessThan(progress.required_total);
    expect(progress.full_node_wire_ready).toBe(false);

    const allRequired = Object.fromEntries(
      CAPABILITIES.map((cap) => [cap.id, cap.required ? 1 : 0]),
    );
    expect(fullNodeWireProgress(allRequired).full_node_wire_ready).toBe(true);
  });
});

describe("project tracker wire seeding", () => {
  it("seeds wire_capabilities from registry on init", () => {
    const dir = mkdtempSync(join(tmpdir(), "tsbitnode-test-"));
    const statePath = join(dir, "test.stateDir");
    try {
      const tracker = new NativeNodeState(statePath);
      const progress = tracker.wireProgress();
      expect(progress.capabilities).toHaveLength(CAPABILITIES.length);
      expect(progress.summary.required_total).toBe(43);
      expect(progress.summary.checkpoints_total).toBe(9);
      expect(progress.summary.full_node_wire_ready).toBe(false);

      const frameBuild = progress.capabilities.find(
        (row) => row.capability_id === "frame.build",
      );
      expect(frameBuild?.implemented).toBe(1);
      tracker.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("summary matches Python hierarchical shape", () => {
    const dir = mkdtempSync(join(tmpdir(), "tsbitnode-summary-"));
    const statePath = join(dir, "summary.stateDir");
    try {
      const tracker = new NativeNodeState(statePath);
      tracker.upsertSyncState("testnet4", { syncStatus: "headers_current", bestHeight: 100 });
      const summary = tracker.summary("testnet4");
      expect(summary.chain).toBe("testnet4");
      expect(summary.sync).toBeDefined();
      expect(summary.wire.full_node_wire_ready).toBe(false);
      expect(summary.checkpoints.cp6_serving?.required_pass).toBe(false);
      expect(Array.isArray(summary.recent_events)).toBe(true);
      tracker.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
