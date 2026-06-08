package com.jbitnode.db;

import com.jbitnode.chain.ChainParams;
import com.jbitnode.storage.BlockStorage;
import com.jbitnode.storage.BlockStore;
import com.jbitnode.storage.DatadirLock;
import com.jbitnode.storage.DatadirLockBusyException;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.SQLException;
import java.util.Map;

/**
 * Owns the one active chainstate opening path for sync, live, rebuild, and status.
 *
 * <p>The session acquires the single-writer datadir lock before opening runtime truth surfaces.
 * Project may import their observations later, but sync and validation read the stores opened here.
 */
public final class ChainstateSession implements AutoCloseable {

  public static final String NATIVE_STORAGE_MARKER = ".jbitnode_native_storage";

  private final DatadirLock lock;
  private final OperationalStore operationalStore;
  private final ProjectTracker tracker;
  private final BlockStorage blockStorage;
  private final ChainstateStore chainstateStore;

  private ChainstateSession(
      DatadirLock lock,
      OperationalStore operationalStore,
      ProjectTracker tracker,
      BlockStorage blockStorage,
      ChainstateStore chainstateStore) {
    this.lock = lock;
    this.operationalStore = operationalStore;
    this.tracker = tracker;
    this.blockStorage = blockStorage;
    this.chainstateStore = chainstateStore;
  }

  public static ChainstateSession openReadWrite(
      Path dataDir, Path dbPath, ChainParams chain, Map<String, String> env, boolean requireAligned)
      throws IOException, SQLException, DatadirLockBusyException, ChainstateInvariantException,
          com.jbitnode.sync.ChainInconsistentException {
    DatadirLock lock = DatadirLock.acquire(dataDir);
    try {
      markNativeStorage(dataDir);
      OperationalStore operationalStore = openOperationalStore(dataDir, env);
      try {
        ProjectTracker tracker = new ProjectTracker(operationalStore);
        BlockStorage blockStorage =
            new BlockStorage(new BlockStore(dataDir.resolve("blocks"), chain.magic()), operationalStore);
        ChainstateStore store =
            ChainstateStoreFactory.open(
                tracker, dataDir, chain.name(), env, ChainstateOpenMode.READ_WRITE);
        try {
          ChainstateInvariants.verify(
              tracker, chain.name(), store, ChainstateOpenMode.READ_WRITE, requireAligned);
          return new ChainstateSession(lock, operationalStore, tracker, blockStorage, store);
        } catch (SQLException
            | ChainstateInvariantException
            | com.jbitnode.sync.ChainInconsistentException
            | RuntimeException error) {
          closeQuietly(store);
          throw error;
        }
      } catch (SQLException
          | IOException
          | ChainstateInvariantException
          | com.jbitnode.sync.ChainInconsistentException
          | RuntimeException error) {
        closeQuietly(operationalStore);
        throw error;
      }
    } catch (SQLException
        | IOException
        | ChainstateInvariantException
        | com.jbitnode.sync.ChainInconsistentException
        | RuntimeException error) {
      closeQuietly(lock);
      throw error;
    }
  }

  public static ChainstateSession openRebuild(
      Path dataDir, Path dbPath, ChainParams chain, Map<String, String> env)
      throws IOException, SQLException, DatadirLockBusyException {
    DatadirLock lock = DatadirLock.acquire(dataDir);
    try {
      markNativeStorage(dataDir);
      OperationalStore operationalStore = openOperationalStore(dataDir, env);
      try {
        ProjectTracker tracker = new ProjectTracker(operationalStore);
        BlockStorage blockStorage =
            new BlockStorage(new BlockStore(dataDir.resolve("blocks"), chain.magic()), operationalStore);
        ChainstateStore store =
            ChainstateStoreFactory.open(tracker, dataDir, chain.name(), env, ChainstateOpenMode.REBUILD);
        return new ChainstateSession(lock, operationalStore, tracker, blockStorage, store);
      } catch (SQLException | IOException | RuntimeException error) {
        closeQuietly(operationalStore);
        throw error;
      }
    } catch (SQLException | IOException | RuntimeException error) {
      closeQuietly(lock);
      throw error;
    }
  }

  public ProjectTracker tracker() {
    return tracker;
  }

  public OperationalStore operationalStore() {
    return operationalStore;
  }

  public BlockStorage blockStorage() {
    return blockStorage;
  }

  public ChainstateStore chainstateStore() {
    return chainstateStore;
  }

  public UtxoStore utxoStore() {
    return chainstateStore.utxoStore();
  }

  public void refreshTip(String chain) throws SQLException {
    ChainstateStoreFactory.refreshTip(tracker, chainstateStore, chain);
  }

  @Override
  public void close() throws IOException, SQLException {
    try {
      chainstateStore.close();
    } finally {
      try {
        if (operationalStore != null) {
          operationalStore.close();
        }
      } finally {
        lock.close();
      }
    }
  }

  private static void closeQuietly(AutoCloseable closeable) {
    if (closeable == null) {
      return;
    }
    try {
      closeable.close();
    } catch (Exception ignored) {
      // best-effort cleanup while preserving original failure
    }
  }

  private static OperationalStore openOperationalStore(Path dataDir, Map<String, String> env)
      throws IOException {
    String backend = env.getOrDefault("UTXO_BACKEND", "rocksdb").trim().toLowerCase(java.util.Locale.ROOT);
    if ("sqlite".equals(backend)) {
      throw new IOException("Java runtime requires a native UTXO backend");
    }
    return new RocksDbOperationalStore(dataDir.resolve("operational-rocksdb"), true);
  }

  public static Path nativeStorageMarker(Path dataDir) {
    return dataDir.resolve(NATIVE_STORAGE_MARKER);
  }

  private static void markNativeStorage(Path dataDir) throws IOException {
    Files.createDirectories(dataDir);
    Files.writeString(
        nativeStorageMarker(dataDir),
        "native_storage=true" + System.lineSeparator() + "kv_backend=rocksdb" + System.lineSeparator());
  }

}
