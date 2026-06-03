package com.jbitnode.db;

import org.rocksdb.BlockBasedTableConfig;
import org.rocksdb.BloomFilter;
import org.rocksdb.LRUCache;
import org.rocksdb.Options;

/**
 * Shared RocksDB {@link Options} tuning for the native stores.
 *
 * <p>Adds a block cache + bloom filter (cuts disk reads and makes negative point lookups cheap on
 * the UTXO / block-index hot path) and larger write buffers with more memtables (fewer, bigger
 * flushes during bulk catch-up). The bare {@code new Options().setCreateIfMissing(...)} the stores
 * used previously left every read going to the OS page cache only and every write on a small 64 MB
 * default memtable.
 *
 * <p>The native cache/filter handles are owned by {@link Tuned} and must be released (after the DB
 * is closed) via {@link Tuned#closeResources()}.
 */
final class RocksDbTuning {

  private RocksDbTuning() {}

  record Tuned(Options options, LRUCache blockCache, BloomFilter filter) {
    void closeResources() {
      filter.close();
      blockCache.close();
      options.close();
    }
  }

  static Tuned create(
      boolean createIfMissing, long blockCacheBytes, long writeBufferBytes, int maxWriteBufferNumber) {
    LRUCache blockCache = new LRUCache(blockCacheBytes);
    BloomFilter filter = new BloomFilter(10);
    BlockBasedTableConfig tableConfig =
        new BlockBasedTableConfig()
            .setBlockCache(blockCache)
            .setFilterPolicy(filter)
            .setCacheIndexAndFilterBlocks(true)
            .setPinL0FilterAndIndexBlocksInCache(true);
    Options options =
        new Options()
            .setCreateIfMissing(createIfMissing)
            .setTableFormatConfig(tableConfig)
            .setWriteBufferSize(writeBufferBytes)
            .setMaxWriteBufferNumber(maxWriteBufferNumber)
            .setMaxBackgroundJobs(4);
    return new Tuned(options, blockCache, filter);
  }

  static boolean envFlag(String value) {
    return value != null && ("1".equals(value.trim()) || "true".equalsIgnoreCase(value.trim()));
  }
}
