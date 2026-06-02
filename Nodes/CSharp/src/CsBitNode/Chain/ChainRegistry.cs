using CsBitNode.Util;

namespace CsBitNode.Chain;

public static class ChainRegistry
{
    public static readonly ChainParams Testnet4 = new(
        Name: "testnet4",
        Magic: Hex.Decode("1c163f28"),
        DefaultPort: 48_333,
        GenesisHash: Genesis.Testnet4Hash,
        ProtocolVersion: 70_016,
        UserAgent: "/csbitnode:0.1.0/");

    private static readonly Dictionary<string, ChainParams> Chains =
        new(StringComparer.OrdinalIgnoreCase) { ["testnet4"] = Testnet4 };

    public static ChainParams Get(string name) =>
        Chains.TryGetValue(name, out var chain)
            ? chain
            : throw new ArgumentException($"Unknown chain {name}; choose from {string.Join(", ", Chains.Keys)}");
}
