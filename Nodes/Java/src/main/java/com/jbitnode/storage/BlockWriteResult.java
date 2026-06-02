package com.jbitnode.storage;

/** Result of appending one block record to a blk*.dat flat file. */
public record BlockWriteResult(String fileName, int fileNumber, int offset, int blockSize) {}
