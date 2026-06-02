namespace CsBitNode.Wire;

public sealed record NetworkMessage(string Command, byte[] Payload);
