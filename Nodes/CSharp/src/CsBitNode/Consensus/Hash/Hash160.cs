using System.Security.Cryptography;
using Org.BouncyCastle.Crypto.Digests;

namespace CsBitNode.Consensus.Hash;

public static class Hash160
{
    public static byte[] Sha1(ReadOnlySpan<byte> data) => SHA1.HashData(data);

    public static byte[] Ripemd160(ReadOnlySpan<byte> data)
    {
        var ripemd = new RipeMD160Digest();
        ripemd.BlockUpdate(data.ToArray(), 0, data.Length);
        var output = new byte[ripemd.GetDigestSize()];
        ripemd.DoFinal(output, 0);
        return output;
    }

    public static byte[] Compute(ReadOnlySpan<byte> data)
    {
        var sha = SHA256.HashData(data);
        return Ripemd160(sha);
    }

    public static byte[] Sha256(ReadOnlySpan<byte> data) => SHA256.HashData(data);

    public static byte[] Hash256(ReadOnlySpan<byte> data) => SHA256.HashData(SHA256.HashData(data));
}
