import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  SYNC_LOCK_HELD_MESSAGE,
  SyncLockHeldError,
  acquireSyncLock,
  isProcessAlive,
  readSyncLockMetadata,
  releaseSyncLock,
  syncLockPath,
} from "../src/storage/syncLock.js";

describe("syncLock", () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  function tempDatadir(): string {
    const dir = mkdtempSync(join(tmpdir(), "ts-sync-lock-"));
    dirs.push(dir);
    return dir;
  }

  it("acquires and releases the unified lock file", () => {
    const datadir = tempDatadir();
    const handle = acquireSyncLock(datadir, { holder: "test" });
    expect(handle.path).toBe(syncLockPath(datadir));

    const metadata = readSyncLockMetadata(handle.path);
    expect(metadata?.pid).toBe(process.pid);
    expect(metadata?.holder).toBe("test");

    releaseSyncLock(handle);
    expect(readSyncLockMetadata(handle.path)).toBeNull();
  });

  it("rejects a second writer with a clear error", () => {
    const datadir = tempDatadir();
    const first = acquireSyncLock(datadir, { holder: "first" });

    try {
      expect(() => acquireSyncLock(datadir, { holder: "second" })).toThrow(SyncLockHeldError);
      try {
        acquireSyncLock(datadir, { holder: "second" });
      } catch (error) {
        expect(error).toBeInstanceOf(SyncLockHeldError);
        expect((error as SyncLockHeldError).message).toContain(SYNC_LOCK_HELD_MESSAGE);
        expect((error as SyncLockHeldError).message).toContain(String(process.pid));
      }
    } finally {
      releaseSyncLock(first);
    }
  });

  it("reclaims stale locks from dead processes", () => {
    const datadir = tempDatadir();
    const handle = acquireSyncLock(datadir, { holder: "stale-test" });
    releaseSyncLock(handle);

    const lockPath = syncLockPath(datadir);
    const stalePid = 2_000_000_000;
    expect(isProcessAlive(stalePid)).toBe(false);

    writeFileSync(lockPath, `pid=${stalePid}\nholder=dead\nstarted=2020-01-01T00:00:00.000Z\n`);

    const reclaimed = acquireSyncLock(datadir, { holder: "fresh" });
    expect(readSyncLockMetadata(reclaimed.path)?.pid).toBe(process.pid);
    releaseSyncLock(reclaimed);
  });

  it("allows batch-loop children when parent holds the lock", () => {
    const datadir = tempDatadir();
    const parent = acquireSyncLock(datadir, { holder: "syncBatchLoop" });

    const child = acquireSyncLock(datadir, {
      holder: "syncRunner",
      parentPid: process.pid,
    });
    expect(child.fd).toBe(-1);

    expect(() =>
      acquireSyncLock(datadir, {
        holder: "other",
      }),
    ).toThrow(SyncLockHeldError);

    releaseSyncLock(child);
    releaseSyncLock(parent);
  });
});
