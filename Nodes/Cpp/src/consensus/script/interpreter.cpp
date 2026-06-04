#include "cpbitnode/consensus/script/interpreter.hpp"

#include "cpbitnode/consensus/hash.hpp"
#include "cpbitnode/consensus/ripemd160.hpp"
#include "cpbitnode/consensus/secp256k1.hpp"
#include "cpbitnode/consensus/sha1.hpp"
#include "cpbitnode/consensus/sha256.hpp"
#include "cpbitnode/consensus/script/sighash.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace cpbitnode::consensus::script {
namespace {

constexpr int MAX_P2SH_REDEEM_PUSH = 520;
constexpr int MAX_CONSENSUS_SCRIPT_SIZE = 10000;
constexpr int MAX_TAPSCRIPT_STACK_ELEMENTS = 1000;
constexpr int MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS = 520;
constexpr std::uint8_t ANNEX_TAG = 0x50;
constexpr std::uint8_t TAPROOT_LEAF_VERSION_TAPSCRIPT = 0xC0;
constexpr int VALIDATION_WEIGHT_OFFSET = 50;
constexpr int VALIDATION_WEIGHT_PER_SIGOP = 50;
constexpr int MAX_PUBKEYS_PER_MULTISIG = 20;
constexpr std::uint32_t LOCKTIME_THRESHOLD = 500'000'000;
constexpr std::uint32_t SEQUENCE_FINAL = 0xFFFFFFFF;
constexpr std::uint32_t SEQUENCE_LOCKTIME_DISABLE_FLAG = 1u << 31;
constexpr std::uint32_t SEQUENCE_LOCKTIME_TYPE_FLAG = 1u << 22;
constexpr std::uint32_t SEQUENCE_LOCKTIME_MASK = 0x0000FFFF;
constexpr int MAX_SCRIPTNUM_SIZE_LOCKTIME = 5;

using Stack = std::vector<std::vector<std::uint8_t>>;

std::vector<std::uint8_t> popItem(Stack& stack) {
    if (stack.empty()) {
        throw ScriptError("stack underflow");
    }
    auto item = stack.back();
    stack.pop_back();
    return item;
}

void pushItem(Stack& stack, std::vector<std::uint8_t> item) { stack.push_back(std::move(item)); }

std::pair<std::vector<std::uint8_t>, std::size_t> readPush(std::span<const std::uint8_t> data, std::size_t offset) {
    const auto opcode = data[offset++];
    if (opcode == OP_0) {
        return {{}, offset};
    }
    if (opcode >= OP_1 && opcode <= OP_16) {
        return {std::vector<std::uint8_t>{static_cast<std::uint8_t>(opcode - OP_1 + 1)}, offset};
    }
    if (opcode == OP_1NEGATE) {
        return {std::vector<std::uint8_t>{0x81}, offset};
    }
    if (opcode >= 1 && opcode <= 75) {
        const auto end = offset + opcode;
        return {std::vector<std::uint8_t>(data.begin() + static_cast<std::ptrdiff_t>(offset),
                                          data.begin() + static_cast<std::ptrdiff_t>(end)),
                end};
    }
    if (opcode == OP_PUSHDATA1) {
        const auto size = data[offset++];
        const auto end = offset + size;
        return {std::vector<std::uint8_t>(data.begin() + static_cast<std::ptrdiff_t>(offset),
                                          data.begin() + static_cast<std::ptrdiff_t>(end)),
                end};
    }
    if (opcode == OP_PUSHDATA2) {
        std::uint16_t size = 0;
        std::memcpy(&size, data.data() + offset, 2);
        offset += 2;
        const auto end = offset + size;
        return {std::vector<std::uint8_t>(data.begin() + static_cast<std::ptrdiff_t>(offset),
                                          data.begin() + static_cast<std::ptrdiff_t>(end)),
                end};
    }
    if (opcode == OP_PUSHDATA4) {
        std::uint32_t size = 0;
        std::memcpy(&size, data.data() + offset, 4);
        offset += 4;
        const auto end = offset + size;
        return {std::vector<std::uint8_t>(data.begin() + static_cast<std::ptrdiff_t>(offset),
                                          data.begin() + static_cast<std::ptrdiff_t>(end)),
                end};
    }
    throw ScriptError("unsupported push opcode");
}

bool castToBool(const std::vector<std::uint8_t>& item) {
    for (std::size_t index = 0; index < item.size(); ++index) {
        const auto byte = item[index];
        if (byte != 0) {
            if (index == item.size() - 1 && byte == 0x80) {
                return false;
            }
            return true;
        }
    }
    return false;
}

std::vector<std::uint8_t> encodeOpN(int value) {
    if (value == 0) return {};
    if (value >= 1 && value <= 16) {
        return {static_cast<std::uint8_t>(value)};
    }
    throw ScriptError("cannot encode numeric");
}

std::int64_t decodeScriptNum(const std::vector<std::uint8_t>& item, int maxLen = 4) {
    if (static_cast<int>(item.size()) > maxLen) {
        throw ScriptError("script number overflow");
    }
    if (item.empty()) {
        return 0;
    }
    if (item.back() & 0x80) {
        std::vector<std::uint8_t> magnitude(item.begin(), item.end());
        magnitude.back() &= 0x7F;
        bool allZero = true;
        for (const auto byte : magnitude) {
            if (byte != 0) {
                allZero = false;
                break;
            }
        }
        if (allZero) {
            return 0;
        }
        std::int64_t result = 0;
        for (std::size_t i = 0; i < magnitude.size(); ++i) {
            result |= static_cast<std::int64_t>(magnitude[i]) << (8 * static_cast<int>(i));
        }
        return -result;
    }
    std::int64_t result = 0;
    for (std::size_t i = 0; i < item.size(); ++i) {
        result |= static_cast<std::int64_t>(item[i]) << (8 * static_cast<int>(i));
    }
    return result;
}

std::vector<std::uint8_t> encodeScriptNum(int value, int maxLen = 4) {
    if (value == 0) {
        return {};
    }
    bool neg = value < 0;
    int absValue = neg ? -value : value;
    std::vector<std::uint8_t> out;
    while (absValue > 0) {
        out.push_back(static_cast<std::uint8_t>(absValue & 0xff));
        absValue >>= 8;
    }
    if (out.back() & 0x80) {
        out.push_back(neg ? static_cast<std::uint8_t>(0x80) : static_cast<std::uint8_t>(0x00));
    } else if (neg) {
        out.back() |= 0x80;
    }
    if (static_cast<int>(out.size()) > maxLen) {
        throw ScriptError("script number overflow");
    }
    return out;
}

const std::vector<std::uint8_t>& stackItem(const Stack& stack, std::size_t depthFromTop) {
    if (stack.size() < depthFromTop) {
        throw ScriptError("stack underflow");
    }
    return stack[stack.size() - depthFromTop];
}

std::vector<std::uint8_t> legacyFindAndDelete(std::span<const std::uint8_t> scriptCode,
                                              std::span<const std::uint8_t> target) {
    std::vector<std::uint8_t> output;
    std::size_t offset = 0;
    while (offset < scriptCode.size()) {
        const std::size_t start = offset;
        const auto opcode = scriptCode[offset++];
        std::vector<std::uint8_t> item;
        if (opcode == OP_0) {
            item = {};
        } else if (opcode >= OP_1 && opcode <= OP_16) {
            item = {static_cast<std::uint8_t>(opcode - OP_1 + 1)};
        } else if (opcode == OP_1NEGATE) {
            item = {0x81};
        } else if ((opcode >= 1 && opcode <= 75) || opcode == OP_PUSHDATA1 || opcode == OP_PUSHDATA2 ||
                   opcode == OP_PUSHDATA4) {
            offset = start;
            try {
                std::tie(item, offset) = readPush(scriptCode, offset);
            } catch (const ScriptError&) {
                output.insert(output.end(), scriptCode.begin() + static_cast<std::ptrdiff_t>(start),
                              scriptCode.end());
                break;
            }
        } else {
            output.insert(output.end(), scriptCode.begin() + static_cast<std::ptrdiff_t>(start),
                          scriptCode.begin() + static_cast<std::ptrdiff_t>(offset));
            continue;
        }
        if (item != std::vector<std::uint8_t>(target.begin(), target.end())) {
            output.insert(output.end(), scriptCode.begin() + static_cast<std::ptrdiff_t>(start),
                          scriptCode.begin() + static_cast<std::ptrdiff_t>(offset));
        }
    }
    return output;
}

bool checkEcdsaSignature(const std::vector<std::uint8_t>& signature, const std::vector<std::uint8_t>& pubkey,
                         const messages::Transaction& tx, std::size_t inputIndex,
                         std::span<const std::uint8_t> scriptCode, std::int64_t amount, bool witness) {
    if (signature.empty()) return false;
    const auto sighashType = signature.back();
    const std::vector<std::uint8_t> sigDer(signature.begin(), signature.end() - 1);
    std::vector<std::uint8_t> digest;
    if (witness) {
        digest = bip143Sighash(tx, inputIndex, scriptCode, amount, sighashType);
    } else {
        const auto trimmed = legacyFindAndDelete(scriptCode, signature);
        digest = legacySighash(tx, inputIndex, trimmed, sighashType);
    }
    return verifyDerSignature(pubkey, digest, sigDer);
}

void execCheckmultisig(Stack& stack, std::uint8_t opcode, const messages::Transaction& tx, std::size_t inputIndex,
                       std::span<const std::uint8_t> scriptCode, std::int64_t amount, bool witness) {
    std::size_t i = 1;
    if (stack.size() < i) {
        throw ScriptError("CHECKMULTISIG stack underflow");
    }

    const int nKeysCount = decodeScriptNum(stackItem(stack, i));
    if (nKeysCount < 0 || nKeysCount > MAX_PUBKEYS_PER_MULTISIG) {
        throw ScriptError("pubkey count out of range");
    }

    const std::size_t ikey = i + 1;
    i = ikey + static_cast<std::size_t>(nKeysCount);
    if (stack.size() < i) {
        throw ScriptError("CHECKMULTISIG stack underflow");
    }

    const int nSigsCount = decodeScriptNum(stackItem(stack, i));
    if (nSigsCount < 0 || nSigsCount > nKeysCount) {
        throw ScriptError("signature count out of range");
    }

    const std::size_t isig = i + 1;
    i = isig + static_cast<std::size_t>(nSigsCount);
    if (stack.size() < i) {
        throw ScriptError("CHECKMULTISIG stack underflow");
    }

    bool success = true;
    int sigOffset = 0;
    int keyOffset = 0;
    int remainingSigs = nSigsCount;
    int remainingKeys = nKeysCount;
    std::vector<std::uint8_t> activeScriptCode(scriptCode.begin(), scriptCode.end());
    if (!witness) {
        for (int offset = 0; offset < nSigsCount; ++offset) {
            activeScriptCode =
                legacyFindAndDelete(activeScriptCode, stackItem(stack, isig + static_cast<std::size_t>(offset)));
        }
    }
    while (success && remainingSigs > 0) {
        const auto& sig = stackItem(stack, isig + static_cast<std::size_t>(sigOffset));
        const auto& pubkey = stackItem(stack, ikey + static_cast<std::size_t>(keyOffset));
        if (checkEcdsaSignature(sig, pubkey, tx, inputIndex, activeScriptCode, amount, witness)) {
            ++sigOffset;
            --remainingSigs;
        }
        ++keyOffset;
        --remainingKeys;
        if (remainingSigs > remainingKeys) {
            success = false;
        }
    }

    while (i > 1) {
        popItem(stack);
        --i;
    }

    if (stack.empty()) {
        throw ScriptError("CHECKMULTISIG missing dummy");
    }
    popItem(stack);
    if (opcode == OP_CHECKMULTISIG) {
        pushItem(stack, encodeOpN(success ? 1 : 0));
    } else if (!success) {
        throw ScriptError("CHECKMULTISIGVERIFY failed");
    }
}

bool txIsFinalForCltv(const messages::Transaction& tx) {
    if (tx.lockTime == 0) return true;
    for (const auto& txIn : tx.inputs) {
        if (txIn.sequence != SEQUENCE_FINAL) return false;
    }
    return true;
}

void execChecklocktimeverify(Stack& stack, const messages::Transaction& tx) {
    if (stack.empty()) {
        throw ScriptError("CHECKLOCKTIMEVERIFY stack empty");
    }
    if (tx.version < 2) {
        return;
    }
    if (txIsFinalForCltv(tx)) {
        throw ScriptError("CHECKLOCKTIMEVERIFY on final tx");
    }
    const auto locktimeValue = decodeScriptNum(stack.back(), MAX_SCRIPTNUM_SIZE_LOCKTIME);
    if (locktimeValue < 0) {
        throw ScriptError("CHECKLOCKTIMEVERIFY negative locktime");
    }
    const auto nLockTime = tx.lockTime;
    if ((nLockTime < LOCKTIME_THRESHOLD) != (static_cast<std::uint32_t>(locktimeValue) < LOCKTIME_THRESHOLD)) {
        throw ScriptError("CHECKLOCKTIMEVERIFY locktime type mismatch");
    }
    if (static_cast<std::uint32_t>(locktimeValue) > nLockTime) {
        throw ScriptError("CHECKLOCKTIMEVERIFY unsatisfied locktime");
    }
}

void execChecksequenceverify(Stack& stack, const messages::Transaction& tx, std::size_t inputIndex) {
    if (stack.empty()) {
        throw ScriptError("CHECKSEQUENCEVERIFY stack empty");
    }
    if (tx.version < 2) {
        return;
    }
    const auto seqValue = decodeScriptNum(stack.back(), MAX_SCRIPTNUM_SIZE_LOCKTIME);
    if ((static_cast<std::uint32_t>(seqValue) & SEQUENCE_LOCKTIME_DISABLE_FLAG) != 0) {
        return;
    }
    if (seqValue < 0) {
        throw ScriptError("CHECKSEQUENCEVERIFY negative locktime");
    }
    const auto nSequence = tx.inputs[inputIndex].sequence;
    if (nSequence == SEQUENCE_FINAL) {
        throw ScriptError("CHECKSEQUENCEVERIFY on final sequence");
    }
    if (nSequence & SEQUENCE_LOCKTIME_DISABLE_FLAG) {
        throw ScriptError("CHECKSEQUENCEVERIFY disabled sequence");
    }
    const bool stackType = (static_cast<std::uint32_t>(seqValue) & SEQUENCE_LOCKTIME_TYPE_FLAG) != 0;
    const bool seqType = (nSequence & SEQUENCE_LOCKTIME_TYPE_FLAG) != 0;
    if (stackType != seqType) {
        throw ScriptError("CHECKSEQUENCEVERIFY locktime type mismatch");
    }
    if ((static_cast<std::uint32_t>(seqValue) & SEQUENCE_LOCKTIME_MASK) > (nSequence & SEQUENCE_LOCKTIME_MASK)) {
        throw ScriptError("CHECKSEQUENCEVERIFY unsatisfied locktime");
    }
}

bool legacyFExec(const std::vector<bool>& vfExec) {
    for (const bool flag : vfExec) {
        if (!flag) {
            return false;
        }
    }
    return true;
}

std::size_t tapscriptAdvanceOpcode(std::span<const std::uint8_t> script, std::size_t offset) {
    const auto opcode = script[offset];
    if (opcode == OP_0 || (opcode >= OP_1 && opcode <= OP_16) || opcode == OP_1NEGATE) {
        return offset + 1;
    }
    if (opcode >= 1 && opcode <= 75) {
        return offset + 1 + opcode;
    }
    if (opcode == OP_PUSHDATA1 || opcode == OP_PUSHDATA2 || opcode == OP_PUSHDATA4) {
        const auto [ignored, next] = readPush(script, offset);
        (void)ignored;
        return next;
    }
    return offset + 1;
}

void evaluateScriptImpl(std::span<const std::uint8_t> script, Stack& stack, const messages::Transaction& tx,
                        std::size_t inputIndex, std::span<const std::uint8_t> scriptCode, std::int64_t amount,
                        bool witness, int verifyFlags = SCRIPT_VERIFY_DEFAULT) {
    std::size_t offset = 0;
    std::size_t codeseparatorOffset = 0;
    std::vector<bool> vfExec;
    Stack altstack;
    while (offset < script.size()) {
        const auto opcode = script[offset];
        const bool fExec = legacyFExec(vfExec);

        if (opcode == OP_IF || opcode == OP_NOTIF) {
            if (fExec) {
                if (stack.empty()) {
                    throw ScriptError("OP_IF stack empty");
                }
                bool branch = castToBool(popItem(stack));
                if (opcode == OP_NOTIF) {
                    branch = !branch;
                }
                vfExec.push_back(branch);
            } else {
                vfExec.push_back(false);
            }
            ++offset;
            continue;
        }
        if (opcode == OP_ELSE) {
            if (vfExec.empty()) {
                throw ScriptError("unbalanced conditional");
            }
            vfExec.back() = !vfExec.back();
            ++offset;
            continue;
        }
        if (opcode == OP_ENDIF) {
            if (vfExec.empty()) {
                throw ScriptError("unbalanced conditional");
            }
            vfExec.pop_back();
            ++offset;
            continue;
        }
        if (!fExec) {
            offset = tapscriptAdvanceOpcode(script, offset);
            continue;
        }

        ++offset;
        if (opcode == OP_0) {
            pushItem(stack, {});
        } else if (opcode >= OP_1 && opcode <= OP_16) {
            pushItem(stack, encodeOpN(opcode - OP_1 + 1));
        } else if (opcode == OP_1NEGATE) {
            pushItem(stack, {0x81});
        } else if ((opcode >= 1 && opcode <= 75) || opcode == OP_PUSHDATA1 || opcode == OP_PUSHDATA2 ||
                   opcode == OP_PUSHDATA4) {
            --offset;
            auto [item, next] = readPush(script, offset);
            offset = next;
            pushItem(stack, std::move(item));
        } else if (opcode == OP_DUP) {
            auto item = popItem(stack);
            pushItem(stack, item);
            pushItem(stack, item);
        } else if (opcode == OP_DROP) {
            popItem(stack);
        } else if (opcode == OP_2DROP) {
            popItem(stack);
            popItem(stack);
        } else if (opcode == OP_2DUP) {
            if (stack.size() < 2) throw ScriptError("stack underflow");
            stack.insert(stack.end(), stack.end() - 2, stack.end());
        } else if (opcode == OP_3DUP) {
            if (stack.size() < 3) throw ScriptError("stack underflow");
            stack.insert(stack.end(), stack.end() - 3, stack.end());
        } else if (opcode == OP_2OVER) {
            if (stack.size() < 4) throw ScriptError("stack underflow");
            stack.insert(stack.end(), stack.end() - 4, stack.end() - 2);
        } else if (opcode == OP_2SWAP) {
            if (stack.size() < 4) throw ScriptError("stack underflow");
            std::swap(stack[stack.size() - 4], stack[stack.size() - 2]);
            std::swap(stack[stack.size() - 3], stack[stack.size() - 1]);
        } else if (opcode == OP_IFDUP) {
            if (stack.empty()) throw ScriptError("stack underflow");
            if (castToBool(stack.back())) {
                pushItem(stack, stack.back());
            }
        } else if (opcode == OP_NIP) {
            if (stack.size() < 2) throw ScriptError("stack underflow");
            stack.erase(stack.end() - 2);
        } else if (opcode == OP_OVER) {
            if (stack.size() < 2) throw ScriptError("stack underflow");
            pushItem(stack, stack[stack.size() - 2]);
        } else if (opcode == OP_ROT) {
            if (stack.size() < 3) throw ScriptError("stack underflow");
            auto item = stack[stack.size() - 3];
            stack.erase(stack.end() - 3);
            pushItem(stack, item);
        } else if (opcode == OP_TUCK) {
            if (stack.size() < 2) throw ScriptError("stack underflow");
            stack.insert(stack.begin() + static_cast<std::ptrdiff_t>(stack.size()) - 2, stack.back());
        } else if (opcode == OP_TOALTSTACK) {
            altstack.push_back(popItem(stack));
        } else if (opcode == OP_FROMALTSTACK) {
            if (altstack.empty()) throw ScriptError("altstack underflow");
            pushItem(stack, altstack.back());
            altstack.pop_back();
        } else if (opcode == OP_DEPTH) {
            pushItem(stack, encodeScriptNum(static_cast<int>(stack.size())));
        } else if (opcode == OP_PICK) {
            const int n = decodeScriptNum(popItem(stack));
            if (n < 0 || static_cast<std::size_t>(n) >= stack.size()) throw ScriptError("stack underflow");
            pushItem(stack, stack[stack.size() - static_cast<std::size_t>(n) - 1]);
        } else if (opcode == OP_ROLL) {
            const int n = decodeScriptNum(popItem(stack));
            if (n < 0 || static_cast<std::size_t>(n) >= stack.size()) throw ScriptError("stack underflow");
            auto item = stack[stack.size() - static_cast<std::size_t>(n) - 1];
            stack.erase(stack.end() - static_cast<std::size_t>(n) - 1);
            pushItem(stack, item);
        } else if (opcode == OP_SIZE) {
            if (stack.empty()) throw ScriptError("stack underflow");
            pushItem(stack, encodeScriptNum(static_cast<int>(stack.back().size())));
        } else if (opcode == OP_SWAP) {
            auto top = popItem(stack);
            auto second = popItem(stack);
            pushItem(stack, std::move(top));
            pushItem(stack, std::move(second));
        } else if (opcode == OP_ABS) {
            pushItem(stack, encodeScriptNum(std::abs(decodeScriptNum(popItem(stack))), 5));
        } else if (opcode == OP_NOT) {
            pushItem(stack, encodeOpN(decodeScriptNum(popItem(stack)) == 0 ? 1 : 0));
        } else if (opcode == OP_0NOTEQUAL) {
            pushItem(stack, encodeOpN(decodeScriptNum(popItem(stack)) != 0 ? 1 : 0));
        } else if (opcode == OP_ADD) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            pushItem(stack, encodeScriptNum(aVal + bVal, 5));
        } else if (opcode == OP_SUB) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            pushItem(stack, encodeScriptNum(aVal - bVal));
        } else if (opcode == OP_LESSTHAN || opcode == OP_GREATERTHAN || opcode == OP_LESSTHANOREQUAL ||
                   opcode == OP_GREATERTHANOREQUAL) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            bool result = false;
            if (opcode == OP_LESSTHAN) result = aVal < bVal;
            else if (opcode == OP_GREATERTHAN) result = aVal > bVal;
            else if (opcode == OP_LESSTHANOREQUAL) result = aVal <= bVal;
            else result = aVal >= bVal;
            pushItem(stack, encodeOpN(result ? 1 : 0));
        } else if (opcode == OP_BOOLAND) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            pushItem(stack, encodeOpN((aVal != 0 && bVal != 0) ? 1 : 0));
        } else if (opcode == OP_BOOLOR) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            pushItem(stack, encodeOpN((aVal != 0 || bVal != 0) ? 1 : 0));
        } else if (opcode == OP_MIN) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            pushItem(stack, encodeScriptNum(std::min(aVal, bVal), 5));
        } else if (opcode == OP_MAX) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            pushItem(stack, encodeScriptNum(std::max(aVal, bVal), 5));
        } else if (opcode == OP_WITHIN) {
            const int maxVal = decodeScriptNum(popItem(stack));
            const int minVal = decodeScriptNum(popItem(stack));
            const int xVal = decodeScriptNum(popItem(stack));
            pushItem(stack, encodeOpN((minVal <= xVal && xVal < maxVal) ? 1 : 0));
        } else if (opcode == OP_RIPEMD160) {
            pushItem(stack, ripemd160Digest(popItem(stack)));
        } else if (opcode == OP_SHA1) {
            pushItem(stack, sha1Digest(popItem(stack)));
        } else if (opcode == OP_SHA256) {
            pushItem(stack, sha256Digest(popItem(stack)));
        } else if (opcode == OP_HASH256) {
            pushItem(stack, doubleSha256(popItem(stack)));
        } else if (opcode == OP_HASH160) {
            pushItem(stack, hash160(popItem(stack)));
        } else if (opcode == OP_EQUAL) {
            auto bVal = popItem(stack);
            auto aVal = popItem(stack);
            pushItem(stack, encodeOpN(aVal == bVal ? 1 : 0));
        } else if (opcode == OP_EQUALVERIFY) {
            auto bVal = popItem(stack);
            auto aVal = popItem(stack);
            if (aVal != bVal) {
                throw ScriptError("EQUALVERIFY failed");
            }
        } else if (opcode == OP_VERIFY) {
            if (!castToBool(popItem(stack))) {
                throw ScriptError("VERIFY failed");
            }
        } else if (opcode == 0x61) {
            // OP_NOP
        } else if (opcode == OP_CODESEPARATOR) {
            codeseparatorOffset = offset;
        } else if (opcode == OP_CHECKSIG || opcode == OP_CHECKSIGVERIFY) {
            auto pubkey = popItem(stack);
            auto signature = popItem(stack);
            const auto activeScript = scriptCode.subspan(codeseparatorOffset);
            const bool valid =
                checkEcdsaSignature(signature, pubkey, tx, inputIndex, activeScript, amount, witness);
            if (opcode == OP_CHECKSIG) {
                pushItem(stack, encodeOpN(valid ? 1 : 0));
            } else if (!valid) {
                throw ScriptError("CHECKSIGVERIFY failed");
            }
        } else if (opcode == OP_CHECKMULTISIG || opcode == OP_CHECKMULTISIGVERIFY) {
            const auto activeScript = scriptCode.subspan(codeseparatorOffset);
            execCheckmultisig(stack, opcode, tx, inputIndex, activeScript, amount, witness);
        } else if (opcode == OP_CHECKLOCKTIMEVERIFY) {
            if (verifyFlags & SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY) {
                execChecklocktimeverify(stack, tx);
            }
        } else if (opcode == OP_CHECKSEQUENCEVERIFY) {
            if (verifyFlags & SCRIPT_VERIFY_CHECKSEQUENCEVERIFY) {
                execChecksequenceverify(stack, tx, inputIndex);
            }
        } else {
            throw ScriptError("unsupported opcode");
        }
    }
}

