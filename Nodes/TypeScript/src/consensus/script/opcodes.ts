export const OP_0 = 0x00;
export const OP_PUSHDATA1 = 0x4c;
export const OP_PUSHDATA2 = 0x4d;
export const OP_PUSHDATA4 = 0x4e;
export const OP_1NEGATE = 0x4f;
export const OP_1 = 0x51;
export const OP_16 = 0x60;
export const OP_DUP = 0x76;
export const OP_EQUAL = 0x87;
export const OP_EQUALVERIFY = 0x88;
export const OP_HASH160 = 0xa9;
export const OP_CHECKSIG = 0xac;
export const OP_CHECKSIGVERIFY = 0xad;
export const OP_CHECKMULTISIG = 0xae;
export const OP_CHECKMULTISIGVERIFY = 0xaf;
export const OP_CHECKLOCKTIMEVERIFY = 0xb1;
export const OP_CHECKSEQUENCEVERIFY = 0xb2;
export const OP_VERIFY = 0x69;
export const OP_DROP = 0x75;
export const OP_SWAP = 0x7c;
export const OP_CODESEPARATOR = 0xab;

export const SCRIPT_VERIFY_P2SH = 1 << 0;
export const SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY = 1 << 10;
export const SCRIPT_VERIFY_CHECKSEQUENCEVERIFY = 1 << 11;

export const SCRIPT_VERIFY_DEFAULT =
  SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY | SCRIPT_VERIFY_CHECKSEQUENCEVERIFY;

export const MAX_P2SH_REDEEM_PUSH = 520;
export const MAX_CONSENSUS_SCRIPT_SIZE = 10_000;
export const MAX_PUBKEYS_PER_MULTISIG = 20;
export const MAX_TAPSCRIPT_STACK_ELEMENTS = 1000;
export const MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS = 520;
export const WITNESS_V1_TAPROOT_XONLY_PK_LEN = 32;
export const ANNEX_TAG = 0x50;
export const TAPROOT_LEAF_VERSION_TAPSCRIPT = 0xc0;
export const VALIDATION_WEIGHT_OFFSET = 50;
export const VALIDATION_WEIGHT_PER_SIGOP = 50;
