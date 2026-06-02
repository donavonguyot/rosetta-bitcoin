#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <utility>
#include <vector>

#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus::script {

std::vector<std::uint8_t> bitcoinTaggedHash(const std::string& tag, std::span<const std::uint8_t> msg);
std::vector<std::uint8_t> tapleafHash(int leafVersion, std::span<const std::uint8_t> tapscriptBytes);
std::vector<std::uint8_t> tapbranchHash(std::span<const std::uint8_t, 32> left,
                                         std::span<const std::uint8_t, 32> right);
std::vector<std::uint8_t> taprootTweakPubkeyHash(std::span<const std::uint8_t, 32> internalPubkeyXonly,
                                                  std::span<const std::uint8_t> merkleRoot);
std::vector<std::uint8_t> taprootMerkleRootFromBranch(
    const std::vector<std::vector<std::uint8_t>>& branchNodes, std::span<const std::uint8_t, 32> leafHash);
std::vector<std::uint8_t> serializedWitnessStackBytes(
    const std::vector<std::vector<std::uint8_t>>& stack);

inline constexpr int TAPROOT_SIGHASH_DEFAULT = 0;
inline constexpr int TAPROOT_SIGHASH_ALL = 1;
inline constexpr int TAPROOT_SIGHASH_NONE = 2;
inline constexpr int TAPROOT_SIGHASH_SINGLE = 3;

std::vector<std::uint8_t> taprootSignatureHash(
    const messages::Transaction& transaction, std::size_t inputIndex,
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>& spentPrevouts, int hashType,
    const std::vector<std::uint8_t>* annex = nullptr, int extFlag = 0,
    std::span<const std::uint8_t> tapleafHashBytes = {}, std::uint32_t tapscriptCodeseparatorPos = 0xFFFFFFFF);

std::vector<std::uint8_t> legacySighash(const messages::Transaction& transaction, std::size_t inputIndex,
                                          std::span<const std::uint8_t> scriptCode, int sighashType = 1);

std::vector<std::uint8_t> bip143Sighash(const messages::Transaction& transaction, std::size_t inputIndex,
                                          std::span<const std::uint8_t> scriptCode, std::int64_t amount,
                                          int sighashType = 1);

}  // namespace cpbitnode::consensus::script
