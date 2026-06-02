package com.jbitnode.consensus.script;

/** Bitcoin script opcode constants (mirrors TypeScriptNode/src/consensus/script/opcodes.ts). */
public final class OpCodes {

  public static final int OP_0 = 0x00;
  public static final int OP_PUSHDATA1 = 0x4c;
  public static final int OP_PUSHDATA2 = 0x4d;
  public static final int OP_PUSHDATA4 = 0x4e;
  public static final int OP_1NEGATE = 0x4f;
  public static final int OP_1 = 0x51;
  public static final int OP_16 = 0x60;
  public static final int OP_IF = 0x63;
  public static final int OP_NOTIF = 0x64;
  public static final int OP_ELSE = 0x67;
  public static final int OP_ENDIF = 0x68;
  public static final int OP_TOALTSTACK = 0x6b;
  public static final int OP_FROMALTSTACK = 0x6c;
  public static final int OP_TUCK = 0x7d;
  public static final int OP_PICK = 0x79;
  public static final int OP_IFDUP = 0x73;
  public static final int OP_2DROP = 0x6d;
  public static final int OP_2DUP = 0x6e;
  public static final int OP_3DUP = 0x6f;
  public static final int OP_2OVER = 0x70;
  public static final int OP_2SWAP = 0x72;
  public static final int OP_DEPTH = 0x74;
  public static final int OP_ROLL = 0x7a;
  public static final int OP_DROP = 0x75;
  public static final int OP_DUP = 0x76;
  public static final int OP_NIP = 0x77;
  public static final int OP_OVER = 0x78;
  public static final int OP_0NOTEQUAL = 0x92;
  public static final int OP_NOT = 0x91;
  public static final int OP_1SUB = 0x8c;
  public static final int OP_NEGATE = 0x8f;
  public static final int OP_ABS = 0x90;
  public static final int OP_ADD = 0x93;
  public static final int OP_SUB = 0x94;
  public static final int OP_MIN = 0xa3;
  public static final int OP_MAX = 0xa4;
  public static final int OP_WITHIN = 0xa5;
  public static final int OP_RIPEMD160 = 0xa6;
  public static final int OP_MUL = 0x95;
  public static final int OP_ROT = 0x7b;
  public static final int OP_SIZE = 0x82;
  public static final int OP_SWAP = 0x7c;
  public static final int OP_EQUAL = 0x87;
  public static final int OP_EQUALVERIFY = 0x88;
  public static final int OP_VERIFY = 0x69;
  public static final int OP_SHA1 = 0xa7;
  public static final int OP_SHA256 = 0xa8;
  public static final int OP_HASH256 = 0xaa;
  public static final int OP_HASH160 = 0xa9;
  public static final int OP_CODESEPARATOR = 0xab;
  public static final int OP_CHECKSIG = 0xac;
  public static final int OP_CHECKSIGVERIFY = 0xad;
  public static final int OP_CHECKMULTISIG = 0xae;
  public static final int OP_CHECKMULTISIGVERIFY = 0xaf;
  public static final int OP_BOOLAND = 0x9a;
  public static final int OP_BOOLOR = 0x9b;
  public static final int OP_NUMEQUAL = 0x9c;
  public static final int OP_NUMEQUALVERIFY = 0x9d;
  public static final int OP_NUMNOTEQUAL = 0x9e;
  public static final int OP_LESSTHAN = 0x9f;
  public static final int OP_GREATERTHAN = 0xa0;
  public static final int OP_LESSTHANOREQUAL = 0xa1;
  public static final int OP_GREATERTHANOREQUAL = 0xa2;
  public static final int OP_CHECKSIGADD = 0xba;
  public static final int OP_CHECKLOCKTIMEVERIFY = 0xb1;
  public static final int OP_CHECKSEQUENCEVERIFY = 0xb2;
  public static final int OP_NOP = 0x61;

  private OpCodes() {}
}
