using CsBitNode.Cli;
using CsBitNode.Consensus.Script;
using CsBitNode.Consensus.Tx;
using CsBitNode.Util;

namespace CsBitNode.Tests.Consensus;

public class BlockerDiagnosticsTests
{
    [Fact]
    public void ClassifiesAndAccepts22830P2trScriptPathSpend()
    {
        var tx = FixtureTransaction("tx_p2tr_scriptpath_22830.hex");
        var prevSpk = Hex.Decode(File.ReadAllText(FixturePath("tx_p2tr_scriptpath_22830_prev_spk.hex")).Trim());

        var diagnostic = BlockerDiagnosticsService.AnalyzeTransaction(
            tx,
            prevSpk,
            22830,
            "630725d944cb0ddba2e249f248b725d1f136fc3d698e8dc4f6be61e9103fa33c",
            0);

        Assert.Equal("P2TR", diagnostic["spent_script_template"]!.GetValue<string>());
        Assert.Equal("script_path", diagnostic["p2tr_spend_type"]!.GetValue<string>());
        Assert.Equal(3, diagnostic["witness_item_count"]!.GetValue<int>());
        Assert.Equal("P2TR script-path / BIP342", diagnostic["missing_rule"]!.GetValue<string>());
        ScriptVerify.VerifyTransactionInput(
            tx,
            0,
            new ScriptVerify.VerifyInputOptions(prevSpk, 798, [new ScriptVerify.SpentPrevout(798, prevSpk)]));
    }

    private static Transaction FixtureTransaction(string name)
    {
        var data = Hex.Decode(File.ReadAllText(FixturePath(name)).Trim());
        var offset = 0;
        return TransactionParser.Parse(data, ref offset);
    }

    private static string FixturePath(string name) =>
        Path.Combine(AppContext.BaseDirectory, "Fixtures", name);
}
