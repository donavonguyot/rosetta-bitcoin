using System.Text.Json.Serialization;
using CsBitNode.Consensus.Script;
using CsBitNode.Util;

namespace CsBitNode.Consensus.Connect;

public sealed class ValidationBlocker : Exception
{
    public int Height { get; }
    public string BlockHashHex { get; }
    public string? TxidHex { get; }
    public int? InputIndex { get; }
    public string? SpentScriptPubKeyHex { get; }
    public string MissingRule { get; }

    public ValidationBlocker(
        int height,
        string blockHashHex,
        string? txidHex,
        int? inputIndex,
        string? spentScriptPubKeyHex,
        string message,
        string missingRule) : base(message)
    {
        Height = height;
        BlockHashHex = blockHashHex;
        TxidHex = txidHex;
        InputIndex = inputIndex;
        SpentScriptPubKeyHex = spentScriptPubKeyHex;
        MissingRule = missingRule;
    }

    public static ValidationBlocker FromUnsupportedTemplate(
        int height,
        string blockHashHex,
        string txidHex,
        int inputIndex,
        byte[] scriptPubKey) =>
        new(
            height,
            blockHashHex,
            txidHex,
            inputIndex,
            Hex.Encode(scriptPubKey),
            $"unsupported scriptPubKey template {ScriptTemplates.Describe(scriptPubKey)}",
            "unsupported_script_template");

    public ValidationBlockerRecord ToRecord() =>
        new(
            Height,
            BlockHashHex,
            TxidHex,
            InputIndex,
            SpentScriptPubKeyHex,
            Message,
            MissingRule);
}

public sealed record ValidationBlockerRecord(
    [property: JsonPropertyName("height")] int Height,
    [property: JsonPropertyName("block_hash")] string BlockHashHex,
    [property: JsonPropertyName("txid")] string? TxidHex,
    [property: JsonPropertyName("input_index")] int? InputIndex,
    [property: JsonPropertyName("spent_script_pubkey")] string? SpentScriptPubKeyHex,
    [property: JsonPropertyName("failure")] string Failure,
    [property: JsonPropertyName("missing_rule")] string MissingRule);

public sealed class ConnectBlockException : Exception
{
    public ConnectBlockException(string message) : base(message) { }
    public ConnectBlockException(string message, Exception inner) : base(message, inner) { }
}
