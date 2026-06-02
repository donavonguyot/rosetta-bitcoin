using System.Security.Cryptography;

namespace CsBitNode.Util;

public static class CryptoUtil
{
    public static byte[] DoubleSha256(ReadOnlySpan<byte> data)
    {
        var first = SHA256.HashData(data);
        return SHA256.HashData(first);
    }

    public static byte[] MessageChecksum(ReadOnlySpan<byte> payload)
    {
        var hash = DoubleSha256(payload);
        return hash[..4];
    }
}
