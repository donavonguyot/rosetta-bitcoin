package com.jbitnode.chain;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.jbitnode.messages.BlockHeaderCodec;
import org.junit.jupiter.api.Test;

class ChainRegistryTest {

  @Test
  void resolvesTestnet4() {
    ChainParams chain = ChainRegistry.get("testnet4");
    assertEquals("testnet4", chain.name());
    assertEquals(48_333, chain.defaultPort());
    assertEquals("1c163f28", com.jbitnode.util.Hex.encode(chain.magic()));
  }

  @Test
  void genesisMatchesKnownHash() {
    assertEquals(Genesis.TESTNET4_HASH, ChainRegistry.TESTNET4.genesisHash());
    assertEquals(
        "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043",
        BlockHeaderCodec.blockHashHex(Genesis.TESTNET4));
  }

  @Test
  void rejectsUnknownChain() {
    assertThrows(IllegalArgumentException.class, () -> ChainRegistry.get("mainnet"));
  }

  @Test
  void genesisForChain() {
    assertEquals(Genesis.TESTNET4, Genesis.forChain("testnet4"));
    assertThrows(IllegalArgumentException.class, () -> Genesis.forChain("regtest"));
  }
}
