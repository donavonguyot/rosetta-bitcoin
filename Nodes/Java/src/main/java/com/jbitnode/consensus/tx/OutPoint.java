package com.jbitnode.consensus.tx;

/** Previous transaction output reference (txid + vout). */
public record OutPoint(byte[] hash, long index) {

  public OutPoint {
    if (hash.length != 32) {
      throw new IllegalArgumentException("outpoint hash must be 32 bytes");
    }
  }
}
