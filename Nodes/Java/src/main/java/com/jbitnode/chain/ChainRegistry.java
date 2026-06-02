package com.jbitnode.chain;

import com.jbitnode.util.Hex;
import java.util.Map;

/** Resolves chain parameters by name. */
public final class ChainRegistry {

  public static final ChainParams TESTNET4 =
      new ChainParams(
          "testnet4",
          Hex.decode("1c163f28"),
          48_333,
          Genesis.TESTNET4_HASH,
          70_016,
          "/jbitnode:0.1.0/");

  private static final Map<String, ChainParams> CHAINS = Map.of("testnet4", TESTNET4);

  private ChainRegistry() {}

  public static ChainParams get(String name) {
    ChainParams chain = CHAINS.get(name.toLowerCase());
    if (chain == null) {
      throw new IllegalArgumentException(
          "Unknown chain " + name + "; choose from " + CHAINS.keySet());
    }
    return chain;
  }
}
