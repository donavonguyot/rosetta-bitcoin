package com.jbitnode.db;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.SQLException;
import java.time.Instant;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/** Opens the active operational chainstate backend and records backend metadata. */
public final class ChainstateStoreFactory {

  public static final int CHAINSTATE_SCHEMA_VERSION = 1;

  static final String META_PREFIX = "chainstate.";
  static final String BACKEND_NAME = META_PREFIX + "backend_name";
  static final String BACKEND_PATH = META_PREFIX + "backend_path";
  static final String GENERATION_ID = META_PREFIX + "generation_id";
  static final String STATUS = META_PREFIX + "status";
  static final String TIP_HEIGHT = META_PREFIX + "tip_height";
  static final String TIP_HASH = META_PREFIX + "tip_hash";
  static final String UTXO_COUNT = META_PREFIX + "utxo_count";
  static final String SCHEMA_VERSION = META_PREFIX + "schema_version";
  static final String CODEC_VERSION = META_PREFIX + "codec_version";
  static final String UPDATED_AT = META_PREFIX + "updated_at";

  private ChainstateStoreFactory() {}

  public static ChainstateStore open(
      ProjectTracker tracker,
      Path dataDir,
      String chain,
      Map<String, String> env,
      ChainstateOpenMode mode)
      throws IOException, SQLException {
    verifyRequestedBackendMatchesActiveDeclaration(tracker, dataDir, chain, env);
    UtxoStoreFactory.OpenedUtxoStore opened = UtxoStoreFactory.open(tracker, dataDir, env);
    Path backendPath = backendPath(dataDir, opened, env);
    ChainstateMetadata metadata = ensureMetadata(tracker, opened, backendPath, chain, mode);
    mirrorMetadataToNativeStore(opened, metadata);
    return new OpenedChainstateStore(tracker, chain, opened, metadata);
  }

  private static void verifyRequestedBackendMatchesActiveDeclaration(
      ProjectTracker tracker, Path dataDir, String chain, Map<String, String> env)
      throws SQLException {
    if (tracker.getMeta(BACKEND_NAME) == null) {
      return;
    }
    ChainstateMetadata existing = readMetadata(tracker, dataDir, chain);
    String requestedBackend =
        env.getOrDefault("UTXO_BACKEND", "rocksdb").trim().toLowerCase(Locale.ROOT);
    if (requestedBackend.isBlank()) {
      requestedBackend = "rocksdb";
    }
    if (!existing.backendName().equals(requestedBackend)) {
      throw new SQLException(
          "active chainstate backend is "
              + existing.backendName()
              + " at "
              + existing.backendPath()
              + "; refusing silent switch to "
              + requestedBackend
              + " (use chainstate rebuild/promote)");
    }
    Path requestedPath = backendPath(dataDir, requestedBackend, env);
    if (!Files.exists(existing.backendPath())) {
      throw new SQLException(
          "active "
              + existing.backendName()
              + " chainstate path is missing: "
              + existing.backendPath());
    }
    if (!existing.backendPath().equals(requestedPath)) {
      throw new SQLException(
          "active chainstate backend path is "
              + existing.backendPath()
              + "; refusing silent switch to "
              + requestedPath
              + " (use chainstate rebuild/promote)");
    }
  }

  public static ChainstateMetadata readMetadata(ProjectTracker tracker, Path dataDir, String chain)
      throws SQLException {
    String backendName = tracker.getMeta(BACKEND_NAME);
    if (backendName == null || backendName.isBlank()) {
      return nativeDefaultMetadata(tracker, dataDir, chain);
    }
    return new ChainstateMetadata(
        backendName,
        Path.of(valueOrDefault(tracker.getMeta(BACKEND_PATH), dataDir.resolve("utxos-sqlite").toString()))
            .toAbsolutePath()
            .normalize(),
        valueOrDefault(tracker.getMeta(GENERATION_ID), generationId(backendName)),
        valueOrDefault(tracker.getMeta(STATUS), "usable"),
        parseInt(tracker.getMeta(TIP_HEIGHT), tracker.getValidatedHeight(chain)),
        valueOrDefault(tracker.getMeta(TIP_HASH), tracker.getValidatedHash(chain)),
        parseLong(tracker.getMeta(UTXO_COUNT), -1),
        valueOrDefault(tracker.getMeta(SCHEMA_VERSION), Integer.toString(CHAINSTATE_SCHEMA_VERSION)),
        valueOrDefault(tracker.getMeta(UPDATED_AT), nowIso()));
  }

  public static void refreshTip(ProjectTracker tracker, ChainstateStore store, String chain)
      throws SQLException {
    ChainstateTip tip = store.tip();
    ChainstateMetadata existing = store.metadata();
    ChainstateMetadata updated =
        new ChainstateMetadata(
            existing.backendName(),
            existing.backendPath(),
            existing.generationId(),
            "usable",
            tip.height(),
            tip.hash(),
            statsUtxoCount(store, existing),
            existing.schemaVersion(),
            nowIso());
    writeMetadata(tracker, updated);
    if (store.utxoStore() instanceof RocksDbChainstateStore rocksDb) {
      writeRocksDbMetadata(rocksDb, updated);
    }
    if (store instanceof OpenedChainstateStore opened) {
      opened.refreshMetadata(updated);
    }
  }

