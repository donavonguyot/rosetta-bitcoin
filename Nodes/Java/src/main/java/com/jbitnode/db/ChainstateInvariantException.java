package com.jbitnode.db;

/** Raised when active chainstate metadata and durable state disagree. */
public final class ChainstateInvariantException extends Exception {
  public ChainstateInvariantException(String message) {
    super(message);
  }
}
