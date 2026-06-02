package com.jbitnode.consensus.connect;

/** Block connect failed (validation, ordering, or script blocker). */
public class ConnectBlockException extends Exception {

  public ConnectBlockException(String message) {
    super(message);
  }

  public ConnectBlockException(String message, Throwable cause) {
    super(message, cause);
  }
}