  public static void writeMetadata(ProjectTracker tracker, ChainstateMetadata metadata) throws SQLException {
    tracker.setMeta(BACKEND_NAME, metadata.backendName());
    tracker.setMeta(BACKEND_PATH, metadata.backendPath().toString());
    tracker.setMeta(GENERATION_ID, metadata.generationId());
    tracker.setMeta(STATUS, metadata.status());
    tracker.setMeta(TIP_HEIGHT, Integer.toString(metadata.tipHeight()));
    tracker.setMeta(TIP_HASH, valueOrDefault(metadata.tipHash(), ""));
    tracker.setMeta(UTXO_COUNT, Long.toString(metadata.utxoCount()));
    tracker.setMeta(SCHEMA_VERSION, metadata.schemaVersion());
    tracker.setMeta(UPDATED_AT, metadata.updatedAt());
  }

  private static ChainstateMetadata ensureMetadata(
      ProjectTracker tracker,
      UtxoStoreFactory.OpenedUtxoStore opened,
      Path backendPath,
      String chain,
      ChainstateOpenMode mode)
      throws SQLException {
    ChainstateMetadata existing = readMetadata(tracker, backendPath.getParent(), chain);
    int currentTipHeight = tracker.getValidatedHeight(chain);
    String currentTipHash = tracker.getValidatedHash(chain);
    boolean hasDeclaration = tracker.getMeta(BACKEND_NAME) != null;
    if (hasDeclaration && !existing.backendName().equals(opened.backend())) {
      throw new SQLException(
          "active chainstate backend is "
              + existing.backendName()
              + " at "
              + existing.backendPath()
              + "; refusing silent switch to "
              + opened.backend()
              + " (use chainstate rebuild/promote)");
    }
    ChainstateMetadata metadata =
        new ChainstateMetadata(
            opened.backend(),
            backendPath,
            hasDeclaration ? existing.generationId() : generationId(opened.backend()),
            mode == ChainstateOpenMode.REBUILD ? "rebuilding" : "usable",
            currentTipHeight,
            currentTipHash,
            existing.utxoCount(),
            Integer.toString(CHAINSTATE_SCHEMA_VERSION),
            nowIso());
    writeMetadata(tracker, metadata);
    return metadata;
  }

  private static ChainstateMetadata nativeDefaultMetadata(
      ProjectTracker tracker, Path dataDir, String chain) throws SQLException {
    return new ChainstateMetadata(
        "rocksdb",
        dataDir.resolve("utxo-rocksdb").toAbsolutePath().normalize(),
        generationId("rocksdb"),
        "usable",
        tracker.getValidatedHeight(chain),
        tracker.getValidatedHash(chain),
        parseLong(tracker.getMeta(UTXO_COUNT), -1),
        Integer.toString(CHAINSTATE_SCHEMA_VERSION),
        nowIso());
  }

  private static void mirrorMetadataToNativeStore(
      UtxoStoreFactory.OpenedUtxoStore opened, ChainstateMetadata metadata) throws SQLException {
    if (opened.store() instanceof RocksDbChainstateStore rocksDb) {
      writeRocksDbMetadata(rocksDb, metadata);
    }
  }

  private static void writeRocksDbMetadata(RocksDbChainstateStore rocksDb, ChainstateMetadata metadata)
      throws SQLException {
    rocksDb.putMetadata(BACKEND_NAME, metadata.backendName());
    rocksDb.putMetadata(BACKEND_PATH, metadata.backendPath().toString());
    rocksDb.putMetadata(GENERATION_ID, metadata.generationId());
    rocksDb.putMetadata(STATUS, metadata.status());
    rocksDb.putMetadata(TIP_HEIGHT, Integer.toString(metadata.tipHeight()));
    rocksDb.putMetadata(TIP_HASH, valueOrDefault(metadata.tipHash(), ""));
    rocksDb.putMetadata(UTXO_COUNT, Long.toString(metadata.utxoCount()));
    rocksDb.putMetadata(SCHEMA_VERSION, metadata.schemaVersion());
    rocksDb.putMetadata(CODEC_VERSION, "2");
    rocksDb.putMetadata(UPDATED_AT, metadata.updatedAt());
  }

  private static Path backendPath(
      Path dataDir, UtxoStoreFactory.OpenedUtxoStore opened, Map<String, String> env) {
    if ("rocksdb".equals(opened.backend())) {
      return Path.of(env.getOrDefault("ROCKSDB_DIR", dataDir.resolve("utxo-rocksdb").toString()))
          .toAbsolutePath()
          .normalize();
    }
    throw new IllegalArgumentException("unsupported UTXO_BACKEND: " + opened.backend());
  }

  private static Path backendPath(Path dataDir, String backend, Map<String, String> env) {
    if ("rocksdb".equals(backend)) {
      return Path.of(env.getOrDefault("ROCKSDB_DIR", dataDir.resolve("utxo-rocksdb").toString()))
          .toAbsolutePath()
          .normalize();
    }
    throw new IllegalArgumentException("unsupported UTXO_BACKEND: " + backend);
  }

  private static String generationId(String backend) {
    return backend + "-" + UUID.randomUUID();
  }

  private static String nowIso() {
    return Instant.now().toString();
  }

  private static int parseInt(String value, int defaultValue) {
    if (value == null || value.isBlank()) {
      return defaultValue;
    }
    return Integer.parseInt(value);
  }

  private static long parseLong(String value, long defaultValue) {
    if (value == null || value.isBlank()) {
      return defaultValue;
    }
    return Long.parseLong(value);
  }

  private static long statsUtxoCount(ChainstateStore store, ChainstateMetadata existing)
      throws SQLException {
    if (existing.utxoCount() >= 0) {
      return existing.utxoCount();
    }
    return store.stats().utxoCount();
  }

  private static String valueOrDefault(String value, String defaultValue) {
    return value == null || value.isBlank() ? defaultValue : value;
  }
}
