using CsBitNode.Util;
using CsBitNode.Wire;

namespace CsBitNode.Tests.Wire;

public class MessageFramerTests
{
    [Fact]
    public void BuildAndParseRoundTrip()
    {
        var magic = Hex.Decode("1c163f28");
        var payload = new byte[] { 1, 2, 3, 4 };
        var frame = MessageFramer.BuildMessage(magic, "version", payload);
        var header = MessageFramer.ParseHeader(frame);
        Assert.Equal("version", header.Command);
        Assert.Equal(payload.Length, header.Length);
        Assert.True(MessageFramer.VerifyChecksum(payload, header.Checksum));
    }
}