bool tapscriptOpcodeIsSuccess(std::uint8_t opcode) {
    if (opcode == 80 || opcode == 98) return true;
    if (opcode >= 126 && opcode <= 129) return true;
    if (opcode >= 131 && opcode <= 134) return true;
    if (opcode >= 137 && opcode <= 138) return true;
    if (opcode >= 141 && opcode <= 142) return true;
    if (opcode >= 149 && opcode <= 153) return true;
    if (opcode >= 187 && opcode <= 254) return true;
    return false;
}

bool tapscriptPrescanOpSuccess(std::span<const std::uint8_t> script) {
    std::size_t pc = 0;
    while (pc < script.size()) {
        const auto opcode = script[pc];
        if (opcode == OP_0) {
            ++pc;
            continue;
        }
        if ((opcode >= OP_1 && opcode <= OP_16) || opcode == OP_1NEGATE) {
            ++pc;
            continue;
        }
        if (opcode >= 1 && opcode <= 75) {
            pc += 1 + opcode;
            continue;
        }
        if (opcode == OP_PUSHDATA1 || opcode == OP_PUSHDATA2 || opcode == OP_PUSHDATA4) {
            try {
                std::tie(std::ignore, pc) = readPush(script, pc);
            } catch (const ScriptError&) {
                return false;
            }
            continue;
        }
        if (tapscriptOpcodeIsSuccess(opcode)) return true;
        ++pc;
    }
    return false;
}

