namespace CsBitNode.Consensus.Script;

internal static class ScriptNum
{
    public const int MaxScriptNumSizeLockTime = 5;

    public static int Decode(byte[] item, int maxLen = 4) => (int)DecodeLong(item, maxLen);

    public static long DecodeLong(byte[] item, int maxLen)
    {
        if (item.Length > maxLen)
            throw new ScriptError("script number overflow");
        if (item.Length == 0)
            return 0;

        var negative = (item[^1] & 0x80) != 0;
        long value = 0;
        for (var index = 0; index < item.Length; index++)
        {
            var b = item[index];
            if (index == item.Length - 1)
                b &= 0x7f;
            value |= (long)b << (8 * index);
        }
        return negative ? -value : value;
    }

    public static byte[] Encode(int value, int maxLen = 4)
    {
        if (value == 0)
            return [];

        var negative = value < 0;
        var absValue = negative ? -value : value;
        var bytes = new List<byte>();
        while (absValue > 0)
        {
            bytes.Add((byte)(absValue & 0xff));
            absValue >>= 8;
        }

        if ((bytes[^1] & 0x80) != 0)
            bytes.Add(0);
        if (negative)
            bytes[^1] |= 0x80;
        if (bytes.Count > maxLen)
            throw new ScriptError("script number overflow");
        return bytes.ToArray();
    }
}
