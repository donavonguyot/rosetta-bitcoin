package com.jbitnode.db;

import com.jbitnode.db.ProjectTracker.StoredUtxo;
import com.jbitnode.db.ProjectTracker.UtxoUndoEntry;
import com.jbitnode.util.Hex;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/** Shared native chainstate key/value encoding for byte-oriented KV backends. */
final class NativeChainstateCodec {

  private static final byte UTXO_PREFIX = 'u';
  private static final byte META_PREFIX = 'm';
  private static final byte TIP_PREFIX = 't';
  private static final byte UNDO_PREFIX = 'd';
  private static final byte BLOCK_INDEX_PREFIX = 'b';
  private static final byte HEADER_PREFIX = 'h';

  private NativeChainstateCodec() {}

  static byte[] utxoKey(String chain, String txidHex, int vout) {
    byte[] prefix = utxoKeyPrefix(chain);
    byte[] txidBytes = txidHex.getBytes(StandardCharsets.US_ASCII);
    ByteArrayOutputStream out = new ByteArrayOutputStream(prefix.length + txidBytes.length + 1 + 4);
    try {
      out.write(prefix);
      out.write(txidBytes);
      out.write(0);
      out.write(new byte[] {(byte) (vout >>> 24), (byte) (vout >>> 16), (byte) (vout >>> 8), (byte) vout});
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate UTXO key serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] utxoKeyV2(String chain, String txidHex, int vout) {
    return utxoKeyV2(chain, Hex.decode(txidHex), vout);
  }

  static byte[] utxoKeyV2(String chain, byte[] txidBytes, int vout) {
    byte[] prefix = chainPrefix(UTXO_PREFIX, chain);
    ByteArrayOutputStream out = new ByteArrayOutputStream(prefix.length + txidBytes.length + 4);
    try {
      out.write(prefix);
      out.write(txidBytes);
      writeU32(out, vout);
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate v2 UTXO key serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] utxoKeyPrefixV2(String chain) {
    return chainPrefix(UTXO_PREFIX, chain);
  }

  static byte[] utxoKeyPrefix(String chain) {
    byte[] chainBytes = chain.getBytes(StandardCharsets.UTF_8);
    ByteArrayOutputStream out = new ByteArrayOutputStream(chainBytes.length + 2);
    out.write(UTXO_PREFIX);
    out.write(chainBytes.length);
    try {
      out.write(chainBytes);
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate UTXO key prefix serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] metadataKey(String key) {
    byte[] keyBytes = key.getBytes(StandardCharsets.UTF_8);
    ByteArrayOutputStream out = new ByteArrayOutputStream(keyBytes.length + 2);
    out.write(META_PREFIX);
    out.write(0);
    try {
      out.write(keyBytes);
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate metadata key serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] metadataKeyV2(String key) {
    byte[] keyBytes = key.getBytes(StandardCharsets.UTF_8);
    ByteArrayOutputStream out = new ByteArrayOutputStream(keyBytes.length + 2);
    out.write(META_PREFIX);
    out.write(keyBytes.length);
    try {
      out.write(keyBytes);
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate v2 metadata key serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] metadataValue(String value) {
    return value.getBytes(StandardCharsets.UTF_8);
  }

  static String decodeMetadataValue(byte[] value) {
    return new String(value, StandardCharsets.UTF_8);
  }

  static byte[] tipKey(String chain) {
    byte[] chainBytes = chain.getBytes(StandardCharsets.UTF_8);
    ByteArrayOutputStream out = new ByteArrayOutputStream(chainBytes.length + 2);
    out.write(TIP_PREFIX);
    out.write(0);
    try {
      out.write(chainBytes);
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate tip key serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] tipKeyV2(String chain) {
    return chainPrefix(TIP_PREFIX, chain);
  }

  static byte[] undoKey(String chain, int height) {
    byte[] chainBytes = chain.getBytes(StandardCharsets.UTF_8);
    ByteArrayOutputStream out = new ByteArrayOutputStream(chainBytes.length + 2 + 4);
    out.write(UNDO_PREFIX);
    out.write(chainBytes.length);
    try {
      out.write(chainBytes);
      out.write(new byte[] {(byte) (height >>> 24), (byte) (height >>> 16), (byte) (height >>> 8), (byte) height});
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate undo key serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] undoKeyV2(String chain, int height) {
    byte[] prefix = chainPrefix(UNDO_PREFIX, chain);
    ByteArrayOutputStream out = new ByteArrayOutputStream(prefix.length + 4);
    try {
      out.write(prefix);
      writeU32(out, height);
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate v2 undo key serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] blockIndexKeyV2(String chain, int height) {
    byte[] prefix = chainPrefix(BLOCK_INDEX_PREFIX, chain);
    ByteArrayOutputStream out = new ByteArrayOutputStream(prefix.length + 4);
    try {
      out.write(prefix);
      writeU32(out, height);
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate v2 block index key serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] headerKeyV2(String chain, int height) {
    byte[] prefix = chainPrefix(HEADER_PREFIX, chain);
    ByteArrayOutputStream out = new ByteArrayOutputStream(prefix.length + 4);
    try {
      out.write(prefix);
      writeU32(out, height);
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate v2 header key serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] encodeUtxoV2(StoredUtxo utxo) throws IOException {
    byte[] script = utxo.scriptPubKey();
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(4 + 8 + 1 + 4 + script.length);
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      out.writeInt(utxo.height());
      out.writeLong(utxo.valueSats());
      out.writeByte(utxo.coinbase() ? 1 : 0);
      writeBytes(out, script);
    }
    return bytes.toByteArray();
  }

  static StoredUtxo decodeUtxoV2(byte[] txid, int vout, byte[] value) throws SQLException {
    try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(value))) {
      int height = in.readInt();
      long valueSats = in.readLong();
      boolean coinbase = (in.readUnsignedByte() & 1) != 0;
      byte[] script = readBytes(in);
      return new StoredUtxo(txid, vout, height, valueSats, script, coinbase);
    } catch (IOException error) {
      throw new SQLException("native chainstate v2 UTXO decode failed", error);
    }
  }

  static byte[] encodeTip(ChainstateTip tip) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(4 + 4 + tip.hash().length());
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      out.writeInt(tip.height());
      writeString(out, tip.hash());
    }
    return bytes.toByteArray();
  }

  static byte[] encodeTipV2(ChainstateTip tip) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(4 + 32);
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      out.writeInt(tip.height());
      out.write(Hex.decode(tip.hash()));
    }
    return bytes.toByteArray();
  }

  static ChainstateTip decodeTip(byte[] value) throws SQLException {
    try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(value))) {
      return new ChainstateTip(in.readInt(), readString(in));
    } catch (IOException error) {
      throw new SQLException("native chainstate tip decode failed", error);
    }
  }

  static ChainstateTip decodeTipV2(byte[] value) throws SQLException {
    try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(value))) {
      int height = in.readInt();
      byte[] hash = in.readNBytes(32);
      if (hash.length != 32) {
        throw new IOException("truncated tip hash");
      }
      return new ChainstateTip(height, Hex.encode(hash));
    } catch (IOException error) {
      throw new SQLException("native chainstate v2 tip decode failed", error);
    }
  }

  static byte[] encodeUndoV2(List<UtxoUndoEntry> entries) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      out.writeInt(entries.size());
      for (UtxoUndoEntry entry : entries) {
        out.write(entry.txid());
        out.writeInt(entry.vout());
        out.writeInt(entry.height());
        out.writeLong(entry.valueSats());
        out.writeByte(entry.coinbase() ? 1 : 0);
        writeBytes(out, entry.scriptPubKey());
      }
    }
    return bytes.toByteArray();
  }

  static List<UtxoUndoEntry> decodeUndoV2(byte[] value) throws SQLException {
    try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(value))) {
      int count = in.readInt();
      ArrayList<UtxoUndoEntry> entries = new ArrayList<>(count);
      for (int index = 0; index < count; index++) {
        byte[] txid = in.readNBytes(32);
        if (txid.length != 32) {
          throw new IOException("truncated undo txid");
        }
        int vout = in.readInt();
        int height = in.readInt();
        long valueSats = in.readLong();
        boolean coinbase = (in.readUnsignedByte() & 1) != 0;
        byte[] script = readBytes(in);
        entries.add(new UtxoUndoEntry(txid, vout, height, valueSats, script, coinbase));
      }
      return entries;
    } catch (IOException error) {
      throw new SQLException("native chainstate v2 undo decode failed", error);
    }
  }

  static byte[] encodeBlockIndexV2(String blockHashHex, int fileNumber, int fileOffset, int blockSize)
      throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(32 + 4 + 4 + 4);
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      out.write(Hex.decode(blockHashHex));
      out.writeInt(fileNumber);
      out.writeInt(fileOffset);
      out.writeInt(blockSize);
    }
    return bytes.toByteArray();
  }

  static byte[] encodeHeaderV2(byte[] serializedHeader) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream(4 + serializedHeader.length);
    try (DataOutputStream out = new DataOutputStream(bytes)) {
      writeBytes(out, serializedHeader);
    }
    return bytes.toByteArray();
  }

  static boolean startsWith(byte[] value, byte[] prefix) {
    if (value.length < prefix.length) {
      return false;
    }
    for (int index = 0; index < prefix.length; index++) {
      if (value[index] != prefix[index]) {
        return false;
      }
    }
    return true;
  }

  private static void writeString(DataOutputStream out, String value) throws IOException {
    byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
    out.writeInt(bytes.length);
    out.write(bytes);
  }

  private static byte[] chainPrefix(byte prefix, String chain) {
    byte[] chainBytes = chain.getBytes(StandardCharsets.UTF_8);
    ByteArrayOutputStream out = new ByteArrayOutputStream(chainBytes.length + 2);
    out.write(prefix);
    out.write(chainBytes.length);
    try {
      out.write(chainBytes);
    } catch (IOException error) {
      throw new IllegalStateException("native chainstate v2 prefix serialization failed", error);
    }
    return out.toByteArray();
  }

  private static void writeU32(ByteArrayOutputStream out, int value) {
    out.write((byte) (value >>> 24));
    out.write((byte) (value >>> 16));
    out.write((byte) (value >>> 8));
    out.write((byte) value);
  }

  private static void writeBytes(DataOutputStream out, byte[] value) throws IOException {
    out.writeInt(value.length);
    out.write(value);
  }

  private static byte[] readBytes(DataInputStream in) throws IOException {
    int length = in.readInt();
    byte[] bytes = in.readNBytes(length);
    if (bytes.length != length) {
      throw new IOException("truncated bytes");
    }
    return bytes;
  }

  private static String readString(DataInputStream in) throws IOException {
    int length = in.readInt();
    byte[] bytes = in.readNBytes(length);
    if (bytes.length != length) {
      throw new IOException("truncated string");
    }
    return new String(bytes, StandardCharsets.UTF_8);
  }
}
