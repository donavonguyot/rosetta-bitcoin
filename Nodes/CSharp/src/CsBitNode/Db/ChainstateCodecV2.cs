using System.Buffers.Binary;
using CsBitNode.Util;

namespace CsBitNode.Db;

public static class ChainstateCodecV2
{
    private const byte UtxoPrefix = (byte)'u';
    private const byte MetadataPrefix = (byte)'m';
    private const byte TipPrefix = (byte)'t';
    private const byte UndoPrefix = (byte)'d';
    private const byte BlockIndexPrefix = (byte)'b';
    private const byte HeaderPrefix = (byte)'h';

    public static byte[] UtxoKey(string chain, string txidHex, int vout)
    {
        using var stream = new MemoryStream();
        WriteChainPrefix(stream, UtxoPrefix, chain);
        stream.Write(Hex.Decode(txidHex));
        WriteU32(stream, vout);
        return stream.ToArray();
    }

    public static byte[] UtxoPrefixKey(string chain) => ChainPrefix(UtxoPrefix, chain);

    public static byte[] UndoKey(string chain, int height)
    {
        using var stream = new MemoryStream();
        WriteChainPrefix(stream, UndoPrefix, chain);
        WriteU32(stream, height);
        return stream.ToArray();
    }

    public static byte[] TipKey(string chain) => ChainPrefix(TipPrefix, chain);

