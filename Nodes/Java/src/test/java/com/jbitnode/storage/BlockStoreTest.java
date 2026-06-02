package com.jbitnode.storage;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.testutil.FixtureLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class BlockStoreTest {

  @Test
  void rejectsInvalidMagicLength() {
    assertThrows(
        IllegalArgumentException.class,
        () -> new BlockStore(Path.of("."), new byte[] {1, 2, 3}));
  }

  @Test
  void writesAndReadsBlockRecord(@TempDir Path tempDir) {
    byte[] blockData = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    byte[] magic = ChainRegistry.TESTNET4.magic();
    BlockStore store = new BlockStore(tempDir.resolve("blocks"), magic);
    BlockWriteResult write = store.write(blockData);
    assertEquals("blk00000.dat", write.fileName());
    assertEquals(0, write.fileNumber());
    assertEquals(0, write.offset());
    assertEquals(blockData.length, write.blockSize());
    assertArrayEquals(blockData, store.read(write.fileName(), write.offset(), write.blockSize()));
    assertTrue(store.hasDataFile(0));
    assertTrue(store.verifyMagic());
  }

  @Test
  void rotatesFilesWhenMaxSizeExceeded(@TempDir Path tempDir) {
    byte[] blockData = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    byte[] magic = ChainRegistry.TESTNET4.magic();
    BlockStore store = new BlockStore(tempDir.resolve("blocks"), magic, 280);
    BlockWriteResult first = store.write(blockData);
    BlockWriteResult second = store.write(blockData);
    assertEquals("blk00000.dat", first.fileName());
    assertEquals("blk00001.dat", second.fileName());
    assertEquals(0, second.offset());
    assertArrayEquals(blockData, store.read(second.fileName(), second.offset(), second.blockSize()));
  }

  @Test
  void readRejectsMagicAndSizeMismatch(@TempDir Path tempDir) throws Exception {
    byte[] blockData = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    byte[] magic = ChainRegistry.TESTNET4.magic();
    BlockStore store = new BlockStore(tempDir.resolve("blocks"), magic);
    BlockWriteResult write = store.write(blockData);
    byte[] wrongMagic = new byte[] {0, 0, 0, 0};
    BlockStore other = new BlockStore(tempDir.resolve("blocks"), wrongMagic);
    assertThrows(
        IllegalArgumentException.class,
        () -> other.read(write.fileName(), write.offset(), write.blockSize()));
    assertThrows(
        IllegalArgumentException.class,
        () -> store.read(write.fileName(), write.offset(), write.blockSize() + 1));
  }

  @Test
  void readRejectsUnexpectedEof(@TempDir Path tempDir) throws Exception {
    byte[] blockData = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    BlockStore store = new BlockStore(tempDir.resolve("blocks"), ChainRegistry.TESTNET4.magic());
    BlockWriteResult write = store.write(blockData);
    Path path = tempDir.resolve("blocks").resolve(write.fileName());
    Files.write(path, new byte[] {0});
    assertThrows(
        IllegalArgumentException.class,
        () -> store.read(write.fileName(), 0, write.blockSize()));
  }

  @Test
  void verifyMagicReturnsTrueForEmptyBlocksDir(@TempDir Path tempDir) {
    Path blocksDir = tempDir.resolve("missing-blocks");
    BlockStore store = new BlockStore(blocksDir, ChainRegistry.TESTNET4.magic());
    assertTrue(store.verifyMagic());
    assertTrue(store.hasDataFile(0));
  }

  @Test
  void fileNumberFromNameParsesBlkIndex() {
    assertEquals(3, BlockStore.fileNumberFromName("blk00003.dat"));
    assertEquals(0, BlockStore.fileNumberFromName("invalid.dat"));
  }

  @Test
  void verifyMagicDetectsMismatch(@TempDir Path tempDir) throws Exception {
    Path blocksDir = tempDir.resolve("blocks");
    Files.createDirectories(blocksDir);
    Files.write(blocksDir.resolve("blk00000.dat"), new byte[] {9, 9, 9, 9, 0, 0, 0, 0});
    BlockStore store = new BlockStore(blocksDir, ChainRegistry.TESTNET4.magic());
    assertFalse(store.verifyMagic());
  }
}
