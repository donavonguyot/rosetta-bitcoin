package com.jbitnode.consensus.script;

import com.jbitnode.util.Hex;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Hash helpers for script evaluation (HASH160 = RIPEMD160(SHA256(x))). */
public final class ScriptHash {

  private ScriptHash() {}

  public static byte[] hash160(byte[] data) {
    return ripemd160(sha256(data));
  }

  public static String hash160Hex(byte[] data) {
    return Hex.encode(hash160(data));
  }

  static byte[] sha1(byte[] data) {
    try {
      return MessageDigest.getInstance("SHA-1").digest(data);
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException("SHA-1 unavailable", e);
    }
  }

  static byte[] sha256(byte[] data) {
    try {
      return MessageDigest.getInstance("SHA-256").digest(data);
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException("SHA-256 unavailable", e);
    }
  }

  /** OP_HASH256: SHA256(SHA256(x)). */
  static byte[] hash256(byte[] data) {
    return sha256(sha256(data));
  }

  /** BIP340/BIP341 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || msg). */
  public static byte[] bitcoinTaggedHash(String tag, byte[] message) {
    byte[] tagDigest = sha256(tag.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    byte[] prefixed = new byte[tagDigest.length + tagDigest.length + message.length];
    System.arraycopy(tagDigest, 0, prefixed, 0, tagDigest.length);
    System.arraycopy(tagDigest, 0, prefixed, tagDigest.length, tagDigest.length);
    System.arraycopy(message, 0, prefixed, tagDigest.length + tagDigest.length, message.length);
    return sha256(prefixed);
  }

  static byte[] ripemd160(byte[] data) {
    return Ripemd160.hash(data);
  }
}
