package com.jbitnode.storage;

import java.io.IOException;

/** Raised when another jbitnode process already holds the datadir lock. */
public final class DatadirLockBusyException extends IOException {

  public DatadirLockBusyException(String message) {
    super(message);
  }
}
