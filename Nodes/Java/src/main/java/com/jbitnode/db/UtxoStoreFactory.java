package com.jbitnode.db;

import java.io.IOException;
import java.nio.file.Path;
import java.util.Locale;
import java.util.Map;

/** Opens the Java hot UTXO backend. RocksDB is the only runtime backend. */
public final class UtxoStoreFactory {

  private UtxoStoreFactory() {}

  public static OpenedUtxoStore open(ProjectTracker tracker, Path dataDir, Map<String, String> env)
      throws IOException {
    String backend = env.getOrDefault("UTXO_BACKEND", "rocksdb").trim().toLowerCase(Locale.ROOT);
    return switch (backend) {
      case "", "sqlite" -> throw new IllegalArgumentException("Java runtime requires a native UTXO backend");
      case "rocksdb" -> {
        Path rocksDbDir =
            Path.of(env.getOrDefault("ROCKSDB_DIR", dataDir.resolve("utxo-rocksdb").toString()))
                .toAbsolutePath()
                .normalize();
        try {
          RocksDbChainstateStore store = new RocksDbChainstateStore(rocksDbDir, true);
          yield new OpenedUtxoStore("rocksdb", store, store::close);
        } catch (org.rocksdb.RocksDBException error) {
          throw new IOException("failed to open RocksDB chainstate at " + rocksDbDir, error);
        }
      }
      default -> throw new IllegalArgumentException("unsupported UTXO_BACKEND: " + backend);
    };
  }

  public record OpenedUtxoStore(String backend, UtxoStore store, CloseAction closeAction)
      implements AutoCloseable {
    @Override
    public void close() throws IOException {
      closeAction.close();
    }
  }

  @FunctionalInterface
  public interface CloseAction {
    void close() throws IOException;
  }
}
