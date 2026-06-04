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
export const LEGACY_LOCAL_DB_NAME = ["tsbitnode", "db"].join(".");

export interface ChainstateSessionOptions {
  acquireLock?: boolean;
  lock?: AcquireSyncLockOptions;
}

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

  static async openNative(
    dataDir: string,
    chain: ChainParams,
    options: ChainstateSessionOptions = {},
  ): Promise<ChainstateSession> {
    const resolved = resolve(dataDir);
    mkdirSync(resolved, { recursive: true });
    const legacyLocalDbPath = join(resolved, LEGACY_LOCAL_DB_NAME);
    if (existsSync(legacyLocalDbPath)) {
      throw new Error(`native TypeScript datadir must not contain legacy local DB: ${legacyLocalDbPath}`);
    }

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
