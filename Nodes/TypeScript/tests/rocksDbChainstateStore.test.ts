import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import {
  ChainstateSession,
  TSBITNODE_NATIVE_MARKER,
  TSBITNODE_SQLITE_DB,
} from "../src/db/chainstateSession.js";

function tempDatadir(): string {
  return mkdtempSync(join(tmpdir(), "tsbitnode-native-"));
}

function cleanup(path: string): void {
  rmSync(path, { recursive: true, force: true });
}

describe("RocksDB chainstate session", () => {
  it("fails closed when a native datadir contains tsbitnode.db", async () => {
    const dir = tempDatadir();
    try {
      writeFileSync(join(dir, TSBITNODE_SQLITE_DB), "");
      await expect(ChainstateSession.openNative(dir, TESTNET4, { acquireLock: false })).rejects.toThrow(
        "must not contain tsbitnode.db",
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
        expect(await session.store.blockCount(chain)).toBe(1);
        expect(await session.store.maxStoredBlockHeight(chain)).toBe(2);
        expect(await session.store.getBlock(chain, 2)).toEqual({
          height: 2,
          blockHash: "33".repeat(32),
          fileNumber: 0,
          fileOffset: 8,
          blockSize: 258,
        });
      } finally {
        await session.close();
      }
    } finally {
      cleanup(dir);
    }
  });
});
