namespace CsBitNode.Consensus.Script;

public static class Opcodes
{
    public const byte OP_0 = 0x00;
    public const byte OP_1 = 0x51;
    public const byte OP_16 = 0x60;
    public const byte OP_NOP = 0x61;
    public const byte OP_1NEGATE = 0x4f;
    public const byte OP_PUSHDATA1 = 0x4c;
    public const byte OP_PUSHDATA2 = 0x4d;
    public const byte OP_PUSHDATA4 = 0x4e;
    public const byte OP_DROP = 0x75;
    public const byte OP_DUP = 0x76;
    public const byte OP_EQUAL = 0x87;
    public const byte OP_EQUALVERIFY = 0x88;
    public const byte OP_CHECKSIG = 0xac;
    public const byte OP_CHECKSIGVERIFY = 0xad;
    public const byte OP_CHECKMULTISIG = 0xae;
    public const byte OP_CHECKMULTISIGVERIFY = 0xaf;
    public const byte OP_HASH160 = 0xa9;
    public const byte OP_CHECKLOCKTIMEVERIFY = 0xb1;
    public const byte OP_CHECKSEQUENCEVERIFY = 0xb2;
}
