using System.Buffers.Binary;
using System.Text;
using CsBitNode.Util;

namespace CsBitNode.Wire;

public static class WireSerialize
{
    public static byte[] DoubleSha256(ReadOnlySpan<byte> data) => CryptoUtil.DoubleSha256(data);

    public static byte[] MessageChecksum(ReadOnlySpan<byte> payload) => CryptoUtil.MessageChecksum(payload);

    public static byte[] PackInt32Le(int value)
    {
        var buf = new byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(buf, value);
        return buf;
    }

    public static int UnpackInt32Le(ReadOnlySpan<byte> data, int offset) =>
        BinaryPrimitives.ReadInt32LittleEndian(data[offset..]);

    public static byte[] PackInt64Le(long value)
    {
        var buf = new byte[8];
        BinaryPrimitives.WriteInt64LittleEndian(buf, value);
        return buf;
    }

    public static long UnpackInt64Le(ReadOnlySpan<byte> data, int offset) =>
        BinaryPrimitives.ReadInt64LittleEndian(data[offset..]);

    public static byte[] PackUint16Be(int value)
    {
        var buf = new byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(buf, (ushort)value);
        return buf;
    }

    public static int UnpackUint16Be(ReadOnlySpan<byte> data, int offset) =>
        BinaryPrimitives.ReadUInt16BigEndian(data[offset..]);

    public static byte[] WriteCompactSize(long value)
    {
        if (value < 0xfd) return [(byte)value];
        if (value <= 0xffff)
            return [(byte)0xfd, (byte)(value & 0xff), (byte)((value >> 8) & 0xff)];
        if (value <= 0xffff_ffff)
            return [(byte)0xfe, ..PackInt32Le((int)value)];
        return [(byte)0xff, ..PackInt64Le(value)];
    }

    public static (long Value, int BytesRead) ReadCompactSize(ReadOnlySpan<byte> data, int offset)
    {
        if (offset >= data.Length) throw new EndOfStreamException("compact size truncated");
        var first = data[offset];
        return (int)first switch
        {
            < 0xfd => (first, 1),
            0xfd => (BinaryPrimitives.ReadUInt16LittleEndian(data[(offset + 1)..]), 3),
            0xfe => (BinaryPrimitives.ReadUInt32LittleEndian(data[(offset + 1)..]), 5),
            0xff => (BinaryPrimitives.ReadInt64LittleEndian(data[(offset + 1)..]), 9),
            _ => throw new InvalidDataException("invalid compact size")
        };
    }

    public static byte[] ReadBytes(ReadOnlySpan<byte> data, ref int offset, int count)
    {
        if (offset + count > data.Length)
            throw new EndOfStreamException($"need {count} bytes at offset {offset}");
        var slice = data.Slice(offset, count).ToArray();
        offset += count;
        return slice;
    }

    public static string ReadFixedString(ReadOnlySpan<byte> data, ref int offset, int length)
    {
        var bytes = ReadBytes(data, ref offset, length);
        return Encoding.ASCII.GetString(bytes).TrimEnd('\0');
    }
}
