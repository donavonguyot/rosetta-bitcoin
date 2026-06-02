#include "cpbitnode/consensus/script/verify.hpp"

#include "cpbitnode/consensus/script/interpreter.hpp"

#include <string>

namespace cpbitnode::consensus::script {

void verifyTransactionInput(
    const messages::Transaction& transaction, std::size_t inputIndex, std::span<const std::uint8_t> scriptPubkey,
    std::int64_t amount,
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>* spentPrevouts) {
    if (inputIndex >= transaction.inputs.size()) {
        throw ScriptVerifyError("input index out of range");
    }

    const auto& txIn = transaction.inputs[inputIndex];
    std::vector<std::vector<std::uint8_t>> witness;
    if (!transaction.witness.empty() && inputIndex < transaction.witness.size()) {
        witness = transaction.witness[inputIndex];
    }

    const auto version = witnessProgramVersion(scriptPubkey);
    if (version && *version > 1) {
        throw ScriptVerifyError("unsupported witness program version " + std::to_string(*version));
    }

    if (!isP2pk(scriptPubkey) && !isP2pkh(scriptPubkey) && !isP2wpkh(scriptPubkey) && !isP2sh(scriptPubkey) &&
        !isP2wsh(scriptPubkey) && !isP2tr(scriptPubkey)) {
        throw ScriptVerifyError("unsupported scriptPubKey template");
    }

    if (!verifyScript(txIn.scriptSig, scriptPubkey, transaction, inputIndex, amount, witness, spentPrevouts)) {
        throw ScriptVerifyError("script verification failed for input " + std::to_string(inputIndex));
    }
}

}  // namespace cpbitnode::consensus::script
