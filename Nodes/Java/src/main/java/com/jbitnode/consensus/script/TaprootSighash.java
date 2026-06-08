package com.jbitnode.consensus.script;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.wire.WireSerialize;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Arrays;
import java.util.List;

/**
 * BIP341 TapSchnorr sighash for key-path and tapscript spends.
 *
 * <p>Spent-prevout ordering, annex handling, and tapscript ext_flag bytes are consensus data. Keep
 * this close to Shared fixtures when changing Taproot validation.
 */
public final class TaprootSighash {

  public static final int TAPROOT_SIGHASH_DEFAULT = 0;
  public static final int TAPROOT_SIGHASH_ALL = 1;
  public static final int TAPROOT_SIGHASH_NONE = 2;
  public static final int TAPROOT_SIGHASH_SINGLE = 3;

  private TaprootSighash() {}

  public static final class Cache {
    private final byte[] shaPrevouts;
    private final byte[] shaAmounts;
    private final byte[] shaScriptPubKeys;
    private final byte[] shaSequences;
    private final byte[] shaOutputsAll;

    private Cache(
        byte[] shaPrevouts,
        byte[] shaAmounts,
        byte[] shaScriptPubKeys,
        byte[] shaSequences,
        byte[] shaOutputsAll) {
      this.shaPrevouts = shaPrevouts;
      this.shaAmounts = shaAmounts;
      this.shaScriptPubKeys = shaScriptPubKeys;
      this.shaSequences = shaSequences;
      this.shaOutputsAll = shaOutputsAll;
    }

    public static Cache forTransaction(
        Transaction transaction, List<ScriptVerify.SpentPrevout> spentPrevouts) {
      if (spentPrevouts.size() != transaction.inputs().size()) {
        throw new IllegalArgumentException("spent_prevouts length mismatch");
      }
      try {
        return new Cache(
            shaPrevouts(transaction),
            shaAmounts(spentPrevouts),
            shaScriptPubKeys(spentPrevouts),
            shaSequences(transaction),
            shaOutputsAll(transaction));
      } catch (IOException error) {
        throw new IllegalStateException("taproot sighash cache failed", error);
      }
    }
  }

  public record TaprootSighashOptions(
      int hashType,
      byte[] annex,
      int extFlag,
      byte[] tapleafHash,
      long tapscriptCodeseparatorPos) {

    public static TaprootSighashOptions keyPathDefault() {
      return new TaprootSighashOptions(TAPROOT_SIGHASH_DEFAULT, null, 0, null, 0xffff_ffffL);
    }

    public static TaprootSighashOptions keyPath(int hashType) {
      return new TaprootSighashOptions(hashType, null, 0, null, 0xffff_ffffL);
    }
  }

  public static byte[] taprootSignatureHash(
      Transaction transaction,
      int inputIndex,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      TaprootSighashOptions options) {
    return taprootSignatureHash(transaction, inputIndex, spentPrevouts, options, null);
  }

  public static byte[] taprootSignatureHash(
      Transaction transaction,
      int inputIndex,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      TaprootSighashOptions options,
      Cache cache) {
    return ScriptVerifyProfiler.measure(
        "script_sighash_taproot",
        () -> taprootSignatureHashUnprofiled(transaction, inputIndex, spentPrevouts, options, cache));
  }

