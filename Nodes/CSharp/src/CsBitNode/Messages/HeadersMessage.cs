using CsBitNode.Consensus;
using CsBitNode.Wire;

namespace CsBitNode.Messages;

public static class HeadersMessage
{
    public const string Command = "headers";

    public sealed record Message(IReadOnlyList<BlockHeader> Headers);

    public static byte[] SerializeGetHeaders(int protocolVersion, IReadOnlyList<byte[]> locator, byte[] stopHash)
    {
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.PackInt32Le(protocolVersion));
        ms.Write(WireSerialize.WriteCompactSize(locator.Count));
        foreach (var hash in locator)
            ms.Write(hash);
        ms.Write(stopHash);
        return ms.ToArray();
    }

    public static Message Deserialize(byte[] payload)
    {
        var offset = 0;
        var (count, read) = WireSerialize.ReadCompactSize(payload, offset);
        offset += read;
        var headers = new List<BlockHeader>((int)count);
        for (var i = 0; i < count; i++)
        {
            var header = BlockHeaderCodec.Deserialize(payload, ref offset);
            var (txCount, txRead) = WireSerialize.ReadCompactSize(payload, offset);
            offset += txRead;
            if (txCount != 0)
                throw new InvalidDataException("headers message must have tx_count=0 per header");
            headers.Add(header);
        }
        return new Message(headers);
    }
}

public static class GetHeadersMessage
{
    public const string Command = "getheaders";
}
