import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

import { BlockStore } from "../storage/blocks.js";
import {
  acquireSyncLock,
  type AcquireSyncLockOptions,
  type SyncLockHandle,
} from "../storage/syncLock.js";
import type { ChainParams } from "../chain/params.js";
import type { ChainstateStore } from "./chainstate.js";
import { RocksDbChainstateStore } from "./rocksDbChainstateStore.js";

export const TSBITNODE_NATIVE_MARKER = ".tsbitnode_native_storage";

export interface ChainstateSessionOptions {
  acquireLock?: boolean;
  lock?: AcquireSyncLockOptions;
}

/**
 * Native chainstate session: opens RocksDB runtime truth for sync, proof, and
 * status. By default acquires the single-writer datadir lock; read-only status
 * may pass {@link acquireLock} `false`.
 */
export class ChainstateSession {
  private constructor(
    private readonly lockHandle: SyncLockHandle | null,
    readonly dataDir: string,
    readonly store: ChainstateStore,
    readonly blockStore: BlockStore,
  ) {}

  static nativeMarkerPath(dataDir: string): string {
    return join(resolve(dataDir), TSBITNODE_NATIVE_MARKER);
  }

  static isNativeDatadir(dataDir: string): boolean {
    return existsSync(ChainstateSession.nativeMarkerPath(dataDir));
  }

  /**
   * Opens native RocksDB chainstate and block storage under {@link dataDir}.
   * Runtime truth comes from this session; Project projections observe it later
   * and must not be read by sync or consensus code.
   */
  static async openNative(
    dataDir: string,
    chain: ChainParams,
    options: ChainstateSessionOptions = {},
  ): Promise<ChainstateSession> {
    const resolved = resolve(dataDir);
    mkdirSync(resolved, { recursive: true });

    const lockHandle =
      options.acquireLock === false
        ? null
        : acquireSyncLock(resolved, { holder: "chainstateSession", ...options.lock });
    try {
      writeFileSync(
        ChainstateSession.nativeMarkerPath(resolved),
        "native_storage=true\nbackend=rocksdb\ncodec_version=2\n",
        "utf8",
      );
      const store = await RocksDbChainstateStore.open(join(resolved, "chainstate-rocksdb"), chain.name);
      const blockStore = new BlockStore(join(resolved, "blocks"), chain.magic);
      return new ChainstateSession(lockHandle, resolved, store, blockStore);
    } catch (error) {
      lockHandle?.release();
      throw error;
    }
  }

  async close(): Promise<void> {
    try {
      await this.store.close();
    } finally {
      this.lockHandle?.release();
    }
  }
}
