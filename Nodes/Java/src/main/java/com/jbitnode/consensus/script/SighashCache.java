package com.jbitnode.consensus.script;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.secp256k1.Secp256k1;
import java.util.List;

/** Immutable per-transaction sighash precomputations shared by input verification workers. */
public final class SighashCache {

  private final WitnessSighash.Cache witnessCache;
  private final TaprootSighash.Cache taprootCache;
  private final Secp256k1.VerificationCache secp256k1Cache;

  private SighashCache(
      WitnessSighash.Cache witnessCache,
      TaprootSighash.Cache taprootCache,
      Secp256k1.VerificationCache secp256k1Cache) {
    this.witnessCache = witnessCache;
    this.taprootCache = taprootCache;
    this.secp256k1Cache = secp256k1Cache;
  }

  public static SighashCache forTransaction(
      Transaction transaction, List<ScriptVerify.SpentPrevout> spentPrevouts) {
    return forTransaction(transaction, spentPrevouts, new Secp256k1.VerificationCache());
  }

  public static SighashCache forTransaction(
      Transaction transaction,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      Secp256k1.VerificationCache secp256k1Cache) {
    return new SighashCache(
        WitnessSighash.Cache.forTransaction(transaction),
        spentPrevouts != null ? TaprootSighash.Cache.forTransaction(transaction, spentPrevouts) : null,
        secp256k1Cache);
  }

  WitnessSighash.Cache witnessCache() {
    return witnessCache;
  }

  TaprootSighash.Cache taprootCache() {
    return taprootCache;
  }

  Secp256k1.VerificationCache secp256k1Cache() {
    return secp256k1Cache;
  }
}
