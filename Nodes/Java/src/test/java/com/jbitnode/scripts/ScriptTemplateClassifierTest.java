package com.jbitnode.scripts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.script.OpCodes;
import com.jbitnode.testutil.ScriptTestHelpers;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

class ScriptTemplateClassifierTest {

  @Test
  void classifiesStandardTemplates() {
    byte[] p2pkh = ScriptTestHelpers.p2pkhScriptPubKey(new byte[20]);
    assertEquals(ScriptTemplateClassifier.P2PKH, ScriptTemplateClassifier.classify(p2pkh));
    assertEquals(ScriptTemplateClassifier.P2PKH, ScriptTemplateClassifier.spendCategory("p2pkh"));

    byte[] p2pk = new byte[35];
    p2pk[0] = 33;
    p2pk[34] = (byte) OpCodes.OP_CHECKSIG;
    assertEquals(ScriptTemplateClassifier.P2PK, ScriptTemplateClassifier.classify(p2pk));

    byte[] p2wpkh = ScriptTestHelpers.p2wpkhScriptPubKey(new byte[20]);
    assertEquals(ScriptTemplateClassifier.P2WPKH, ScriptTemplateClassifier.classify(p2wpkh));

    byte[] p2wsh = new byte[34];
    p2wsh[0] = 0x00;
    p2wsh[1] = 0x20;
    assertEquals(ScriptTemplateClassifier.P2WSH, ScriptTemplateClassifier.classify(p2wsh));

    byte[] p2sh = new byte[23];
    p2sh[0] = (byte) OpCodes.OP_HASH160;
    p2sh[1] = 0x14;
    p2sh[22] = (byte) OpCodes.OP_EQUAL;
    assertEquals(ScriptTemplateClassifier.P2SH, ScriptTemplateClassifier.classify(p2sh));

    byte[] p2tr = Hex.decode("5120" + "aa".repeat(32));
    assertEquals(ScriptTemplateClassifier.P2TR, ScriptTemplateClassifier.classify(p2tr));
  }

  @Test
  void classifiesWitnessFutureAndOther() {
    byte[] witnessV2 = Hex.decode("52" + "20" + "bb".repeat(32));
    assertEquals("witness_v2", ScriptTemplateClassifier.classify(witnessV2));
    assertEquals(ScriptTemplateClassifier.UNKNOWN, ScriptTemplateClassifier.spendCategory("witness_v2"));

    assertEquals("bare_op_n", ScriptTemplateClassifier.classify(new byte[] {(byte) OpCodes.OP_1}));
    assertEquals(
        "bare_op_n", ScriptTemplateClassifier.classify(Hex.decode("51024e73")));
    assertEquals(ScriptTemplateClassifier.UNKNOWN, ScriptTemplateClassifier.spendCategory("bare_op_n"));

    assertEquals("empty", ScriptTemplateClassifier.classify(new byte[0]));
    assertEquals("op_return", ScriptTemplateClassifier.classify(new byte[] {0x6a, 0x04}));
    assertTrue(ScriptTemplateClassifier.classify(new byte[] {(byte) 0xab, 0x01}).startsWith("other("));
    assertFalse(ScriptTemplateClassifier.isKnownSpendCategory(ScriptTemplateClassifier.UNKNOWN));
    assertTrue(ScriptTemplateClassifier.isKnownSpendCategory(ScriptTemplateClassifier.P2TR));
  }
}
