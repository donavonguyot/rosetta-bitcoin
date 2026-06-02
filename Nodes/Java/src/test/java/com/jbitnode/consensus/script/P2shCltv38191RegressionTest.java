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
 * Regression anchor for testnet4 block 38191 P2SH CLTV redeem spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 4e477ff4e1a12fd78e76fb7dec0d0fcd6fb0372f757fabceb83fdb041c6ee9b6}, input 0.
 * Redeem script: {@code 30000 OP_CHECKLOCKTIMEVERIFY OP_DROP pubkey OP_CHECKSIG} with {@code
 * nVersion=1} and {@code nLockTime=30000}; BIP65 requires CLTV to no-op on version-1 txs.
 */
class P2shCltv38191RegressionTest {

  private static final long PREVOUT_AMOUNT = 10_000L;

  @Test
  void acceptsRealTestnet4Block38191P2shCltvRedeemInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_cltv_38191.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_cltv_38191_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }

  @Test
  void rejects38191SpendWithTamperedSignature() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_cltv_38191.hex");
    Transaction base = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_cltv_38191_prev_spk.hex");
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
  void detectsP2shScriptTemplate() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_cltv_38191_prev_spk.hex");
    assertTrue(ScriptTemplates.isP2sh(prevSpk));
    assertEquals("P2SH", ScriptVerify.describeScriptPubKey(prevSpk));
  }
}