void evaluateTapscript(std::span<const std::uint8_t> script, Stack& stack, const messages::Transaction& tx,
                       std::size_t inputIndex, std::span<const std::uint8_t, 32> tapleafDigest,
                       const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>& spentPrevouts,
                       const std::vector<std::uint8_t>* annex, int& validationBudgetLeft) {
    if (tapscriptPrescanOpSuccess(script)) return;

    std::uint32_t codeseparatorPos = 0xFFFFFFFF;
    std::uint32_t instructionPos = 0;
    std::size_t offset = 0;
    std::vector<bool> vfExec;
    Stack altstack;
    while (offset < script.size()) {
        const auto instrAt = instructionPos;
        const auto opcode = script[offset];
        const bool fExec = legacyFExec(vfExec);

        if (opcode == OP_IF || opcode == OP_NOTIF) {
            if (fExec) {
                if (stack.empty()) {
                    throw ScriptError("OP_IF stack empty");
                }
                bool branch = castToBool(popItem(stack));
                if (opcode == OP_NOTIF) {
                    branch = !branch;
                }
                vfExec.push_back(branch);
            } else {
                vfExec.push_back(false);
            }
            ++offset;
            ++instructionPos;
            continue;
        }
        if (opcode == OP_ELSE) {
            if (vfExec.empty()) {
                throw ScriptError("unbalanced conditional");
            }
            vfExec.back() = !vfExec.back();
            ++offset;
            ++instructionPos;
            continue;
        }
        if (opcode == OP_ENDIF) {
            if (vfExec.empty()) {
                throw ScriptError("unbalanced conditional");
            }
            vfExec.pop_back();
            ++offset;
            ++instructionPos;
            continue;
        }
        if (!fExec) {
            offset = tapscriptAdvanceOpcode(script, offset);
            ++instructionPos;
            continue;
        }

        if (opcode == OP_0) {
            pushItem(stack, {});
            ++offset;
            ++instructionPos;
        } else if (opcode >= OP_1 && opcode <= OP_16) {
            pushItem(stack, encodeOpN(opcode - OP_1 + 1));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_1NEGATE) {
            pushItem(stack, {0x81});
            ++offset;
            ++instructionPos;
        } else if ((opcode >= 1 && opcode <= 75) || opcode == OP_PUSHDATA1 || opcode == OP_PUSHDATA2 ||
                   opcode == OP_PUSHDATA4) {
            auto [item, next] = readPush(script, offset);
            offset = next;
            pushItem(stack, std::move(item));
            ++instructionPos;
        } else if (opcode == OP_DROP) {
            popItem(stack);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_SWAP) {
            auto a = popItem(stack);
            auto b = popItem(stack);
            pushItem(stack, std::move(a));
            pushItem(stack, std::move(b));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_DUP) {
            auto item = popItem(stack);
            pushItem(stack, item);
            pushItem(stack, item);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_HASH160) {
            pushItem(stack, hash160(popItem(stack)));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_EQUAL) {
            auto bVal = popItem(stack);
            auto aVal = popItem(stack);
            pushItem(stack, encodeOpN(aVal == bVal ? 1 : 0));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_EQUALVERIFY) {
            auto bVal = popItem(stack);
            auto aVal = popItem(stack);
            if (aVal != bVal) {
                throw ScriptError("EQUALVERIFY failed");
            }
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_VERIFY) {
            if (!castToBool(popItem(stack))) {
                throw ScriptError("VERIFY failed");
            }
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_CODESEPARATOR) {
            codeseparatorPos = instrAt;
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_CHECKMULTISIG || opcode == OP_CHECKMULTISIGVERIFY) {
            throw ScriptError("CHECKMULTISIG disabled in tapscript");
        } else if (opcode == 0x61) {
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_CHECKSIG || opcode == OP_CHECKSIGVERIFY) {
            auto pubkey = popItem(stack);
            auto signature = popItem(stack);
            if (pubkey.empty()) {
                throw ScriptError("empty pubkey in tapscript checksig");
            }

            auto consumeSigopIfNonempty = [&]() {
                if (!signature.empty()) {
                    validationBudgetLeft -= VALIDATION_WEIGHT_PER_SIGOP;
                    if (validationBudgetLeft < 0) {
                        throw ScriptError("tapscript validation weight exceeded");
                    }
                }
            };

            if (pubkey.size() != 32) {
                if (signature.empty()) {
                    if (opcode == OP_CHECKSIGVERIFY) {
                        throw ScriptError("CHECKSIGVERIFY failed");
                    }
                    pushItem(stack, {});
                } else {
                    consumeSigopIfNonempty();
                    if (opcode == OP_CHECKSIG) {
                        pushItem(stack, {1});
                    }
                }
                ++offset;
                ++instructionPos;
                continue;
            }

            bool valid = false;
            if (!signature.empty()) {
                consumeSigopIfNonempty();
                int hashType = TAPROOT_SIGHASH_DEFAULT;
                std::span<const std::uint8_t> sig64 = signature;
                std::vector<std::uint8_t> sig64Storage;
                if (signature.size() == 65) {
                    hashType = signature[64];
                    if (hashType == TAPROOT_SIGHASH_DEFAULT) {
                        throw ScriptError("invalid tap hashtype byte");
                    }
                    sig64Storage.assign(signature.begin(), signature.begin() + 64);
                    sig64 = sig64Storage;
                } else if (signature.size() != 64) {
                    throw ScriptError("invalid Schnorr signature length");
                }
                try {
                    const auto digest = taprootSignatureHash(tx, inputIndex, spentPrevouts, hashType, annex, 1,
                                                             tapleafDigest, codeseparatorPos);
                    valid = verifySchnorrSignature(
                        std::span<const std::uint8_t, 32>(pubkey.data(), 32),
                        std::span<const std::uint8_t, 32>(digest.data(), 32),
                        std::span<const std::uint8_t, 64>(sig64.data(), 64));
                } catch (const std::runtime_error& exc) {
                    throw ScriptError(exc.what());
                }
            }

            if (opcode == OP_CHECKSIG) {
                pushItem(stack, encodeOpN(valid ? 1 : 0));
            } else if (!valid) {
                throw ScriptError("CHECKSIGVERIFY failed");
            }
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_CHECKLOCKTIMEVERIFY) {
            execChecklocktimeverify(stack, tx);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_CHECKSEQUENCEVERIFY) {
            execChecksequenceverify(stack, tx, inputIndex);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_SHA256) {
            pushItem(stack, sha256Digest(popItem(stack)));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_HASH256) {
            pushItem(stack, doubleSha256(popItem(stack)));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_SHA1) {
            pushItem(stack, sha1Digest(popItem(stack)));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_RIPEMD160) {
            pushItem(stack, ripemd160Digest(popItem(stack)));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_2DROP) {
            popItem(stack);
            popItem(stack);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_NIP) {
            if (stack.size() < 2) throw ScriptError("stack underflow");
            stack.erase(stack.end() - 2);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_2DUP) {
            if (stack.size() < 2) throw ScriptError("stack underflow");
            stack.insert(stack.end(), stack.end() - 2, stack.end());
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_3DUP) {
            if (stack.size() < 3) throw ScriptError("stack underflow");
            stack.insert(stack.end(), stack.end() - 3, stack.end());
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_2OVER) {
            if (stack.size() < 4) throw ScriptError("stack underflow");
            stack.insert(stack.end(), stack.end() - 4, stack.end() - 2);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_2SWAP) {
            if (stack.size() < 4) throw ScriptError("stack underflow");
            std::swap(stack[stack.size() - 4], stack[stack.size() - 2]);
            std::swap(stack[stack.size() - 3], stack[stack.size() - 1]);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_TOALTSTACK) {
            altstack.push_back(popItem(stack));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_FROMALTSTACK) {
            if (altstack.empty()) {
                throw ScriptError("altstack underflow");
            }
            pushItem(stack, altstack.back());
            altstack.pop_back();
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_TUCK) {
            if (stack.size() < 2) throw ScriptError("stack underflow");
            auto top = popItem(stack);
            auto second = popItem(stack);
            pushItem(stack, top);
            pushItem(stack, std::move(second));
            pushItem(stack, std::move(top));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_DEPTH) {
            pushItem(stack, encodeScriptNum(static_cast<int>(stack.size())));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_PICK) {
            const int n = static_cast<int>(decodeScriptNum(popItem(stack)));
            if (n < 0 || static_cast<std::size_t>(n) >= stack.size()) throw ScriptError("stack underflow");
            pushItem(stack, stack[stack.size() - static_cast<std::size_t>(n) - 1]);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_ROLL) {
            const int n = decodeScriptNum(popItem(stack));
            if (n < 0 || static_cast<std::size_t>(n) >= stack.size()) throw ScriptError("stack underflow");
            auto item = stack[stack.size() - static_cast<std::size_t>(n) - 1];
            stack.erase(stack.end() - static_cast<std::size_t>(n) - 1);
            pushItem(stack, item);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_ROT) {
            if (stack.size() < 3) throw ScriptError("stack underflow");
            auto item = stack[stack.size() - 3];
            stack.erase(stack.end() - 3);
            pushItem(stack, item);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_OVER) {
            if (stack.size() < 2) throw ScriptError("stack underflow");
            pushItem(stack, stack[stack.size() - 2]);
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_IFDUP) {
            if (stack.empty()) throw ScriptError("stack underflow");
            if (castToBool(stack.back())) {
                pushItem(stack, stack.back());
            }
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_SIZE) {
            if (stack.empty()) throw ScriptError("stack underflow");
            pushItem(stack, encodeScriptNum(static_cast<int>(stack.back().size())));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_ADD || opcode == OP_SUB) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            pushItem(stack, encodeScriptNum(opcode == OP_ADD ? aVal + bVal : aVal - bVal));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_NEGATE) {
            pushItem(stack, encodeScriptNum(-decodeScriptNum(popItem(stack))));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_1SUB) {
            pushItem(stack, encodeScriptNum(decodeScriptNum(popItem(stack)) - 1));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_NOT) {
            pushItem(stack, encodeOpN(castToBool(popItem(stack)) ? 0 : 1));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_0NOTEQUAL) {
            pushItem(stack, encodeOpN(castToBool(popItem(stack)) ? 1 : 0));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_BOOLAND || opcode == OP_BOOLOR) {
            const bool bVal = castToBool(popItem(stack));
            const bool aVal = castToBool(popItem(stack));
            pushItem(stack, encodeOpN((opcode == OP_BOOLAND ? (aVal && bVal) : (aVal || bVal)) ? 1 : 0));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_MIN || opcode == OP_MAX) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            pushItem(stack, encodeScriptNum(opcode == OP_MIN ? std::min(aVal, bVal) : std::max(aVal, bVal), 5));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_WITHIN) {
            const int maxVal = decodeScriptNum(popItem(stack));
            const int minVal = decodeScriptNum(popItem(stack));
            const int xVal = decodeScriptNum(popItem(stack));
            pushItem(stack, encodeOpN((minVal <= xVal && xVal < maxVal) ? 1 : 0));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_NUMEQUAL || opcode == OP_NUMNOTEQUAL) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            const bool result = opcode == OP_NUMEQUAL ? aVal == bVal : aVal != bVal;
            pushItem(stack, encodeOpN(result ? 1 : 0));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_NUMEQUALVERIFY) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            if (aVal != bVal) {
                throw ScriptError("NUMEQUALVERIFY failed");
            }
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_LESSTHAN || opcode == OP_GREATERTHAN || opcode == OP_LESSTHANOREQUAL ||
                   opcode == OP_GREATERTHANOREQUAL) {
            const int bVal = decodeScriptNum(popItem(stack));
            const int aVal = decodeScriptNum(popItem(stack));
            bool result = false;
            if (opcode == OP_LESSTHAN) result = aVal < bVal;
            else if (opcode == OP_GREATERTHAN) result = aVal > bVal;
            else if (opcode == OP_LESSTHANOREQUAL) result = aVal <= bVal;
            else result = aVal >= bVal;
            pushItem(stack, encodeOpN(result ? 1 : 0));
            ++offset;
            ++instructionPos;
        } else if (opcode == OP_CHECKSIGADD) {
            auto pubkey = popItem(stack);
            auto nItem = popItem(stack);
            auto signature = popItem(stack);
            if (pubkey.empty()) {
                throw ScriptError("empty pubkey in tapscript checksigadd");
            }
            int n = decodeScriptNum(nItem);
            auto consumeSigop = [&]() {
                if (!signature.empty()) {
                    validationBudgetLeft -= VALIDATION_WEIGHT_PER_SIGOP;
                    if (validationBudgetLeft < 0) {
                        throw ScriptError("tapscript validation weight exceeded");
                    }
                }
            };
            if (pubkey.size() != 32) {
                if (!signature.empty()) {
                    consumeSigop();
                    pushItem(stack, encodeScriptNum(n + 1));
                } else {
                    pushItem(stack, encodeScriptNum(n));
                }
                ++offset;
                ++instructionPos;
                continue;
            }
            if (signature.empty()) {
                pushItem(stack, encodeScriptNum(n));
            } else {
                consumeSigop();
                bool valid = false;
                int hashType = TAPROOT_SIGHASH_DEFAULT;
                std::span<const std::uint8_t> sig64 = signature;
                std::vector<std::uint8_t> sig64Storage;
                if (signature.size() == 65) {
                    hashType = signature[64];
                    if (hashType == TAPROOT_SIGHASH_DEFAULT) {
                        throw ScriptError("invalid tap hashtype byte");
                    }
                    sig64Storage.assign(signature.begin(), signature.begin() + 64);
                    sig64 = sig64Storage;
                } else if (signature.size() != 64) {
                    throw ScriptError("invalid Schnorr signature length");
                }
                const auto digest = taprootSignatureHash(tx, inputIndex, spentPrevouts, hashType, annex, 1,
                                                         tapleafDigest, codeseparatorPos);
                valid = verifySchnorrSignature(std::span<const std::uint8_t, 32>(pubkey.data(), 32),
                                               std::span<const std::uint8_t, 32>(digest.data(), 32),
                                               std::span<const std::uint8_t, 64>(sig64.data(), 64));
                pushItem(stack, encodeScriptNum(n + (valid ? 1 : 0)));
            }
            ++offset;
            ++instructionPos;
        } else {
            throw ScriptError("unsupported tapscript opcode");
        }
    }
}

