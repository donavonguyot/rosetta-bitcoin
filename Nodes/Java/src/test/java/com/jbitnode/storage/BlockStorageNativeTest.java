package com.jbitnode.storage;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.db.RocksDbOperationalStore;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Path;

class BlockStorageNativeTest {

  @Test
  void storesBlockBytesAndMetadataInNativeStores(@TempDir Path tempDir) throws Exception {
    try (RocksDbOperationalStore operational =
        new RocksDbOperationalStore(tempDir.resolve("operational-rocksdb"), true)) {
      BlockStorage storage =
          new BlockStorage(new BlockStore(tempDir.resolve("blocks"), new byte[] {7, 9, 17, 11}), operational);
      byte[] payload = new byte[] {1, 2, 3, 4};

      BlockRecord record = storage.storeBlock("testnet4", 7, "block-7", payload);

      assertEquals(7, record.height());
      assertArrayEquals(payload, storage.readBlock("testnet4", 7));
      assertTrue(storage.getBlock("testnet4", 7).isPresent());
      assertEquals(1, operational.blockCount("testnet4"));
    }
  }
}
