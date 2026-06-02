#include "script_helpers.hpp"

#include "cpbitnode/consensus/hash.hpp"
#include "cpbitnode/consensus/script/interpreter.hpp"
#include "cpbitnode/consensus/script/opcodes.hpp"
#include "cpbitnode/consensus/script/sighash.hpp"
#include "cpbitnode/consensus/secp256k1.hpp"

namespace cpbitnode::tests {
namespace {

std::uint8_t opN(int value) {
    if (value >= 1 && value <= 16) {
        return static_cast<std::uint8_t>(0x50 + value);
    }
    throw std::runtime_error("OP_n out of range");
}

messages::OutPoint makeOutPoint(std::span<const std::uint8_t> hash, std::uint32_t index) {
    return messages::OutPoint{std::vector<std::uint8_t>(hash.begin(), hash.end()), index};
}

}  // namespace

std::vector<std::uint8_t> pushScriptNum(int value) {
    if (value == 0) return {0x00};
    if (value >= 1 && value <= 16) {
        return {static_cast<std::uint8_t>(0x50 + value)};
    }
    std::vector<std::uint8_t> encoded;
    int v = value;
    while (v > 0) {
        encoded.push_back(static_cast<std::uint8_t>(v & 0xff));
        v >>= 8;
    }
    return pushData(encoded);
}

std::vector<std::uint8_t> pushData(std::span<const std::uint8_t> data) {
    if (data.size() < 0x4C) {
        std::vector<std::uint8_t> out = {static_cast<std::uint8_t>(data.size())};
        out.insert(out.end(), data.begin(), data.end());
        return out;
    }
    std::vector<std::uint8_t> out = {0x4C, static_cast<std::uint8_t>(data.size())};
    out.insert(out.end(), data.begin(), data.end());
    return out;
}

std::vector<std::uint8_t> p2pkhScriptPubkey(std::span<const std::uint8_t> pubkeyHash) {
    std::vector<std::uint8_t> out = {consensus::script::OP_DUP, consensus::script::OP_HASH160, 0x14};
    out.insert(out.end(), pubkeyHash.begin(), pubkeyHash.end());
    out.push_back(consensus::script::OP_EQUALVERIFY);
    out.push_back(consensus::script::OP_CHECKSIG);
    return out;
}

std::vector<std::uint8_t> p2shScriptPubkey(std::span<const std::uint8_t> scriptHash160) {
    std::vector<std::uint8_t> out = {consensus::script::OP_HASH160, 0x14};
    out.insert(out.end(), scriptHash160.begin(), scriptHash160.end());
    out.push_back(consensus::script::OP_EQUAL);
    return out;
}

std::vector<std::uint8_t> p2pkScriptPubkey(std::span<const std::uint8_t> pubkey) {
    auto out = pushData(pubkey);
    out.push_back(consensus::script::OP_CHECKSIG);
    return out;
}

std::vector<std::uint8_t> cltvRedeemScript(int locktimeValue, std::span<const std::uint8_t> pubkey) {
    auto out = pushScriptNum(locktimeValue);
    out.push_back(consensus::script::OP_CHECKLOCKTIMEVERIFY);
    out.push_back(consensus::script::OP_DROP);
    const auto pkPush = pushData(pubkey);
    out.insert(out.end(), pkPush.begin(), pkPush.end());
    out.push_back(consensus::script::OP_CHECKSIG);
    return out;
}

std::vector<std::uint8_t> csvRedeemScript(int sequenceValue, std::span<const std::uint8_t> pubkey) {
    auto out = pushScriptNum(sequenceValue);
    out.push_back(consensus::script::OP_CHECKSEQUENCEVERIFY);
    out.push_back(consensus::script::OP_DROP);
    const auto pkPush = pushData(pubkey);
    out.insert(out.end(), pkPush.begin(), pkPush.end());
    out.push_back(consensus::script::OP_CHECKSIG);
    return out;
}

std::vector<std::uint8_t> multisigRedeemScript(int required,
                                               const std::vector<std::vector<std::uint8_t>>& pubkeys) {
    std::vector<std::uint8_t> script = {opN(required)};
    for (const auto& pubkey : pubkeys) {
        const auto pushed = pushData(pubkey);
        script.insert(script.end(), pushed.begin(), pushed.end());
    }
    script.push_back(opN(static_cast<int>(pubkeys.size())));
    script.push_back(consensus::script::OP_CHECKMULTISIG);
    return script;
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2pkhSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount,
    std::span<const std::uint8_t> pubkey, std::int64_t outputValue, std::span<const std::uint8_t> outputScriptPubkey) {
    const auto scriptPubkey = p2pkhScriptPubkey(consensus::hash160(pubkey));
    const std::vector<std::uint8_t> defaultOutput = {0x51};
    const auto& outSpk = outputScriptPubkey.empty() ? defaultOutput : outputScriptPubkey;
    messages::Transaction unsignedTx;
    unsignedTx.version = 1;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, 0xFFFFFFFF});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, std::vector<std::uint8_t>(outSpk.begin(), outSpk.end())});
    unsignedTx.lockTime = 0;
    const auto sighash = consensus::script::legacySighash(unsignedTx, 0, scriptPubkey, 1);
    const auto signature = consensus::signDer(privateKey, sighash);
    std::vector<std::uint8_t> sigWithType = signature;
    sigWithType.push_back(1);
    auto scriptSig = pushData(sigWithType);
    const auto pkPush = pushData(pubkey);
    scriptSig.insert(scriptSig.end(), pkPush.begin(), pkPush.end());
    messages::Transaction signedTx = unsignedTx;
    signedTx.inputs[0].scriptSig = std::move(scriptSig);
    return {std::move(signedTx), scriptPubkey};
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2pkSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount,
    std::span<const std::uint8_t> pubkey, std::int64_t outputValue) {
    (void)prevAmount;
    const auto scriptPubkey = p2pkScriptPubkey(pubkey);
    messages::Transaction unsignedTx;
    unsignedTx.version = 1;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, 0xFFFFFFFF});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    unsignedTx.lockTime = 0;
    const auto sighash = consensus::script::legacySighash(unsignedTx, 0, scriptPubkey, 1);
    const auto signature = consensus::signDer(privateKey, sighash);
    std::vector<std::uint8_t> sigWithType = signature;
    sigWithType.push_back(1);
    messages::Transaction signedTx = unsignedTx;
    signedTx.inputs[0].scriptSig = pushData(sigWithType);
    return {std::move(signedTx), scriptPubkey};
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2wpkhSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount,
    std::span<const std::uint8_t> pubkey, std::int64_t outputValue) {
    const auto pubkeyHash = consensus::hash160(pubkey);
    std::vector<std::uint8_t> scriptPubkey = {0x00, 0x14};
    scriptPubkey.insert(scriptPubkey.end(), pubkeyHash.begin(), pubkeyHash.end());
    const auto scriptCode = consensus::script::p2pkhScriptCode(pubkeyHash);
    messages::Transaction unsignedTx;
    unsignedTx.version = 1;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, 0xFFFFFFFF});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    unsignedTx.lockTime = 0;
    unsignedTx.witness = {{}};
    const auto sighash = consensus::script::bip143Sighash(unsignedTx, 0, scriptCode, prevAmount, 1);
    const auto signature = consensus::signDer(privateKey, sighash);
    std::vector<std::uint8_t> sigWithType = signature;
    sigWithType.push_back(1);
    messages::Transaction signedTx = unsignedTx;
    signedTx.witness = {{sigWithType, std::vector<std::uint8_t>(pubkey.begin(), pubkey.end())}};
    return {std::move(signedTx), scriptPubkey};
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2shP2pkhSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount,
    std::span<const std::uint8_t> pubkey, std::int64_t outputValue) {
    (void)prevAmount;
    const auto redeemScript = p2pkhScriptPubkey(consensus::hash160(pubkey));
    const auto scriptPubkey = p2shScriptPubkey(consensus::hash160(redeemScript));
    messages::Transaction unsignedTx;
    unsignedTx.version = 1;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, 0xFFFFFFFF});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    unsignedTx.lockTime = 0;
    const auto sighash = consensus::script::legacySighash(unsignedTx, 0, redeemScript, 1);
    const auto signature = consensus::signDer(privateKey, sighash);
    std::vector<std::uint8_t> sigWithType = signature;
    sigWithType.push_back(1);
    auto scriptSig = pushData(sigWithType);
    const auto pkPush = pushData(pubkey);
    scriptSig.insert(scriptSig.end(), pkPush.begin(), pkPush.end());
    const auto redeemPush = pushData(redeemScript);
    scriptSig.insert(scriptSig.end(), redeemPush.begin(), redeemPush.end());
    messages::Transaction signedTx = unsignedTx;
    signedTx.inputs[0].scriptSig = std::move(scriptSig);
    return {std::move(signedTx), scriptPubkey};
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2wshP2pkhSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount,
    std::span<const std::uint8_t> pubkey, std::int64_t outputValue) {
    const auto witnessScript = p2pkhScriptPubkey(consensus::hash160(pubkey));
    std::vector<std::uint8_t> scriptPubkey = {0x00, 0x20};
    const auto program = consensus::sha256Digest(witnessScript);
    scriptPubkey.insert(scriptPubkey.end(), program.begin(), program.end());
    messages::Transaction unsignedTx;
    unsignedTx.version = 1;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, 0xFFFFFFFF});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    unsignedTx.lockTime = 0;
    unsignedTx.witness = {{}};
    const auto sighash = consensus::script::bip143Sighash(unsignedTx, 0, witnessScript, prevAmount, 1);
    const auto signature = consensus::signDer(privateKey, sighash);
    std::vector<std::uint8_t> sigWithType = signature;
    sigWithType.push_back(1);
    messages::Transaction signedTx = unsignedTx;
    signedTx.witness = {{sigWithType, std::vector<std::uint8_t>(pubkey.begin(), pubkey.end()), witnessScript}};
    return {std::move(signedTx), scriptPubkey};
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2shMultisigSpend(
    const std::vector<std::uint64_t>& privateKeys, const std::vector<std::vector<std::uint8_t>>& pubkeys, int required,
    std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount, std::int64_t outputValue) {
    (void)prevAmount;
    const auto redeemScript = multisigRedeemScript(required, pubkeys);
    const auto scriptPubkey = p2shScriptPubkey(consensus::hash160(redeemScript));
    messages::Transaction unsignedTx;
    unsignedTx.version = 1;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, 0xFFFFFFFF});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    unsignedTx.lockTime = 0;
    std::vector<std::uint8_t> scriptSig = {0x00};
    for (std::size_t i = 0; i < privateKeys.size() && static_cast<int>(i) < required; ++i) {
        const auto sighash = consensus::script::legacySighash(unsignedTx, 0, redeemScript, 1);
        const auto signature = consensus::signDer(privateKeys[i], sighash);
        std::vector<std::uint8_t> sigWithType = signature;
        sigWithType.push_back(1);
        const auto pushed = pushData(sigWithType);
        scriptSig.insert(scriptSig.end(), pushed.begin(), pushed.end());
    }
    const auto redeemPush = pushData(redeemScript);
    scriptSig.insert(scriptSig.end(), redeemPush.begin(), redeemPush.end());
    messages::Transaction signedTx = unsignedTx;
    signedTx.inputs[0].scriptSig = std::move(scriptSig);
    return {std::move(signedTx), scriptPubkey};
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2wshMultisigSpend(
    const std::vector<std::uint64_t>& privateKeys, const std::vector<std::vector<std::uint8_t>>& pubkeys, int required,
    std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount, std::int64_t outputValue) {
    const auto witnessScript = multisigRedeemScript(required, pubkeys);
    std::vector<std::uint8_t> scriptPubkey = {0x00, 0x20};
    const auto program = consensus::sha256Digest(witnessScript);
    scriptPubkey.insert(scriptPubkey.end(), program.begin(), program.end());
    messages::Transaction unsignedTx;
    unsignedTx.version = 1;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, 0xFFFFFFFF});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    unsignedTx.lockTime = 0;
    unsignedTx.witness = {{}};
    std::vector<std::vector<std::uint8_t>> witnessItems = {{}};
    for (std::size_t i = 0; i < privateKeys.size() && static_cast<int>(i) < required; ++i) {
        const auto sighash = consensus::script::bip143Sighash(unsignedTx, 0, witnessScript, prevAmount, 1);
        const auto signature = consensus::signDer(privateKeys[i], sighash);
        std::vector<std::uint8_t> sigWithType = signature;
        sigWithType.push_back(1);
        witnessItems.push_back(std::move(sigWithType));
    }
    witnessItems.push_back(witnessScript);
    messages::Transaction signedTx = unsignedTx;
    signedTx.witness = {witnessItems};
    return {std::move(signedTx), scriptPubkey};
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2shCltvSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> pubkey, int locktimeValue, std::uint32_t txLockTime,
    std::uint32_t inputSequence, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout,
    std::int64_t prevAmount, std::int64_t outputValue) {
    (void)prevAmount;
    const auto redeemScript = cltvRedeemScript(locktimeValue, pubkey);
    const auto scriptPubkey = p2shScriptPubkey(consensus::hash160(redeemScript));
    messages::Transaction unsignedTx;
    unsignedTx.version = 2;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, inputSequence});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    unsignedTx.lockTime = txLockTime;
    const auto sighash = consensus::script::legacySighash(unsignedTx, 0, redeemScript, 1);
    const auto signature = consensus::signDer(privateKey, sighash);
    std::vector<std::uint8_t> sigWithType = signature;
    sigWithType.push_back(1);
    auto scriptSig = pushData(sigWithType);
    const auto redeemPush = pushData(redeemScript);
    scriptSig.insert(scriptSig.end(), redeemPush.begin(), redeemPush.end());
    messages::Transaction signedTx = unsignedTx;
    signedTx.inputs[0].scriptSig = std::move(scriptSig);
    return {std::move(signedTx), scriptPubkey};
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2wshCltvSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> pubkey, int locktimeValue, std::uint32_t txLockTime,
    std::uint32_t inputSequence, std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout,
    std::int64_t prevAmount, std::int64_t outputValue) {
    const auto witnessScript = cltvRedeemScript(locktimeValue, pubkey);
    std::vector<std::uint8_t> scriptPubkey = {0x00, 0x20};
    const auto program = consensus::sha256Digest(witnessScript);
    scriptPubkey.insert(scriptPubkey.end(), program.begin(), program.end());
    messages::Transaction unsignedTx;
    unsignedTx.version = 2;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, inputSequence});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    unsignedTx.lockTime = txLockTime;
    unsignedTx.witness = {{}};
    const auto sighash = consensus::script::bip143Sighash(unsignedTx, 0, witnessScript, prevAmount, 1);
    const auto signature = consensus::signDer(privateKey, sighash);
    std::vector<std::uint8_t> sigWithType = signature;
    sigWithType.push_back(1);
    messages::Transaction signedTx = unsignedTx;
    signedTx.witness = {{sigWithType, witnessScript}};
    return {std::move(signedTx), scriptPubkey};
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2shCsvSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> pubkey, int csvOperand, std::uint32_t inputSequence,
    std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount, std::int64_t outputValue) {
    (void)prevAmount;
    const auto redeemScript = csvRedeemScript(csvOperand, pubkey);
    const auto scriptPubkey = p2shScriptPubkey(consensus::hash160(redeemScript));
    messages::Transaction unsignedTx;
    unsignedTx.version = 2;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, inputSequence});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    unsignedTx.lockTime = 0;
    const auto sighash = consensus::script::legacySighash(unsignedTx, 0, redeemScript, 1);
    const auto signature = consensus::signDer(privateKey, sighash);
    std::vector<std::uint8_t> sigWithType = signature;
    sigWithType.push_back(1);
    auto scriptSig = pushData(sigWithType);
    const auto redeemPush = pushData(redeemScript);
    scriptSig.insert(scriptSig.end(), redeemPush.begin(), redeemPush.end());
    messages::Transaction signedTx = unsignedTx;
    signedTx.inputs[0].scriptSig = std::move(scriptSig);
    return {std::move(signedTx), scriptPubkey};
}

