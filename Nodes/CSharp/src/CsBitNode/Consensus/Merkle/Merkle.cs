using CsBitNode.Consensus.Tx;
using CsBitNode.Util;
using CsBitNode.Wire;

namespace CsBitNode.Consensus.Merkle;

public static class MerkleComputer
{
    public static byte[] TransactionTxid(Transaction transaction) =>
        WireSerialize.DoubleSha256(TransactionSerializer.Serialize(transaction, includeWitness: false));

    public static byte[] ComputeRoot(IReadOnlyList<byte[]> hashes)
    {
        if (hashes.Count == 0)
            return new byte[32];
        var layer = hashes.Select(h => (byte[])h.Clone()).ToList();
        while (layer.Count > 1)
        {
            if (layer.Count % 2 == 1)
                layer.Add(layer[^1]);
            var next = new List<byte[]>();
            for (var i = 0; i < layer.Count; i += 2)
            {
                var combined = new byte[64];
                layer[i].CopyTo(combined, 0);
                layer[i + 1].CopyTo(combined, 32);
                next.Add(WireSerialize.DoubleSha256(combined));
            }
            layer = next;
        }
        return layer[0];
    }

    public static byte[] BlockMerkleRoot(IReadOnlyList<Transaction> transactions)
    {
        var txids = transactions.Select(TransactionTxid).ToList();
        return ComputeRoot(txids);
    }
}
