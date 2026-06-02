package com.jbitnode.consensus.merkle;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionSerializer;
import com.jbitnode.wire.WireSerialize;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Transaction txid and block merkle root (Bitcoin Core algorithm). */
public final class Merkle {

  private Merkle() {}

  public static byte[] transactionTxid(Transaction transaction) {
    return WireSerialize.doubleSha256(
        TransactionSerializer.serialize(transaction, false));
  }

  public static byte[] merkleRoot(List<byte[]> hashes) {
    if (hashes.isEmpty()) {
      return new byte[32];
    }
    List<byte[]> layer = new ArrayList<>(hashes);
    while (layer.size() > 1) {
      if (layer.size() % 2 == 1) {
        layer.add(layer.getLast());
      }
      List<byte[]> nextLayer = new ArrayList<>();
      for (int index = 0; index < layer.size(); index += 2) {
        byte[] combined = new byte[64];
        System.arraycopy(layer.get(index), 0, combined, 0, 32);
        System.arraycopy(layer.get(index + 1), 0, combined, 32, 32);
        nextLayer.add(WireSerialize.doubleSha256(combined));
      }
      layer = nextLayer;
    }
    return Arrays.copyOf(layer.getFirst(), 32);
  }

  public static byte[] blockMerkleRoot(List<Transaction> transactions) {
    List<byte[]> txids = new ArrayList<>();
    for (Transaction transaction : transactions) {
      txids.add(transactionTxid(transaction));
    }
    return merkleRoot(txids);
  }
}
