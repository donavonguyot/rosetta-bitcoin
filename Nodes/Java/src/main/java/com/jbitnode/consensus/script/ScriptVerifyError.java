package com.jbitnode.consensus.script;

/** Raised when script verification fails at the transaction input boundary. */
public final class ScriptVerifyError extends RuntimeException {

  public ScriptVerifyError(String message) {
    super(message);
  }
}
