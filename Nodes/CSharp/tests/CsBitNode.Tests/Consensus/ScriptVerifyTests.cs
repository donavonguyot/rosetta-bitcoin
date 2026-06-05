using CsBitNode.Consensus.Script;
using CsBitNode.Consensus.Tx;
using CsBitNode.Util;

namespace CsBitNode.Tests.Consensus;

public class ScriptVerifyTests
{
    private static void VerifyOk(Transaction tx, byte[] scriptPubKey, long amount) =>
        ScriptVerify.VerifyTransactionInput(
            tx,
            0,
            new ScriptVerify.VerifyInputOptions(scriptPubKey, amount, null));

    [Fact]
    public void P2pkSpendRoundtrip()
    {
        var pubkey = ScriptTestHelpers.CompressedPubkey(1);
        var prevTxid = Enumerable.Repeat((byte)0x02, 32).ToArray();
        var (signed, scriptPubKey) = ScriptTestHelpers.MakeSignedP2pkSpend(
            1, prevTxid, 0, 5_000_000_000, pubkey, 4_900_000_000);
        VerifyOk(signed, scriptPubKey, 5_000_000_000);
    }

    [Fact]
    public void P2pkhSpendRoundtrip()
    {
        var pubkey = ScriptTestHelpers.CompressedPubkey(1);
        var prevTxid = Enumerable.Repeat((byte)0x02, 32).ToArray();
        var (signed, scriptPubKey) = ScriptTestHelpers.MakeSignedP2pkhSpend(
            1, prevTxid, 0, 5_000_000_000, pubkey, 4_900_000_000);
        VerifyOk(signed, scriptPubKey, 5_000_000_000);
    }

    [Fact]
    public void P2wpkhSpendRoundtrip()
    {
        var pubkey = ScriptTestHelpers.CompressedPubkey(1);
        var prevTxid = Enumerable.Repeat((byte)0x02, 32).ToArray();
        var (signed, scriptPubKey) = ScriptTestHelpers.MakeSignedP2wpkhSpend(
            1, prevTxid, 0, 5_000_000_000, pubkey, 4_900_000_000);
        VerifyOk(signed, scriptPubKey, 5_000_000_000);
    }

    [Fact]
    public void P2wpkhTemplateDetected()
    {
        var spk = Hex.Decode("0014a54e2a1ec06389203887661535ed118b7d053889");
        Assert.True(ScriptTemplates.IsP2wpkh(spk));
        Assert.Equal("P2WPKH", ScriptTemplates.Describe(spk));
    }

    [Fact]
    public void P2shRedeemScriptAccepted()
    {
        var redeemScript = new byte[] { Opcodes.OP_1 };
        var scriptPubKey = new byte[] { Opcodes.OP_HASH160, 0x14 }
            .Concat(CsBitNode.Consensus.Hash.Hash160.Compute(redeemScript))
            .Append(Opcodes.OP_EQUAL)
            .ToArray();
        var tx = new Transaction(
            1,
            [new TxIn(new OutPoint(Enumerable.Repeat((byte)0x03, 32).ToArray(), 0), ScriptTestHelpers.EncodePush(redeemScript), 0xffff_fffe)],
            [new TxOut(1_000, [Opcodes.OP_1])],
            0,
            []);
        VerifyOk(tx, scriptPubKey, 2_000);
    }

    [Fact]
    public void P2wshWitnessScriptAccepted()
    {
        var witnessScript = new byte[] { Opcodes.OP_1 };
        var scriptPubKey = new byte[] { 0x00, 0x20 }
            .Concat(CsBitNode.Consensus.Hash.Hash160.Sha256(witnessScript))
            .ToArray();
        var tx = new Transaction(
            1,
            [new TxIn(new OutPoint(Enumerable.Repeat((byte)0x04, 32).ToArray(), 0), [], 0xffff_fffe)],
            [new TxOut(1_000, [Opcodes.OP_1])],
            0,
            [[witnessScript]]);
        VerifyOk(tx, scriptPubKey, 2_000);
    }

    [Fact]
    public void FutureWitnessProgramAcceptedWithoutScriptExecution()
    {
        var scriptPubKey = Hex.Decode("51024e73");
        var tx = new Transaction(
            1,
            [new TxIn(new OutPoint(Enumerable.Repeat((byte)0x05, 32).ToArray(), 0), [], 0xffff_fffe)],
            [new TxOut(1_000, [Opcodes.OP_1])],
            0,
            [[Hex.Decode("010203")]]); // Future witness versions are not interpreted by current consensus.

        VerifyOk(tx, scriptPubKey, 2_000);
        Assert.True(ScriptTemplates.IsFutureWitnessProgram(scriptPubKey));
        Assert.Equal("future_witness", ScriptTemplates.Describe(scriptPubKey));
    }

