using System.Text.Json;
using System.Text.Json.Nodes;
using CsBitNode.Chain;
using CsBitNode.Config;
using CsBitNode.Consensus.Block;
using CsBitNode.Consensus.Connect;
using CsBitNode.Consensus.Merkle;
using CsBitNode.Consensus.Script;
using CsBitNode.Consensus.Tx;
using CsBitNode.Db;
using CsBitNode.Util;

namespace CsBitNode.Cli;

public static class BlockerDiagnosticsService
{
    public static JsonObject AnalyzeTransaction(
        Transaction transaction,
        byte[] spentScriptPubKey,
        int height,
        string? txidHex,
        int inputIndex)
    {
        var witness = inputIndex < transaction.Witness.Count
            ? transaction.Witness[inputIndex]
            : Array.Empty<byte[]>();
        var spendType = ClassifyP2trSpend(spentScriptPubKey, witness);
        return new JsonObject
        {
            ["height"] = height,
            ["txid"] = txidHex ?? Hex.Encode(Hex.Reverse(MerkleComputer.TransactionTxid(transaction))),
            ["input_index"] = inputIndex,
            ["spent_script_template"] = ScriptTemplates.Describe(spentScriptPubKey),
            ["spent_script_pubkey"] = Hex.Encode(spentScriptPubKey),
            ["witness_item_count"] = witness.Count,
            ["witness_item_lengths"] = new JsonArray(witness.Select(item => JsonValue.Create(item.Length)).ToArray<JsonNode?>()),
            ["p2tr_spend_type"] = spendType,
            ["missing_rule"] = spendType == "script_path" ? "P2TR script-path / BIP342" : ""
        };
    }

    public static int Run(string[] args, TextWriter output)
    {
        var env = Environment.GetEnvironmentVariables()
            .Cast<System.Collections.DictionaryEntry>()
            .ToDictionary(e => e.Key.ToString()!, e => e.Value?.ToString());

        var txHex = ValueFromArgs(args, "--tx-hex") ?? env.GetValueOrDefault("TX_HEX");
        var spentScriptPubKeyHex = ValueFromArgs(args, "--spent-script-pubkey") ?? env.GetValueOrDefault("SPENT_SCRIPT_PUBKEY");
        if (!string.IsNullOrWhiteSpace(txHex) && !string.IsNullOrWhiteSpace(spentScriptPubKeyHex))
        {
            var directTx = ParseTransaction(Hex.Decode(txHex));
            var height = int.TryParse(ValueFromArgs(args, "--height") ?? env.GetValueOrDefault("HEIGHT"), out var parsedHeight)
                ? parsedHeight
                : -1;
            var inputIndex = int.TryParse(ValueFromArgs(args, "--input-index") ?? env.GetValueOrDefault("INPUT_INDEX"), out var parsedIndex)
                ? parsedIndex
                : 0;
            var txid = ValueFromArgs(args, "--txid") ?? env.GetValueOrDefault("TXID");
            output.WriteLine(AnalyzeTransaction(directTx, Hex.Decode(spentScriptPubKeyHex), height, txid, inputIndex).ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }

        var chainName = ValueFromArgs(args, "--chain") ?? NodePaths.ChainFromEnv();
        var dataDir = ValueFromArgs(args, "--datadir") ?? NodePaths.DataDirFromEnv(null);
        var chain = ChainRegistry.Get(chainName);
        using var session = ChainstateSession.OpenNative(dataDir, chain, acquireLock: false);
        var blockerJson = session.Store.CurrentBlockerJson(chain.Name);
        if (string.IsNullOrWhiteSpace(blockerJson))
        {
            output.WriteLine(new JsonObject { ["current_blocker"] = null }.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }

        var blocker = JsonSerializer.Deserialize<ValidationBlockerRecord>(blockerJson)
            ?? throw new InvalidOperationException("current blocker JSON could not be decoded");
        if (blocker.TxidHex is null || blocker.InputIndex is null || blocker.SpentScriptPubKeyHex is null)
            throw new InvalidOperationException("current blocker is missing txid, input_index, or spent_script_pubkey");
        var blockIndex = session.Store.GetBlock(chain.Name, blocker.Height)
            ?? throw new InvalidOperationException($"stored block index missing at height {blocker.Height}");
        var payload = session.BlockStorage.Load(blockIndex.FileNumber, blockIndex.FileOffset, blockIndex.BlockSize);
        var block = BlockDeserializer.Deserialize(payload);
        var storedTx = block.Transactions.FirstOrDefault(transaction =>
            Hex.Encode(Hex.Reverse(MerkleComputer.TransactionTxid(transaction))).Equals(blocker.TxidHex, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException($"tx {blocker.TxidHex} not found in stored block {blocker.Height}");
        var result = AnalyzeTransaction(storedTx, Hex.Decode(blocker.SpentScriptPubKeyHex), blocker.Height, blocker.TxidHex, blocker.InputIndex.Value);
        result["block_hash"] = blocker.BlockHashHex;
        result["failure"] = blocker.Failure;
        output.WriteLine(result.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }

    private static string ClassifyP2trSpend(byte[] spentScriptPubKey, IReadOnlyList<byte[]> witness)
    {
        if (!ScriptTemplates.IsP2tr(spentScriptPubKey))
            return "malformed";
        if (witness.Count == 1 && witness[0].Length is 64 or 65)
            return "key_path";
        if (witness.Count >= 2 && IsControlBlock(witness[^1]))
            return "script_path";
        return "malformed";
    }

    private static bool IsControlBlock(byte[] item) =>
        item.Length >= 33 && (item.Length - 33) % 32 == 0;

    private static Transaction ParseTransaction(byte[] data)
    {
        var offset = 0;
        var transaction = TransactionParser.Parse(data, ref offset);
        if (offset != data.Length)
            throw new InvalidDataException($"transaction had {data.Length - offset} trailing bytes");
        return transaction;
    }

    private static string? ValueFromArgs(string[] args, string name)
    {
        for (var i = 0; i < args.Length - 1; i++)
        {
            if (args[i] == name)
                return args[i + 1];
        }
        return null;
    }
}

public static class BlockerDiagnosticsProgram
{
    public static int Run(string[] args) => BlockerDiagnosticsService.Run(args, Console.Out);
}
