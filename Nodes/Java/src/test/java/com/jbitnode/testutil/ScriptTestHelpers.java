package com.jbitnode.testutil;

import com.jbitnode.consensus.script.LegacySighash;
import com.jbitnode.consensus.script.ScriptHash;
import com.jbitnode.consensus.script.ScriptTemplates;
import com.jbitnode.consensus.script.WitnessSighash;
import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.wire.WireSerialize;
import java.math.BigInteger;
import java.util.List;

/** Synthetic signed spends for script regression tests (mirrors Python script_helpers). */
public final class ScriptTestHelpers {

  private ScriptTestHelpers() {}

  public static byte[] pushData(byte[] data) {
    if (data.length < 0x4c) {
      byte[] out = new byte[1 + data.length];
      out[0] = (byte) data.length;
      System.arraycopy(data, 0, out, 1, data.length);
      return out;
    }
    byte[] out = new byte[2 + data.length];
    out[0] = 0x4c;
    out[1] = (byte) data.length;
    System.arraycopy(data, 0, out, 2, data.length);
    return out;
  }

  public static byte[] p2pkhScriptPubKey(byte[] pubkeyHash) {
    return ScriptTemplates.p2pkhScriptCode(pubkeyHash);
  }

  public static byte[] p2pkScriptPubKey(byte[] pubkey) {
    return concat(pushData(pubkey), new byte[] {(byte) 0xac});
  }

  public record SignedSpend(Transaction transaction, byte[] scriptPubKey) {}

  public static SignedSpend makeSignedP2pkhSpend(
      BigInteger privateKey,
      byte[] prevTxid,
      int prevVout,
      long prevAmount,
      byte[] pubkey,
      long outputValue) {
    byte[] scriptPubKey = p2pkhScriptPubKey(ScriptHash.hash160(pubkey));
    Transaction unsigned =
        new Transaction(
            1,
            List.of(
                new TxIn(
                    new OutPoint(prevTxid, prevVout),
                    new byte[0],
                    0xffff_ffffL)),
            List.of(new TxOut(outputValue, new byte[] {0x51})),
            0,
            List.of());
    byte[] sighash = LegacySighash.legacySighash(unsigned, 0, scriptPubKey, 1);
    byte[] signature = concat(Secp256k1.signDer(privateKey, sighash), new byte[] {0x01});
    byte[] scriptSig = concat(pushData(signature), pushData(pubkey));
    Transaction signed =
        new Transaction(
            unsigned.version(),
            List.of(new TxIn(unsigned.inputs().getFirst().previousOutput(), scriptSig, 0xffff_ffffL)),
            unsigned.outputs(),
            unsigned.lockTime(),
            List.of());
    return new SignedSpend(signed, scriptPubKey);
  }

  public static byte[] p2wpkhScriptPubKey(byte[] pubkeyHash) {
    byte[] out = new byte[22];
    out[0] = 0x00;
    out[1] = 0x14;
    System.arraycopy(pubkeyHash, 0, out, 2, 20);
    return out;
  }

  public static byte[] p2shScriptPubKey(byte[] redeemScriptHash160) {
    byte[] out = new byte[23];
    out[0] = (byte) 0xa9;
    out[1] = 0x14;
    System.arraycopy(redeemScriptHash160, 0, out, 2, 20);
    out[22] = (byte) 0x87;
    return out;
  }

  public static SignedSpend makeSignedP2shP2pkhSpend(
      BigInteger privateKey,
      byte[] prevTxid,
      int prevVout,
      long prevAmount,
      byte[] pubkey,
      long outputValue) {
    byte[] pubkeyHash = ScriptHash.hash160(pubkey);
    byte[] redeemScript = p2pkhScriptPubKey(pubkeyHash);
    byte[] scriptPubKey = p2shScriptPubKey(ScriptHash.hash160(redeemScript));
    Transaction unsigned =
        new Transaction(
            1,
            List.of(
                new TxIn(
                    new OutPoint(prevTxid, prevVout),
                    new byte[0],
                    0xffff_ffffL)),
            List.of(new TxOut(outputValue, new byte[] {0x51})),
            0,
            List.of());
    byte[] sighash = LegacySighash.legacySighash(unsigned, 0, redeemScript, 1);
    byte[] signature = concat(Secp256k1.signDer(privateKey, sighash), new byte[] {0x01});
    byte[] scriptSig = concat(pushData(signature), pushData(pubkey), pushData(redeemScript));
    Transaction signed =
        new Transaction(
            unsigned.version(),
            List.of(new TxIn(unsigned.inputs().getFirst().previousOutput(), scriptSig, 0xffff_ffffL)),
            unsigned.outputs(),
            unsigned.lockTime(),
            List.of());
    return new SignedSpend(signed, scriptPubKey);
  }

