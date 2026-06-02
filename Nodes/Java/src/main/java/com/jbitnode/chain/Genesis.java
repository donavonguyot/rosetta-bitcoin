package com.jbitnode.chain;

import com.jbitnode.consensus.BlockHeader;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.util.Hex;

/** testnet4 genesis from Bitcoin Core v29 chainparams.cpp. */
public final class Genesis {

  public static final BlockHeader TESTNET4 =
      new BlockHeader(
          1,
          new byte[32],
          Hex.reverse(
              Hex.decode("7aa0a7ae1e223414cb807e40cd57e667b718e42aaf9306db9102fe28912b7b4e")),
          1_714_777_860L,
          0x1d00ffffL,
          393_743_547L);

  public static final String TESTNET4_HASH =
      BlockHeaderCodec.blockHashHex(TESTNET4);

  private Genesis() {}

  public static BlockHeader forChain(String chainName) {
    if ("testnet4".equalsIgnoreCase(chainName)) {
      return TESTNET4;
    }
    throw new IllegalArgumentException("No genesis header defined for chain " + chainName);
  }
}
