namespace CsBitNode.Chain;

public sealed record ChainParams(
    string Name,
    byte[] Magic,
    int DefaultPort,
    string GenesisHash,
    int ProtocolVersion,
    string UserAgent);
