namespace CsBitNode.Consensus.Tx;

public sealed record OutPoint(byte[] Hash, uint Index);

public sealed record TxIn(OutPoint PreviousOutput, byte[] ScriptSig, uint Sequence);

public sealed record TxOut(long Value, byte[] ScriptPubKey);

public sealed record Transaction(
    int Version,
    IReadOnlyList<TxIn> Inputs,
    IReadOnlyList<TxOut> Outputs,
    uint LockTime,
    IReadOnlyList<IReadOnlyList<byte[]>> Witness)
{
    public bool IsCoinbase =>
        Inputs.Count == 1
        && Inputs[0].PreviousOutput.Hash.All(b => b == 0)
        && Inputs[0].PreviousOutput.Index == 0xffff_ffff;
}
