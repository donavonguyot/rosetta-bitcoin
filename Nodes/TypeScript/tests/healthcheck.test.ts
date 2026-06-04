import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import { Settings } from "../src/config/settings.js";
import { NativeNodeState } from "../src/runtime/nodeState.js";
import {
  dockerHealthDocument,
  runHealthcheck,
  validateHealthcheckPayload,
  type HealthcheckPayload,
} from "../src/healthcheck.js";

const tempDirs: string[] = [];

afterEach(() => {
  delete process.env.DATA_DIR;
  delete process.env.CHAIN;
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
});

function tempDb(name: string): string {
  const dir = mkdtempSync(join(tmpdir(), "tsbitnode-hc-"));
  tempDirs.push(dir);
  return join(dir, name);
}

function basePayload(overrides: Partial<HealthcheckPayload> = {}): HealthcheckPayload {
  return {
    ok: true,
    healthy: true,
    sync_status: "running",
    chain: "testnet4",
    validated_height: 0,
    header_height: 0,
    block_count: 0,
    utxo_count: 0,
    peer_count: 0,
    peer_records_total: 0,
    mempool_tx_count: 0,
    mempool_size: 0,
    mempool_size_bytes: 0,
    metrics: { blocks_validated_total: 0, txs_relayed_total: 0 },
    summary: {},
    ...overrides,
  };
}

describe("healthcheck", () => {
  it("builds docker health document from tracker state", () => {
    const stateDir = tempDb("hc.stateDir");
    const settings = Settings.fromEnv({ chain: "testnet4", dataDir: stateDir });
    const tracker = new NativeNodeState(settings.dataDir);

    tracker.upsertSyncState("testnet4", { bestHeight: 100, syncStatus: "connected" });
    tracker.setMeta("mempool_tx_count", "3");
    tracker.setMeta("mempool_size_bytes", "2048");

    const doc = dockerHealthDocument(settings, tracker);
    tracker.close();

    expect(doc.validated_height).toBe(0);
    expect(doc.header_height).toBe(0);
    expect(doc.mempool_tx_count).toBe(3);
    expect(doc.mempool_size).toBe(3);
    expect(doc.mempool_size_bytes).toBe(2048);
    expect(doc.sync_progress_pct).toBe(0);
    expect(doc.metrics).toEqual({ blocks_validated_total: 0, txs_relayed_total: 0 });
    validateHealthcheckPayload(doc);
  });

  it("rejects bad metrics values", () => {
    expect(() =>
      validateHealthcheckPayload(
        basePayload({
          metrics: { blocks_validated_total: -1, txs_relayed_total: 0 },
        }),
      ),
    ).toThrow(/non-negative/);
  });

  it("accepts future metric counters", () => {
    validateHealthcheckPayload(
      basePayload({
        metrics: { blocks_validated_total: 0, txs_relayed_total: 0, future_total: 1 },
      }),
    );
  });

  it("ignores unknown top-level keys", () => {
    validateHealthcheckPayload(
      basePayload({
        future_field: { any: "thing" },
      }),
    );
  });

  it("exits 0 with JSON on stdout when healthy", async () => {
    const stateDir = tempDb("ok.stateDir");
    process.env.DATA_DIR = stateDir;
    process.env.CHAIN = "testnet4";

    const tracker = await NativeNodeState.open(Settings.fromEnv({ dataDir: stateDir }), TESTNET4, { acquireLock: false });
    tracker.upsertSyncState("testnet4", { syncStatus: "headers_current" });
    await tracker.close();

    expect(await runHealthcheck()).toBe(0);
  });

  it("exits 1 when sync_status is error", async () => {
    const stateDir = tempDb("bad.stateDir");
    process.env.DATA_DIR = stateDir;
    process.env.CHAIN = "testnet4";

    const tracker = await NativeNodeState.open(Settings.fromEnv({ dataDir: stateDir }), TESTNET4, { acquireLock: false });
    tracker.upsertSyncState("testnet4", { syncStatus: "error" });
    await tracker.close();

    expect(await runHealthcheck()).toBe(1);
  });

  it("includes last_error from meta", () => {
    const stateDir = tempDb("le.stateDir");
    const settings = Settings.fromEnv({ chain: "testnet4", dataDir: stateDir });
    const tracker = new NativeNodeState(settings.dataDir);
    tracker.upsertSyncState("testnet4", { bestHeight: 1, syncStatus: "running" });
    tracker.setMeta("last_error", "connection reset");

    const doc = dockerHealthDocument(settings, tracker);
    tracker.close();

    expect(doc.last_error).toBe("connection reset");
    validateHealthcheckPayload(doc);
  });
});
