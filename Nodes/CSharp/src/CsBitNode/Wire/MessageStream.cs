using System.Net.Sockets;

namespace CsBitNode.Wire;

public sealed class MessageStream : IDisposable
{
    private readonly NetworkStream _stream;
    private readonly byte[] _magic;
    private readonly byte[] _headerBuf = new byte[MessageFramer.HeaderSize];

    public MessageStream(NetworkStream stream, byte[] magic)
    {
        _stream = stream;
        _magic = magic;
    }

    public void Send(string command, byte[] payload)
    {
        var frame = MessageFramer.BuildMessage(_magic, command, payload);
        _stream.Write(frame);
        _stream.Flush();
    }

    public NetworkMessage ReadMessage(CancellationToken cancellationToken = default)
    {
        ReadExact(_headerBuf, cancellationToken);
        var header = MessageFramer.ParseHeader(_headerBuf);
        if (!header.Magic.AsSpan().SequenceEqual(_magic))
            throw new InvalidDataException($"unexpected magic for command {header.Command}");
        var payload = new byte[header.Length];
        if (header.Length > 0)
            ReadExact(payload, cancellationToken);
        if (!MessageFramer.VerifyChecksum(payload, header.Checksum))
            throw new InvalidDataException($"checksum mismatch for {header.Command}");
        return new NetworkMessage(header.Command, payload);
    }

    public NetworkMessage ReadUntilCommand(string command, TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        while (true)
        {
            var message = ReadMessage(cts.Token);
            if (message.Command == command)
                return message;
        }
    }

    public NetworkMessage ReadUntilAnyCommand(IReadOnlyList<string> commands, TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        while (true)
        {
            var message = ReadMessage(cts.Token);
            if (commands.Contains(message.Command))
                return message;
        }
    }

    private void ReadExact(byte[] buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var read = _stream.Read(buffer, offset, buffer.Length - offset);
            if (read == 0)
                throw new EndOfStreamException("peer closed connection");
            offset += read;
        }
    }

    public void Dispose() => _stream.Dispose();
}