bool terminalSuccessStrict(const Stack& stack) {
    return stack.size() == 1 && castToBool(stack[0]);
}

bool terminalSuccessRelaxed(const Stack& stack) { return !stack.empty() && castToBool(stack.back()); }

bool verifyP2trScriptPath(std::span<const std::uint8_t> scriptPubkey,
                            const std::vector<std::vector<std::uint8_t>>& witnessItemsWithoutAnnex,
                            const std::vector<std::uint8_t>* annex, const messages::Transaction& tx,
                            std::size_t inputIndex,
                            const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>& spentPrevouts,
                            std::span<const std::uint8_t> serializedWitnessForWeight) {
    if (spentPrevouts.size() != tx.inputs.size()) return false;
    if (witnessItemsWithoutAnnex.size() < 2) return false;

    const auto& scriptBytes = witnessItemsWithoutAnnex[witnessItemsWithoutAnnex.size() - 2];
    const auto& control = witnessItemsWithoutAnnex.back();
    std::vector<std::vector<std::uint8_t>> stackItems(witnessItemsWithoutAnnex.begin(),
                                                      witnessItemsWithoutAnnex.end() - 2);

    // BIP342: the legacy 10_000-byte script size cap does not apply to tapscript leaves.
    if (scriptBytes.empty()) return false;
    const auto ctlLen = control.size();
    if (ctlLen < 33 || ctlLen > 33 + 128 * 32 || (ctlLen - 33) % 32 != 0) return false;

    const auto leafMasked = static_cast<std::uint8_t>(control[0] & 0xFE);
    if (leafMasked == ANNEX_TAG) return false;

    std::array<std::uint8_t, 32> internalX{};
    std::memcpy(internalX.data(), control.data() + 1, 32);

    std::vector<std::vector<std::uint8_t>> merkleBranch;
    for (std::size_t i = 33; i < ctlLen; i += 32) {
        merkleBranch.emplace_back(control.begin() + static_cast<std::ptrdiff_t>(i),
                                  control.begin() + static_cast<std::ptrdiff_t>(i + 32));
    }

    try {
        const auto leafDigestVec = tapleafHash(leafMasked, scriptBytes);
        std::array<std::uint8_t, 32> leafDigest{};
        std::memcpy(leafDigest.data(), leafDigestVec.data(), 32);
        const auto merkleRoot = taprootMerkleRootFromBranch(merkleBranch, leafDigest);
        const auto [parityOut, outX] =
            taprootTweakPubkeyXonly(internalX, merkleRoot);

        if (std::memcmp(outX.data(), scriptPubkey.data() + 2, 32) != 0 ||
            control[0] != static_cast<std::uint8_t>(leafMasked | parityOut)) {
            return false;
        }

        if (leafMasked != TAPROOT_LEAF_VERSION_TAPSCRIPT) return true;
        if (tapscriptPrescanOpSuccess(scriptBytes)) return true;
        if (stackItems.size() > MAX_TAPSCRIPT_STACK_ELEMENTS) return false;
        for (const auto& elem : stackItems) {
            if (static_cast<int>(elem.size()) > MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS) return false;
        }

        int budget = VALIDATION_WEIGHT_OFFSET + static_cast<int>(serializedWitnessForWeight.size());
        Stack execStack = stackItems;
        evaluateTapscript(scriptBytes, execStack, tx, inputIndex, leafDigest, spentPrevouts, annex, budget);
        if (!terminalSuccessStrict(execStack)) {
            throw ScriptError("tapscript failed final stack check");
        }
        return true;
    } catch (const ScriptError&) {
        throw;
    } catch (const Secp256k1Error&) {
        return false;
    }
}

}  // namespace

