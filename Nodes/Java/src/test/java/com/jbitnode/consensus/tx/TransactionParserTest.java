package com.jbitnode.consensus.tx;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

class TransactionParserTest {

  @Test
  void parsesBlock1CoinbaseFromFixtureBlock() {
    byte[] blockPayload = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(blockPayload, 81);
    assertEquals(blockPayload.length, parsed.nextOffset());
    Transaction tx = parsed.transaction();
    assertEquals(1, tx.version());
    assertTrue(tx.isCoinbase());
    assertEquals(1, tx.inputs().size());
    assertEquals(2, tx.outputs().size());
    assertEquals(50L * 100_000_000L, tx.outputs().getFirst().value());
    assertEquals(1, tx.witness().size());
    assertEquals(32, tx.witness().getFirst().getFirst().length);
  }

  @Test
  void parsesTaproot6975WitnessTransaction() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_taproot_6975.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertEquals(payload.length, parsed.nextOffset());
    Transaction tx = parsed.transaction();
    assertEquals(2, tx.version());
    assertFalse(tx.isCoinbase());
    assertEquals(1, tx.inputs().size());
    assertEquals(2, tx.outputs().size());
    assertEquals(1, tx.witness().size());
    assertEquals(1, tx.witness().getFirst().size());
    assertEquals(64, tx.witness().getFirst().getFirst().length);
  }

  @Test
  void roundTripsCoinbaseSerialization() {
    byte[] blockPayload = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    Transaction tx = TransactionParser.deserialize(blockPayload, 81).transaction();
    byte[] serialized = TransactionSerializer.serialize(tx, false);
    Transaction restored = TransactionParser.deserialize(serialized, 0).transaction();
    assertEquals(tx.version(), restored.version());
    assertEquals(tx.outputs().getFirst().value(), restored.outputs().getFirst().value());
    assertTrue(restored.isCoinbase());
  }

  @Test
  void roundTripsWitnessSerialization() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_taproot_6975.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] serialized = TransactionSerializer.serialize(tx, true);
    TransactionParser.ParseResult restored = TransactionParser.deserialize(serialized, 0);
    assertEquals(serialized.length, restored.nextOffset());
    assertEquals(tx.witness().size(), restored.transaction().witness().size());
  }

  @Test
  void rejectsInvalidOutPointHashLength() {
    assertThrows(IllegalArgumentException.class, () -> new OutPoint(new byte[16], 0));
  }
}
