package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 27042 native P2WSH spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 0864a600ee15635ebb60678c1f25ea043f8470a126b0fb0d7acd2e10afd1bf33},
 * input 0 spends prevout tx {@code 6274e40d…} vout 0 (94800 sats, P2WSH program
 * {@code 0020379e4b…}). Witness script is 2-of-2 {@code OP_CHECKMULTISIG}.
 * Script verification regression: {@link P2wsh27042RegressionTest}.
 */
class BareP2wsh27042FixtureTest {

  static final String TXID =
      "0864a600ee15635ebb60678c1f25ea043f8470a126b0fb0d7acd2e10afd1bf33";
  static final long P2WSH_AMOUNT = 94_800L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_27042.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(2, tx.outputs().size());
    assertEquals(1, tx.witness().size());
    assertEquals(4, tx.witness().getFirst().size());

    assertEquals(0, tx.inputs().getFirst().scriptSig().length);

    byte[] p2wshSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_27042_prev_spk.hex");
    assertEquals(34, p2wshSpk.length);
    assertEquals(0x00, p2wshSpk[0] & 0xFF);
    assertEquals(0x20, p2wshSpk[1] & 0xFF);

    assertEquals(0, FixtureLoader.readBytes("/fixtures/tx_p2wsh_27042_witness_0.hex").length);
    assertEquals(71, FixtureLoader.readHex("/fixtures/tx_p2wsh_27042_witness_script.hex").length);
    assertEquals(0x52, FixtureLoader.readHex("/fixtures/tx_p2wsh_27042_witness_script.hex")[0] & 0xFF);
  }
}
