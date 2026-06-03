#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <utility>
#include <vector>

#include "cpbitnode/consensus/script/opcodes.hpp"
#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus::script {

class ScriptError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

using ScriptStack = std::vector<std::vector<std::uint8_t>>;

inline constexpr int WITNESS_V1_TAPROOT_XONLY_PK_LEN = 32;

std::vector<std::uint8_t> p2pkhScriptCode(std::span<const std::uint8_t> pubkeyHash);
std::vector<std::vector<std::uint8_t>> parsePushOnlyScriptSig(std::span<const std::uint8_t> scriptSig);

bool isP2pk(std::span<const std::uint8_t> scriptPubkey);
bool isP2pkh(std::span<const std::uint8_t> scriptPubkey);
bool isP2wpkh(std::span<const std::uint8_t> scriptPubkey);
bool isP2sh(std::span<const std::uint8_t> scriptPubkey);
bool isP2wsh(std::span<const std::uint8_t> scriptPubkey);
bool isP2tr(std::span<const std::uint8_t> scriptPubkey);
bool isBareOpN(std::span<const std::uint8_t> scriptPubkey);
bool isBareMultisig(std::span<const std::uint8_t> scriptPubkey);
bool isBareLegacyScript(std::span<const std::uint8_t> scriptPubkey);
std::optional<int> witnessProgramVersion(std::span<const std::uint8_t> scriptPubkey);

void evaluateScript(std::span<const std::uint8_t> script, ScriptStack& stack, const messages::Transaction& tx,
                    std::size_t inputIndex, std::span<const std::uint8_t> scriptCode, std::int64_t amount,
                    bool witness, int verifyFlags = SCRIPT_VERIFY_DEFAULT);

bool verifyScript(std::span<const std::uint8_t> scriptSig, std::span<const std::uint8_t> scriptPubkey,
                  const messages::Transaction& tx, std::size_t inputIndex, std::int64_t amount,
                  const std::vector<std::vector<std::uint8_t>>& witness = {},
                  const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>* spentPrevouts =
                      nullptr);

}  // namespace cpbitnode::consensus::script
