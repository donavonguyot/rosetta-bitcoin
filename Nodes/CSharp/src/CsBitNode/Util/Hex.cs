namespace CsBitNode.Util;

public static class Hex
{
    public static string Encode(ReadOnlySpan<byte> data) =>
        Convert.ToHexString(data).ToLowerInvariant();

    public static byte[] Decode(string hex)
    {
        if (hex.Length % 2 != 0)
            throw new FormatException("hex string must have even length");
        var bytes = new byte[hex.Length / 2];
        for (var i = 0; i < bytes.Length; i++)
            bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
        return bytes;
    }

    public static byte[] Reverse(byte[] data)
    {
        var copy = (byte[])data.Clone();
        Array.Reverse(copy);
        return copy;
    }
}
