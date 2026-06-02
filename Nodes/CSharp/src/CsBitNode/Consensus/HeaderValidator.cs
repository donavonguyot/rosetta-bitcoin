using System.Numerics;
using CsBitNode.Consensus.Merkle;
using CsBitNode.Messages;
using CsBitNode.Util;

namespace CsBitNode.Consensus;

public static class Target
{
    public static BigInteger FromBits(uint bits)
    {
        var exponent = (int)(bits >> 24);
        var mantissa = bits & 0x007f_ffff;
        if (exponent <= 3)
        {
            mantissa >>= 8 * (3 - exponent);
            return mantissa;
        }
        return mantissa * BigInteger.Pow(256, exponent - 3);
    }

    public static bool MeetsTarget(byte[] blockHashInternal, uint bits)
    {
        var target = FromBits(bits);
        var hash = new BigInteger(Hex.Reverse(blockHashInternal), isUnsigned: true, isBigEndian: true);
        return hash <= target;
    }
}

public static class HeaderValidator
{
    public static BigInteger ChainWorkForHeader(BlockHeader header)
    {
        var target = Target.FromBits(header.Bits);
        if (target.Sign <= 0)
            return BigInteger.Zero;
        var max = BigInteger.Pow(2, 256);
        return max / (target + BigInteger.One);
    }

    public static void ValidateHeader(BlockHeader header, byte[] expectedPrevInternal, BigInteger prevChainWork)
    {
        if (!header.PrevBlock.AsSpan().SequenceEqual(expectedPrevInternal))
            throw new HeaderValidationException("prev block hash mismatch");
        var hash = BlockHeaderCodec.BlockHash(header);
        if (!Target.MeetsTarget(hash, header.Bits))
            throw new HeaderValidationException("header does not meet proof-of-work target");
        _ = prevChainWork;
    }
}

public sealed class HeaderValidationException : Exception
{
    public HeaderValidationException(string message) : base(message) { }
}

public static class BlockValidator
{
    public sealed record ValidateOptions(byte[] ExpectedPrevInternal, byte[] ExpectedHashInternal);

    public static Block.Block ValidateBlock(byte[] payload, ValidateOptions options)
    {
        var block = Block.BlockDeserializer.Deserialize(payload);
        var hash = BlockHeaderCodec.BlockHash(block.Header);
        if (!hash.AsSpan().SequenceEqual(options.ExpectedHashInternal))
            throw new BlockValidationException("block hash mismatch");
        if (!block.Header.PrevBlock.AsSpan().SequenceEqual(options.ExpectedPrevInternal))
            throw new BlockValidationException("prev block hash mismatch");
        var merkle = MerkleComputer.BlockMerkleRoot(block.Transactions);
        if (!block.Header.MerkleRoot.AsSpan().SequenceEqual(merkle))
            throw new BlockValidationException("merkle root mismatch");
        if (block.Transactions.Count == 0 || !block.Transactions[0].IsCoinbase)
            throw new BlockValidationException("first transaction must be coinbase");
        return block;
    }
}

public sealed class BlockValidationException : Exception
{
    public BlockValidationException(string message) : base(message) { }
}

public static class ConsensusConstants
{
    public const int CoinbaseMaturity = 100;
}
