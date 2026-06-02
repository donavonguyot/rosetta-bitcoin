package com.jbitnode.storage;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.Arrays;

/** Append-only block flat files (Bitcoin Core blk*.dat style). */
public final class BlockStore {

  public static final long DEFAULT_MAX_FILE_BYTES = 128L * 1024 * 1024;

  private final Path blocksDir;
  private final byte[] magic;
  private final long maxFileBytes;
  private int fileIndex;
  private Path filePath;
  private int offset;

  public BlockStore(Path blocksDir, byte[] magic) {
    this(blocksDir, magic, DEFAULT_MAX_FILE_BYTES);
  }

  public BlockStore(Path blocksDir, byte[] magic, long maxFileBytes) {
    if (magic.length != 4) {
      throw new IllegalArgumentException("network magic must be 4 bytes");
    }
    this.blocksDir = blocksDir;
    this.magic = Arrays.copyOf(magic, 4);
    this.maxFileBytes = maxFileBytes;
    try {
      Files.createDirectories(blocksDir);
    } catch (IOException e) {
      throw new IllegalStateException("cannot create blocks directory " + blocksDir, e);
    }
    this.fileIndex = lastExistingFileIndex(blocksDir);
    this.filePath = openFile(this.fileIndex);
    if (Files.exists(filePath)) {
      try {
        this.offset = (int) Files.size(filePath);
      } catch (IOException e) {
        throw new IllegalStateException("cannot stat " + filePath, e);
      }
    } else {
      this.offset = 0;
    }
  }

  public BlockWriteResult write(byte[] blockData) {
    byte[] sizeHeader = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(blockData.length).array();
    byte[] record = new byte[4 + 4 + blockData.length];
    System.arraycopy(magic, 0, record, 0, 4);
    System.arraycopy(sizeHeader, 0, record, 4, 4);
    System.arraycopy(blockData, 0, record, 8, blockData.length);
    if (offset + record.length > maxFileBytes && offset > 0) {
      fileIndex += 1;
      filePath = openFile(fileIndex);
      offset = 0;
    }
    int recordOffset = offset;
    try {
      Files.write(
          filePath,
          record,
          StandardOpenOption.CREATE,
          StandardOpenOption.WRITE,
          StandardOpenOption.APPEND);
    } catch (IOException e) {
      throw new IllegalStateException("cannot append block to " + filePath, e);
    }
    offset += record.length;
    String fileName = fileNameForIndex(fileIndex);
    return new BlockWriteResult(fileName, fileIndex, recordOffset, blockData.length);
  }

  public byte[] read(String fileName, int recordOffset, int blockSize) {
    Path path = blocksDir.resolve(fileName);
    try (FileChannel channel = FileChannel.open(path, StandardOpenOption.READ)) {
      ByteBuffer magicBuf = ByteBuffer.allocate(4);
      if (channel.read(magicBuf, recordOffset) < 4) {
        throw new IllegalArgumentException("Unexpected EOF reading block");
      }
      magicBuf.flip();
      byte[] readMagic = new byte[4];
      magicBuf.get(readMagic);
      if (!Arrays.equals(readMagic, magic)) {
        throw new IllegalArgumentException("Block file magic mismatch");
      }
      ByteBuffer sizeBuf = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
      if (channel.read(sizeBuf, recordOffset + 4L) < 4) {
        throw new IllegalArgumentException("Unexpected EOF reading block");
      }
      sizeBuf.flip();
      int payloadSize = sizeBuf.getInt();
      if (payloadSize != blockSize) {
        throw new IllegalArgumentException(
            "Block size mismatch: expected " + blockSize + ", file has " + payloadSize);
      }
      ByteBuffer data = ByteBuffer.allocate(blockSize);
      int readBytes = channel.read(data, recordOffset + 8L);
      if (readBytes != blockSize) {
        throw new IllegalArgumentException("Unexpected EOF reading block");
      }
      data.flip();
      byte[] out = new byte[blockSize];
      data.get(out);
      return out;
    } catch (IOException e) {
      throw new IllegalStateException("cannot read block from " + path, e);
    } catch (RuntimeException e) {
      if (e instanceof IllegalArgumentException) {
        throw e;
      }
      throw new IllegalArgumentException("Unexpected EOF reading block", e);
    }
  }

  public boolean hasDataFile(int fileNumber) {
    return Files.exists(blocksDir.resolve(fileNameForIndex(fileNumber)));
  }

  public boolean verifyMagic() {
    Path path = blocksDir.resolve(fileNameForIndex(0));
    if (!Files.exists(path)) {
      return true;
    }
    try {
      if (Files.size(path) < 4) {
        return true;
      }
      try (FileChannel channel = FileChannel.open(path, StandardOpenOption.READ)) {
        ByteBuffer buf = ByteBuffer.allocate(4);
        int read = channel.read(buf, 0);
        if (read < 4) {
          return true;
        }
        buf.flip();
        byte[] readMagic = new byte[4];
        buf.get(readMagic);
        return Arrays.equals(readMagic, magic);
      }
    } catch (IOException e) {
      throw new IllegalStateException("cannot verify magic in " + path, e);
    }
  }

  public Path blocksDir() {
    return blocksDir;
  }

  private Path openFile(int index) {
    Path path = blocksDir.resolve(fileNameForIndex(index));
    if (!Files.exists(path)) {
      try {
        Files.createFile(path);
      } catch (IOException e) {
        throw new IllegalStateException("cannot create " + path, e);
      }
    }
    return path;
  }

  private static int lastExistingFileIndex(Path blocksDir) {
    int index = 0;
    while (Files.exists(blocksDir.resolve(fileNameForIndex(index)))) {
      index += 1;
    }
    return Math.max(0, index - 1);
  }

  static String fileNameForIndex(int index) {
    return "blk%05d.dat".formatted(index);
  }

  static int fileNumberFromName(String fileName) {
    if (!fileName.startsWith("blk") || !fileName.endsWith(".dat")) {
      return 0;
    }
    String digits = fileName.substring(3, fileName.length() - 4);
    return Integer.parseInt(digits);
  }
}
