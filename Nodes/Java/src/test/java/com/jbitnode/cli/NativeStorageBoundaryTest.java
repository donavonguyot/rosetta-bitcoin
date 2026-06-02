package com.jbitnode.cli;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.db.ChainstateSession;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class NativeStorageBoundaryTest {

  @Test
  void nonNativeBackendFailsAtOpenBoundary(@TempDir Path tempDir) {
    var chain = ChainRegistry.get("testnet4");

    IOException error =
        assertThrows(
            IOException.class,
            () ->
                ChainstateSession.openReadWrite(
                    tempDir.resolve("data-java"),
                    tempDir.resolve("ignored.db"),
                    chain,
                    Map.of("UTXO_BACKEND", "sqlite"),
                    false));

    assertTrue(error.getMessage().contains("native UTXO backend"));
  }

  @Test
  void snapshotExportReportsNativeUnsupported() {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();

    int exitCode = ExportSnapshotsService.run(new String[0], new PrintStream(bytes, true, StandardCharsets.UTF_8));

    assertEquals(2, exitCode);
    assertTrue(bytes.toString(StandardCharsets.UTF_8).contains("native_storage_snapshot_export_not_implemented"));
  }

  @Test
  void scriptSurveyReportsNativeUnsupported() throws Exception {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();

    int exitCode = ScriptTemplateSurveyService.run(new String[0], new PrintStream(bytes, true, StandardCharsets.UTF_8));

    assertEquals(2, exitCode);
    assertTrue(bytes.toString(StandardCharsets.UTF_8).contains("native_storage_survey_not_implemented"));
  }

  @Test
  void rocksDbReplayProofWritesArtifact(@TempDir Path tempDir) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    Path proof = tempDir.resolve("java_rocksdb_replay.json");

    int exitCode =
        ChainstateBackendReplayService.run(
            new PrintStream(bytes, true, StandardCharsets.UTF_8),
            Map.of(
                "DATA_DIR",
                tempDir.resolve("data-java-replay").toString(),
                "FIXTURE_BLOCKS_DIR",
                Path.of("src/test/resources/fixtures").toAbsolutePath().normalize().toString(),
                "PROOF_PATH",
                proof.toString(),
                "BLOCKS_MAX",
                "2"));

    assertEquals(0, exitCode);
    assertTrue(Files.exists(proof));
    assertTrue(Files.readString(proof).contains("\"fixture_replay_status\" : \"passed\""));
  }
}