void evaluateScript(std::span<const std::uint8_t> script, ScriptStack& stack, const messages::Transaction& tx,
                    std::size_t inputIndex, std::span<const std::uint8_t> scriptCode, std::int64_t amount,
                    bool witness, int verifyFlags) {
    Stack internalStack = stack;
    evaluateScriptImpl(script, internalStack, tx, inputIndex, scriptCode, amount, witness, verifyFlags);
    stack = std::move(internalStack);
}

std::vector<std::uint8_t> p2pkhScriptCode(std::span<const std::uint8_t> pubkeyHash) {
    std::vector<std::uint8_t> out = {OP_DUP, OP_HASH160, static_cast<std::uint8_t>(pubkeyHash.size())};
    out.insert(out.end(), pubkeyHash.begin(), pubkeyHash.end());
    out.push_back(OP_EQUALVERIFY);
    out.push_back(OP_CHECKSIG);
    return out;
}

std::vector<std::vector<std::uint8_t>> parsePushOnlyScriptSig(std::span<const std::uint8_t> scriptSig) {
    std::size_t offset = 0;
    std::vector<std::vector<std::uint8_t>> pushes;
    while (offset < scriptSig.size()) {
        const auto opcode = scriptSig[offset++];
        if (opcode == OP_0) {
            pushes.emplace_back();
        } else if (opcode >= OP_1 && opcode <= OP_16) {
            pushes.push_back({static_cast<std::uint8_t>(opcode - OP_1 + 1)});
        } else if (opcode == OP_1NEGATE) {
            pushes.push_back({0x81});
        } else if ((opcode >= 1 && opcode <= 75) || opcode == OP_PUSHDATA1 || opcode == OP_PUSHDATA2 ||
                   opcode == OP_PUSHDATA4) {
            --offset;
            auto [item, next] = readPush(scriptSig, offset);
            offset = next;
            pushes.push_back(std::move(item));
        } else {
            throw ScriptError("non-push opcode in P2SH scriptSig");
        }
    }
    return pushes;
}

