package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Regression for testnet4 block 41700 bare OP_1 + push spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 4a89d5d1568b5cbcb4118559cb65d2357657d361a41cd96b14e74ed3d065975c}, input 0 spends
 * prevout {@code cedcdf44…:1} with scriptPubKey {@code 51024e73} (OP_1 + 2-byte push).
 */
class BareOp1Push41700RegressionTest {

  private static final long PREVOUT_AMOUNT = 20_000L;

  @Test
  void acceptsRealTestnet4Block41700BareOp1PushInput0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_bare_op1_push_41700.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_bare_op1_push_41700_prev_spk.hex");
    assertEquals("bare_op_n", ScriptVerify.describeScriptPubKey(prevSpk));

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                parsed.transaction(),
                0,
                new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }
}
