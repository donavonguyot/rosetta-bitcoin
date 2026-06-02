package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * Regression anchor for testnet4 block 6975 P2TR key-path spend (Python dd65c78 / OPERATIONS.md).
 *
 * <p>Tx {@code 12376f5a136a337ce4ea4025dbef2c18158945ef6aac58f2fc4d7c5fe81dff62}, input 0.
 */
class Taproot6975RegressionTest {

  private static final long PREVOUT_AMOUNT = 64_300_000_000L;

  @Test
  void acceptsRealTestnet4Block6975KeyPathSpend() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_taproot_6975.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_taproot_6975_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts =
        List.of(new ScriptVerify.SpentPrevout(PREVOUT_AMOUNT, prevSpk));

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT, spentPrevouts)));
  }

  @Test
  void rejects6975SpendWithoutSpentPrevouts() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_taproot_6975.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_taproot_6975_prev_spk.hex");

    ScriptVerifyError error =
        assertThrows(
            ScriptVerifyError.class,
            () ->
                ScriptVerify.verifyTransactionInput(
                    tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
    assertTrue(error.getMessage().contains("script verification failed"));
  }

  @Test
  void detectsP2trScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_taproot_6975_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2tr(prevSpk));
    assertEqualsWitnessVersionOne(prevSpk);
  }

  private static void assertEqualsWitnessVersionOne(byte[] scriptPubKey) {
    Integer version = ScriptTemplates.witnessProgramVersion(scriptPubKey);
    assertTrue(version != null && version == 1);
  }

  @Test
  void rejectsInvalidKeyPathWitnessStack() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_taproot_6975.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_taproot_6975_prev_spk.hex");
    List<ScriptVerify.SpentPrevout> spentPrevouts =
        List.of(new ScriptVerify.SpentPrevout(PREVOUT_AMOUNT, prevSpk));

    assertFalse(
        Taproot.verifyKeyPathSpend(
            prevSpk,
            new byte[] {0x01},
            tx.witness().getFirst(),
            tx,
            0,
            spentPrevouts));
  }
}