    public static byte[] MetadataKey(string name)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(name);
        return [(byte)'m', (byte)bytes.Length, .. bytes];
    }

    public static byte[] BlockIndexKey(string chain, int height)
    {
        using var stream = new MemoryStream();
        WriteChainPrefix(stream, BlockIndexPrefix, chain);
        WriteU32(stream, height);
        return stream.ToArray();
    }

    public static byte[] HeaderKey(string chain, int height)
    {
        using var stream = new MemoryStream();
        WriteChainPrefix(stream, HeaderPrefix, chain);
        WriteU32(stream, height);
        return stream.ToArray();
    }

    public static byte[] EncodeUtxo(StoredUtxo utxo)
    {
        using var stream = new MemoryStream();
        WriteU32(stream, utxo.Height);
        WriteU64(stream, utxo.ValueSats);
        stream.WriteByte((byte)(utxo.Coinbase ? 1 : 0));
        WriteBytes(stream, Hex.Decode(utxo.ScriptPubKeyHex));
        return stream.ToArray();
    }

    public static StoredUtxo DecodeUtxo(string txidHex, int vout, byte[] value)
    {
        var offset = 0;
        var height = ReadU32(value, ref offset);
        var sats = ReadU64(value, ref offset);
        var flags = value[offset++];
        var script = ReadBytes(value, ref offset);
        return new StoredUtxo(txidHex, vout, height, sats, Hex.Encode(script), (flags & 1) != 0);
    }

    public static byte[] EncodeUndo(IReadOnlyList<UtxoUndoEntry> entries)
    {
        using var stream = new MemoryStream();
        WriteU32(stream, entries.Count);
        foreach (var entry in entries)
        {
            stream.Write(Hex.Decode(entry.Txid));
            WriteU32(stream, entry.Vout);
            WriteU32(stream, entry.Height);
            WriteU64(stream, entry.ValueSats);
            stream.WriteByte((byte)(entry.Coinbase ? 1 : 0));
            WriteBytes(stream, Hex.Decode(entry.ScriptPubKeyHex));
        }
        return stream.ToArray();
    }

    public static IReadOnlyList<UtxoUndoEntry> DecodeUndo(byte[] value)
    {
        var offset = 0;
        var count = ReadU32(value, ref offset);
        var entries = new List<UtxoUndoEntry>(count);
        for (var i = 0; i < count; i++)
        {
            var txid = value[offset..(offset + 32)];
            offset += 32;
            var vout = ReadU32(value, ref offset);
            var height = ReadU32(value, ref offset);
            var sats = ReadU64(value, ref offset);
            var flags = value[offset++];
            var script = ReadBytes(value, ref offset);
            entries.Add(new UtxoUndoEntry(Hex.Encode(txid), vout, height, sats, Hex.Encode(script), (flags & 1) != 0));
        }
        return entries;
    }

    public static byte[] EncodeTip(int height, string hashHex)
    {
        using var stream = new MemoryStream();
        WriteU32(stream, height);
        stream.Write(Hex.Decode(hashHex));
        return stream.ToArray();
    }

    public static (int Height, string HashHex) DecodeTip(byte[] value)
    {
        var offset = 0;
        var height = ReadU32(value, ref offset);
        var hash = value[offset..(offset + 32)];
        return (height, Hex.Encode(hash));
    }

    public static byte[] EncodeBlockIndex(string blockHashHex, int fileNumber, int fileOffset, int blockSize)
    {
        using var stream = new MemoryStream();
        stream.Write(Hex.Decode(blockHashHex));
        WriteU32(stream, fileNumber);
        WriteU32(stream, fileOffset);
        WriteU32(stream, blockSize);
        return stream.ToArray();
    }

    public static (string BlockHashHex, int FileNumber, int FileOffset, int BlockSize) DecodeBlockIndex(byte[] value)
    {
        var offset = 0;
        var hash = value[offset..(offset + 32)];
        offset += 32;
        var fileNumber = ReadU32(value, ref offset);
        var fileOffset = ReadU32(value, ref offset);
        var blockSize = ReadU32(value, ref offset);
        return (Hex.Encode(hash), fileNumber, fileOffset, blockSize);
    }

    public static byte[] EncodeHeader(byte[] serializedHeader)
    {
        using var stream = new MemoryStream();
        WriteBytes(stream, serializedHeader);
        return stream.ToArray();
    }

    public static byte[] DecodeHeader(byte[] value)
    {
        var offset = 0;
        return ReadBytes(value, ref offset);
    }

    public static byte[] MetadataValue(string value) => System.Text.Encoding.UTF8.GetBytes(value);

    public static string DecodeMetadataValue(byte[] value) => System.Text.Encoding.UTF8.GetString(value);

    private static byte[] ChainPrefix(byte prefix, string chain)
    {
        using var stream = new MemoryStream();
        WriteChainPrefix(stream, prefix, chain);
        return stream.ToArray();
    }

    private static void WriteChainPrefix(Stream stream, byte prefix, string chain)
    {
        var chainBytes = System.Text.Encoding.UTF8.GetBytes(chain);
        stream.WriteByte(prefix);
        stream.WriteByte((byte)chainBytes.Length);
        stream.Write(chainBytes);
    }

    private static void WriteU32(Stream stream, int value)
    {
        Span<byte> bytes = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(bytes, (uint)value);
        stream.Write(bytes);
    }

    private static void WriteU64(Stream stream, long value)
    {
        Span<byte> bytes = stackalloc byte[8];
        BinaryPrimitives.WriteUInt64BigEndian(bytes, (ulong)value);
        stream.Write(bytes);
    }

    private static int ReadU32(byte[] value, ref int offset)
    {
        var result = (int)BinaryPrimitives.ReadUInt32BigEndian(value.AsSpan(offset, 4));
        offset += 4;
        return result;
    }

    private static long ReadU64(byte[] value, ref int offset)
    {
        var result = (long)BinaryPrimitives.ReadUInt64BigEndian(value.AsSpan(offset, 8));
        offset += 8;
        return result;
    }

    private static void WriteBytes(Stream stream, byte[] value)
    {
        WriteU32(stream, value.Length);
        stream.Write(value);
    }

    private static byte[] ReadBytes(byte[] value, ref int offset)
    {
        var length = ReadU32(value, ref offset);
        var bytes = value[offset..(offset + length)];
        offset += length;
        return bytes;
    }
}
