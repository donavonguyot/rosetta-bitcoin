using CsBitNode.Consensus.Hash;
using CsBitNode.Wire;

namespace CsBitNode.Consensus.Script;

internal static class TaprootHash
{
    public const int TaprootLeafVersionTapscript = 0xc0;

    public static byte[] TaggedHash(string tag, ReadOnlySpan<byte> payload)
    {
        var tagHash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.ASCII.GetBytes(tag));
        var buffer = new byte[tagHash.Length * 2 + payload.Length];
        tagHash.CopyTo(buffer, 0);
        tagHash.CopyTo(buffer, tagHash.Length);
        payload.CopyTo(buffer.AsSpan(tagHash.Length * 2));
        return System.Security.Cryptography.SHA256.HashData(buffer);
    }

    public static byte[] TapLeafHash(int leafVersion, byte[] script)
    {
        using var ms = new MemoryStream();
        ms.WriteByte((byte)(leafVersion & 0xff));
        ms.Write(WireSerialize.WriteCompactSize(script.Length));
        ms.Write(script);
        return TaggedHash("TapLeaf", ms.ToArray());
    }

    public static byte[] TapBranchHash(byte[] left, byte[] right)
    {
        using var ms = new MemoryStream();
        if (CompareLex(left, right) < 0)
        {
            ms.Write(left);
            ms.Write(right);
        }
        else
        {
            ms.Write(right);
            ms.Write(left);
        }
        return TaggedHash("TapBranch", ms.ToArray());
    }

    public static byte[] MerkleRootFromBranch(IReadOnlyList<byte[]> branch, byte[] leafHash)
    {
        var accumulator = leafHash;
        foreach (var sibling in branch)
            accumulator = TapBranchHash(accumulator, sibling);
        return accumulator;
    }

    public static byte[] SerializedWitnessStackBytes(IReadOnlyList<byte[]> stack)
    {
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.WriteCompactSize(stack.Count));
        foreach (var item in stack)
        {
            ms.Write(WireSerialize.WriteCompactSize(item.Length));
            ms.Write(item);
        }
        return ms.ToArray();
    }

    private static int CompareLex(byte[] left, byte[] right)
    {
        var length = Math.Min(left.Length, right.Length);
        for (var i = 0; i < length; i++)
        {
            var diff = left[i].CompareTo(right[i]);
            if (diff != 0)
                return diff;
        }
        return left.Length.CompareTo(right.Length);
    }
}
