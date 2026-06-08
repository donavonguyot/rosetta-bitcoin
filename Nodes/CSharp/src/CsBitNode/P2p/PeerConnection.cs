using System.Net;
using System.Net.Sockets;
using CsBitNode.Chain;
using CsBitNode.Db;
using CsBitNode.Messages;
using CsBitNode.Sync;
using CsBitNode.Wire;

namespace CsBitNode.P2p;

// Outbound P2P for sync: deferred advanced negotiation and honest start_height during catch-up.
public sealed class PeerConnection : IDisposable, BlockSync.IBlockSource
{
    private readonly string _host;
    private readonly int _port;
    private readonly ChainParams _chain;
    private readonly IChainstateStore _tracker;
    private readonly int _startHeight;

    private TcpClient? _client;
    private MessageStream? _stream;
    private HandshakeMessages.VersionMessage? _remoteVersion;

    public PeerConnection(string host, int port, ChainParams chain, IChainstateStore tracker, int startHeight)
    {
        _host = host;
        _port = port;
        _chain = chain;
        _tracker = tracker;
        _startHeight = startHeight;
    }

    public string Host => _host;
    public int Port => _port;
    public HandshakeMessages.VersionMessage? RemoteVersion => _remoteVersion;

    public void Connect()
    {
        _client = new TcpClient();
        _client.NoDelay = true;
        _client.Connect(_host, _port);
        _client.ReceiveTimeout = 0;
        _stream = new MessageStream(_client.GetStream(), _chain.Magic);
        HandshakeAsInitiator();
        _tracker.RecordPeerConnected(
            _host,
            _port,
            "outbound",
            _remoteVersion?.Services ?? 0,
            _remoteVersion?.Version ?? 0,
            _remoteVersion?.UserAgent ?? "",
            _remoteVersion?.StartHeight ?? 0);
    }

    public HeadersMessage.Message RequestHeaders(IReadOnlyList<byte[]> locator)
    {
        var payload = HeadersMessage.SerializeGetHeaders(_chain.ProtocolVersion, locator, new byte[32]);
        _stream!.Send(GetHeadersMessage.Command, payload);
        var response = _stream.ReadUntilCommand(HeadersMessage.Command, TimeSpan.FromSeconds(120));
        return HeadersMessage.Deserialize(response.Payload);
    }

    public byte[]? RequestBlock(byte[] blockHashInternal)
    {
        foreach (var invType in new[] { InventoryMessages.MsgWitnessBlock, InventoryMessages.MsgBlock })
        {
            var payload = RequestBlockOnce(blockHashInternal, invType, TimeSpan.FromSeconds(120));
            if (payload is not null)
                return payload;
        }
        return null;
    }

    private byte[]? RequestBlockOnce(byte[] blockHashInternal, int invType, TimeSpan timeout)
    {
        var inv = new InventoryMessages.InventoryVector(invType, blockHashInternal);
        _stream!.Send(InventoryMessages.GetDataCommand, InventoryMessages.SerializeGetData(new[] { inv }));

        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var remaining = deadline - DateTime.UtcNow;
            var message = _stream.ReadUntilAnyCommand(
                new[] { BlockMessage.Command, InventoryMessages.NotFoundCommand },
                remaining);
            if (message.Command == BlockMessage.Command)
            {
                var payload = message.Payload;
                var receivedHash = BlockMessage.BlockHashFromPayload(payload);
                if (!receivedHash.AsSpan().SequenceEqual(blockHashInternal))
                    continue;
                return payload;
            }
            return null;
        }
        return null;
    }

    private void HandshakeAsInitiator()
    {
        var nonce = Random.Shared.NextInt64();
        var addrRecv = new HandshakeMessages.NetworkAddress(
            HandshakeMessages.NodeNetwork | HandshakeMessages.NodeWitness,
            EncodeNetworkAddressIp(IPAddress.Loopback),
            _port);
        var addrFrom = addrRecv;
        var localVersion = new HandshakeMessages.VersionMessage(
            _chain.ProtocolVersion,
            HandshakeMessages.NodeNetwork | HandshakeMessages.NodeWitness,
            DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            addrRecv,
            addrFrom,
            (ulong)nonce,
            _chain.UserAgent,
            _startHeight,
            Relay: false);

        _stream!.Send(HandshakeMessages.VersionCommand, HandshakeMessages.SerializeVersion(localVersion));

        var remotePayload = _stream.ReadUntilCommand(HandshakeMessages.VersionCommand, TimeSpan.FromSeconds(30)).Payload;
        _remoteVersion = HandshakeMessages.DeserializeVersion(remotePayload);

        _stream.Send(HandshakeMessages.VerAckCommand, HandshakeMessages.SerializeVerAck());
        _ = _stream.ReadUntilCommand(HandshakeMessages.VerAckCommand, TimeSpan.FromSeconds(30));

        // Simple handshake: sendheaders only; defer feefilter/mempool/sendcmpct until headers_current.
        _stream.Send(HandshakeMessages.SendHeadersCommand, HandshakeMessages.SerializeSendHeaders());
    }

    private static byte[] EncodeNetworkAddressIp(IPAddress address)
    {
        var bytes = new byte[16];
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            bytes[10] = 0xff;
            bytes[11] = 0xff;
            address.GetAddressBytes().CopyTo(bytes, 12);
        }
        else
        {
            address.GetAddressBytes().CopyTo(bytes, 0);
        }
        return bytes;
    }

    public void Dispose()
    {
        _stream?.Dispose();
        _client?.Dispose();
    }
}
