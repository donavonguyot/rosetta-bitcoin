#pragma once

#include <cstdint>

namespace cpbitnode::consensus::script {

inline constexpr std::uint8_t OP_0 = 0x00;
inline constexpr std::uint8_t OP_PUSHDATA1 = 0x4C;
inline constexpr std::uint8_t OP_PUSHDATA2 = 0x4D;
inline constexpr std::uint8_t OP_PUSHDATA4 = 0x4E;
inline constexpr std::uint8_t OP_1NEGATE = 0x4F;
inline constexpr std::uint8_t OP_1 = 0x51;
inline constexpr std::uint8_t OP_16 = 0x60;
inline constexpr std::uint8_t OP_IF = 0x63;
inline constexpr std::uint8_t OP_NOTIF = 0x64;
inline constexpr std::uint8_t OP_ELSE = 0x67;
inline constexpr std::uint8_t OP_ENDIF = 0x68;
inline constexpr std::uint8_t OP_VERIFY = 0x69;
inline constexpr std::uint8_t OP_TOALTSTACK = 0x6B;
inline constexpr std::uint8_t OP_FROMALTSTACK = 0x6C;
inline constexpr std::uint8_t OP_2DROP = 0x6D;
inline constexpr std::uint8_t OP_2DUP = 0x6E;
inline constexpr std::uint8_t OP_3DUP = 0x6F;
inline constexpr std::uint8_t OP_2OVER = 0x70;
inline constexpr std::uint8_t OP_2ROT = 0x71;
inline constexpr std::uint8_t OP_2SWAP = 0x72;
inline constexpr std::uint8_t OP_IFDUP = 0x73;
inline constexpr std::uint8_t OP_DEPTH = 0x74;
inline constexpr std::uint8_t OP_DROP = 0x75;
inline constexpr std::uint8_t OP_DUP = 0x76;
inline constexpr std::uint8_t OP_NIP = 0x77;
inline constexpr std::uint8_t OP_OVER = 0x78;
inline constexpr std::uint8_t OP_PICK = 0x79;
inline constexpr std::uint8_t OP_ROLL = 0x7A;
inline constexpr std::uint8_t OP_ROT = 0x7B;
inline constexpr std::uint8_t OP_SWAP = 0x7C;
inline constexpr std::uint8_t OP_TUCK = 0x7D;
inline constexpr std::uint8_t OP_SIZE = 0x82;
inline constexpr std::uint8_t OP_1SUB = 0x8C;
inline constexpr std::uint8_t OP_NEGATE = 0x8F;
inline constexpr std::uint8_t OP_ABS = 0x90;
inline constexpr std::uint8_t OP_NOT = 0x91;
inline constexpr std::uint8_t OP_0NOTEQUAL = 0x92;
inline constexpr std::uint8_t OP_ADD = 0x93;
inline constexpr std::uint8_t OP_SUB = 0x94;
inline constexpr std::uint8_t OP_BOOLAND = 0x9A;
inline constexpr std::uint8_t OP_BOOLOR = 0x9B;
inline constexpr std::uint8_t OP_NUMEQUAL = 0x9C;
inline constexpr std::uint8_t OP_NUMEQUALVERIFY = 0x9D;
inline constexpr std::uint8_t OP_NUMNOTEQUAL = 0x9E;
inline constexpr std::uint8_t OP_LESSTHAN = 0x9F;
inline constexpr std::uint8_t OP_GREATERTHAN = 0xA0;
inline constexpr std::uint8_t OP_LESSTHANOREQUAL = 0xA1;
inline constexpr std::uint8_t OP_GREATERTHANOREQUAL = 0xA2;
inline constexpr std::uint8_t OP_MIN = 0xA3;
inline constexpr std::uint8_t OP_MAX = 0xA4;
inline constexpr std::uint8_t OP_WITHIN = 0xA5;
inline constexpr std::uint8_t OP_RIPEMD160 = 0xA6;
inline constexpr std::uint8_t OP_SHA1 = 0xA7;
inline constexpr std::uint8_t OP_SHA256 = 0xA8;
inline constexpr std::uint8_t OP_EQUAL = 0x87;
inline constexpr std::uint8_t OP_EQUALVERIFY = 0x88;
inline constexpr std::uint8_t OP_HASH160 = 0xA9;
inline constexpr std::uint8_t OP_HASH256 = 0xAA;
inline constexpr std::uint8_t OP_CODESEPARATOR = 0xAB;
inline constexpr std::uint8_t OP_CHECKSIG = 0xAC;
inline constexpr std::uint8_t OP_CHECKSIGVERIFY = 0xAD;
inline constexpr std::uint8_t OP_CHECKMULTISIG = 0xAE;
inline constexpr std::uint8_t OP_CHECKMULTISIGVERIFY = 0xAF;
inline constexpr std::uint8_t OP_CHECKLOCKTIMEVERIFY = 0xB1;
inline constexpr std::uint8_t OP_CHECKSEQUENCEVERIFY = 0xB2;
inline constexpr std::uint8_t OP_CHECKSIGADD = 0xBA;

inline constexpr int SIGHASH_ALL = 1;
inline constexpr int SIGHASH_NONE = 2;
inline constexpr int SIGHASH_SINGLE = 3;
inline constexpr int SIGHASH_ANYONECANPAY = 0x80;

inline constexpr int SCRIPT_VERIFY_P2SH = 1 << 0;
inline constexpr int SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY = 1 << 10;
inline constexpr int SCRIPT_VERIFY_CHECKSEQUENCEVERIFY = 1 << 11;

inline constexpr int SCRIPT_VERIFY_DEFAULT =
    SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY | SCRIPT_VERIFY_CHECKSEQUENCEVERIFY;

}  // namespace cpbitnode::consensus::script
