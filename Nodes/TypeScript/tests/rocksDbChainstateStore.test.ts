import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import rocksdb from "rocksdb";
import { describe, expect, it } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import {
  ChainstateSession,
  LEGACY_LOCAL_DB_NAME,
  TSBITNODE_NATIVE_MARKER,
} from "../src/chainstate/chainstateSession.js";
import { Settings } from "../src/config/settings.js";
import { nativeStatusDocument } from "../src/cli/nativeStatus.js";
import { metadataKey } from "../src/storage/chainstateCodecV2.js";

function tempDatadir(): string {
  return mkdtempSync(join(tmpdir(), "tsbitnode-native-"));
}

function cleanup(path: string): void {
  rmSync(path, { recursive: true, force: true });
}

function callbackVoid(fn: (callback: (error?: Error | null) => void) => void): Promise<void> {
  return new Promise((resolvePromise, reject) => {
    fn((error) => {
      if (error) reject(error);
      else resolvePromise();
    });
  });
}

async function deleteNativeCounterMetadata(dir: string, chain: string): Promise<void> {
  const db = rocksdb(join(dir, "chainstate-rocksdb"));
  await callbackVoid((callback) => db.open({ createIfMissing: false }, callback));
  try {
    for (const key of [
      `counter:headers:${chain}`,
      `counter:blocks:${chain}`,
      `counter:utxos:${chain}`,
      `max_stored_block_height:${chain}`,
    ]) {
      await callbackVoid((callback) => db.del(metadataKey(key), {}, callback));
    }
  } finally {
    await callbackVoid((callback) => db.close(callback));
  }
}

