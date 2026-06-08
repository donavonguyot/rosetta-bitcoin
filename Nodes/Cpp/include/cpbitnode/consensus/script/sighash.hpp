#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <utility>
#include <vector>

#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus::script {

class SighashCache {
public:
    SighashCache(const messages::Transaction& transaction,
                 const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>* spentPrevouts = nullptr);

    const std::vector<std::uint8_t>& bip143HashPrevouts() const { return bip143HashPrevouts_; }
    const std::vector<std::uint8_t>& bip143HashSequence() const { return bip143HashSequence_; }
    const std::vector<std::uint8_t>& bip143HashOutputs() const { return bip143HashOutputs_; }
    const std::vector<std::uint8_t>& bip143HashSingle(std::size_t outputIndex) const;

    bool hasTaprootPrevouts() const { return taprootReady_; }
    const std::vector<std::uint8_t>& taprootHashPrevouts() const { return taprootHashPrevouts_; }
    const std::vector<std::uint8_t>& taprootHashAmounts() const { return taprootHashAmounts_; }
    const std::vector<std::uint8_t>& taprootHashScriptPubkeys() const { return taprootHashScriptPubkeys_; }
    const std::vector<std::uint8_t>& taprootHashSequences() const { return taprootHashSequences_; }
    const std::vector<std::uint8_t>& taprootHashOutputs() const { return taprootHashOutputs_; }
    const std::vector<std::uint8_t>& taprootHashSingle(std::size_t outputIndex) const;

private:
    std::vector<std::uint8_t> bip143HashPrevouts_;
    std::vector<std::uint8_t> bip143HashSequence_;
    std::vector<std::uint8_t> bip143HashOutputs_;
    std::vector<std::vector<std::uint8_t>> bip143HashSingle_;
    bool taprootReady_ = false;
    std::vector<std::uint8_t> taprootHashPrevouts_;
    std::vector<std::uint8_t> taprootHashAmounts_;
    std::vector<std::uint8_t> taprootHashScriptPubkeys_;
    std::vector<std::uint8_t> taprootHashSequences_;
    std::vector<std::uint8_t> taprootHashOutputs_;
    std::vector<std::vector<std::uint8_t>> taprootHashSingle_;
};

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
    std::span<const std::uint8_t> tapleafHashBytes = {}, std::uint32_t tapscriptCodeseparatorPos = 0xFFFFFFFF,
    const SighashCache* cache = nullptr);

// Legacy pre-segwit sighash; consensus byte-shape must match Shared script fixtures.
std::vector<std::uint8_t> legacySighash(const messages::Transaction& transaction, std::size_t inputIndex,
                                          std::span<const std::uint8_t> scriptCode, int sighashType = 1);

// BIP143 witness sighash; amount and scriptCode come from spent prevout runtime truth.
std::vector<std::uint8_t> bip143Sighash(const messages::Transaction& transaction, std::size_t inputIndex,
                                          std::span<const std::uint8_t> scriptCode, std::int64_t amount,
                                          int sighashType = 1, const SighashCache* cache = nullptr);

}  // namespace cpbitnode::consensus::script
