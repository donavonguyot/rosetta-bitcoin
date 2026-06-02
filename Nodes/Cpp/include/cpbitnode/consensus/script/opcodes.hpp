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
inline constexpr std::uint8_t OP_DROP = 0x75;
inline constexpr std::uint8_t OP_DUP = 0x76;
inline constexpr std::uint8_t OP_EQUAL = 0x87;
inline constexpr std::uint8_t OP_EQUALVERIFY = 0x88;
inline constexpr std::uint8_t OP_VERIFY = 0x69;
inline constexpr std::uint8_t OP_HASH160 = 0xA9;
inline constexpr std::uint8_t OP_CHECKSIG = 0xAC;
inline constexpr std::uint8_t OP_CHECKSIGVERIFY = 0xAD;
inline constexpr std::uint8_t OP_CHECKMULTISIG = 0xAE;
inline constexpr std::uint8_t OP_CHECKMULTISIGVERIFY = 0xAF;
inline constexpr std::uint8_t OP_CHECKLOCKTIMEVERIFY = 0xB1;
inline constexpr std::uint8_t OP_CHECKSEQUENCEVERIFY = 0xB2;

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
