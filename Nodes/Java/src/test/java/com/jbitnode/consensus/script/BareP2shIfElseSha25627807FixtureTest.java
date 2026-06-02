package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 27807 P2SH OP_IF/OP_ELSE + OP_SHA256 spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code d1a68c8f20cc0ce8297e4f4b5ec297af1c6f98630e8105fd9d63b39c004c4ff0}, input 0
 * spends P2SH {@code a914d569…} with branch selector {@code OP_0} (ELSE hashlock path).
 */
class BareP2shIfElseSha25627807FixtureTest {

  static final String TXID =
      "d1a68c8f20cc0ce8297e4f4b5ec297af1c6f98630e8105fd9d63b39c004c4ff0";
  static final long P2SH_AMOUNT = 489_171L;
  static final String PREIMAGE_ASCII = "810899055";
  static final String SHA256_DIGEST_HEX =
      "6009b3c19a19f84e6b5208493a411939d0f49a90b462aa55b5b32466602c80b4";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_sha256_27807.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(0, tx.witness().size());

    byte[] p2shSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_sha256_27807_prev_spk.hex");
    assertEquals(23, p2shSpk.length);
    assertEquals(0xA9, p2shSpk[0] & 0xFF);
    assertEquals(0x14, p2shSpk[1] & 0xFF);

    assertEquals(71, FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_sha256_27807_scriptsig_sig.hex").length);
    assertArrayEquals(
        PREIMAGE_ASCII.getBytes(StandardCharsets.US_ASCII),
        FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_sha256_27807_scriptsig_preimage.hex"));
    assertEquals(0, FixtureLoader.readBytes("/fixtures/tx_p2sh_ifelse_sha256_27807_scriptsig_branch.hex").length);

    byte[] redeem = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_sha256_27807_redeem_script.hex");
    assertEquals(114, redeem.length);
    assertEquals(0x63, redeem[0] & 0xFF);
    assertEquals(0x67, redeem[10] & 0xFF);
    assertEquals(0xA8, redeem[11] & 0xFF);
    assertEquals(0x68, redeem[46] & 0xFF);
    assertEquals(0xAC, redeem[redeem.length - 1] & 0xFF);

    assertEquals(
        SHA256_DIGEST_HEX,
        FixtureLoader.readText("/fixtures/tx_p2sh_ifelse_sha256_27807_sha256_digest.hex").trim());
  }
}
