using CsBitNode.Consensus.Merkle;
using CsBitNode.Consensus.Tx;
using CsBitNode.Util;

namespace CsBitNode.Tests.Consensus;

public class MerkleTests
{
    [Fact]
    public void SingleHashMerkleRootIsIdentity()
    {
        var hash = Hex.Decode("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20");
        var root = MerkleComputer.ComputeRoot(new[] { hash });
        Assert.Equal(Hex.Encode(hash), Hex.Encode(root));
    }
}
