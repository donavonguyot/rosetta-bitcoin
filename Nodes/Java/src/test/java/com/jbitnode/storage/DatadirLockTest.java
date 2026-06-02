package com.jbitnode.storage;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class DatadirLockTest {

  @Test
  void acquireAndRelease(@TempDir Path tempDir) throws Exception {
    try (DatadirLock lock = DatadirLock.acquire(tempDir)) {
      assertDoesNotThrow(() -> {});
    }
  }

  @Test
  void rejectsSecondWriter(@TempDir Path tempDir) throws Exception {
    try (DatadirLock first = DatadirLock.acquire(tempDir)) {
      assertThrows(DatadirLockBusyException.class, () -> DatadirLock.acquire(tempDir));
    }
  }

  @Test
  void lockFileRecordsHolderPid(@TempDir Path tempDir) throws Exception {
    try (DatadirLock lock = DatadirLock.acquire(tempDir)) {
      var pid = DatadirLock.readHolderPid(tempDir);
      assertTrue(pid.isPresent());
      assertEquals(ProcessHandle.current().pid(), pid.getAsLong());
      var metadata = DatadirLock.readLockMetadata(tempDir);
      assertTrue(metadata.orElse("").contains("holder=SyncLocalCore"));
    }
  }
}
