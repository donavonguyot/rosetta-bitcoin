package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Disabled;
import org.junit.jupiter.api.Test;

/** Regression for testnet4 block 118555 bare legacy mega-script spend (input 1). */
class BareLegacy118555RegressionTest {

  private static final long PREVOUT_AMOUNT = 8_000L;

  /** Reference digest for SIGHASH_ALL on input 1 (cross-checked with manual serialization). */
  private static final byte[] REFERENCE_SIGHASH_ALL =
      Hex.decode("b3a29cef574d19524a11845ae92d5a45bc5ecbcfe43fe8fba8577bdd840586cb");

  @Test
  void detectsBareLegacyTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_legacy_118555_prev_spk.hex");
    assertTrue(ScriptTemplates.isBareLegacyScript(prevSpk));
    assertEquals("bare_legacy", ScriptVerify.describeScriptPubKey(prevSpk));
    assertTrue(!ScriptTemplates.isBareOpN(prevSpk));
    assertTrue(!ScriptTemplates.isBareMultisig(prevSpk));
  }

  @Test
  void legacySighashAllMatchesReference() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_bare_legacy_118555.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_legacy_118555_prev_spk.hex");
    assertArrayEquals(
        REFERENCE_SIGHASH_ALL, LegacySighash.legacySighash(tx, 1, prevSpk, 1));
  }

  @Test
  void bareLegacyScriptEvaluatesToTruthyTop() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_bare_legacy_118555.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_legacy_118555_prev_spk.hex");
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(tx, 1, prevSpk, PREVOUT_AMOUNT, false, null);
    ScriptStack stackSig = new ScriptStack();
    ScriptInterpreter.evaluateScript(
        tx.inputs().get(1).scriptSig(), stackSig, context, ScriptInterpreter.EvalOptions.defaults());
    ScriptStack stack = new ScriptStack();
    stack.pushAll(stackSig.snapshot());
    ScriptInterpreter.evaluateScript(
        prevSpk, stack, context, ScriptInterpreter.EvalOptions.defaults());
    assertTrue(ScriptInterpreter.terminalSuccessRelaxed(stack));
  }

  @Test
  void acceptsRealTestnet4Block118555BareLegacyInput1() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_bare_legacy_118555.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_legacy_118555_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                1,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }
}
