package com.jbitnode.messages;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import java.util.List;
import org.junit.jupiter.api.Test;

class InventoryMessagesTest {

  @Test
  void roundTripsGetDataInventory() {
    byte[] hash = Hex.decode("0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28");
    InventoryMessages.InventoryVector item =
        new InventoryMessages.InventoryVector(
            InventoryMessages.MSG_WITNESS_BLOCK, Hex.reverse(hash));
    InventoryMessages.InvMessage message =
        new InventoryMessages.InvMessage(List.of(item));
    InventoryMessages.InvMessage restored =
        InventoryMessages.GetDataMessage.deserialize(
            InventoryMessages.GetDataMessage.serialize(message));
    assertEquals(1, restored.inventory().size());
    assertEquals(InventoryMessages.MSG_WITNESS_BLOCK, restored.inventory().getFirst().type());
    assertArrayEquals(Hex.reverse(hash), restored.inventory().getFirst().hash());
  }

  @Test
  void roundTripsNotFound() {
    InventoryMessages.InvMessage message =
        new InventoryMessages.InvMessage(
            List.of(
                new InventoryMessages.InventoryVector(
                    InventoryMessages.MSG_BLOCK, new byte[32])));
    InventoryMessages.InvMessage restored =
        InventoryMessages.NotFoundMessage.deserialize(
            InventoryMessages.NotFoundMessage.serialize(message));
    assertEquals(1, restored.inventory().size());
  }

  @Test
  void detectsBlockInventoryAndHashMembership() {
    byte[] hash = new byte[32];
    hash[0] = 0x01;
    InventoryMessages.InvMessage message =
        new InventoryMessages.InvMessage(
            List.of(new InventoryMessages.InventoryVector(InventoryMessages.MSG_TX, new byte[32])));
    assertFalse(InventoryMessages.hasBlockInventory(message));
    InventoryMessages.InvMessage blockInv =
        new InventoryMessages.InvMessage(
            List.of(
                new InventoryMessages.InventoryVector(InventoryMessages.MSG_WITNESS_BLOCK, hash)));
    assertTrue(InventoryMessages.hasBlockInventory(blockInv));
    assertTrue(InventoryMessages.inventoryContainsHash(blockInv, hash));
  }

  @Test
  void rejectsInvalidInventoryHashLength() {
    assertThrows(
        IllegalArgumentException.class,
        () ->
            InventoryMessages.InvMessageCodec.serialize(
                new InventoryMessages.InvMessage(
                    List.of(
                        new InventoryMessages.InventoryVector(
                            InventoryMessages.MSG_BLOCK, new byte[31])))));
  }

  @Test
  void blockMessagePassesThroughPayload() {
    byte[] payload = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    assertArrayEquals(payload, BlockMessage.deserialize(BlockMessage.serialize(payload)));
    assertEquals(
        FixtureLoader.readText("/fixtures/block1_hash.txt"),
        BlockMessage.blockHashHexFromPayload(payload));
  }

  @Test
  void rejectsInvalidInvPayloadLength() {
    assertThrows(
        IllegalArgumentException.class,
        () -> InventoryMessages.InvMessageCodec.deserialize(new byte[] {1, 0, 0}));
  }
}
