namespace CsBitNode.Consensus;

public sealed record BlockHeader(
    int Version,
    byte[] PrevBlock,
    byte[] MerkleRoot,
    long Timestamp,
    uint Bits,
    uint Nonce);
