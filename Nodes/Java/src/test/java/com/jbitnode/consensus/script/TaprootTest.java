package com.jbitnode.consensus.script;
import static org.junit.jupiter.api.Assertions.*;
import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.*;
import com.jbitnode.util.Hex;
import java.math.BigInteger;
import java.util.List;
import org.junit.jupiter.api.Test;
class TaprootTest {
  @Test void rejectsNonP2trScript() {
    Transaction tx = new Transaction(1, List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)), List.of(new TxOut(1, new byte[] {0x51})), 0, List.of());
    assertFalse(Taproot.verifyKeyPathSpend(Hex.decode("76a914" + "11".repeat(20) + "88ac"), new byte[0], List.of(new byte[64]), tx, 0, List.of(new ScriptVerify.SpentPrevout(1, Hex.decode("76a914" + "11".repeat(20) + "88ac")))));
  }
  @Test void rejectsScriptPathWitnessStack() {
    byte[] prevSpk = Hex.decode("5120" + "44".repeat(32));
    Transaction tx = new Transaction(1, List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)), List.of(new TxOut(1, new byte[] {0x51})), 0, List.of(List.of(new byte[64], new byte[] {(byte)0xc0}, new byte[33])));
    assertFalse(Taproot.verifyTaprootSpend(prevSpk, new byte[0], tx.witness().getFirst(), tx, 0, List.of(new ScriptVerify.SpentPrevout(1, prevSpk))));
  }
  @Test void rejectsAnnexWitnessStack() {
    byte[] prevSpk = Hex.decode("5120" + "55".repeat(32));
    Transaction tx = new Transaction(1, List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)), List.of(new TxOut(1, new byte[] {0x51})), 0, List.of(List.of(new byte[64], new byte[] {0x50, 0x01})));
    assertFalse(Taproot.verifyKeyPathSpend(prevSpk, new byte[0], tx.witness().getFirst(), tx, 0, List.of(new ScriptVerify.SpentPrevout(1, prevSpk))));
  }
  @Test void rejects65ByteSignatureWithDefaultHashType() {
    BigInteger secret = BigInteger.valueOf(7);
    byte[] internalXonly = xonlyFromSecret(secret);
    byte[] outputXonly = Taproot.taprootOutputKeyXonly(internalXonly, new byte[0]);
    byte[] prevSpk = concat(new byte[] {(byte) OpCodes.OP_1, 32}, outputXonly);
    Transaction tx = new Transaction(1, List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)), List.of(new TxOut(1, new byte[] {0x51})), 0, List.of());
    var prevouts = List.of(new ScriptVerify.SpentPrevout(1000, prevSpk));
    byte[] digest = TaprootSighash.taprootSignatureHash(tx, 0, prevouts, TaprootSighash.TaprootSighashOptions.keyPathDefault());
    byte[] sig64 = Secp256k1.signBip340Schnorr(Secp256k1.modN(secret.add(Taproot.taprootTweakScalar(internalXonly, new byte[0]))), digest);
    byte[] sig65 = new byte[65]; System.arraycopy(sig64, 0, sig65, 0, 64); sig65[64] = 0;
    Transaction signed = new Transaction(tx.version(), tx.inputs(), tx.outputs(), tx.lockTime(), List.of(List.of(sig65)));
    assertFalse(Taproot.verifyKeyPathSpend(prevSpk, new byte[0], signed.witness().getFirst(), signed, 0, prevouts));
  }
  private static byte[] xonlyFromSecret(BigInteger secret) { return java.util.Arrays.copyOfRange(Secp256k1.testPubkeySec1(secret), 1, 33); }
  private static byte[] concat(byte[] a, byte[] b) { byte[] out = new byte[a.length+b.length]; System.arraycopy(a,0,out,0,a.length); System.arraycopy(b,0,out,a.length,b.length); return out; }
}
