package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 38010 P2PKH SIGHASH_SINGLE + nSequence (scout path).
 *
 * <p>Tx {@code ba32ba8e2d812d93317a0503d37d505a826517343f7fec3b8c2e0c715f142eb6},
 * input 0 spends P2PKH {@code 76a9149ec1cc…} with {@code nSequence=0xfffffffd} and
 * DER signature ending in SIGHASH_SINGLE (0x03).
 *
 * <p>Python scout: {@code test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted}.
 */
class BareFixture38010Test {

  static final String TXID =
      "ba32ba8e2d812d93317a0503d37d505a826517343f7fec3b8c2e0c715f142eb6";
  static final long P2PKH_AMOUNT = 85_922_406_945_143L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2pkh_sighash_single_38010.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(0xfffffffdL, tx.inputs().getFirst().sequence() & 0xffffffffL);

    byte[] p2pkhSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_sighash_single_38010_prev_spk.hex");
    assertEquals(25, p2pkhSpk.length);
    assertEquals(0x76, p2pkhSpk[0] & 0xFF);
    assertEquals(0xa9, p2pkhSpk[1] & 0xFF);
    assertEquals(0x14, p2pkhSpk[2] & 0xFF);

    byte[] scriptSig = FixtureLoader.readHex("/fixtures/tx_p2pkh_sighash_single_38010_scriptsig.hex");
    assertEquals(0x47, scriptSig[0] & 0xFF);
    assertEquals(0x03, scriptSig[scriptSig.length - 33] & 0xFF);
  }
}
