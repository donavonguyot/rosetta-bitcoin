using CsBitNode.Consensus.Connect;

namespace CsBitNode.Tests.Consensus.Connect;

public class BlockConnectorTests
{
    [Fact]
    public void SpendableOutputRejectsCoreUnspendableScripts()
    {
        Assert.False(BlockConnector.IsSpendableOutput([]));
        Assert.False(BlockConnector.IsSpendableOutput([0x6a, 0x01, 0x02]));
        Assert.True(BlockConnector.IsSpendableOutput([0x51]));
    }

    [Fact]
    public void FirstScriptFailureIndexPreservesTaskOrder()
    {
        Exception?[] errors =
        [
            null,
            new InvalidOperationException("first"),
            null,
            new InvalidOperationException("later")
        ];

        Assert.Equal(1, BlockConnector.FirstScriptFailureIndex(errors));
        Assert.Null(BlockConnector.FirstScriptFailureIndex([null, null]));
    }
}