bool isEcdsaPubkey(std::span<const std::uint8_t> item) {
    if (item.size() == 33) {
        return item[0] == 0x02 || item[0] == 0x03;
    }
    if (item.size() == 65) {
        return item[0] == 0x04;
    }
    return false;
}

bool isBareOpN(std::span<const std::uint8_t> scriptPubkey) {
    if (scriptPubkey.empty()) {
        return false;
    }
    const auto opcode = scriptPubkey[0];
    if (!((opcode >= OP_1 && opcode <= OP_16) || opcode == OP_1NEGATE)) {
        return false;
    }
    if (scriptPubkey.size() == 1) {
        return true;
    }
    if (isP2tr(scriptPubkey) || isP2wpkh(scriptPubkey) || isP2wsh(scriptPubkey)) {
        return false;
    }
    const auto pushOpcode = scriptPubkey[1];
    if (pushOpcode == OP_0 || (pushOpcode >= OP_1 && pushOpcode <= OP_16) || pushOpcode == OP_1NEGATE) {
        return false;
    }
    try {
        const auto [item, next] = readPush(scriptPubkey, 1);
        (void)item;
        return next == scriptPubkey.size();
    } catch (const ScriptError&) {
        return false;
    }
}

bool isBareMultisig(std::span<const std::uint8_t> scriptPubkey) {
    if (scriptPubkey.size() < 4) {
        return false;
    }
    std::size_t offset = 0;
    const auto mOpcode = scriptPubkey[offset++];
    if (mOpcode < OP_1 || mOpcode > OP_16) {
        return false;
    }
    const int required = mOpcode - OP_1 + 1;
    std::vector<std::vector<std::uint8_t>> pubkeys;
    try {
        while (offset < scriptPubkey.size()) {
            const auto opcode = scriptPubkey[offset];
            if (opcode >= OP_1 && opcode <= OP_16) {
                break;
            }
            auto [item, next] = readPush(scriptPubkey, offset);
            offset = next;
            if (!isEcdsaPubkey(item)) {
                return false;
            }
            pubkeys.push_back(std::move(item));
            if (static_cast<int>(pubkeys.size()) > MAX_PUBKEYS_PER_MULTISIG) {
                return false;
            }
        }
    } catch (const ScriptError&) {
        return false;
    }
    if (static_cast<int>(pubkeys.size()) < required || pubkeys.empty()) {
        return false;
    }
    if (offset >= scriptPubkey.size()) {
        return false;
    }
    const auto nOpcode = scriptPubkey[offset++];
    if (nOpcode < OP_1 || nOpcode > OP_16) {
        return false;
    }
    if (nOpcode - OP_1 + 1 != static_cast<int>(pubkeys.size())) {
        return false;
    }
    if (offset >= scriptPubkey.size() || scriptPubkey[offset] != OP_CHECKMULTISIG) {
        return false;
    }
    ++offset;
    return offset == scriptPubkey.size();
}

