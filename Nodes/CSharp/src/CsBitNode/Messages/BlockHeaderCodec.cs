using CsBitNode.Consensus;
using CsBitNode.Util;
using CsBitNode.Wire;

namespace CsBitNode.Messages;

public static class BlockHeaderCodec
{
    public const int SerializedSize = 80;

    public static byte[] Serialize(BlockHeader header)
    {
        var buf = new byte[SerializedSize];
        var offset = 0;
        WireSerialize.PackInt32Le(header.Version).CopyTo(buf, offset); offset += 4;
        header.PrevBlock.CopyTo(buf, offset); offset += 32;
        header.MerkleRoot.CopyTo(buf, offset); offset += 32;
        WireSerialize.PackInt32Le((int)header.Timestamp).CopyTo(buf, offset); offset += 4;
        WireSerialize.PackInt32Le((int)header.Bits).CopyTo(buf, offset); offset += 4;
        WireSerialize.PackInt32Le((int)header.Nonce).CopyTo(buf, offset);
        return buf;
    }

    public static BlockHeader Deserialize(ReadOnlySpan<byte> data, ref int offset)
    {
        var version = WireSerialize.UnpackInt32Le(data, offset); offset += 4;
        var prev = WireSerialize.ReadBytes(data, ref offset, 32);
        var merkle = WireSerialize.ReadBytes(data, ref offset, 32);
        var timestamp = WireSerialize.UnpackInt32Le(data, offset); offset += 4;
        var bits = (uint)WireSerialize.UnpackInt32Le(data, offset); offset += 4;
        var nonce = (uint)WireSerialize.UnpackInt32Le(data, offset); offset += 4;
        return new BlockHeader(version, prev, merkle, timestamp, bits, nonce);
    }

    public static byte[] BlockHash(BlockHeader header) => WireSerialize.DoubleSha256(Serialize(header));

    public static string BlockHashHex(BlockHeader header) => Hex.Encode(Hex.Reverse(BlockHash(header)));
}
