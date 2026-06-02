package com.jbitnode.storage;

/** Metadata row for a stored block (mirrors blocks table). */
public record BlockRecord(
    String chain,
    int height,
    String blockHash,
    int fileNumber,
    int fileOffset,
    int blockSize) {}