std::pair<messages::Transaction, std::vector<std::uint8_t>> makeSignedP2wshCsvSpend(
    std::uint64_t privateKey, std::span<const std::uint8_t> pubkey, int csvOperand, std::uint32_t inputSequence,
    std::span<const std::uint8_t> prevTxid, std::uint32_t prevVout, std::int64_t prevAmount, std::int64_t outputValue) {
    const auto witnessScript = csvRedeemScript(csvOperand, pubkey);
    std::vector<std::uint8_t> scriptPubkey = {0x00, 0x20};
    const auto program = consensus::sha256Digest(witnessScript);
    scriptPubkey.insert(scriptPubkey.end(), program.begin(), program.end());
    messages::Transaction unsignedTx;
    unsignedTx.version = 2;
    unsignedTx.inputs.push_back(messages::TxIn{makeOutPoint(prevTxid, prevVout), {}, inputSequence});
    unsignedTx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    unsignedTx.lockTime = 0;
    unsignedTx.witness = {{}};
    const auto sighash = consensus::script::bip143Sighash(unsignedTx, 0, witnessScript, prevAmount, 1);
    const auto signature = consensus::signDer(privateKey, sighash);
    std::vector<std::uint8_t> sigWithType = signature;
    sigWithType.push_back(1);
    messages::Transaction signedTx = unsignedTx;
    signedTx.witness = {{sigWithType, witnessScript}};
    return {std::move(signedTx), scriptPubkey};
}

}  // namespace cpbitnode::tests
