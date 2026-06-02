package com.jbitnode.sync;

/** Block structure or consensus header check failed during connect prep. */
public final class BlockValidationException extends Exception {

  public BlockValidationException(String message) {
    super(message);
  }

  public BlockValidationException(String message, Throwable cause) {
    super(message, cause);
  }
}
