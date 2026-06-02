using CsBitNode.Consensus.Tx;
using CsBitNode.Messages;
using CsBitNode.Wire;

namespace CsBitNode.Consensus.Block;

public sealed record Block(BlockHeader Header, IReadOnlyList<Transaction> Transactions);

public static class BlockDeserializer
{
    public static Block Deserialize(byte[] payload)
    {
        var offset = 0;
        var header = BlockHeaderCodec.Deserialize(payload, ref offset);
        var (txCount, txRead) = WireSerialize.ReadCompactSize(payload, offset);
        offset += txRead;
        var transactions = new List<Transaction>((int)txCount);
        for (var i = 0; i < txCount; i++)
            transactions.Add(TransactionParser.Parse(payload, ref offset));
        return new Block(header, transactions);
    }
}
