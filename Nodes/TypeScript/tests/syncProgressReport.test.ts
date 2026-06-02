import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";

import { ProjectTracker } from "../src/db/tracker.js";
import {
  buildReport,
  parseBatchLogLines,
  pctToTarget,
  readValidatedHeightDb,
  validatedHeightFromLog,
} from "../src/scripts/syncProgressReport.js";

describe("syncProgressReport", () => {
  it("parses batch log markers and in-progress height", () => {
    const lines = [
      "noise",
      "=== batch 1 start_validated=4800 2026-05-25T00:00:00Z ===",
      "=== batch 1 end_validated=5000 downloaded_delta=200 exit=0 (2026-05-25T00:10:00Z) validated_delta=200 ===",
      "=== batch 2 start_validated=5000 2026-05-25T00:10:00Z ===",
    ];
    const { lastStart, lastEnd } = parseBatchLogLines(lines);
    expect(lastStart?.startValidated).toBe(5000);
    expect(lastEnd?.endValidated).toBe(5000);
    expect(validatedHeightFromLog(lastStart, lastEnd)).toBe(5000);

    const finished = [
      ...lines,
      "=== batch 2 end_validated=5200 downloaded_delta=200 exit=0 (2026-05-25T00:20:00Z) validated_delta=200 ===",
    ];
    const parsed = parseBatchLogLines(finished);
    expect(parsed.lastEnd?.endValidated).toBe(5200);
    expect(validatedHeightFromLog(parsed.lastStart, parsed.lastEnd)).toBe(5200);
  });

  it("buildReport uses db height and log batch metadata", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-sync-report-"));
    const log = join(dir, "run.log");
    writeFileSync(
      log,
      "=== batch 1 start_validated=1 2026-05-25T00:00:00Z ===\n" +
        "=== batch 1 end_validated=9999 downloaded_delta=9998 exit=0 " +
        "(2026-05-25T00:30:00Z) validated_delta=9998 ===\n",
      "utf-8",
    );
    const dbPath = join(dir, "db.sqlite");
    const tracker = new ProjectTracker(dbPath);
    tracker.setValidatedTip("testnet4", 100, "abcd".repeat(16));
    tracker.close();

    const report = buildReport({
      logPath: log,
      target: 10_000,
      dbPath,
      chain: "testnet4",
    });
    expect(report.validated_height).toBe(100);
    expect(report.pct_to_target).toBe(1);
    expect(report.last_batch_validated_delta).toBe(9998);
    expect(report.last_batch_timestamp).toBe("2026-05-25T00:30:00Z");
  });

  it("buildReport works with db only when log is missing", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-sync-report-db-"));
    const dbPath = join(dir, "db.sqlite");
    const tracker = new ProjectTracker(dbPath);
    tracker.setValidatedTip("testnet4", 42, "abcd".repeat(16));
    tracker.close();

    const report = buildReport({
      logPath: join(dir, "missing.log"),
      target: 100,
      dbPath,
      chain: "testnet4",
    });
    expect(report.validated_height).toBe(42);
    expect(report.pct_to_target).toBe(42);
  });

  it("caps pct_to_target at 100", () => {
    expect(pctToTarget(20_000, 10_000)).toBe(100);
  });

  it("errors on empty log without db", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-sync-report-empty-"));
    const log = join(dir, "empty.log");
    writeFileSync(log, "", "utf-8");
    expect(() =>
      buildReport({ logPath: log, target: 10_000, dbPath: null, chain: "testnet4" }),
    ).toThrow(/No batch start\/end markers/);
  });

  it("readValidatedHeightDb returns 0 for missing file", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-sync-report-missing-"));
    expect(readValidatedHeightDb(join(dir, "nosuch.sqlite"), "testnet4")).toBe(0);
  });
});
