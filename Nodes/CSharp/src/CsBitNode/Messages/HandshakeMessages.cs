using CsBitNode.Wire;

namespace CsBitNode.Messages;

public static class HandshakeMessages
{
    public const string VersionCommand = "version";
    public const string VerAckCommand = "verack";
    public const string SendHeadersCommand = "sendheaders";

    public const ulong NodeNetwork = 1;
    public const ulong NodeWitness = 1UL << 3;

    public sealed record NetworkAddress(ulong Services, byte[] Ip, int Port);

    public sealed record VersionMessage(
        int Version,
        ulong Services,
        long Timestamp,
        NetworkAddress AddrRecv,
        NetworkAddress AddrFrom,
        ulong Nonce,
        string UserAgent,
        int StartHeight,
        bool Relay);

    public static byte[] SerializeVersion(VersionMessage message)
    {
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.PackInt32Le(message.Version));
        ms.Write(WireSerialize.PackInt64Le((long)message.Services));
        ms.Write(WireSerialize.PackInt64Le(message.Timestamp));
        ms.Write(SerializeNetworkAddress(message.AddrRecv));
        ms.Write(SerializeNetworkAddress(message.AddrFrom));
        ms.Write(WireSerialize.PackInt64Le((long)message.Nonce));
        var uaBytes = System.Text.Encoding.ASCII.GetBytes(message.UserAgent);
        ms.Write(WireSerialize.WriteCompactSize(uaBytes.Length));
        ms.Write(uaBytes);
        ms.Write(WireSerialize.PackInt32Le(message.StartHeight));
        if (message.Version >= 70_002)
            ms.WriteByte(message.Relay ? (byte)1 : (byte)0);
        return ms.ToArray();
    }

    public static VersionMessage DeserializeVersion(byte[] payload)
    {
        var offset = 0;
        var version = WireSerialize.UnpackInt32Le(payload, offset); offset += 4;
        var services = (ulong)WireSerialize.UnpackInt64Le(payload, offset); offset += 8;
        var timestamp = WireSerialize.UnpackInt64Le(payload, offset); offset += 8;
        var addrRecv = DeserializeNetworkAddress(payload, ref offset);
        var addrFrom = DeserializeNetworkAddress(payload, ref offset);
        var nonce = (ulong)WireSerialize.UnpackInt64Le(payload, offset); offset += 8;
        var (uaLen, uaRead) = WireSerialize.ReadCompactSize(payload, offset); offset += uaRead;
        var userAgent = System.Text.Encoding.ASCII.GetString(payload, offset, (int)uaLen); offset += (int)uaLen;
        var startHeight = WireSerialize.UnpackInt32Le(payload, offset); offset += 4;
        var relay = version < 70_002 || (offset < payload.Length && payload[offset] != 0);
        return new VersionMessage(version, services, timestamp, addrRecv, addrFrom, nonce, userAgent, startHeight, relay);
    }

    public static byte[] SerializeVerAck() => Array.Empty<byte>();
    public static byte[] SerializeSendHeaders() => Array.Empty<byte>();

    private static byte[] SerializeNetworkAddress(NetworkAddress address)
    {
        var buf = new byte[26];
        WireSerialize.PackInt64Le((long)address.Services).CopyTo(buf, 0);
        address.Ip.CopyTo(buf, 8);
        WireSerialize.PackUint16Be(address.Port).CopyTo(buf, 24);
        return buf;
    }

    private static NetworkAddress DeserializeNetworkAddress(byte[] data, ref int offset)
    {
        var services = (ulong)WireSerialize.UnpackInt64Le(data, offset); offset += 8;
        var ip = WireSerialize.ReadBytes(data, ref offset, 16);
        var port = WireSerialize.UnpackUint16Be(data, offset); offset += 2;
        return new NetworkAddress(services, ip, port);
    }
}