  public static SignedSpend makeSignedP2shP2wpkhSpend(
      BigInteger privateKey,
      byte[] prevTxid,
      int prevVout,
      long prevAmount,
      byte[] pubkey,
      long outputValue) {
    byte[] pubkeyHash = ScriptHash.hash160(pubkey);
    byte[] redeemScript = p2wpkhScriptPubKey(pubkeyHash);
    byte[] scriptPubKey = p2shScriptPubKey(ScriptHash.hash160(redeemScript));
    byte[] scriptCode = ScriptTemplates.p2pkhScriptCode(pubkeyHash);
    Transaction unsigned =
        new Transaction(
            2,
            List.of(
                new TxIn(
                    new OutPoint(prevTxid, prevVout),
                    new byte[0],
                    0xffff_ffffL)),
            List.of(new TxOut(outputValue, new byte[] {0x51})),
            0,
            List.of(List.of()));
    byte[] sighash = WitnessSighash.bip143Sighash(unsigned, 0, scriptCode, prevAmount, 1);
    byte[] signature = concat(Secp256k1.signDer(privateKey, sighash), new byte[] {0x01});
    byte[] scriptSig = pushData(redeemScript);
    Transaction signed =
        new Transaction(
            unsigned.version(),
            List.of(new TxIn(unsigned.inputs().getFirst().previousOutput(), scriptSig, 0xffff_ffffL)),
            unsigned.outputs(),
            unsigned.lockTime(),
            List.of(List.of(signature, pubkey)));
    return new SignedSpend(signed, scriptPubKey);
  }

  public static SignedSpend makeSignedP2wpkhSpend(
      BigInteger privateKey,
      byte[] prevTxid,
      int prevVout,
      long prevAmount,
      byte[] pubkey,
      long outputValue) {
    byte[] pubkeyHash = ScriptHash.hash160(pubkey);
    byte[] scriptPubKey = p2wpkhScriptPubKey(pubkeyHash);
    byte[] scriptCode = ScriptTemplates.p2pkhScriptCode(pubkeyHash);
    Transaction unsigned =
        new Transaction(
            1,
            List.of(
                new TxIn(
                    new OutPoint(prevTxid, prevVout),
                    new byte[0],
                    0xffff_ffffL)),
            List.of(new TxOut(outputValue, new byte[] {0x51})),
            0,
            List.of(List.of()));
    byte[] sighash = WitnessSighash.bip143Sighash(unsigned, 0, scriptCode, prevAmount, 1);
    byte[] signature = concat(Secp256k1.signDer(privateKey, sighash), new byte[] {0x01});
    Transaction signed =
        new Transaction(
            unsigned.version(),
            unsigned.inputs(),
            unsigned.outputs(),
            unsigned.lockTime(),
            List.of(List.of(signature, pubkey)));
    return new SignedSpend(signed, scriptPubKey);
  }

  public static SignedSpend makeSignedP2pkSpend(
      BigInteger privateKey,
      byte[] prevTxid,
      int prevVout,
      byte[] pubkey,
      long outputValue) {
    byte[] scriptPubKey = p2pkScriptPubKey(pubkey);
    Transaction unsigned =
        new Transaction(
            1,
            List.of(
                new TxIn(
                    new OutPoint(prevTxid, prevVout),
                    new byte[0],
                    0xffff_ffffL)),
            List.of(new TxOut(outputValue, new byte[] {0x51})),
            0,
            List.of());
    byte[] sighash = LegacySighash.legacySighash(unsigned, 0, scriptPubKey, 1);
    byte[] signature = concat(Secp256k1.signDer(privateKey, sighash), new byte[] {0x01});
    byte[] scriptSig = pushData(signature);
    Transaction signed =
        new Transaction(
            unsigned.version(),
            List.of(new TxIn(unsigned.inputs().getFirst().previousOutput(), scriptSig, 0xffff_ffffL)),
            unsigned.outputs(),
            unsigned.lockTime(),
            List.of());
    return new SignedSpend(signed, scriptPubKey);
  }

  private static byte[] concat(byte[]... parts) {
    int length = 0;
    for (byte[] part : parts) {
      length += part.length;
    }
    byte[] out = new byte[length];
    int offset = 0;
    for (byte[] part : parts) {
      System.arraycopy(part, 0, out, offset, part.length);
      offset += part.length;
    }
    return out;
  }
}
