using System.Text;
using CsBitNode.Util;

namespace CsBitNode.Wire;

public sealed record MessageHeader(byte[] Magic, string Command, int Length, byte[] Checksum);

public static class MessageFramer
{
    public const int HeaderSize = 24;

    public static MessageHeader ParseHeader(ReadOnlySpan<byte> data)
    {
        if (data.Length < HeaderSize)
            throw new ArgumentException($"header requires {HeaderSize} bytes, got {data.Length}");
        var magic = data[..4].ToArray();
        var command = Encoding.ASCII.GetString(data[4..16]).TrimEnd('\0');
        var length = WireSerialize.UnpackInt32Le(data, 16);
        var checksum = data[20..24].ToArray();
        return new MessageHeader(magic, command, length, checksum);
    }

    public static byte[] HeaderToBytes(MessageHeader header)
    {
        var buf = new byte[HeaderSize];
        header.Magic.CopyTo(buf, 0);
        var cmd = new byte[12];
        Encoding.ASCII.GetBytes(header.Command.AsSpan(0, Math.Min(header.Command.Length, 12)), cmd);
        cmd.CopyTo(buf, 4);
        WireSerialize.PackInt32Le(header.Length).CopyTo(buf, 16);
        header.Checksum.CopyTo(buf, 20);
        return buf;
    }

    public static byte[] BuildMessage(byte[] magic, string command, byte[] payload)
    {
        var checksum = WireSerialize.MessageChecksum(payload);
        var header = HeaderToBytes(new MessageHeader(magic, command, payload.Length, checksum));
        var frame = new byte[header.Length + payload.Length];
        header.CopyTo(frame, 0);
        payload.CopyTo(frame, header.Length);
        return frame;
    }

    public static bool VerifyChecksum(ReadOnlySpan<byte> payload, ReadOnlySpan<byte> checksum) =>
        WireSerialize.MessageChecksum(payload).AsSpan().SequenceEqual(checksum);
}
