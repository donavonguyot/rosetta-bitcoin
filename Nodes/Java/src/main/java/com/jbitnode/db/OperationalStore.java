package com.jbitnode.db;

import java.io.IOException;
import java.sql.SQLException;
import java.util.Optional;

/** Node-local operational metadata/index store. Project DB export is separate. */
public interface OperationalStore extends AutoCloseable {

  String getMeta(String key) throws SQLException;

  void setMeta(String key, String value) throws SQLException;

  ChainstateTip getValidatedTip(String chain) throws SQLException;

  void setValidatedTip(String chain, int height, String blockHashHex) throws SQLException;

  void recordHeader(HeaderRecord header) throws SQLException;

  String getHeaderHash(String chain, int height) throws SQLException;

  Optional<HeaderRecord> getHeader(String chain, int height) throws SQLException;

  int headerCount(String chain) throws SQLException;

  void recordBlock(BlockIndexRecord block) throws SQLException;

  Optional<BlockIndexRecord> getBlock(String chain, int height) throws SQLException;

  int blockCount(String chain) throws SQLException;

  Optional<ProjectTracker.SyncState> getSyncState(String chain) throws SQLException;

  void upsertSyncState(String chain, ProjectTracker.SyncStatePatch patch) throws SQLException;

  long logEvent(String source, String message, String level, String detailsJson) throws SQLException;

  @Override
  void close() throws IOException;

  record HeaderRecord(
      String chain, int height, String blockHash, String prevHash, String headerSerializedHex) {}

  record BlockIndexRecord(
      String chain, int height, String blockHash, int fileNumber, long fileOffset, int blockSize) {}
}