    [Fact]
    public void FutureWitnessProgramRejectsNonEmptyScriptSig()
    {
        var scriptPubKey = Hex.Decode("51024e73");
        var tx = new Transaction(
            1,
            [new TxIn(new OutPoint(Enumerable.Repeat((byte)0x06, 32).ToArray(), 0), [Opcodes.OP_1], 0xffff_fffe)],
            [new TxOut(1_000, [Opcodes.OP_1])],
            0,
            [[Hex.Decode("010203")]]);

        Assert.Throws<ScriptVerifyError>(() => ScriptVerify.VerifyTransactionInput(
            tx,
            0,
            new ScriptVerify.VerifyInputOptions(scriptPubKey, 2_000, null)));
    }

    [Fact]
    public void RealTestnet4Block739P2wpkhInput0Accepted()
    {
        var fixturePath = Path.GetFullPath(Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", "Fixtures", "block739_tx.hex"));
        Assert.True(File.Exists(fixturePath), $"missing fixture {fixturePath}");
        var txHex = File.ReadAllText(fixturePath).Trim();

        var data = Hex.Decode(txHex);
        var offset = 0;
        var tx = TransactionParser.Parse(data, ref offset);
        var prevSpk = Hex.Decode("0014a54e2a1ec06389203887661535ed118b7d053889");
        VerifyOk(tx, prevSpk, 5_000_000_000);
    }

    [Fact]
    public void RealTestnet4Block2421MultiInputP2pkhInput0Accepted()
    {
        var fixturePath = Path.GetFullPath(Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", "Fixtures", "block2421_tx.hex"));
        Assert.True(File.Exists(fixturePath), $"missing fixture {fixturePath}");
        var txHex = File.ReadAllText(fixturePath).Trim();

        var data = Hex.Decode(txHex);
        var offset = 0;
        var tx = TransactionParser.Parse(data, ref offset);
        var prevSpk = Hex.Decode("76a9142a6635eb8a1cc7408efc130b3c43e10bbe792bc888ac");
        VerifyOk(tx, prevSpk, 5_000_000_935);
    }

    [Fact]
    public void RealTestnet4Block2421MultiInputP2pkhAllInputsAccepted()
    {
        var fixturePath = Path.GetFullPath(Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", "Fixtures", "block2421_tx.hex"));
        Assert.True(File.Exists(fixturePath), $"missing fixture {fixturePath}");
        var txHex = File.ReadAllText(fixturePath).Trim();

        var data = Hex.Decode(txHex);
        var offset = 0;
        var tx = TransactionParser.Parse(data, ref offset);
        var prevSpk = Hex.Decode("76a9142a6635eb8a1cc7408efc130b3c43e10bbe792bc888ac");
        var spentPrevouts = Enumerable
            .Range(0, tx.Inputs.Count)
            .Select(_ => new ScriptVerify.SpentPrevout(5_000_009_350, prevSpk))
            .ToList();

        Parallel.For(0, tx.Inputs.Count, inputIndex => ScriptVerify.VerifyTransactionInput(
            tx,
            inputIndex,
            new ScriptVerify.VerifyInputOptions(prevSpk, 5_000_009_350, spentPrevouts),
            new SighashCache()));
    }

    [Fact]
    public void LegacySighashCacheMatchesUncachedForRealBlock2421MultiInputP2pkh()
    {
        var fixturePath = Path.GetFullPath(Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", "Fixtures", "block2421_tx.hex"));
        Assert.True(File.Exists(fixturePath), $"missing fixture {fixturePath}");
        var txHex = File.ReadAllText(fixturePath).Trim();

        var data = Hex.Decode(txHex);
        var offset = 0;
        var tx = TransactionParser.Parse(data, ref offset);
        var scriptCode = Hex.Decode("76a9142a6635eb8a1cc7408efc130b3c43e10bbe792bc888ac");
        var cache = new SighashCache();

        for (var inputIndex = 0; inputIndex < tx.Inputs.Count; inputIndex++)
        {
            var uncached = Sighash.LegacySighash(tx, inputIndex, scriptCode);
            var cached = Sighash.LegacySighash(tx, inputIndex, scriptCode, cache: cache);
            Assert.Equal(uncached, cached);
        }
    }
}
