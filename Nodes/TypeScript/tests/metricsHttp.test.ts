import { mkdtempSync, rmSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { Settings } from "../src/config/settings.js";
import { NativeNodeState } from "../src/runtime/nodeState.js";
import {
  META_BLOCKS_VALIDATED_TOTAL,
  META_TXS_RELAYED_TOTAL,
  prometheusExpositionFormat,
} from "../src/metrics.js";
import { createMetricsHttpServer } from "../src/metricsHttp.js";

const tempDirs: string[] = [];

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
});

function tempDb(name: string): string {
  const dir = mkdtempSync(join(tmpdir(), "tsbitnode-metrics-"));
  tempDirs.push(dir);
  return join(dir, name);
}

function fetchMetrics(port: number, path: string): Promise<{ statusCode: number; headers: Record<string, string | string[] | undefined>; body: string }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port,
        path,
        method: "GET",
        headers: { Connection: "close" },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
        res.on("end", () => {
          resolve({
            statusCode: res.statusCode ?? 0,
            headers: res.headers,
            body: Buffer.concat(chunks).toString("utf-8"),
          });
        });
      },
    );
    req.on("error", reject);
    req.end();
  });
}

describe("metrics HTTP", () => {
  it("prometheus exposition shape includes counters and tracker gauges", () => {
    const stateDir = tempDb("m.stateDir");
    const settings = Settings.fromEnv({ chain: "testnet4", dataDir: stateDir });
    const tracker = new NativeNodeState(settings.dataDir);
    tracker.setMeta(META_BLOCKS_VALIDATED_TOTAL, "101");
    tracker.setMeta(META_TXS_RELAYED_TOTAL, "7");
    tracker.setMeta("mempool_tx_count", "3");
    tracker.setMeta("mempool_size_bytes", "2048");
    tracker.upsertSyncState("testnet4", { bestHeight: 500, syncStatus: "running" });
    tracker.recordPeerConnected("127.0.0.1", 48333);

    const text = prometheusExpositionFormat(tracker, { chain: "testnet4" });
    tracker.close();

    const nonemptyLines = text.split("\n").filter((line) => line.trim() !== "");
    const joined = nonemptyLines.join("\n");
    for (const prefix of [
      "# HELP blocks_validated_total",
      "# TYPE blocks_validated_total counter",
      "# HELP txs_relayed_total",
      "# TYPE txs_relayed_total counter",
      "# TYPE validated_height gauge",
      "# TYPE peer_count gauge",
      "# TYPE mempool_tx_count gauge",
      "# TYPE sync_status_info gauge",
    ]) {
      expect(joined).toContain(prefix);
    }
    expect(joined).toMatch(/^blocks_validated_total\{chain="testnet4"\}\s+101\s*$/m);
    expect(joined).toMatch(/^txs_relayed_total\{chain="testnet4"\}\s+7\s*$/m);
    expect(joined).toMatch(/^mempool_tx_count\{chain="testnet4"\}\s+3\s*$/m);
    expect(joined).toMatch(/^sync_status_info\{chain="testnet4",status="running"\}\s+1\s*$/m);
  });

  it("GET /metrics returns Prometheus text", async () => {
    const stateDir = tempDb("mh.stateDir");
    const settings = Settings.fromEnv({ chain: "testnet4", dataDir: stateDir });
    const tracker = new NativeNodeState(settings.dataDir);
    tracker.setMeta(META_BLOCKS_VALIDATED_TOTAL, "42");
    tracker.setMeta(META_TXS_RELAYED_TOTAL, "9");

    const server = createMetricsHttpServer(tracker, settings);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (typeof address !== "object" || address === null) {
      throw new Error("expected bound TCP port");
    }

    try {
      const response = await fetchMetrics(address.port, "/metrics");
      expect(response.statusCode).toBe(200);
      expect(String(response.headers["content-type"] ?? "")).toContain("text/plain");
      expect(response.body).toContain("TYPE txs_relayed_total counter");
      expect(response.body).toMatch(/blocks_validated_total\{chain="testnet4"\}\s+42/);
    } finally {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
      tracker.close();
    }
  });

  it("returns 404 for unknown paths", async () => {
    const stateDir = tempDb("nf.stateDir");
    const settings = Settings.fromEnv({ chain: "testnet4", dataDir: stateDir });
    const tracker = new NativeNodeState(settings.dataDir);

    const server = createMetricsHttpServer(tracker, settings);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (typeof address !== "object" || address === null) {
      throw new Error("expected bound TCP port");
    }

    try {
      const response = await fetchMetrics(address.port, "/not-metrics");
      expect(response.statusCode).toBe(404);
      expect(response.body).toBe("Not Found");
    } finally {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
      tracker.close();
    }
  });
});
