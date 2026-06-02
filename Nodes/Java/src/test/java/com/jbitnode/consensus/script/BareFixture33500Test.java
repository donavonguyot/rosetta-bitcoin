package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 33500 P2SH-wrapped P2WSH len-1 witness (scout path).
 *
 * <p>Tx {@code f89a4629debeee9b32a3aaed72a209877a79b070ddcd4b6358312d5724b60683},
 * input 0 spends P2SH {@code a91472c44f…}. Nested segwit witness stack is
 * {@code [witnessScript]} only (length 1); witness script is single byte {@code OP_1 (0x51)}.
 *
 * <p>Python scout: {@code test_real_testnet4_block33500_p2sh_p2wsh_op1_only_witness_accepted}.
 */
class BareFixture33500Test {

  static final String TXID =
      "f89a4629debeee9b32a3aaed72a209877a79b070ddcd4b6358312d5724b60683";
  static final long P2SH_AMOUNT = 62_819L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_p2wsh_op1_only_33500.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(3, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(3, tx.witness().size());
    assertEquals(1, tx.witness().getFirst().size());

    byte[] p2shSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_p2wsh_op1_only_33500_prev_spk.hex");
    assertEquals(23, p2shSpk.length);
    assertEquals(0xa9, p2shSpk[0] & 0xFF);
    assertEquals(0x14, p2shSpk[1] & 0xFF);

    byte[] witnessScript =
        FixtureLoader.readHex("/fixtures/tx_p2sh_p2wsh_op1_only_33500_witness_script.hex");
    assertEquals(1, witnessScript.length);
    assertEquals(0x51, witnessScript[0] & 0xFF);
    assertArrayEquals(
        witnessScript,
        FixtureLoader.readHex("/fixtures/tx_p2sh_p2wsh_op1_only_33500_witness_0.hex"));

    byte[] redeemPush = FixtureLoader.readHex("/fixtures/tx_p2sh_p2wsh_op1_only_33500_scriptsig.hex");
    assertEquals(0x22, redeemPush[0] & 0xFF);
    assertEquals(0x00, redeemPush[1] & 0xFF);
    assertEquals(0x20, redeemPush[2] & 0xFF);
  }
}