bool isP2pk(std::span<const std::uint8_t> scriptPubkey) {
    if (scriptPubkey.size() == 35) {
        return scriptPubkey[0] == 33 && scriptPubkey.back() == OP_CHECKSIG;
    }
    if (scriptPubkey.size() == 67) {
        return scriptPubkey[0] == 65 && scriptPubkey.back() == OP_CHECKSIG;
    }
    return false;
}

bool isP2pkh(std::span<const std::uint8_t> scriptPubkey) {
    return scriptPubkey.size() == 25 && scriptPubkey[0] == OP_DUP && scriptPubkey[1] == OP_HASH160 &&
           scriptPubkey[2] == 0x14 && scriptPubkey[23] == OP_EQUALVERIFY && scriptPubkey[24] == OP_CHECKSIG;
}

bool isP2wpkh(std::span<const std::uint8_t> scriptPubkey) {
    return scriptPubkey.size() == 22 && scriptPubkey[0] == 0x00 && scriptPubkey[1] == 0x14;
}

bool isP2sh(std::span<const std::uint8_t> scriptPubkey) {
    return scriptPubkey.size() == 23 && scriptPubkey[0] == OP_HASH160 && scriptPubkey[1] == 0x14 &&
           scriptPubkey[22] == OP_EQUAL;
}

bool isP2wsh(std::span<const std::uint8_t> scriptPubkey) {
    return scriptPubkey.size() == 34 && scriptPubkey[0] == 0x00 && scriptPubkey[1] == 0x20;
}

bool isP2tr(std::span<const std::uint8_t> scriptPubkey) {
    return scriptPubkey.size() == 2 + WITNESS_V1_TAPROOT_XONLY_PK_LEN && scriptPubkey[0] == OP_1 &&
           scriptPubkey[1] == WITNESS_V1_TAPROOT_XONLY_PK_LEN;
}

bool isBareLegacyScript(std::span<const std::uint8_t> scriptPubkey) {
    return !scriptPubkey.empty() && scriptPubkey.size() > MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS &&
           scriptPubkey.size() <= MAX_CONSENSUS_SCRIPT_SIZE && !witnessProgramVersion(scriptPubkey).has_value() &&
           !isP2pk(scriptPubkey) && !isP2pkh(scriptPubkey) && !isP2sh(scriptPubkey) && !isP2wpkh(scriptPubkey) &&
           !isP2wsh(scriptPubkey) && !isP2tr(scriptPubkey) && !isBareOpN(scriptPubkey) && !isBareMultisig(scriptPubkey);
}

std::optional<int> witnessProgramVersion(std::span<const std::uint8_t> scriptPubkey) {
    if (scriptPubkey.size() < 4) return std::nullopt;
    const auto versionByte = scriptPubkey[0];
    int version = -1;
    if (versionByte == OP_0) {
        version = 0;
    } else if (versionByte >= OP_1 && versionByte <= OP_16) {
        version = versionByte - OP_1 + 1;
    } else {
        return std::nullopt;
    }

    std::size_t pc = 1;
    if (pc >= scriptPubkey.size()) return std::nullopt;
    const auto opcode = scriptPubkey[pc];
    std::size_t pushLen = 0;
    std::size_t dataStart = 0;
    if (opcode >= 1 && opcode <= 75) {
        pushLen = opcode;
        dataStart = pc + 1;
    } else if (opcode == OP_PUSHDATA1) {
        if (pc + 1 >= scriptPubkey.size()) return std::nullopt;
        pushLen = scriptPubkey[pc + 1];
        dataStart = pc + 2;
    } else if (opcode == OP_PUSHDATA2) {
        if (pc + 2 >= scriptPubkey.size()) return std::nullopt;
        std::uint16_t len = 0;
        std::memcpy(&len, scriptPubkey.data() + pc + 1, 2);
        pushLen = len;
        dataStart = pc + 3;
    } else if (opcode == OP_PUSHDATA4) {
        if (pc + 4 >= scriptPubkey.size()) return std::nullopt;
        std::uint32_t len = 0;
        std::memcpy(&len, scriptPubkey.data() + pc + 1, 4);
        pushLen = len;
        dataStart = pc + 5;
    } else {
        return std::nullopt;
    }

    if (pushLen < 2 || pushLen > 40) return std::nullopt;
    if (dataStart + pushLen != scriptPubkey.size()) return std::nullopt;
    return version;
}

