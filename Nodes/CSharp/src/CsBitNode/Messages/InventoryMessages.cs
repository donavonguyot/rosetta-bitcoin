using CsBitNode.Wire;

namespace CsBitNode.Messages;

public static class InventoryMessages
{
    public const int MsgBlock = 2;
    public const int MsgWitnessBlock = 0x4000_0002;
    public const int MsgWitnessTx = 0x4000_0001;

    public const string InvCommand = "inv";
    public const string GetDataCommand = "getdata";
    public const string NotFoundCommand = "notfound";

    public sealed record InventoryVector(int Type, byte[] Hash);

    public static byte[] SerializeGetData(IReadOnlyList<InventoryVector> vectors)
    {
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.WriteCompactSize(vectors.Count));
        foreach (var inv in vectors)
        {
            ms.Write(WireSerialize.PackInt32Le(inv.Type));
            ms.Write(inv.Hash);
        }
        return ms.ToArray();
    }

    public static byte[] DeserializeBlockPayload(byte[] payload) => payload;
}

public static class BlockMessage
{
    public const string Command = "block";

    public static byte[] BlockHashFromPayload(byte[] payload)
    {
        var offset = 0;
        var header = BlockHeaderCodec.Deserialize(payload, ref offset);
        return BlockHeaderCodec.BlockHash(header);
    }
}
