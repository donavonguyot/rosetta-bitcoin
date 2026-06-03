package com.jbitnode.db;

import com.jbitnode.db.ProjectTracker.StoredUtxo;
import com.jbitnode.db.ProjectTracker.UtxoOutpoint;
import com.jbitnode.db.ProjectTracker.UtxoUndoEntry;
import com.jbitnode.util.Hex;
import java.io.IOException;
import java.nio.file.Path;
import java.sql.SQLException;
import java.time.Instant;
import java.util.List;
import org.rocksdb.RocksDB;
import org.rocksdb.RocksDBException;
import org.rocksdb.RocksIterator;
import org.rocksdb.WriteBatch;
import org.rocksdb.WriteOptions;

/** RocksDB implementation of the native chainstate keyspace. */
public final class RocksDbChainstateStore implements UtxoStore, AutoCloseable {

  static {
    RocksDB.loadLibrary();
  }

  private final RocksDbTuning.Tuned tuned;
  private final RocksDB db;
  private final boolean disableWal;

  public RocksDbChainstateStore(Path path, boolean createIfMissing) throws RocksDBException {
    // UTXO set is the hottest store: give it a large block cache + bloom filter and big memtables.
    this.tuned = RocksDbTuning.create(createIfMissing, 256L << 20, 64L << 20, 4);
    // Chainstate is rebuildable via --rebuild, so bulk catch-up may opt out of the WAL for speed.
    this.disableWal = RocksDbTuning.envFlag(System.getenv("ROCKSDB_DISABLE_WAL"));
    try {
      this.db = RocksDB.open(tuned.options(), path.toString());
    } catch (RocksDBException error) {
      tuned.closeResources();
      throw error;
    }
  }

  private WriteOptions newWriteOptions() {
    WriteOptions writeOptions = new WriteOptions();
    if (disableWal) {
      writeOptions.setDisableWAL(true);
    }
    return writeOptions;
  }

  @Override
  public StoredUtxo get(String chain, String txidHex, int vout) throws SQLException {
    try {
      byte[] txid = Hex.decode(txidHex);
      byte[] value = db.get(NativeChainstateCodec.utxoKeyV2(chain, txid, vout));
      return value == null ? null : NativeChainstateCodec.decodeUtxoV2(txid, vout, value);
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb get failed", error);
    }
  }

  @Override
  public List<StoredUtxo> getMany(String chain, List<UtxoOutpoint> outpoints) throws SQLException {
    if (outpoints.isEmpty()) {
      return List.of();
    }
    List<byte[]> txids = new java.util.ArrayList<>(outpoints.size());
    List<byte[]> keys = new java.util.ArrayList<>(outpoints.size());
    for (UtxoOutpoint outpoint : outpoints) {
      byte[] txid = Hex.decode(outpoint.txidHex());
      txids.add(txid);
      keys.add(NativeChainstateCodec.utxoKeyV2(chain, txid, outpoint.vout()));
    }
    try {
      List<byte[]> values = db.multiGetAsList(keys);
      List<StoredUtxo> result = new java.util.ArrayList<>(outpoints.size());
      for (int i = 0; i < outpoints.size(); i++) {
        byte[] value = values.get(i);
        result.add(
            value == null
                ? null
                : NativeChainstateCodec.decodeUtxoV2(txids.get(i), outpoints.get(i).vout(), value));
      }
      return result;
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb multiGet failed", error);
    }
  }

  @Override
  public void spendBatch(String chain, List<UtxoOutpoint> outpoints) throws SQLException {
    try (WriteBatch batch = new WriteBatch();
        WriteOptions writeOptions = newWriteOptions()) {
      for (UtxoOutpoint outpoint : outpoints) {
        batch.delete(NativeChainstateCodec.utxoKeyV2(chain, outpoint.txidHex(), outpoint.vout()));
      }
      db.write(writeOptions, batch);
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb spend batch failed", error);
    }
  }

  @Override
  public void addBatch(String chain, List<StoredUtxo> utxos) throws SQLException {
    try (WriteBatch batch = new WriteBatch();
        WriteOptions writeOptions = newWriteOptions()) {
      for (StoredUtxo utxo : utxos) {
        batch.put(
            NativeChainstateCodec.utxoKeyV2(chain, utxo.txid(), utxo.vout()),
            NativeChainstateCodec.encodeUtxoV2(utxo));
      }
      db.write(writeOptions, batch);
    } catch (IOException | RocksDBException error) {
      throw new SQLException("rocksdb add batch failed", error);
    }
  }

