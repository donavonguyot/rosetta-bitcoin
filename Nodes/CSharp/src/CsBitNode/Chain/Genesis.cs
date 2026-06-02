using CsBitNode.Consensus;
using CsBitNode.Messages;
using CsBitNode.Util;

namespace CsBitNode.Chain;

public static class Genesis
{
    public static readonly BlockHeader Testnet4 = new(
        Version: 1,
        PrevBlock: new byte[32],
        MerkleRoot: Hex.Reverse(Hex.Decode("7aa0a7ae1e223414cb807e40cd57e667b718e42aaf9306db9102fe28912b7b4e")),
        Timestamp: 1_714_777_860L,
        Bits: 0x1d00ffff,
        Nonce: 393_743_547);

    public static readonly string Testnet4Hash = BlockHeaderCodec.BlockHashHex(Testnet4);

    public static BlockHeader ForChain(string chainName) =>
        chainName.Equals("testnet4", StringComparison.OrdinalIgnoreCase)
            ? Testnet4
            : throw new ArgumentException($"No genesis header defined for chain {chainName}");
}
