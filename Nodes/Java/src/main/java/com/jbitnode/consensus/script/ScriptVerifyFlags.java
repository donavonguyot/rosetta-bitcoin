package com.jbitnode.consensus.script;

/** Script verification flag bits (mirrors TypeScriptNode opcodes.ts). */
public final class ScriptVerifyFlags {

  public static final int SCRIPT_VERIFY_P2SH = 1 << 0;
  public static final int SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY = 1 << 10;
  public static final int SCRIPT_VERIFY_CHECKSEQUENCEVERIFY = 1 << 11;

  public static final int SCRIPT_VERIFY_DEFAULT =
      SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY | SCRIPT_VERIFY_CHECKSEQUENCEVERIFY;

  private ScriptVerifyFlags() {}
}
