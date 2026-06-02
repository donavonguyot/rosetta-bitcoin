package com.jbitnode.consensus.script;

import com.jbitnode.wire.WireSerialize;
import java.util.Arrays;

/** Reads push-data opcodes from a serialized script. */
public final class ScriptPush {

  private ScriptPush() {}

  public record PushResult(byte[] item, int nextOffset) {}

  public static PushResult readPush(byte[] script, int offset) {
    int opcode = script[offset] & 0xff;
    int cursor = offset + 1;
    int length;
    if (opcode >= 1 && opcode <= 75) {
      length = opcode;
    } else if (opcode == OpCodes.OP_PUSHDATA1) {
      length = script[cursor++] & 0xff;
    } else if (opcode == OpCodes.OP_PUSHDATA2) {
      length = (script[cursor] & 0xff) | ((script[cursor + 1] & 0xff) << 8);
      cursor += 2;
    } else if (opcode == OpCodes.OP_PUSHDATA4) {
      length = (int) WireSerialize.unpackUint32Le(script, cursor);
      cursor += 4;
    } else {
      throw new ScriptError("invalid push opcode 0x" + Integer.toHexString(opcode));
    }
    if (cursor + length > script.length) {
      throw new ScriptError("push exceeds script length");
    }
    byte[] item = Arrays.copyOfRange(script, cursor, cursor + length);
    return new PushResult(item, cursor + length);
  }
}
