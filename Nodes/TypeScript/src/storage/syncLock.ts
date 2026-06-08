import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  unlinkSync,
  writeSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";

export const SYNC_LOCK_FILENAME = ".tsbitnode_sync.lock";
export const LEGACY_SYNC_LOCK_FILENAME = ".sync_batch_loop.lock";
export const SYNC_LOCK_HELD_MESSAGE = "another sync process holds lock";
export const SYNC_LOCK_PARENT_ENV = "TSBITNODE_SYNC_LOCK_PARENT_PID";

export interface SyncLockMetadata {
  pid: number;
  holder: string;
  startedAt: string;
}

export class SyncLockHeldError extends Error {
  readonly lockPath: string;
  readonly holderPid: number | null;

  constructor(lockPath: string, holderPid: number | null = null) {
    const detail = holderPid !== null ? ` (pid ${holderPid})` : "";
    super(`${SYNC_LOCK_HELD_MESSAGE}${detail}: ${lockPath}`);
    this.name = "SyncLockHeldError";
    this.lockPath = lockPath;
    this.holderPid = holderPid;
  }
}

export interface SyncLockHandle {
  path: string;
  fd: number;
  release(): void;
}

export interface AcquireSyncLockOptions {
  holder?: string;
  /**
   * Single-writer datadir lock inheritance: a batch-loop child may reuse the
   * parent-held lock, but a separate writer must fail before it can corrupt
   * UTXO, undo, or validated-tip runtime truth.
   */
  parentPid?: number;
}

export function syncLockPath(datadir: string): string {
  return join(resolve(datadir), SYNC_LOCK_FILENAME);
}

export function legacySyncLockPath(datadir: string): string {
  return join(resolve(datadir), LEGACY_SYNC_LOCK_FILENAME);
}

export function syncLockPaths(datadir: string): readonly [string, string] {
  return [syncLockPath(datadir), legacySyncLockPath(datadir)] as const;
}

export function isProcessAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) {
    return false;
  }
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export function readSyncLockMetadata(lockPath: string): SyncLockMetadata | null {
  if (!existsSync(lockPath)) {
    return null;
  }
  try {
    const raw = readFileSync(lockPath, { encoding: "utf-8" }).trim();
    if (!raw) {
      return null;
    }
    if (/^\d+$/.test(raw)) {
      return {
        pid: Number.parseInt(raw, 10),
        holder: "unknown",
        startedAt: "",
      };
    }
    let pid: number | null = null;
    let holder = "unknown";
    let startedAt = "";
    for (const line of raw.split("\n")) {
      const eq = line.indexOf("=");
      if (eq <= 0) {
        continue;
      }
      const key = line.slice(0, eq);
      const value = line.slice(eq + 1);
      if (key === "pid") {
        pid = Number.parseInt(value, 10);
      } else if (key === "holder") {
        holder = value;
      } else if (key === "started") {
        startedAt = value;
      }
    }
    if (pid !== null && Number.isInteger(pid) && pid > 0) {
      return { pid, holder, startedAt };
    }
  } catch {
    return null;
  }
  return null;
}

function formatLockPayload(holder: string): string {
  return `pid=${process.pid}\nholder=${holder}\nstarted=${new Date().toISOString()}\n`;
}

function removeStaleLock(lockPath: string): void {
  try {
    unlinkSync(lockPath);
  } catch {
    // ignore
  }
}

function inspectExistingLock(
  lockPath: string,
  options: AcquireSyncLockOptions,
): { blocked: true; holderPid: number | null } | { blocked: false } {
  const metadata = readSyncLockMetadata(lockPath);
  if (!metadata) {
    removeStaleLock(lockPath);
    return { blocked: false };
  }

  if (metadata.pid === process.pid) {
    return { blocked: false };
  }

  if (options.parentPid !== undefined && metadata.pid === options.parentPid && isProcessAlive(metadata.pid)) {
    return { blocked: false };
  }

  if (!isProcessAlive(metadata.pid)) {
    removeStaleLock(lockPath);
    return { blocked: false };
  }

  return { blocked: true, holderPid: metadata.pid };
}

const PARENT_HELD_HANDLE: SyncLockHandle = {
  path: "",
  fd: -1,
  release() {
    // Parent batch loop owns the lock for this child process.
  },
};

export function acquireSyncLock(datadir: string, options: AcquireSyncLockOptions = {}): SyncLockHandle {
  const resolved = resolve(datadir);
  mkdirSync(resolved, { recursive: true });

  for (const existingPath of syncLockPaths(resolved)) {
    const inspection = inspectExistingLock(existingPath, options);
    if (inspection.blocked) {
      throw new SyncLockHeldError(existingPath, inspection.holderPid);
    }
  }

  const lockPath = syncLockPath(resolved);
  const parentOwnsLock =
    options.parentPid !== undefined &&
    syncLockPaths(resolved).some((path) => {
      const metadata = readSyncLockMetadata(path);
      return metadata !== null && metadata.pid === options.parentPid && isProcessAlive(metadata.pid);
    });
  if (parentOwnsLock) {
    return PARENT_HELD_HANDLE;
  }

  let fd: number;
  try {
    fd = openSync(lockPath, "wx");
  } catch {
    const metadata = readSyncLockMetadata(lockPath);
    if (metadata && isProcessAlive(metadata.pid) && metadata.pid !== process.pid) {
      throw new SyncLockHeldError(lockPath, metadata.pid);
    }
    throw new SyncLockHeldError(lockPath, metadata?.pid ?? null);
  }

  writeSync(fd, formatLockPayload(options.holder ?? "sync"));
  return {
    path: lockPath,
    fd,
    release() {
      releaseSyncLock(this);
    },
  };
}

export function releaseSyncLock(handle: SyncLockHandle): void {
  if (handle.fd < 0) {
    return;
  }
  try {
    closeSync(handle.fd);
  } catch {
    // ignore
  }
  if (handle.path) {
    try {
      unlinkSync(handle.path);
    } catch {
      // ignore
    }
  }
}

export function parseSyncLockParentPid(raw: string | undefined): number | undefined {
  if (!raw?.trim()) {
    return undefined;
  }
  const parsed = Number.parseInt(raw.trim(), 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}
