package com.jbitnode.consensus.script;

/**
 * Raised when a script requires consensus rules not yet implemented in jbitnode (M9/M10 prep).
 *
 * <p>CLTV/CSV throw this when verify flags would activate them; without those flags the opcodes are
 * treated as no-ops (same posture as TypeScript when flags are clear).
 */
public final class UnsupportedScriptRule extends RuntimeException {

  private final String rule;

  public UnsupportedScriptRule(String rule) {
    super("unsupported script rule: " + rule);
    this.rule = rule;
  }

  public String getRule() {
    return rule;
  }
}
