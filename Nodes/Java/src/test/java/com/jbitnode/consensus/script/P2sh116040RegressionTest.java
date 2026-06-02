package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Regression anchor for testnet4 block 116040 P2SH SIGHASH_SINGLE|ANYONECANPAY input 1.
 *
 * <p>Tx {@code a0a9fcb8a99ea3517d8fac76913ec4255066e9890c5f576ae2a4efc532302120}, input 1.
 * Two-input / one-output tx; minimal DER sig with SIGHASH_SINGLE|ANYONECANPAY (0x83) and
 * out-of-range SINGLE digest ({@code uint256::ONE}).
 */
class P2sh116040RegressionTest {

  private static final long PREVOUT_AMOUNT = 10_000L;

  @Test
  void acceptsRealTestnet4Block116040P2shSighashSingleAcpInput1() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_116040.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_116040_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 1, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }
}
