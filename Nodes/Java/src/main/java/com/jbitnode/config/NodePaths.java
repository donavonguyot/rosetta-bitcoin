package com.jbitnode.config;

import java.nio.file.Path;

/** Resolved datadir and database paths for jbitnode. */
public final class NodePaths {

  public static final String DEFAULT_DATA_DIR = "./data-java";
  public static final String DEFAULT_DB_NAME = "jbitnode.db";
  public static final String DEFAULT_CHAIN = "testnet4";

  private NodePaths() {}

  public static Path dataDir() {
    return resolveDataDir(System.getenv("DATA_DIR"));
  }

  public static Path dbPath() {
    return dbPathFromEnv(System.getenv("DATA_DIR"), System.getenv("DB_PATH"));
  }

  public static Path dbPathFromEnv(String dataDirEnv, String dbPathEnv) {
    return resolveDbPath(dbPathEnv, resolveDataDir(dataDirEnv));
  }

  static Path resolveDbPath(String dbPathEnv, Path dataDir) {
    if (dbPathEnv != null && !dbPathEnv.isBlank()) {
      return java.nio.file.Paths.get(dbPathEnv).toAbsolutePath().normalize();
    }
    return dataDir.resolve(DEFAULT_DB_NAME);
  }

  public static String chain() {
    return resolveChain(System.getenv("CHAIN"));
  }

  static Path resolveDataDir(String raw) {
    if (raw == null || raw.isBlank()) {
      raw = DEFAULT_DATA_DIR;
    }
    return java.nio.file.Paths.get(raw).toAbsolutePath().normalize();
  }

  static String resolveChain(String raw) {
    if (raw == null || raw.isBlank()) {
      return DEFAULT_CHAIN;
    }
    return raw;
  }
}
