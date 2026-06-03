package com.jbitnode.db;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.sql.SQLException;
import java.time.Instant;
import java.util.Optional;
import org.rocksdb.RocksDB;
import org.rocksdb.RocksDBException;
import org.rocksdb.RocksIterator;

/** RocksDB-backed operational metadata/index store for JavaNode. */
public final class RocksDbOperationalStore implements OperationalStore {

  private static final byte META_PREFIX = 'm';
  private static final byte HEADER_PREFIX = 'h';
  private static final byte BLOCK_PREFIX = 'b';
  private static final byte SYNC_PREFIX = 's';
  private static final byte VALIDATED_TIP_PREFIX = 't';
  private static final byte EVENT_PREFIX = 'e';
  private static final byte COUNTER_PREFIX = 'c';

  // Maintained counters that replace the O(n) prefix scans formerly run on every sync batch. Stored
  // under the existing counter namespace; lazily initialised from a one-time scan for datadirs
  // written before the counters existed, then kept current by recordHeader/recordBlock.
  private static final String HEADER_COUNT = "header_count";
  private static final String BLOCK_COUNT = "block_count";

  static {
    RocksDB.loadLibrary();
  }

  private final RocksDbTuning.Tuned tuned;
  private final RocksDB db;

  public RocksDbOperationalStore(Path path, boolean createIfMissing) throws IOException {
    this.tuned = RocksDbTuning.create(createIfMissing, 64L << 20, 16L << 20, 3);
    try {
      this.db = RocksDB.open(tuned.options(), path.toString());
    } catch (RocksDBException error) {
      tuned.closeResources();
      throw new IOException("failed to open RocksDB operational store at " + path, error);
    }
  }

  @Override
  public String getMeta(String key) throws SQLException {
    try {
      byte[] value = db.get(stringKey(META_PREFIX, key));
      return value == null ? null : new String(value, StandardCharsets.UTF_8);
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb operational metadata read failed", error);
    }
  }

  @Override
  public void setMeta(String key, String value) throws SQLException {
    try {
      db.put(stringKey(META_PREFIX, key), value.getBytes(StandardCharsets.UTF_8));
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb operational metadata write failed", error);
    }
  }