  @Override
  public long count(String chain) throws SQLException {
    byte[] prefix = NativeChainstateCodec.utxoKeyPrefixV2(chain);
    long count = 0;
    try (RocksIterator iterator = db.newIterator()) {
      for (iterator.seek(prefix); iterator.isValid(); iterator.next()) {
        if (!NativeChainstateCodec.startsWith(iterator.key(), prefix)) {
          break;
        }
        count += 1;
      }
      iterator.status();
      return count;
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb count failed", error);
    }
  }

  public String getMetadata(String key) throws SQLException {
    try {
      byte[] value = db.get(NativeChainstateCodec.metadataKeyV2(key));
      return value == null ? null : NativeChainstateCodec.decodeMetadataValue(value);
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb metadata get failed", error);
    }
  }

  public void putMetadata(String key, String value) throws SQLException {
    try {
      db.put(NativeChainstateCodec.metadataKeyV2(key), NativeChainstateCodec.metadataValue(value));
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb metadata put failed", error);
    }
  }

  public ChainstateCommitResult commitBlockNative(
      ChainstateBlockCommit commit, ChainstateMetadata existingMetadata) throws SQLException {
    ChainstateTip tip = new ChainstateTip(commit.height(), commit.blockHashHex());
    ChainstateMetadata metadata =
        new ChainstateMetadata(
            existingMetadata.backendName(),
            existingMetadata.backendPath(),
            existingMetadata.generationId(),
            "usable",
            tip.height(),
            tip.hash(),
            existingMetadata.schemaVersion(),
            Instant.now().toString());
    try (WriteBatch batch = new WriteBatch();
        WriteOptions writeOptions = newWriteOptions()) {
      for (UtxoOutpoint outpoint : commit.spentOutpoints()) {
        batch.delete(NativeChainstateCodec.utxoKeyV2(commit.chain(), outpoint.txidHex(), outpoint.vout()));
      }
      for (StoredUtxo utxo : commit.createdUtxos()) {
        batch.put(
            NativeChainstateCodec.utxoKeyV2(commit.chain(), utxo.txid(), utxo.vout()),
            NativeChainstateCodec.encodeUtxoV2(utxo));
      }
      batch.put(
          NativeChainstateCodec.undoKeyV2(commit.chain(), commit.height()),
          NativeChainstateCodec.encodeUndoV2(commit.undoEntries()));
      batch.put(NativeChainstateCodec.tipKeyV2(commit.chain()), NativeChainstateCodec.encodeTipV2(tip));
      putMetadata(batch, ChainstateStoreFactory.BACKEND_NAME, metadata.backendName());
      putMetadata(batch, ChainstateStoreFactory.BACKEND_PATH, metadata.backendPath().toString());
      putMetadata(batch, ChainstateStoreFactory.GENERATION_ID, metadata.generationId());
      putMetadata(batch, ChainstateStoreFactory.STATUS, metadata.status());
      putMetadata(batch, ChainstateStoreFactory.TIP_HEIGHT, Integer.toString(metadata.tipHeight()));
      putMetadata(batch, ChainstateStoreFactory.TIP_HASH, metadata.tipHash());
      putMetadata(batch, ChainstateStoreFactory.SCHEMA_VERSION, metadata.schemaVersion());
      putMetadata(batch, ChainstateStoreFactory.UPDATED_AT, metadata.updatedAt());
      db.write(writeOptions, batch);
      return new ChainstateCommitResult(
          tip, commit.createdUtxos().size(), commit.spentOutpoints().size(), metadata);
    } catch (IOException | RocksDBException error) {
      throw new SQLException("rocksdb native chainstate commit failed", error);
    }
  }

  public ChainstateTip readTip(String chain) throws SQLException {
    try {
      byte[] value = db.get(NativeChainstateCodec.tipKeyV2(chain));
      return value == null ? null : NativeChainstateCodec.decodeTipV2(value);
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb tip read failed", error);
    }
  }

  public List<UtxoUndoEntry> readUndo(String chain, int height) throws SQLException {
    try {
      byte[] value = db.get(NativeChainstateCodec.undoKeyV2(chain, height));
      return value == null ? List.of() : NativeChainstateCodec.decodeUndoV2(value);
    } catch (RocksDBException error) {
      throw new SQLException("rocksdb undo read failed", error);
    }
  }

  @Override
  public void close() throws IOException {
    db.close();
    tuned.closeResources();
  }

  private static void putMetadata(WriteBatch batch, String key, String value) throws RocksDBException {
    batch.put(NativeChainstateCodec.metadataKeyV2(key), NativeChainstateCodec.metadataValue(value));
  }
}
