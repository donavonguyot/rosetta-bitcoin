using CsBitNode.Chain;
using CsBitNode.Messages;

namespace CsBitNode.Tests.Consensus;

public class GenesisTests
{
    [Fact]
    public void Testnet4GenesisHashMatchesRegistry()
    {
        Assert.Equal(Genesis.Testnet4Hash, ChainRegistry.Testnet4.GenesisHash);
        Assert.StartsWith("00000000", Genesis.Testnet4Hash);
    }

    [Fact]
    public void HeaderSerializeIs80Bytes()
    {
        Assert.Equal(80, BlockHeaderCodec.Serialize(Genesis.Testnet4).Length);
    }
}