  static byte[] taprootSignatureHashUnprofiled(
      Transaction transaction,
      int inputIndex,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      TaprootSighashOptions options,
      Cache cache) {
    if (spentPrevouts.size() != transaction.inputs().size()) {
      throw new IllegalArgumentException("spent_prevouts length mismatch");
    }
    int hashType = options.hashType();
    if (!taprootAllowedHashtypes(hashType)) {
      throw new IllegalArgumentException("unsupported taproot sighash type");
    }
    boolean annexPresent = options.annex() != null;
    int extFlag = options.extFlag();
    if (extFlag != 0 && extFlag != 1) {
      throw new IllegalArgumentException("invalid taproot ext_flag");
    }
    if (extFlag == 1
        && (options.tapleafHash() == null || options.tapleafHash().length != 32)) {
      throw new IllegalArgumentException("tapscript sighash requires 32-byte tapleaf_hash");
    }

    int outputMode =
        hashType == TAPROOT_SIGHASH_DEFAULT ? TAPROOT_SIGHASH_ALL : (hashType & 0x03);
    boolean anyoneCanPay = (hashType & 0x80) != 0;

    ByteArrayOutputStream body = new ByteArrayOutputStream();
    try {
      body.write(hashType);
      body.write(WireSerialize.packInt32Le(transaction.version()));
      body.write(WireSerialize.packInt32Le((int) transaction.lockTime()));

      if (!anyoneCanPay) {
        Cache effectiveCache =
            cache != null ? cache : Cache.forTransaction(transaction, spentPrevouts);
        body.write(effectiveCache.shaPrevouts);
        body.write(effectiveCache.shaAmounts);
        body.write(effectiveCache.shaScriptPubKeys);
        body.write(effectiveCache.shaSequences);
      } else if (inputIndex >= transaction.inputs().size()) {
        throw new IllegalArgumentException("input_index out of range");
      }

      if (outputMode == TAPROOT_SIGHASH_ALL) {
        Cache effectiveCache =
            cache != null ? cache : Cache.forTransaction(transaction, spentPrevouts);
        body.write(effectiveCache.shaOutputsAll);
      } else if (outputMode == TAPROOT_SIGHASH_SINGLE) {
        if (inputIndex >= transaction.outputs().size()) {
          throw new IllegalArgumentException("SIGHASH_SINGLE without matching output");
        }
      }

      int spendType = (extFlag << 1) + (annexPresent ? 1 : 0);
      body.write(spendType);

      if (anyoneCanPay) {
        TxIn txIn = transaction.inputs().get(inputIndex);
        ScriptVerify.SpentPrevout prevout = spentPrevouts.get(inputIndex);
        body.write(LegacySighash.serializeOutPoint(txIn.previousOutput()));
        body.write(
            LegacySighash.serializeTxOut(
                new TxOut(prevout.amount(), prevout.scriptPubKey())));
        body.write(WireSerialize.packInt32Le((int) txIn.sequence()));
      } else {
        body.write(WireSerialize.packInt32Le(inputIndex));
      }

      if (annexPresent) {
        body.write(taprootAnnexDigest(options.annex() != null ? options.annex() : new byte[0]));
      }

      if (outputMode == TAPROOT_SIGHASH_SINGLE) {
        body.write(
            ScriptHash.sha256(
                LegacySighash.serializeTxOut(transaction.outputs().get(inputIndex))));
      }

      if (extFlag == 1) {
        body.write(options.tapleafHash());
        body.write(0);
        body.write(
            WireSerialize.packInt32Le((int) (options.tapscriptCodeseparatorPos() & 0xffff_ffffL)));
      }
    } catch (IOException error) {
      throw new IllegalStateException("taproot sighash serialization failed", error);
    }

    byte[] epoch = new byte[] {0};
    byte[] sigmsg = concat(epoch, body.toByteArray());
    return ScriptHash.bitcoinTaggedHash("TapSighash", sigmsg);
  }

  static boolean taprootAllowedHashtypes(int hashType) {
    return hashType <= 0x03 || (hashType >= 0x81 && hashType <= 0x83);
  }

  static byte[] taprootAnnexDigest(byte[] annex) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write(WireSerialize.writeCompactSize(annex.length));
      out.write(annex);
    } catch (IOException error) {
      throw new IllegalStateException("annex digest failed", error);
    }
    return ScriptHash.sha256(out.toByteArray());
  }

  private static byte[] sha256Concat(byte[] data) {
    return ScriptHash.sha256(data);
  }

  private static byte[] shaPrevouts(Transaction transaction) throws IOException {
    ByteArrayOutputStream prevBlob = new ByteArrayOutputStream();
    for (TxIn input : transaction.inputs()) {
      prevBlob.write(LegacySighash.serializeOutPoint(input.previousOutput()));
    }
    return sha256Concat(prevBlob.toByteArray());
  }

  private static byte[] shaAmounts(List<ScriptVerify.SpentPrevout> spentPrevouts)
      throws IOException {
    ByteArrayOutputStream amountsBlob = new ByteArrayOutputStream();
    for (ScriptVerify.SpentPrevout prevout : spentPrevouts) {
      amountsBlob.write(WireSerialize.packInt64Le(prevout.amount()));
    }
    return sha256Concat(amountsBlob.toByteArray());
  }

  private static byte[] shaScriptPubKeys(List<ScriptVerify.SpentPrevout> spentPrevouts)
      throws IOException {
    ByteArrayOutputStream scriptBlob = new ByteArrayOutputStream();
    for (ScriptVerify.SpentPrevout prevout : spentPrevouts) {
      byte[] spk = prevout.scriptPubKey();
      scriptBlob.write(WireSerialize.writeCompactSize(spk.length));
      scriptBlob.write(spk);
    }
    return sha256Concat(scriptBlob.toByteArray());
  }

  private static byte[] shaSequences(Transaction transaction) throws IOException {
    ByteArrayOutputStream sequencesBlob = new ByteArrayOutputStream();
    for (TxIn input : transaction.inputs()) {
      sequencesBlob.write(WireSerialize.packInt32Le((int) input.sequence()));
    }
    return sha256Concat(sequencesBlob.toByteArray());
  }

  private static byte[] shaOutputsAll(Transaction transaction) throws IOException {
    ByteArrayOutputStream outsBlob = new ByteArrayOutputStream();
    for (TxOut output : transaction.outputs()) {
      outsBlob.write(LegacySighash.serializeTxOut(output));
    }
    return sha256Concat(outsBlob.toByteArray());
  }

  private static byte[] concat(byte[] a, byte[] b) {
    byte[] out = Arrays.copyOf(a, a.length + b.length);
    System.arraycopy(b, 0, out, a.length, b.length);
    return out;
  }
}