describe("RocksDB chainstate session", () => {
  it("fails closed when a native datadir contains an unapproved operational DB artifact", async () => {
    const dir = tempDatadir();
    try {
      writeFileSync(join(dir, LEGACY_LOCAL_DB_NAME), "");
      await expect(ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false })).rejects.toThrow(
        "unapproved port-local operational DB artifact",
      );
    } finally {
      cleanup(dir);
    }
  });

  it("creates native marker and persists metadata", async () => {
    const dir = tempDatadir();
    try {
      const session = await ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false });
      try {
        expect(existsSync(join(dir, TSBITNODE_NATIVE_MARKER))).toBe(true);
        expect(session.store.metadata.backendName).toBe("rocksdb");
        expect(session.store.metadata.codecVersion).toBe("2");
        expect(await session.store.metadataValue("backend_name")).toBe("rocksdb");
      } finally {
        await session.close();
      }
    } finally {
      cleanup(dir);
    }
  });

  it("commits UTXO, undo, and validated tip atomically", async () => {
    const dir = tempDatadir();
    try {
      const session = await ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false });
      try {
        const chain = TESTNET4.name;
        const blockHash = "11".repeat(32);
        const txid = "22".repeat(32);
        await session.store.commitBlock({
          chain,
          height: 1,
          blockHash,
          spentOutpoints: [],
          createdUtxos: [
            {
              txid,
              vout: 0,
              height: 1,
              value: 50_0000_0000n,
              scriptPubKey: Buffer.from("51", "hex"),
              coinbase: true,
            },
          ],
          undoEntries: [],
        });

        expect(await session.store.getValidatedHeight(chain)).toBe(1);
        expect(await session.store.getValidatedHash(chain)).toBe(blockHash);
        expect(await session.store.utxoCount(chain)).toBe(1);
        expect(await session.store.getUtxo(chain, txid, 0)).toMatchObject({
          txid,
          vout: 0,
          height: 1,
          value: 50_0000_0000n,
          coinbase: true,
        });
        expect(await session.store.readUndo(chain, 1)).toEqual([]);
      } finally {
        await session.close();
      }
    } finally {
      cleanup(dir);
    }
  });

  it("starts counters at zero and updates UTXO counters during commits", async () => {
    const dir = tempDatadir();
    try {
      const session = await ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false });
      try {
        const chain = TESTNET4.name;
        expect(await session.store.headerCount(chain)).toBe(0);
        expect(await session.store.blockCount(chain)).toBe(0);
        expect(await session.store.maxStoredBlockHeight(chain)).toBe(0);
        expect(await session.store.utxoCount(chain)).toBe(0);

        const firstTxid = "44".repeat(32);
        await session.store.commitBlock({
          chain,
          height: 1,
          blockHash: "55".repeat(32),
          spentOutpoints: [],
          createdUtxos: [
            {
              txid: firstTxid,
              vout: 0,
              height: 1,
              value: 1n,
              scriptPubKey: Buffer.from("51", "hex"),
              coinbase: false,
            },
          ],
          undoEntries: [],
        });
        expect(await session.store.utxoCount(chain)).toBe(1);

        await session.store.commitBlock({
          chain,
          height: 2,
          blockHash: "66".repeat(32),
          spentOutpoints: [{ txid: firstTxid, vout: 0 }],
          createdUtxos: [
            {
              txid: "77".repeat(32),
              vout: 0,
              height: 2,
              value: 2n,
              scriptPubKey: Buffer.from("51", "hex"),
              coinbase: false,
            },
            {
              txid: "88".repeat(32),
              vout: 1,
              height: 2,
              value: 3n,
              scriptPubKey: Buffer.from("51", "hex"),
              coinbase: false,
            },
          ],
          undoEntries: [
            {
              txid: firstTxid,
              vout: 0,
              height: 1,
              value: 1n,
              scriptPubKey: Buffer.from("51", "hex"),
              coinbase: false,
            },
          ],
        });
        expect(await session.store.utxoCount(chain)).toBe(2);
      } finally {
        await session.close();
      }
    } finally {
      cleanup(dir);
    }
  });

  it("records block index entries", async () => {
    const dir = tempDatadir();
    try {
      const session = await ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false });
      try {
        const chain = TESTNET4.name;
        await session.store.recordBlock(chain, {
          height: 2,
          blockHash: "33".repeat(32),
          fileNumber: 0,
          fileOffset: 8,
          blockSize: 258,
        });
        await session.store.recordBlock(chain, {
          height: 2,
          blockHash: "44".repeat(32),
          fileNumber: 1,
          fileOffset: 16,
          blockSize: 300,
        });
        expect(await session.store.blockCount(chain)).toBe(1);
        expect(await session.store.maxStoredBlockHeight(chain)).toBe(2);
        expect(await session.store.getBlock(chain, 2)).toEqual({
          height: 2,
          blockHash: "44".repeat(32),
          fileNumber: 1,
          fileOffset: 16,
          blockSize: 300,
        });
      } finally {
        await session.close();
      }
    } finally {
      cleanup(dir);
    }
  });

  it("preserves order and missing rows for bulk UTXO reads", async () => {
    const dir = tempDatadir();
    try {
      const session = await ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false });
      try {
        const chain = TESTNET4.name;
        const firstTxid = "99".repeat(32);
        const secondTxid = "aa".repeat(32);
        await session.store.commitBlock({
          chain,
          height: 1,
          blockHash: "bb".repeat(32),
          spentOutpoints: [],
          createdUtxos: [
            {
              txid: firstTxid,
              vout: 0,
              height: 1,
              value: 1n,
              scriptPubKey: Buffer.from("51", "hex"),
              coinbase: false,
            },
            {
              txid: secondTxid,
              vout: 2,
              height: 1,
              value: 2n,
              scriptPubKey: Buffer.from("52", "hex"),
              coinbase: false,
            },
          ],
          undoEntries: [],
        });

        const rows = await session.store.getUtxos(chain, [
          { txid: secondTxid, vout: 2 },
          { txid: "cc".repeat(32), vout: 0 },
          { txid: firstTxid, vout: 0 },
          { txid: secondTxid, vout: 2 },
        ]);
        expect(rows.map((row) => row?.value ?? null)).toEqual([2n, null, 1n, 2n]);
      } finally {
        await session.close();
      }
    } finally {
      cleanup(dir);
    }
  });

  it("commits block index and connected state in one batch", async () => {
    const dir = tempDatadir();
    try {
      const session = await ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false });
      try {
        const chain = TESTNET4.name;
        await session.store.commitBlock({
          chain,
          height: 3,
          blockHash: "dd".repeat(32),
          blockIndex: {
            height: 3,
            blockHash: "dd".repeat(32),
            fileNumber: 2,
            fileOffset: 24,
            blockSize: 400,
          },
          spentOutpoints: [],
          createdUtxos: [
            {
              txid: "ee".repeat(32),
              vout: 0,
              height: 3,
              value: 3n,
              scriptPubKey: Buffer.from("51", "hex"),
              coinbase: true,
            },
          ],
          undoEntries: [],
        });

        expect(await session.store.getValidatedHeight(chain)).toBe(3);
        expect(await session.store.blockCount(chain)).toBe(1);
        expect(await session.store.maxStoredBlockHeight(chain)).toBe(3);
        expect(await session.store.utxoCount(chain)).toBe(1);
        expect(await session.store.getBlock(chain, 3)).toMatchObject({ fileNumber: 2, blockSize: 400 });
      } finally {
        await session.close();
      }
    } finally {
      cleanup(dir);
    }
  });

  it("does not advance connected state when the RocksDB batch fails", async () => {
    const dir = tempDatadir();
    try {
      const session = await ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false });
      try {
        const chain = TESTNET4.name;
        type BatchDb = {
          batch(
            operations: readonly unknown[],
            options: Record<string, unknown>,
            callback: (error?: Error | null) => void,
          ): void;
        };
        const raw = session.store as unknown as { db: BatchDb };
        const originalBatch = raw.db.batch.bind(raw.db);
        raw.db.batch = (_operations, _options, callback) => callback(new Error("forced batch failure"));
        try {
          await expect(
            session.store.commitBlock({
              chain,
              height: 4,
              blockHash: "12".repeat(32),
              blockIndex: {
                height: 4,
                blockHash: "12".repeat(32),
                fileNumber: 3,
                fileOffset: 0,
                blockSize: 100,
              },
              spentOutpoints: [],
              createdUtxos: [
                {
                  txid: "13".repeat(32),
                  vout: 0,
                  height: 4,
                  value: 1n,
                  scriptPubKey: Buffer.from("51", "hex"),
                  coinbase: false,
                },
              ],
              undoEntries: [],
            }),
          ).rejects.toThrow("forced batch failure");
        } finally {
          raw.db.batch = originalBatch;
        }

        expect(await session.store.getValidatedHeight(chain)).toBe(-1);
        expect(await session.store.getBlock(chain, 4)).toBeNull();
        expect(await session.store.blockCount(chain)).toBe(0);
        expect(await session.store.utxoCount(chain)).toBe(0);
      } finally {
        await session.close();
      }
    } finally {
      cleanup(dir);
    }
  });

  it("backfills missing counter metadata on open", async () => {
    const dir = tempDatadir();
    try {
      const chain = TESTNET4.name;
      const session = await ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false });
      try {
        await session.store.insertHeader(chain, {
          height: 1,
          blockHash: "14".repeat(32),
          prevHash: TESTNET4.genesisHash,
          headerSerializedHex: Buffer.alloc(80).toString("hex"),
        });
        await session.store.commitBlock({
          chain,
          height: 1,
          blockHash: "15".repeat(32),
          blockIndex: {
            height: 1,
            blockHash: "15".repeat(32),
            fileNumber: 0,
            fileOffset: 0,
            blockSize: 80,
          },
          spentOutpoints: [],
          createdUtxos: [
            {
              txid: "16".repeat(32),
              vout: 0,
              height: 1,
              value: 1n,
              scriptPubKey: Buffer.from("51", "hex"),
              coinbase: false,
            },
          ],
          undoEntries: [],
        });
      } finally {
        await session.close();
      }

      await deleteNativeCounterMetadata(dir, chain);
      const reopened = await ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false });
      try {
        expect(await reopened.store.headerCount(chain)).toBe(1);
        expect(await reopened.store.blockCount(chain)).toBe(1);
        expect(await reopened.store.maxStoredBlockHeight(chain)).toBe(1);
        expect(await reopened.store.utxoCount(chain)).toBe(1);
      } finally {
        await reopened.close();
      }
    } finally {
      cleanup(dir);
    }
  });

  it("persists native blocker and last-error metadata for status", async () => {
    const dir = tempDatadir();
    try {
      const session = await ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false });
      try {
        const chain = TESTNET4.name;
        const blocker = {
          height: 6975,
          txid: "aa".repeat(32),
          input_index: 0,
          failure: "script verification failed",
        };
        await session.store.setCurrentBlocker(chain, blocker);
        await session.store.setLastError(chain, "script verification failed");
        expect(await session.store.currentBlocker(chain)).toEqual(blocker);
        expect(await session.store.lastError(chain)).toBe("script verification failed");
      } finally {
        await session.close();
      }

      const status = await nativeStatusDocument(Settings.fromEnv({ dataDir: dir, chain: TESTNET4.name }));
      expect(status.runtime_surface).toBe("native");
      expect(status.binary_gate_status).toBe("failed");
      expect(status.current_blocker).toMatchObject({ height: 6975 });
      expect(status.last_error).toBe("script verification failed");
      expect(status.operational_db_artifact_absent).toBe(true);
      expect(status.runtime_db_boundary_passed).toBe(true);
      expect(status.native_crypto_backend).toBeTruthy();
      expect(status.taproot_tweak_backend).toBeTruthy();
    } finally {
      cleanup(dir);
    }
  });
});
