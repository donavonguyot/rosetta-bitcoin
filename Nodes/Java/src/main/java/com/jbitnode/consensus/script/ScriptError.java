package com.jbitnode.consensus.script;

/** Runtime script evaluation failure (stack underflow, failed verify, unsupported opcode). */
public final class ScriptError extends RuntimeException {

  public ScriptError(String message) {
    super(message);
  }
}
