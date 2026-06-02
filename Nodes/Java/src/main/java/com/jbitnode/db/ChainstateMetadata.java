package com.jbitnode.db;

import java.nio.file.Path;

/** Declares the active operational chainstate backend for a datadir. */
public record ChainstateMetadata(
    String backendName,
    Path backendPath,
    String generationId,
    String status,
    int tipHeight,
    String tipHash,
    String schemaVersion,
    String updatedAt) {

  public boolean usable() {
    return "usable".equals(status);
  }
}
