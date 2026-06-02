package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.testutil.FixtureLoader;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * Regression anchor for testnet4 block 25207 bare OP_1 spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 23bf6f595cc12dde71239de913ea9a30fb60ef20a3a54246701a2dff16227f43}, input 1.
 * scriptPubKey {@code 51} is satisfied by an empty scriptSig (OP_1 pushes true).
 */
class Op1_25207RegressionTest {

  private static final long PREVOUT_AMOUNT = 1L;

  @Test
  void acceptsRealTestnet4Block25207BareOp1Input1() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_op1_25207.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_op1_25207_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                1,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejectsBareOp1SpendWithWitnessStack() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_op1_25207.hex");
    Transaction base = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_op1_25207_prev_spk.hex");
    Transaction withWitness =
        new Transaction(
            base.version(),
            base.inputs(),
            base.outputs(),
            base.lockTime(),
            List.of(
                List.of(),
                List.of(new byte[] {0x01}),
                List.of(),
                List.of(),
                List.of(),
                List.of()));

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    withWitness, 1, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsBareOp1ScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_op1_25207_prev_spk.hex");
    assertTrue(ScriptTemplates.isBareOpN(prevSpk));
    assertEquals("bare_op_n", ScriptVerify.describeScriptPubKey(prevSpk));
  }

  @Test
  void syntheticBareOp1SpendWithEmptyScriptSig() {
    byte[] prevSpk = new byte[] {(byte) OpCodes.OP_1};
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, 1000)));
  }
}
