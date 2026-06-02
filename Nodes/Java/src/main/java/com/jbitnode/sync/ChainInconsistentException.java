package com.jbitnode.sync;

/** Raised when SQLite chain state cannot safely advance without a rebuild. */
public final class ChainInconsistentException extends Exception {

  public ChainInconsistentException(String message) {
    super(message);
  }
}
