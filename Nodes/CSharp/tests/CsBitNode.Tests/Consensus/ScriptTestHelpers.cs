using CsBitNode.Consensus.Hash;
using CsBitNode.Consensus.Script;
using CsBitNode.Consensus.Tx;
using CsBitNode.Util;

namespace CsBitNode.Tests.Consensus;

internal static class ScriptTestHelpers
{
    public static byte[] CompressedPubkey(int privateKey) =>
        Hex.Decode(privateKey == 1
            ? "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
            : throw new NotSupportedException("test helper only supports private key 1"));

    public static byte[] P2pkScriptPubkey(byte[] pubkey) => [(byte)pubkey.Length, ..pubkey, Opcodes.OP_CHECKSIG];

    public static byte[] P2pkhScriptPubkey(byte[] pubkeyHash) =>
    [
        Opcodes.OP_DUP, Opcodes.OP_HASH160, 0x14,
        ..pubkeyHash,
        Opcodes.OP_EQUALVERIFY, Opcodes.OP_CHECKSIG
    ];

    public static (Transaction Signed, byte[] ScriptPubKey) MakeSignedP2pkSpend(
        int privateKey, byte[] prevTxid, int prevVout, long prevAmount, byte[] pubkey, long outputValue)
    {
        var scriptPubKey = P2pkScriptPubkey(pubkey);
        var unsigned = new Transaction(
            1,
            [new TxIn(new OutPoint(prevTxid, (uint)prevVout), [], 0xffff_ffff)],
            [new TxOut(outputValue, [Opcodes.OP_1])],
            0,
            []);
        var sighash = Sighash.LegacySighash(unsigned, 0, scriptPubKey, 1);
        var signature = Secp256k1.SignDer(privateKey, sighash).Append((byte)0x01).ToArray();
        var scriptSig = EncodePush(signature);
        var signed = unsigned with
        {
            Inputs = [new TxIn(new OutPoint(prevTxid, (uint)prevVout), scriptSig, 0xffff_ffff)]
        };
        return (signed, scriptPubKey);
    }

    public static (Transaction Signed, byte[] ScriptPubKey) MakeSignedP2pkhSpend(
        int privateKey, byte[] prevTxid, int prevVout, long prevAmount, byte[] pubkey, long outputValue)
    {
        var pubkeyHash = Hash160.Compute(pubkey);
        var scriptPubKey = P2pkhScriptPubkey(pubkeyHash);
        var unsigned = new Transaction(
            1,
            [new TxIn(new OutPoint(prevTxid, (uint)prevVout), [], 0xffff_ffff)],
            [new TxOut(outputValue, [Opcodes.OP_1])],
            0,
            []);
        var sighash = Sighash.LegacySighash(unsigned, 0, scriptPubKey, 1);
        var signature = Secp256k1.SignDer(privateKey, sighash).Append((byte)0x01).ToArray();
        var scriptSig = EncodePush(signature).Concat(EncodePush(pubkey)).ToArray();
        var signed = unsigned with
        {
            Inputs = [new TxIn(new OutPoint(prevTxid, (uint)prevVout), scriptSig, 0xffff_ffff)]
        };
        return (signed, scriptPubKey);
    }

    public static (Transaction Signed, byte[] ScriptPubKey) MakeSignedP2wpkhSpend(
        int privateKey, byte[] prevTxid, int prevVout, long prevAmount, byte[] pubkey, long outputValue)
    {
        var pubkeyHash = Hash160.Compute(pubkey);
        var scriptPubKey = new byte[] { 0x00, 0x14 }.Concat(pubkeyHash).ToArray();
        var scriptCode = ScriptInterpreter.P2pkhScriptCode(pubkeyHash);
        var unsigned = new Transaction(
            1,
            [new TxIn(new OutPoint(prevTxid, (uint)prevVout), [], 0xffff_ffff)],
            [new TxOut(outputValue, [Opcodes.OP_1])],
            0,
            [Array.Empty<byte[]>()]);
        var sighash = Sighash.Bip143Sighash(unsigned, 0, scriptCode, prevAmount, 1);
        var signature = Secp256k1.SignDer(privateKey, sighash).Append((byte)0x01).ToArray();
        var signed = unsigned with
        {
            Witness = [[signature, pubkey]]
        };
        return (signed, scriptPubKey);
    }

    public static byte[] EncodePush(ReadOnlySpan<byte> data)
    {
        if (data.Length <= 75)
            return [(byte)data.Length, ..data];
        throw new NotSupportedException("test helper push too large");
    }
}
