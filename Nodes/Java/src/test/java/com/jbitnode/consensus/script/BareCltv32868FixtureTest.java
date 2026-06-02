package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 32868 P2WSH IF/ELSE witness script with CLTV on the
 * ELSE branch (BLOCKER_LEDGER live blocker).
 *
 * <p>Tx {@code 8add2663f689111add26c4bc52a2f6060d48e41750c143cdfa8564ac114d97dc},
 * input 0 spends P2WSH {@code 00201b312986…}. Witness stack: DER signature, compressed
 * pubkey, empty branch selector ({@code OP_0} takes ELSE/CLTV path), full witnessScript.
 * ELSE branch: {@code PUSH(1719894876) OP_CHECKLOCKTIMEVERIFY OP_DROP … OP_ENDIF
 * OP_EQUALVERIFY OP_CHECKSIG}.
 *
 * <p>Python: synthetic {@code test_p2wsh_cltv_roundtrip}; related live template {@code
 * test_real_testnet4_block30695_p2wsh_if_hashlock_op_size_accepted}. No dedicated Python
 * block32868 fixture yet.
 */
class BareCltv32868FixtureTest {

  static final String TXID =
      "8add2663f689111add26c4bc52a2f6060d48e41750c143cdfa8564ac114d97dc";
  static final long P2WSH_AMOUNT = 10_000L;
  static final long CLTV_LOCKTIME = 1_719_894_876L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(1, tx.witness().size());
    assertEquals(4, tx.witness().getFirst().size());
    assertEquals(CLTV_LOCKTIME, tx.lockTime());

    byte[] p2wshSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868_prev_spk.hex");
    assertEquals(34, p2wshSpk.length);
    assertEquals(0x00, p2wshSpk[0] & 0xFF);
    assertEquals(0x20, p2wshSpk[1] & 0xFF);

    assertEquals(72, FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868_witness_0.hex").length);
    assertEquals(33, FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868_witness_1.hex").length);
    assertEquals(0, FixtureLoader.readBytes("/fixtures/tx_p2wsh_cltv_32868_witness_2.hex").length);

    byte[] witnessScript =
        FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868_witness_script.hex");
    assertEquals(97, witnessScript.length);
    assertEquals(0x63, witnessScript[0] & 0xFF);
    assertEquals(0xB1, witnessScript[69] & 0xFF);
    assertEquals(0xAC, witnessScript[witnessScript.length - 1] & 0xFF);
    assertArrayEquals(
        witnessScript, FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868_witness_3.hex"));

    byte[] elseBranch =
        FixtureLoader.readHex("/fixtures/tx_p2wsh_cltv_32868_witness_script_else_branch.hex");
    assertEquals(0x04, elseBranch[0] & 0xFF);
    assertEquals(0xB1, elseBranch[5] & 0xFF);
    assertEquals(0x75, elseBranch[6] & 0xFF);
  }
}