bool verifyScript(std::span<const std::uint8_t> scriptSig, std::span<const std::uint8_t> scriptPubkey,
                  const messages::Transaction& tx, std::size_t inputIndex, std::int64_t amount,
                  const std::vector<std::vector<std::uint8_t>>& witness,
                  const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>* spentPrevouts) {
    if (isP2pk(scriptPubkey)) {
        if (!witness.empty()) return false;
        try {
            const auto pushes = parsePushOnlyScriptSig(scriptSig);
            if (pushes.size() != 1 || pushes[0].empty()) {
                return false;
            }
        } catch (const ScriptError&) {
            return false;
        }

        Stack stackSig;
        try {
            evaluateScript(scriptSig, stackSig, tx, inputIndex, scriptPubkey, amount, false);
        } catch (const ScriptError&) {
            return false;
        }
        auto stack = stackSig;
        try {
            evaluateScript(scriptPubkey, stack, tx, inputIndex, scriptPubkey, amount, false);
        } catch (const ScriptError&) {
            return false;
        }
        return terminalSuccessStrict(stack);
    }

    if (isP2wpkh(scriptPubkey)) {
        if (!scriptSig.empty()) return false;
        if (witness.size() != 2) return false;
        const auto scriptCode = p2pkhScriptCode(std::span<const std::uint8_t>(scriptPubkey.data() + 2, 20));
        Stack stack = witness;
        try {
            evaluateScript(scriptCode, stack, tx, inputIndex, scriptCode, amount, true);
        } catch (const ScriptError&) {
            return false;
        }
        return terminalSuccessStrict(stack);
    }

    if (isP2wsh(scriptPubkey)) {
        if (!scriptSig.empty()) return false;
        if (witness.size() < 1) return false;
        const auto witnessProgram = scriptPubkey.subspan(2);
        const auto& witnessScript = witness.back();
        if (witnessScript.empty() || static_cast<int>(witnessScript.size()) > MAX_CONSENSUS_SCRIPT_SIZE) {
            return false;
        }
        if (sha256Digest(witnessScript) != std::vector<std::uint8_t>(witnessProgram.begin(), witnessProgram.end())) {
            return false;
        }
        Stack stack(witness.begin(), witness.end() - 1);
        try {
            evaluateScript(witnessScript, stack, tx, inputIndex, witnessScript, amount, true);
        } catch (const ScriptError&) {
            throw;
        }
        if (!terminalSuccessStrict(stack)) {
            throw ScriptError("P2WSH witness script failed final stack check");
        }
        return true;
    }

    if (isP2tr(scriptPubkey)) {
        if (!scriptSig.empty()) return false;
        auto wit = witness;
        const auto witSerialized = serializedWitnessStackBytes(wit);
        std::vector<std::uint8_t> annexStorage;
        const std::vector<std::uint8_t>* annex = nullptr;
        if (wit.size() >= 2 && !wit.back().empty() && wit.back()[0] == ANNEX_TAG) {
            annexStorage = wit.back();
            annex = &annexStorage;
            wit.pop_back();
        }
        if (wit.size() >= 2) {
            if (!spentPrevouts) return false;
            return verifyP2trScriptPath(scriptPubkey, wit, annex, tx, inputIndex, *spentPrevouts, witSerialized);
        }
        if (!spentPrevouts) return false;
        if (wit.size() != 1) return false;
        const auto& sigblob = wit[0];
        if (sigblob.size() != 64 && sigblob.size() != 65) return false;
        int hashType = TAPROOT_SIGHASH_DEFAULT;
        std::span<const std::uint8_t> sig64 = sigblob;
        std::vector<std::uint8_t> sig64Storage;
        if (sigblob.size() == 65) {
            hashType = sigblob[64];
            if (hashType == TAPROOT_SIGHASH_DEFAULT) return false;
            sig64Storage.assign(sigblob.begin(), sigblob.begin() + 64);
            sig64 = sig64Storage;
        }
        try {
            const auto msg = taprootSignatureHash(tx, inputIndex, *spentPrevouts, hashType, annex);
            return verifySchnorrSignature(std::span<const std::uint8_t, 32>(scriptPubkey.data() + 2, 32),
                                          std::span<const std::uint8_t, 32>(msg.data(), 32),
                                          std::span<const std::uint8_t, 64>(sig64.data(), 64));
        } catch (const std::runtime_error&) {
            return false;
        }
    }

    std::vector<std::uint8_t> redeemCandidate;
    if (isP2sh(scriptPubkey)) {
        try {
            std::size_t off = 0;
            std::vector<std::vector<std::uint8_t>> pushes;
            while (off < scriptSig.size()) {
                const auto op = scriptSig[off++];
                if (op == OP_0) {
                    pushes.emplace_back();
                } else if (op >= OP_1 && op <= OP_16) {
                    pushes.push_back({static_cast<std::uint8_t>(op - OP_1 + 1)});
                } else if (op == OP_1NEGATE) {
                    pushes.push_back({0x81});
                } else if ((op >= 1 && op <= 75) || op == OP_PUSHDATA1 || op == OP_PUSHDATA2 || op == OP_PUSHDATA4) {
                    --off;
                    auto [item, next] = readPush(scriptSig, off);
                    off = next;
                    pushes.push_back(std::move(item));
                } else {
                    throw ScriptError("non-push opcode in P2SH scriptSig");
                }
            }
            if (pushes.empty() || static_cast<int>(pushes.back().size()) > MAX_P2SH_REDEEM_PUSH) return false;
            redeemCandidate = pushes.back();
        } catch (const ScriptError&) {
            return false;
        }
    }

    Stack stackSig;
    try {
        evaluateScript(scriptSig, stackSig, tx, inputIndex, scriptPubkey, amount, false);
    } catch (const ScriptError&) {
        throw;
    }

    if (!redeemCandidate.empty() && (stackSig.empty() || stackSig.back() != redeemCandidate)) {
        return false;
    }

    auto stack = stackSig;
    try {
        evaluateScript(scriptPubkey, stack, tx, inputIndex, scriptPubkey, amount, false);
    } catch (const ScriptError&) {
        throw;
    }

    if (redeemCandidate.empty()) {
        return terminalSuccessRelaxed(stack);
    }
    if (!terminalSuccessRelaxed(stack)) return false;

    const auto expectedH160 = std::span<const std::uint8_t>(scriptPubkey.data() + 2, 20);
    if (hash160(redeemCandidate) != std::vector<std::uint8_t>(expectedH160.begin(), expectedH160.end())) {
        return false;
    }

    if (isP2wpkh(redeemCandidate)) {
        if (witness.size() != 2) return false;
        const auto scriptCode = p2pkhScriptCode(std::span<const std::uint8_t>(redeemCandidate.data() + 2, 20));
        Stack inner(witness);
        try {
            evaluateScript(scriptCode, inner, tx, inputIndex, scriptCode, amount, true);
        } catch (const ScriptError&) {
            return false;
        }
        return terminalSuccessStrict(inner);
    }

    if (isP2wsh(redeemCandidate)) {
        if (witness.size() < 1) return false;
        const std::vector<std::uint8_t> witnessProgram(redeemCandidate.begin() + 2, redeemCandidate.end());
        const auto& witnessScript = witness.back();
        if (witnessScript.empty() || static_cast<int>(witnessScript.size()) > MAX_CONSENSUS_SCRIPT_SIZE) {
            return false;
        }
        if (sha256Digest(witnessScript) != std::vector<std::uint8_t>(witnessProgram.begin(), witnessProgram.end())) {
            return false;
        }
        Stack inner(witness.begin(), witness.end() - 1);
        try {
            evaluateScript(witnessScript, inner, tx, inputIndex, witnessScript, amount, true);
        } catch (const ScriptError&) {
            return false;
        }
        return terminalSuccessStrict(inner);
    }

    Stack inner(stackSig.begin(), stackSig.end() - 1);
    try {
        evaluateScript(redeemCandidate, inner, tx, inputIndex, redeemCandidate, amount, false);
    } catch (const ScriptError&) {
        return false;
    }
    return terminalSuccessRelaxed(inner);
}

}  // namespace cpbitnode::consensus::script
