package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * Regression anchor for testnet4 block 33500 nested P2SH→P2WSH len-1 witness (BLOCKER_LEDGER).
 *
 * <p>Tx {@code f89a4629debeee9b32a3aaed72a209877a79b070ddcd4b6358312d5724b60683}, input 0.
 * scriptSig pushes nested witness program; witness stack is {@code [witnessScript]} only
 * ({@code OP_1} / {@code 0x51}), same edge as native P2WSH @31842.
 *
 * <p>Python scout: {@code test_real_testnet4_block33500_p2sh_p2wsh_op1_only_witness_accepted}.
 */
class P2shP2wshOp1Only33500RegressionTest {

  private static final long PREVOUT_AMOUNT = 62_819L;

  @Test
  void acceptsRealTestnet4Block33500P2shP2wshOp1OnlyInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_p2wsh_op1_only_33500.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_p2wsh_op1_only_33500_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects33500SpendWithEmptyWitnessStack() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_p2wsh_op1_only_33500.hex");
    Transaction base = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_p2wsh_op1_only_33500_prev_spk.hex");
    Transaction withoutWitness =
        new Transaction(
            base.version(),
            base.inputs(),
            base.outputs(),
            base.lockTime(),
            List.of(List.of(), base.witness().get(1), base.witness().get(2)));

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    withoutWitness, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsP2shScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_p2wsh_op1_only_33500_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2sh(prevSpk));
    assertEquals("P2SH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
