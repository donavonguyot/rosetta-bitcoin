package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 61174 P2PKH SIGHASH_SINGLE input 1.
 *
 * <p>Tx {@code 4942f8db3e32bd1f114fbfb5c500e0f9cd06c3c235ffe77b07087750b86cc0ea},
 * input 1 spends P2PKH with SIGHASH_SINGLE (0x03) on a 3-input / 2-output tx.
 */
class BareFixture61174Test {

  static final String TXID =
      "4942f8db3e32bd1f114fbfb5c500e0f9cd06c3c235ffe77b07087750b86cc0ea";
  static final long P2PKH_AMOUNT = 20_000L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(3, tx.inputs().size());
    assertEquals(2, tx.outputs().size());
    assertEquals(0xffffffffL, tx.inputs().get(1).sequence() & 0xffffffffL);

    byte[] p2pkhSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174_prev_spk.hex");
    assertEquals(25, p2pkhSpk.length);
    assertEquals(0x76, p2pkhSpk[0] & 0xFF);
    assertEquals(0xa9, p2pkhSpk[1] & 0xFF);
    assertEquals(0x14, p2pkhSpk[2] & 0xFF);

    byte[] scriptSig = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174_scriptsig.hex");
    assertEquals(0x47, scriptSig[0] & 0xFF);
    assertEquals(0x03, scriptSig[scriptSig[0]] & 0xFF);
  }
}
