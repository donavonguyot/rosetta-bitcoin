package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

class ScriptTemplatesBareOpNTest {

  @Test
  void acceptsSingleOpcodeAndOp1WithTrailingPush() {
    assertTrue(ScriptTemplates.isBareOpN(new byte[] {(byte) OpCodes.OP_1}));
    assertTrue(ScriptTemplates.isBareOpN(Hex.decode("51024e73")));
    assertTrue(ScriptTemplates.isBareOpN(new byte[] {(byte) OpCodes.OP_16}));
  }

  @Test
  void rejectsInvalidBareOpNShapes() {
    assertFalse(ScriptTemplates.isBareOpN(new byte[0]));
    assertFalse(ScriptTemplates.isBareOpN(new byte[] {(byte) OpCodes.OP_CHECKSIG}));
    assertFalse(ScriptTemplates.isBareOpN(new byte[] {0x51, 0x00})); // OP_1 + OP_0, not data push
    assertFalse(ScriptTemplates.isBareOpN(Hex.decode("51024e"))); // truncated push
    assertFalse(ScriptTemplates.isBareOpN(Hex.decode("51024e7300"))); // trailing byte
  }
}
