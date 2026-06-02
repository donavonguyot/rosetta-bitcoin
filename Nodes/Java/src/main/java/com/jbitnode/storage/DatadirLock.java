package com.jbitnode.storage;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.Optional;
import java.util.OptionalLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Exclusive datadir lock — one writer per `DATA_DIR` (mirrors TS `.sync_batch_loop.lock`). */
public final class DatadirLock implements AutoCloseable {

  public static final String LOCK_FILE_NAME = ".jbitnode.lock";
  private static final Pattern PID_PATTERN = Pattern.compile("(?m)^pid=(\\d+)");

  private final FileChannel channel;
  private final FileLock lock;

  private DatadirLock(FileChannel channel, FileLock lock) {
    this.channel = channel;
    this.lock = lock;
  }

  public static DatadirLock acquire(Path dataDir) throws IOException {
    Files.createDirectories(dataDir);
    Path lockPath = dataDir.resolve(LOCK_FILE_NAME);
    FileChannel channel =
        FileChannel.open(
            lockPath, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
    final FileLock lock;
    try {
      lock = channel.tryLock();
    } catch (OverlappingFileLockException error) {
      channel.close();
      throw new DatadirLockBusyException(
          "datadir lock busy: "
              + lockPath
              + " (another jbitnode sync is using this DATA_DIR; stop it first)");
    }
    if (lock == null) {
      channel.close();
      throw new DatadirLockBusyException(
          "datadir lock busy: "
              + lockPath
              + " (another jbitnode sync is using this DATA_DIR; stop it first)");
    }
    writeMetadata(channel);
    return new DatadirLock(channel, lock);
  }

  public static OptionalLong readHolderPid(Path dataDir) throws IOException {
    Path lockPath = dataDir.resolve(LOCK_FILE_NAME);
    if (!Files.isRegularFile(lockPath)) {
      return OptionalLong.empty();
    }
    String contents = Files.readString(lockPath, StandardCharsets.UTF_8);
    Matcher matcher = PID_PATTERN.matcher(contents);
    if (matcher.find()) {
      return OptionalLong.of(Long.parseLong(matcher.group(1)));
    }
    return OptionalLong.empty();
  }

  public static Optional<String> readLockMetadata(Path dataDir) throws IOException {
    Path lockPath = dataDir.resolve(LOCK_FILE_NAME);
    if (!Files.isRegularFile(lockPath)) {
      return Optional.empty();
    }
    return Optional.of(Files.readString(lockPath, StandardCharsets.UTF_8).trim());
  }

  private static void writeMetadata(FileChannel channel) throws IOException {
    String metadata =
        "pid="
            + ProcessHandle.current().pid()
            + " started="
            + Instant.now()
            + " holder=SyncLocalCore\n";
    byte[] bytes = metadata.getBytes(StandardCharsets.UTF_8);
    channel.truncate(0);
    channel.write(ByteBuffer.wrap(bytes));
  }

  @Override
  public void close() throws IOException {
    try {
      lock.release();
    } finally {
      channel.close();
    }
  }
}
