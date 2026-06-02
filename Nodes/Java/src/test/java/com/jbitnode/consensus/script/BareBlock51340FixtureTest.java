package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 51340 P2SH OP_ADD redeem spend (BLOCKER_LEDGER).
 *
 * <p>Block tx index 2: {@code 03911305033a5aa73d7d730f16ba63b53582c6a6570d8d9f86e2f2b76fa2cbc3},
 * input 0 spends P2SH {@code a914c464d0…}. scriptSig pushes {@code OP_1 OP_2} plus redeem script
 * {@code OP_ADD OP_3 OP_EQUAL} ({@code 935387}); empty witness. tx[1] P2WPKH in the same block
 * passes Java verification — first connect-order script stall is this P2SH input.
 *
 * <p>Harvested via Core RPC {@code 127.0.0.1:48332}. Main agent implements {@code OP_ADD}; this
 * test only anchors fixture fields.
 */
class BareBlock51340FixtureTest {

  static final String TXID =
      "03911305033a5aa73d7d730f16ba63b53582c6a6570d8d9f86e2f2b76fa2cbc3";
  static final String PREV_SPK = "a914c464d0169c41085bcf10e3ab2cf83e74859d640b87";
  static final String REDEEM_SCRIPT = "935387";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_add_51340.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(6, tx.inputs().getFirst().scriptSig().length);
    assertTrue(tx.witness().isEmpty());

    assertArrayEquals(
        Hex.decode(PREV_SPK), FixtureLoader.readHex("/fixtures/tx_p2sh_add_51340_prev_spk.hex"));
    assertArrayEquals(
        Hex.decode("515203935387"),
        FixtureLoader.readHex("/fixtures/tx_p2sh_add_51340_scriptsig.hex"));
    assertArrayEquals(
        Hex.decode(REDEEM_SCRIPT),
        FixtureLoader.readHex("/fixtures/tx_p2sh_add_51340_redeem_script.hex"));

    byte[] redeem = FixtureLoader.readHex("/fixtures/tx_p2sh_add_51340_redeem_script.hex");
    assertEquals(3, redeem.length);
    assertEquals(0x93, redeem[0] & 0xFF);
    assertEquals(0x53, redeem[1] & 0xFF);
    assertEquals(0x87, redeem[2] & 0xFF);
  }
}
