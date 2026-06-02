using CsBitNode.Consensus.Tx;
using CsBitNode.Wire;

namespace CsBitNode.Consensus.Tx;

public static class TransactionParser
{
    public static Transaction Parse(byte[] data, ref int offset, bool witnessEnabled = true)
    {
        var start = offset;
        var version = WireSerialize.UnpackInt32Le(data, offset); offset += 4;

        var hasWitness = false;
        if (witnessEnabled && offset + 2 <= data.Length && data[offset] == 0 && data[offset + 1] == 1)
        {
            hasWitness = true;
            offset += 2;
        }

        var (inputCount, inputRead) = WireSerialize.ReadCompactSize(data, offset);
        offset += inputRead;
        var inputs = new List<TxIn>((int)inputCount);
        for (var i = 0; i < inputCount; i++)
            inputs.Add(ParseInput(data, ref offset));

        var (outputCount, outputRead) = WireSerialize.ReadCompactSize(data, offset);
        offset += outputRead;
        var outputs = new List<TxOut>((int)outputCount);
        for (var i = 0; i < outputCount; i++)
            outputs.Add(ParseOutput(data, ref offset));

        var witness = new List<IReadOnlyList<byte[]>>();
        if (hasWitness)
        {
            for (var i = 0; i < inputCount; i++)
            {
                var (stackCount, stackRead) = WireSerialize.ReadCompactSize(data, offset);
                offset += stackRead;
                var stack = new List<byte[]>((int)stackCount);
                for (var j = 0; j < stackCount; j++)
                {
                    var (itemLen, itemRead) = WireSerialize.ReadCompactSize(data, offset);
                    offset += itemRead;
                    stack.Add(WireSerialize.ReadBytes(data, ref offset, (int)itemLen));
                }
                witness.Add(stack);
            }
        }

        var lockTime = (uint)WireSerialize.UnpackInt32Le(data, offset); offset += 4;
        _ = start;
        return new Transaction(version, inputs, outputs, lockTime, witness);
    }

    private static TxIn ParseInput(byte[] data, ref int offset)
    {
        var prevHash = WireSerialize.ReadBytes(data, ref offset, 32);
        var prevIndex = (uint)WireSerialize.UnpackInt32Le(data, offset); offset += 4;
        var (scriptLen, scriptRead) = WireSerialize.ReadCompactSize(data, offset);
        offset += scriptRead;
        var scriptSig = WireSerialize.ReadBytes(data, ref offset, (int)scriptLen);
        var sequence = (uint)WireSerialize.UnpackInt32Le(data, offset); offset += 4;
        return new TxIn(new OutPoint(prevHash, prevIndex), scriptSig, sequence);
    }

    private static TxOut ParseOutput(byte[] data, ref int offset)
    {
        var value = WireSerialize.UnpackInt64Le(data, offset); offset += 8;
        var (scriptLen, scriptRead) = WireSerialize.ReadCompactSize(data, offset);
        offset += scriptRead;
        var script = WireSerialize.ReadBytes(data, ref offset, (int)scriptLen);
        return new TxOut(value, script);
    }
}

public static class TransactionSerializer
{
    public static byte[] Serialize(Transaction tx, bool includeWitness)
    {
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.PackInt32Le(tx.Version));
        if (includeWitness && tx.Witness.Count > 0)
        {
            ms.WriteByte(0);
            ms.WriteByte(1);
        }
        ms.Write(WireSerialize.WriteCompactSize(tx.Inputs.Count));
        foreach (var input in tx.Inputs)
        {
            ms.Write(input.PreviousOutput.Hash);
            ms.Write(WireSerialize.PackInt32Le((int)input.PreviousOutput.Index));
            ms.Write(WireSerialize.WriteCompactSize(input.ScriptSig.Length));
            ms.Write(input.ScriptSig);
            ms.Write(WireSerialize.PackInt32Le((int)input.Sequence));
        }
        ms.Write(WireSerialize.WriteCompactSize(tx.Outputs.Count));
        foreach (var output in tx.Outputs)
        {
            ms.Write(WireSerialize.PackInt64Le(output.Value));
            ms.Write(WireSerialize.WriteCompactSize(output.ScriptPubKey.Length));
            ms.Write(output.ScriptPubKey);
        }
        if (includeWitness && tx.Witness.Count > 0)
        {
            foreach (var stack in tx.Witness)
            {
                ms.Write(WireSerialize.WriteCompactSize(stack.Count));
                foreach (var item in stack)
                {
                    ms.Write(WireSerialize.WriteCompactSize(item.Length));
                    ms.Write(item);
                }
            }
        }
        ms.Write(WireSerialize.PackInt32Le((int)tx.LockTime));
        return ms.ToArray();
    }
}
