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
 * Regression anchor for testnet4 block 38010 P2PKH SIGHASH_SINGLE + nSequence (BLOCKER_LEDGER).
 *
 * <p>Tx {@code ba32ba8e2d812d93317a0503d37d505a826517343f7fec3b8c2e0c715f142eb6}, input 0.
 * Legacy sighash must keep signing input {@code nSequence=0xfffffffd} for SIGHASH_SINGLE (0x03).
 *
 * <p>Python scout: {@code test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted}.
 */
class P2pkhSighashSingle38010RegressionTest {

  private static final long PREVOUT_AMOUNT = 85_922_406_945_143L;

  @Test
  void acceptsRealTestnet4Block38010P2pkhSighashSingleInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2pkh_sighash_single_38010.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_sighash_single_38010_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects38010SpendWithTamperedSignature() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2pkh_sighash_single_38010.hex");
    Transaction base = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_sighash_single_38010_prev_spk.hex");
    byte[] scriptSig = base.inputs().getFirst().scriptSig().clone();
    scriptSig[10] ^= 0x01;
    Transaction tampered =
        new Transaction(
            base.version(),
            List.of(
                new com.jbitnode.consensus.tx.TxIn(
                    base.inputs().getFirst().previousOutput(), scriptSig, base.inputs().getFirst().sequence())),
            base.outputs(),
            base.lockTime(),
            base.witness());

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tampered, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsP2pkhScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_sighash_single_38010_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2pkh(prevSpk));
    assertEquals("P2PKH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
