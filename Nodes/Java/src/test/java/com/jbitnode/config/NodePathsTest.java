package com.jbitnode.config;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class NodePathsTest {

  @Test
  void defaultsUseDataJava() {
    Path dataDir = NodePaths.dataDir();
    assertTrue(dataDir.isAbsolute());
    assertTrue(dataDir.endsWith(NodePaths.DEFAULT_DATA_DIR.replace("./", "")));
    assertEquals(dataDir.resolve(NodePaths.DEFAULT_DB_NAME), NodePaths.dbPath());
    assertEquals(NodePaths.DEFAULT_CHAIN, NodePaths.chain());
  }

  @Test
  void resolveDataDirUsesDefaultWhenBlank() {
    Path resolved = NodePaths.resolveDataDir("  ");
    assertTrue(resolved.isAbsolute());
    assertTrue(resolved.endsWith("data-java"));
  }

  @Test
  void resolveDataDirHonorsOverride() {
    Path resolved = NodePaths.resolveDataDir("./custom-data");
    assertTrue(resolved.isAbsolute());
    assertTrue(resolved.endsWith("custom-data"));
  }

  @Test
  void resolveChainHonorsOverride() {
    assertEquals("regtest", NodePaths.resolveChain("regtest"));
    assertEquals(NodePaths.DEFAULT_CHAIN, NodePaths.resolveChain(""));
  }

  @Test
  void resolveDbPathHonorsOverride(@TempDir Path tempDir) {
    Path custom = tempDir.resolve("nested/custom.db");
    assertEquals(
        custom.toAbsolutePath().normalize(),
        NodePaths.resolveDbPath(custom.toString(), tempDir));
  }

  @Test
  void resolveDbPathDefaultsUnderDataDir(@TempDir Path tempDir) {
    assertEquals(
        tempDir.resolve(NodePaths.DEFAULT_DB_NAME).toAbsolutePath().normalize(),
        NodePaths.resolveDbPath("", tempDir));
  }

  @Test
  void dbPathFromEnvUsesDataDir(@TempDir Path tempDir) {
    Path dbPath = NodePaths.dbPathFromEnv(tempDir.toString(), null);
    assertEquals(tempDir.resolve(NodePaths.DEFAULT_DB_NAME).toAbsolutePath().normalize(), dbPath);
  }

  @Test
  void constantsAreDocumented() {
    assertEquals("./data-java", NodePaths.DEFAULT_DATA_DIR);
    assertEquals("jbitnode.db", NodePaths.DEFAULT_DB_NAME);
    assertEquals("testnet4", NodePaths.DEFAULT_CHAIN);
  }
}
