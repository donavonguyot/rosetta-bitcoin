package com.jbitnode.consensus;

/** 80-byte Bitcoin block header fields (internal little-endian layout). */
public record BlockHeader(
    int version,
    byte[] prevBlock,
    byte[] merkleRoot,
    long timestamp,
    long bits,
    long nonce) {

  public BlockHeader {
    if (prevBlock.length != 32 || merkleRoot.length != 32) {
      throw new IllegalArgumentException("prevBlock and merkleRoot must be 32 bytes");
    }
  }
}