  @Override
  public ChainstateTip getValidatedTip(String chain) throws SQLException {
    try {
      byte[] value = db.get(stringKey(VALIDATED_TIP_PREFIX, chain));
      if (value == null) {
        return new ChainstateTip(-1, "");
      }
      try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(value))) {
        return new ChainstateTip(in.readInt(), readString(in));
      }
    } catch (IOException | RocksDBException error) {
      throw new SQLException("rocksdb operational validated tip decode failed", error);
    }
  }

  @Override
  public void setValidatedTip(String chain, int height, String blockHashHex) throws SQLException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      out.writeInt(height);
      writeString(out, blockHashHex);
      db.put(stringKey(VALIDATED_TIP_PREFIX, chain), bytes.toByteArray());
    } catch (IOException | RocksDBException error) {
      throw new SQLException("rocksdb operational validated tip encode failed", error);
    }
  }

  @Override
  public void recordHeader(HeaderRecord header) throws SQLException {
    try {
      byte[] key = heightKey(HEADER_PREFIX, header.chain(), header.height());
      boolean isNew = db.get(key) == null;
      db.put(key, encodeHeader(header));
      if (isNew) {
        bumpCounterIfPresent(HEADER_COUNT, header.chain());
      }
    } catch (IOException | RocksDBException error) {
      throw new SQLException("rocksdb operational header encode failed", error);
    }
  }

  @Override
  public String getHeaderHash(String chain, int height) throws SQLException {
    return getHeader(chain, height).map(HeaderRecord::blockHash).orElse(null);
  }

  @Override
  public Optional<HeaderRecord> getHeader(String chain, int height) throws SQLException {
    try {
      byte[] value = db.get(heightKey(HEADER_PREFIX, chain, height));
      return value == null ? Optional.empty() : Optional.of(decodeHeader(value));
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb operational header read failed", error);
    }
  }

  @Override
  public int headerCount(String chain) throws SQLException {
    return maintainedCount(HEADER_COUNT, HEADER_PREFIX, chain);
  }

  @Override
  public void recordBlock(BlockIndexRecord block) throws SQLException {
    try {
      byte[] key = heightKey(BLOCK_PREFIX, block.chain(), block.height());
      boolean isNew = db.get(key) == null;
      db.put(key, encodeBlock(block));
      if (isNew) {
        bumpCounterIfPresent(BLOCK_COUNT, block.chain());
      }
    } catch (IOException | RocksDBException error) {
      throw new SQLException("rocksdb operational block index encode failed", error);
    }
  }

  @Override
  public Optional<BlockIndexRecord> getBlock(String chain, int height) throws SQLException {
    try {
      byte[] value = db.get(heightKey(BLOCK_PREFIX, chain, height));
      return value == null ? Optional.empty() : Optional.of(decodeBlock(value));
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb operational block index read failed", error);
    }
  }

  @Override
  public int blockCount(String chain) throws SQLException {
    return maintainedCount(BLOCK_COUNT, BLOCK_PREFIX, chain);
  }

  @Override
  public Optional<ProjectTracker.SyncState> getSyncState(String chain) throws SQLException {
    try {
      byte[] value = db.get(stringKey(SYNC_PREFIX, chain));
      if (value == null) {
        return Optional.empty();
      }
      try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(value))) {
        return Optional.of(
            new ProjectTracker.SyncState(
                chain, in.readInt(), readString(in), in.readInt(), readString(in), readString(in)));
      }
    } catch (IOException | RocksDBException error) {
      throw new SQLException("rocksdb operational sync state decode failed", error);
    }
  }

  @Override
  public void upsertSyncState(String chain, ProjectTracker.SyncStatePatch patch) throws SQLException {
    ProjectTracker.SyncState existing = getSyncState(chain).orElse(null);
    int bestHeight = patch.bestHeight() != null ? patch.bestHeight() : existing != null ? existing.bestHeight() : 0;
    String bestHash =
        patch.bestHash() != null ? patch.bestHash() : existing != null ? existing.bestHash() : "";
    int headerCount =
        patch.headerCount() != null ? patch.headerCount() : existing != null ? existing.headerCount() : 0;
    String syncStatus =
        patch.syncStatus() != null ? patch.syncStatus() : existing != null ? existing.syncStatus() : "starting";
    try {
      db.put(stringKey(SYNC_PREFIX, chain), encodeSyncState(bestHeight, bestHash, headerCount, syncStatus));
    } catch (IOException | RocksDBException error) {
      throw new SQLException("rocksdb operational sync state encode failed", error);
    }
  }

  @Override
  public long logEvent(String source, String message, String level, String detailsJson) throws SQLException {
    long id = nextCounter("event");
    try {
      db.put(longKey(EVENT_PREFIX, id), encodeEvent(source, message, level, detailsJson));
      return id;
    } catch (IOException | RocksDBException error) {
      throw new SQLException("rocksdb operational event encode failed", error);
    }
  }

  @Override
  public void close() throws IOException {
    db.close();
    tuned.closeResources();
  }

  private int countPrefix(byte[] prefix) throws SQLException {
    int count = 0;
    try (RocksIterator iterator = db.newIterator()) {
      for (iterator.seek(prefix); iterator.isValid(); iterator.next()) {
        byte[] key = iterator.key();
        if (!NativeChainstateCodec.startsWith(key, prefix)) {
          break;
        }
        count += 1;
      }
      iterator.status();
      return count;
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb operational prefix count failed", error);
    }
  }

  private int maintainedCount(String counterName, byte recordPrefix, String chain)
      throws SQLException {
    byte[] key = stringKey(COUNTER_PREFIX, counterName + ":" + chain);
    try {
      byte[] value = db.get(key);
      if (value != null) {
        return (int) decodeLong(value);
      }
      int counted = countPrefix(heightPrefix(recordPrefix, chain));
      db.put(key, encodeLong(counted));
      return counted;
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb operational maintained count failed", error);
    }
  }

  private void bumpCounterIfPresent(String counterName, String chain)
      throws SQLException, RocksDBException {
    // Only adjust the counter once it has been initialised (by maintainedCount). Until then a fresh
    // scan recomputes the true total, so a no-op here keeps legacy datadirs correct.
    byte[] key = stringKey(COUNTER_PREFIX, counterName + ":" + chain);
    byte[] value = db.get(key);
    if (value != null) {
      db.put(key, encodeLong(decodeLong(value) + 1));
    }
  }

  private long nextCounter(String name) throws SQLException {
    byte[] key = stringKey(COUNTER_PREFIX, name);
    try {
      byte[] value = db.get(key);
      long next = value == null ? 1 : decodeLong(value) + 1;
      db.put(key, encodeLong(next));
      return next;
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb operational counter failed", error);
    }
  }

  private static byte[] stringKey(byte prefix, String key) {
    byte[] keyBytes = key.getBytes(StandardCharsets.UTF_8);
    ByteArrayOutputStream out = new ByteArrayOutputStream(keyBytes.length + 2);
    out.write(prefix);
    out.write(0);
    try {
      out.write(keyBytes);
    } catch (IOException error) {
      throw new IllegalStateException("rocksdb operational string key failed", error);
    }
    return out.toByteArray();
  }

  private static byte[] heightPrefix(byte prefix, String chain) {
    byte[] chainBytes = chain.getBytes(StandardCharsets.UTF_8);
    ByteArrayOutputStream out = new ByteArrayOutputStream(chainBytes.length + 2);
    out.write(prefix);
    out.write(chainBytes.length);
    try {
      out.write(chainBytes);
    } catch (IOException error) {
      throw new IllegalStateException("rocksdb operational height prefix failed", error);
    }
    return out.toByteArray();
  }

  private static byte[] heightKey(byte prefix, String chain, int height) {
    byte[] keyPrefix = heightPrefix(prefix, chain);
    ByteArrayOutputStream out = new ByteArrayOutputStream(keyPrefix.length + 4);
    try {
      out.write(keyPrefix);
      out.write(new byte[] {(byte) (height >>> 24), (byte) (height >>> 16), (byte) (height >>> 8), (byte) height});
    } catch (IOException error) {
      throw new IllegalStateException("rocksdb operational height key failed", error);
    }
    return out.toByteArray();
  }

  private static byte[] longKey(byte prefix, long value) {
    ByteArrayOutputStream out = new ByteArrayOutputStream(9);
    out.write(prefix);
    try {
      out.write(
          new byte[] {
            (byte) (value >>> 56),
            (byte) (value >>> 48),
            (byte) (value >>> 40),
            (byte) (value >>> 32),
            (byte) (value >>> 24),
            (byte) (value >>> 16),
            (byte) (value >>> 8),
            (byte) value
          });
    } catch (IOException error) {
      throw new IllegalStateException("rocksdb operational long key failed", error);
    }
    return out.toByteArray();
  }

  private static byte[] encodeHeader(HeaderRecord header) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      writeString(out, header.chain());
      out.writeInt(header.height());
      writeString(out, header.blockHash());
      writeString(out, header.prevHash());
      writeString(out, header.headerSerializedHex());
    }
    return bytes.toByteArray();
  }

  private static HeaderRecord decodeHeader(byte[] value) throws SQLException {
    try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(value))) {
      return new HeaderRecord(readString(in), in.readInt(), readString(in), readString(in), readString(in));
    } catch (IOException error) {
      throw new SQLException("rocksdb operational header decode failed", error);
    }
  }

  private static byte[] encodeBlock(BlockIndexRecord block) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      writeString(out, block.chain());
      out.writeInt(block.height());
      writeString(out, block.blockHash());
      out.writeInt(block.fileNumber());
      out.writeLong(block.fileOffset());
      out.writeInt(block.blockSize());
    }
    return bytes.toByteArray();
  }

  private static BlockIndexRecord decodeBlock(byte[] value) throws SQLException {
    try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(value))) {
      return new BlockIndexRecord(
          readString(in), in.readInt(), readString(in), in.readInt(), in.readLong(), in.readInt());
    } catch (IOException error) {
      throw new SQLException("rocksdb operational block index decode failed", error);
    }
  }

  private static byte[] encodeSyncState(
      int bestHeight, String bestHash, int headerCount, String syncStatus) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      out.writeInt(bestHeight);
      writeString(out, bestHash);
      out.writeInt(headerCount);
      writeString(out, syncStatus);
      writeString(out, Instant.now().toString());
    }
    return bytes.toByteArray();
  }

  private static byte[] encodeEvent(String source, String message, String level, String detailsJson)
      throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      writeString(out, source);
      writeString(out, message);
      writeString(out, level);
      writeString(out, detailsJson == null ? "" : detailsJson);
      writeString(out, Instant.now().toString());
    }
    return bytes.toByteArray();
  }

  private static byte[] encodeLong(long value) {
    return new byte[] {
      (byte) (value >>> 56),
      (byte) (value >>> 48),
      (byte) (value >>> 40),
      (byte) (value >>> 32),
      (byte) (value >>> 24),
      (byte) (value >>> 16),
      (byte) (value >>> 8),
      (byte) value
    };
  }

  private static long decodeLong(byte[] value) throws SQLException {
    if (value.length != 8) {
      throw new SQLException("invalid encoded counter length");
    }
    long result = 0;
    for (byte b : value) {
      result = (result << 8) | (b & 0xffL);
    }
    return result;
  }

  private static void writeString(DataOutputStream out, String value) throws IOException {
    byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
    out.writeInt(bytes.length);
    out.write(bytes);
  }

  private static String readString(DataInputStream in) throws IOException {
    int length = in.readInt();
    byte[] bytes = in.readNBytes(length);
    if (bytes.length != length) {
      throw new IOException("truncated string");
    }
    return new String(bytes, StandardCharsets.UTF_8);
  }
}
