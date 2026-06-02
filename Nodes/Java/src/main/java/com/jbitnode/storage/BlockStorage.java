package com.jbitnode.storage;

import com.jbitnode.db.OperationalStore;
import java.sql.SQLException;
import java.util.Optional;

/** Transactional block blob persistence: append raw block bytes and record metadata in {@code blocks}. */
public final class BlockStorage {

  private final BlockStore blockStore;
  private final OperationalStore operationalStore;

  public BlockStorage(BlockStore blockStore, OperationalStore operationalStore) {
    if (operationalStore == null) {
      throw new IllegalArgumentException("BlockStorage requires an OperationalStore");
    }
    this.blockStore = blockStore;
    this.operationalStore = operationalStore;
  }

  public BlockRecord storeBlock(String chain, int height, String blockHashHex, byte[] blockData)
      throws SQLException {
    return storeBlock(chain, height, blockHashHex, blockData, false);
  }

  public BlockRecord storeBlockReplacingMetadata(
      String chain, int height, String blockHashHex, byte[] blockData)
      throws SQLException {
    return storeBlock(chain, height, blockHashHex, blockData, true);
  }

  private BlockRecord storeBlock(
      String chain, int height, String blockHashHex, byte[] blockData, boolean replaceMetadata)
      throws SQLException {
    BlockWriteResult write = blockStore.write(blockData);
    int fileNumber = BlockStore.fileNumberFromName(write.fileName());
    operationalStore.recordBlock(
        new OperationalStore.BlockIndexRecord(
            chain, height, blockHashHex, fileNumber, write.offset(), write.blockSize()));
    return new BlockRecord(chain, height, blockHashHex, fileNumber, write.offset(), write.blockSize());
  }

  public byte[] readBlock(String chain, int height) throws SQLException {
    BlockRecord record =
        getBlock(chain, height)
            .orElseThrow(() -> new IllegalArgumentException("no stored block at height " + height));
    return blockStore.read(
        BlockStore.fileNameForIndex(record.fileNumber()),
        record.fileOffset(),
        record.blockSize());
  }

  public Optional<BlockRecord> getBlock(String chain, int height) throws SQLException {
    return operationalStore
        .getBlock(chain, height)
        .map(
            record ->
                new BlockRecord(
                    record.chain(),
                    record.height(),
                    record.blockHash(),
                    record.fileNumber(),
                    Math.toIntExact(record.fileOffset()),
                    record.blockSize()));
  }
}
