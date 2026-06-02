#pragma once

#include <cstdint>
#include <span>
#include <tuple>
#include <vector>

#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::tests {

std::vector<std::uint8_t> pushData(std::span<const std::uint8_t> data);
std::vector<std::uint8_t> pushScriptNum(int value);
std::vector<std::uint8_t> p2pkhScriptPubkey(std::span<const std::uint8_t> pubkeyHash);
std::vector<std::uint8_t> p2shScriptPubkey(std::span<const std::uint8_t> scriptHash160);
std::vector<std::uint8_t> p2pkScriptPubkey(std::span<const std::uint8_t> pubkey);
std::vector<std::uint8_t> cltvRedeemScript(int locktimeValue, std::span<const std::uint8_t> pubkey);
std::vector<std::uint8_t> csvRedeemScript(int sequenceValue, std::span<const std::uint8_t> pubkey);
std::vector<std::uint8_t> multisigRedeemScript(int required, const std::vector<std::vector<std::uint8_t>>& pubkeys);

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2pkSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount,
    std::span<const std::uint8_t> pubkey, std::int64_t outputValue);

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2pkhSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount,
    std::span<const std::uint8_t> pubkey, std::int64_t outputValue,
    std::span<const std::uint8_t> outputScriptPubkey = std::span<const std::uint8_t>());

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2wpkhSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount,
    std::span<const std::uint8_t> pubkey, std::int64_t outputValue);

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2shP2pkhSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount,
    std::span<const std::uint8_t> pubkey, std::int64_t outputValue);

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2wshP2pkhSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount,
    std::span<const std::uint8_t> pubkey, std::int64_t outputValue);

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2shMultisigSpend(
    const std::vector<std::uint64_t>& privateKeys, const std::vector<std::vector<std::uint8_t>>& pubkeys, int required,
    std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount, std::int64_t outputValue);

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2wshMultisigSpend(
    const std::vector<std::uint64_t>& privateKeys, const std::vector<std::vector<std::uint8_t>>& pubkeys, int required,
    std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount, std::int64_t outputValue);

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2shCltvSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> pubkey, int locktimeValue, std::uint32_t txLockTime,
    std::uint32_t inputSequence, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout,
    std::int64_t prevAmount, std::int64_t outputValue);

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2wshCltvSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> pubkey, int locktimeValue, std::uint32_t txLockTime,
    std::uint32_t inputSequence, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout,
    std::int64_t prevAmount, std::int64_t outputValue);

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2shCsvSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> pubkey, int csvOperand, std::uint32_t inputSequence,
    std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount, std::int64_t outputValue);

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2wshCsvSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> pubkey, int csvOperand, std::uint32_t inputSequence,
    std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount, std::int64_t outputValue);

}  // namespace cpbitnode::tests
