#include "test_support.hpp"

#include "script_helpers.hpp"

#include "cpbitnode/consensus/hash.hpp"
#include "cpbitnode/consensus/ripemd160.hpp"
#include "cpbitnode/consensus/secp256k1.hpp"
#include "cpbitnode/consensus/sha1.hpp"
#include "cpbitnode/consensus/sha256.hpp"
#include "cpbitnode/consensus/script/interpreter.hpp"
#include "cpbitnode/consensus/script/opcodes.hpp"
#include "cpbitnode/consensus/script/sighash.hpp"
#include "cpbitnode/consensus/script/verify.hpp"
#include "cpbitnode/messages/transaction.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <functional>
#include <sstream>
#include <stdexcept>

void registerScriptTests();

namespace {
using namespace cpbitnode;

bool expectRuntimeError(const std::function<void()>& fn) {
    try {
        fn();
        return false;
    } catch (const std::runtime_error&) {
        return true;
    }
}

std::vector<std::uint8_t> hexBytes(const char* hex) {
    std::vector<std::uint8_t> out;
    std::string s(hex);
    for (std::size_t i = 0; i + 1 < s.size(); i += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoul(s.substr(i, 2), nullptr, 16)));
    }
    return out;
}

std::vector<std::uint8_t> repeatByte(std::uint8_t b, std::size_t n) {
    return std::vector<std::uint8_t>(n, b);
}

std::vector<std::uint8_t> compressedPubkey(std::uint64_t secret) {
    const auto g = consensus::secp256k1Generator();
    const auto pt = consensus::scalarMult(secret, g);
    EXPECT_TRUE(pt.has_value());
    const auto& p = *pt;
    std::vector<std::uint8_t> out = {static_cast<std::uint8_t>(0x02 + (p.y[31] & 1))};
    out.insert(out.end(), p.x.begin(), p.x.end());
    return out;
}

#define EXPECT_NO_THROW(expr) \
    do { \
        try { \
            expr; \
        } catch (const std::exception& ex) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " threw " << ex.what() << " for " #expr "\n"; \
            ++g_failures; \
        } \
    } while (0)

#define EXPECT_THROW(expr) \
    do { \
        bool threw = false; \
        try { \
            expr; \
        } catch (const std::exception&) { \
            threw = true; \
        } \
        if (!threw) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " expected throw for " #expr "\n"; \
            ++g_failures; \
        } \
    } while (0)

#define EXPECT_THROW_MSG(expr, needle) \
    do { \
        bool threw = false; \
        try { \
            expr; \
        } catch (const std::exception& ex) { \
            threw = true; \
            const std::string msg = ex.what(); \
            if (msg.find(needle) == std::string::npos) { \
                std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " expected message containing \"" << needle \
                          << "\", got \"" << msg << "\"\n"; \
                ++g_failures; \
            } \
        } \
        if (!threw) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " expected throw for " #expr "\n"; \
            ++g_failures; \
        } \
    } while (0)

std::pair<std::uint64_t, std::array<std::uint8_t, 32>> normalizedXonlyPubkey(std::uint64_t seed) {
    const auto g = consensus::secp256k1Generator();
    for (std::uint64_t sk = seed; sk < seed + 1000; ++sk) {
        const auto pt = consensus::scalarMult(sk, g);
        if (!pt.has_value()) {
            continue;
        }
        if ((pt->y[31] & 1) == 0) {
            return {sk, pt->x};
        }
    }
    throw std::runtime_error("could not derive even-y xonly pubkey");
}

std::string bytesToHex(std::span<const std::uint8_t> data) {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.reserve(data.size() * 2);
    for (const auto byte : data) {
        out.push_back(kHex[(byte >> 4) & 0xf]);
        out.push_back(kHex[byte & 0xf]);
    }
    return out;
}

std::tuple<messages::Transaction, std::vector<std::uint8_t>,
           std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>>>
makeTapscriptCltvOrCsvSpend(std::uint64_t seed, const std::vector<std::uint8_t>& tapscript, std::uint32_t lockTime,
                            std::uint32_t sequence, std::span<const std::uint8_t> prevHash) {
    const auto [secret, pkXonly] = normalizedXonlyPubkey(seed);
    constexpr int leafVersion = 0xC0;
    const auto leafDigest = consensus::script::tapleafHash(leafVersion, tapscript);
    const auto [parity, outputX] = consensus::taprootTweakPubkeyXonly(pkXonly, leafDigest);
    std::vector<std::uint8_t> controlBlock = {static_cast<std::uint8_t>(leafVersion | (parity & 1))};
    controlBlock.insert(controlBlock.end(), pkXonly.begin(), pkXonly.end());

    std::vector<std::uint8_t> prevSpk = {consensus::script::OP_1, consensus::script::WITNESS_V1_TAPROOT_XONLY_PK_LEN};
    prevSpk.insert(prevSpk.end(), outputX.begin(), outputX.end());

    messages::Transaction unsignedTx;
    unsignedTx.version = 2;
    unsignedTx.inputs.push_back(
        messages::TxIn{messages::OutPoint{std::vector<std::uint8_t>(prevHash.begin(), prevHash.end()), 0}, {}, sequence});
    unsignedTx.outputs.push_back(messages::TxOut{99'998'999, {0x51}});
    unsignedTx.lockTime = lockTime;

    constexpr std::int64_t amount = 100'000'000;
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts = {{amount, prevSpk}};
    const auto digest = consensus::script::taprootSignatureHash(unsignedTx, 0, spentPrevouts, 0, nullptr, 1,
                                                                leafDigest, 0xFFFFFFFF);
    const auto sig = consensus::signBip340Schnorr(secret, digest);
    messages::Transaction signedTx = unsignedTx;
    signedTx.witness = {{sig, tapscript, controlBlock}};
    return {std::move(signedTx), std::move(prevSpk), spentPrevouts};
}

void testSecp256k1SignVerifyRoundtrip() {
    const auto g = consensus::secp256k1Generator();
    const auto pt = consensus::scalarMult(1, g);
    EXPECT_TRUE(pt.has_value());
    std::vector<std::uint8_t> pubkey = {static_cast<std::uint8_t>(0x02 + (pt->y[31] & 1))};
    pubkey.insert(pubkey.end(), pt->x.begin(), pt->x.end());
    const auto digest = hexBytes("abababababababababababababababababababababababababababababababab");
    const auto signature = consensus::signDer(1, digest);
    EXPECT_TRUE(consensus::verifyDerSignature(pubkey, digest, signature));
}

void testP2pkSpendRoundtrip() {
    const auto pubkey = compressedPubkey(1);
    const auto [signedTx, scriptPubkey] = tests::makeSignedP2pkSpend(
        1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(signedTx, 0, scriptPubkey, 5'000'000'000));
}

void testP2pkhSpendRoundtrip() {
    const auto pubkey = compressedPubkey(1);
    const auto [signedTx, scriptPubkey] = tests::makeSignedP2pkhSpend(
        1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(signedTx, 0, scriptPubkey, 5'000'000'000));
}

void testP2wpkhSpendRoundtrip() {
    const auto pubkey = compressedPubkey(1);
    const auto [signedTx, scriptPubkey] = tests::makeSignedP2wpkhSpend(
        1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(signedTx, 0, scriptPubkey, 5'000'000'000));
}

void testP2shSpendRoundtrip() {
    const auto pubkey = compressedPubkey(1);
    const auto [signedTx, scriptPubkey] = tests::makeSignedP2shP2pkhSpend(
        1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(signedTx, 0, scriptPubkey, 5'000'000'000));
}

void testP2wshSpendRoundtrip() {
    const auto pubkey = compressedPubkey(1);
    const auto [signedTx, scriptPubkey] = tests::makeSignedP2wshP2pkhSpend(
        1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(signedTx, 0, scriptPubkey, 5'000'000'000));
}

void testScriptTemplates() {
    const auto hash = hexBytes("5b6462475454710f3c22f5fdf0b40704c92f25c3");
    EXPECT_EQ(tests::p2pkhScriptPubkey(hash).size(), 25u);
    EXPECT_EQ(tests::p2shScriptPubkey(hash).size(), 23u);
    const auto pubkey = compressedPubkey(1);
    EXPECT_TRUE(consensus::script::isP2pk(tests::p2pkScriptPubkey(pubkey)));
    EXPECT_EQ(tests::p2pkScriptPubkey(pubkey).size(), 35u);
}

void testVerifyScriptRejectsBadSignature() {
    const auto pubkey = compressedPubkey(1);
    auto [signedTx, scriptPubkey] = tests::makeSignedP2pkhSpend(
        1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    if (!signedTx.inputs[0].scriptSig.empty()) {
        signedTx.inputs[0].scriptSig[5] ^= 0xFF;
    }
    EXPECT_TRUE(!consensus::script::verifyScript(signedTx.inputs[0].scriptSig, scriptPubkey, signedTx, 0,
                                                 5'000'000'000));
}

void testUnsupportedScriptRejected() {
    const auto pubkey = compressedPubkey(1);
    const auto [signedTx, _] = tests::makeSignedP2pkhSpend(
        1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    std::vector<std::uint8_t> witnessV2 = {0x52, 0x20};
    witnessV2.insert(witnessV2.end(), 32, 0x01);
    EXPECT_THROW(consensus::script::verifyTransactionInput(signedTx, 0, witnessV2, 5'000'000'000));
}

void testWitnessProgramVersion() {
    using consensus::script::witnessProgramVersion;
    using consensus::script::OP_0;
    using consensus::script::OP_1;
    std::vector<std::uint8_t> v0 = {OP_0, 0x14};
    v0.insert(v0.end(), 20, 0xAB);
    EXPECT_TRUE(witnessProgramVersion(v0).value_or(-1) == 0);
    std::vector<std::uint8_t> v1 = {OP_1, 0x20};
    v1.insert(v1.end(), 32, 0xCD);
    EXPECT_TRUE(witnessProgramVersion(v1).value_or(-1) == 1);
    EXPECT_TRUE(!witnessProgramVersion(std::vector<std::uint8_t>{OP_1}).has_value());
}

void testMultisigRoundtrips() {
    const auto pkA = compressedPubkey(1);
    const auto pkB = compressedPubkey(2);
    const auto redeem = tests::multisigRedeemScript(2, {pkA, pkB});
    EXPECT_EQ(redeem.front(), 0x52);
    EXPECT_EQ(redeem[redeem.size() - 2], 0x52);
    EXPECT_EQ(redeem.back(), consensus::script::OP_CHECKMULTISIG);

    const auto [p2shTx, p2shSpk] = tests::makeSignedP2shMultisigSpend(
        {1, 2}, {pkA, pkB}, 2, repeatByte(0x03, 32), 0, 5'000'000'000, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(p2shTx, 0, p2shSpk, 5'000'000'000));

    const auto [p2wshTx, p2wshSpk] = tests::makeSignedP2wshMultisigSpend(
        {1, 2}, {pkA, pkB}, 2, repeatByte(0x04, 32), 0, 5'000'000'000, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(p2wshTx, 0, p2wshSpk, 5'000'000'000));
}

void testCltvCsvRoundtrips() {
    const auto pk = compressedPubkey(1);
    const auto [cltvP2sh, cltvSpk] = tests::makeSignedP2shCltvSpend(
        1, pk, 100, 100, 0xFFFFFFFE, repeatByte(0x07, 32), 0, 5'000'000'000, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(cltvP2sh, 0, cltvSpk, 5'000'000'000));

    const auto [csvP2sh, csvSpk] = tests::makeSignedP2shCsvSpend(
        1, pk, 10, 10, repeatByte(0x0A, 32), 0, 5'000'000'000, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(csvP2sh, 0, csvSpk, 5'000'000'000));
}

void testTaprootScriptPathOpSuccess() {
    const auto g = consensus::secp256k1Generator();
    auto pt = consensus::scalarMult(42, g);
    EXPECT_TRUE(pt.has_value());
    if (pt->y[31] & 1) {
        pt = scalarMult(42, g);  // test internal key normalization handled in control block setup
    }
    std::array<std::uint8_t, 32> internalX = pt->x;
    const std::vector<std::uint8_t> tapscript = {consensus::script::OP_1};
    const auto merkle = consensus::script::tapleafHash(0xC0, tapscript);
    const auto [parityQ, outputX] = consensus::taprootTweakPubkeyXonly(internalX, merkle);
    std::vector<std::uint8_t> scriptPubkey = {consensus::script::OP_1, 0x20};
    scriptPubkey.insert(scriptPubkey.end(), outputX.begin(), outputX.end());
    const std::vector<std::uint8_t> controlBlock = {static_cast<std::uint8_t>(0xC0 | (parityQ & 1))};
    std::vector<std::uint8_t> ctrl = controlBlock;
    ctrl.insert(ctrl.end(), internalX.begin(), internalX.end());

    messages::Transaction spend;
    spend.version = 2;
    spend.inputs.push_back(messages::TxIn{
        messages::OutPoint{repeatByte(0x33, 32), 0}, {}, 0xFFFFFFFD});
    spend.outputs.push_back(messages::TxOut{123'456'789 - 10'000, {0x51}});
    spend.lockTime = 0;
    spend.witness = {{tapscript, ctrl}};

    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts = {
        {123'456'789, scriptPubkey}};
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(spend, 0, scriptPubkey, 123'456'789, &spentPrevouts));
}

void testRealTestnet4TaprootKeypath() {
    const auto payload = hexBytes(
        "020000000001016760fe836cb885189111d4e3cdb8c66446cdc85c1f4b2b43fdd8eea2fe0b0b96"
        "0100000000fdffffff02899b92f80e000000225120640d6c0f4087e81de6e82df09435fb9d4628999d38c124eaaecc98f165c889b0"
        "a086010000000000225120b6ce5933c68826bb261fe730f4f8a78b8a9f8898e1ce794d664abf0a9494ac59"
        "0140ecba16793ec416745da044701928f046da5761eacb384892cbde3c3706187251d3ca3c78adfde0eb560b0"
        "de89d4124023f0536be3d5e900960816780ae3d97f53d1b0000");
    const auto [tx, consumed] = messages::deserializeTransaction(payload);
    EXPECT_EQ(consumed, payload.size());
    const auto prevSpk = hexBytes("512096519126915cde17e68250819b504b3fda380b8d98e3540a3f2baa3b011eb29c");
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts = {{64300000000LL, prevSpk}};
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(tx, 0, prevSpk, 64300000000LL, &spentPrevouts));
}

void testFixtureBlock1CoinbaseP2pkh() {
    const auto spk = hexBytes("76a9140a59837ccd4df25adc31cdad39be6a8d97557ed688ac");
    EXPECT_TRUE(consensus::script::isP2pkh(spk));
}

void testP2pkScriptTemplateSizes() {
    const auto g = consensus::secp256k1Generator();
    const auto pt = consensus::scalarMult(1, g);
    EXPECT_TRUE(pt.has_value());
    std::vector<std::uint8_t> compressed = {static_cast<std::uint8_t>(0x02 + (pt->y[31] & 1))};
    compressed.insert(compressed.end(), pt->x.begin(), pt->x.end());
    EXPECT_EQ(tests::p2pkScriptPubkey(compressed).size(), 35u);
    EXPECT_TRUE(consensus::script::isP2pk(tests::p2pkScriptPubkey(compressed)));

    std::vector<std::uint8_t> uncompressed = {0x04};
    uncompressed.insert(uncompressed.end(), pt->x.begin(), pt->x.end());
    uncompressed.insert(uncompressed.end(), pt->y.begin(), pt->y.end());
    EXPECT_EQ(tests::p2pkScriptPubkey(uncompressed).size(), 67u);
    EXPECT_TRUE(consensus::script::isP2pk(tests::p2pkScriptPubkey(uncompressed)));
}

void testWitnessProgramVersionExtended() {
    using consensus::script::witnessProgramVersion;
    using consensus::script::OP_1;
    using consensus::script::OP_16;
    std::vector<std::uint8_t> v2 = {0x52, 0x20};
    v2.insert(v2.end(), 32, 0xEF);
    EXPECT_TRUE(witnessProgramVersion(v2).value_or(-1) == 2);
    std::vector<std::uint8_t> v16 = {OP_16, 0x28};
    v16.insert(v16.end(), 40, 0xCA);
    EXPECT_TRUE(witnessProgramVersion(v16).value_or(-1) == 16);
    EXPECT_TRUE(!witnessProgramVersion(std::vector<std::uint8_t>{0x00, 0x01, 0x00}).has_value());
}

void testVerifyTransactionInputRejectsWitnessV2Program() {
    const auto program = repeatByte(0xBE, 32);
    std::vector<std::uint8_t> scriptPubkey = {0x52, static_cast<std::uint8_t>(program.size())};
    scriptPubkey.insert(scriptPubkey.end(), program.begin(), program.end());
    messages::Transaction spend;
    spend.version = 2;
    spend.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x03, 32), 0}, {}, 0xFFFFFFFF});
    spend.outputs.push_back(messages::TxOut{4'900'000'000, {0x51}});
    spend.witness = {{{0x01}}};
    EXPECT_THROW_MSG(consensus::script::verifyTransactionInput(spend, 0, scriptPubkey, 5'000'000'000),
                     "unsupported witness program version 2");
}

void testVerifyTransactionInputRejectsWitnessV16Program() {
    const auto program = repeatByte(0xCA, 40);
    std::vector<std::uint8_t> scriptPubkey = {consensus::script::OP_16, static_cast<std::uint8_t>(program.size())};
    scriptPubkey.insert(scriptPubkey.end(), program.begin(), program.end());
    messages::Transaction spend;
    spend.version = 2;
    spend.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x04, 32), 0}, {}, 0xFFFFFFFF});
    spend.outputs.push_back(messages::TxOut{1, {0x51}});
    spend.witness = {{program}};
    EXPECT_THROW_MSG(consensus::script::verifyTransactionInput(spend, 0, scriptPubkey, 5'000'000'000),
                     "unsupported witness program version 16");
}

void testP2shScriptPubkeyHashMismatchRejected() {
    const auto pubkey = compressedPubkey(1);
    const auto [signedTx, _] = tests::makeSignedP2shP2pkhSpend(
        1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    const auto wrongOuter = tests::p2shScriptPubkey(consensus::hash160(repeatByte(0xFE, 32)));
    EXPECT_THROW(consensus::script::verifyTransactionInput(signedTx, 0, wrongOuter, 5'000'000'000));
}

void testP2wshWitnessProgramCommitmentMismatchRejected() {
    const auto pubkey = compressedPubkey(1);
    const auto [signedTx, goodSpk] = tests::makeSignedP2wshP2pkhSpend(
        1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    auto badSpk = goodSpk;
    if (badSpk.size() > 11) {
        badSpk[11] ^= 0xFF;
    }
    EXPECT_THROW(consensus::script::verifyTransactionInput(signedTx, 0, badSpk, 5'000'000'000));
}

void testP2pkCorruptedSignatureScriptRejected() {
    const auto pubkey = compressedPubkey(1);
    auto [signedTx, scriptPubkey] = tests::makeSignedP2pkSpend(
        1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    if (signedTx.inputs[0].scriptSig.size() >= 2) {
        signedTx.inputs[0].scriptSig[signedTx.inputs[0].scriptSig.size() - 2] ^= 0xFF;
    }
    EXPECT_TRUE(!consensus::script::verifyScript(signedTx.inputs[0].scriptSig, scriptPubkey, signedTx, 0,
                                                 5'000'000'000));
}

void testP2shMultisigRejectsInsufficientSignatures() {
    const auto pkA = compressedPubkey(1);
    const auto pkB = compressedPubkey(2);
    const auto [signedTx, scriptPubkey] = tests::makeSignedP2shMultisigSpend(
        {1}, {pkA, pkB}, 2, repeatByte(0x05, 32), 0, 5'000'000'000, 4'900'000'000);
    EXPECT_THROW_MSG(consensus::script::verifyTransactionInput(signedTx, 0, scriptPubkey, 5'000'000'000),
                     "script verification failed");
}

void testP2shMultisigSignatureOrderMustMatchPubkeys() {
    const auto pkA = compressedPubkey(1);
    const auto pkB = compressedPubkey(2);
    const auto redeem = tests::multisigRedeemScript(2, {pkA, pkB});
    const auto scriptPubkey = tests::p2shScriptPubkey(consensus::hash160(redeem));
    messages::Transaction unsignedTx;
    unsignedTx.version = 1;
    unsignedTx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x06, 32), 0}, {}, 0xFFFFFFFF});
    unsignedTx.outputs.push_back(messages::TxOut{4'900'000'000, {0x51}});
    const auto sighash = consensus::script::legacySighash(unsignedTx, 0, redeem, 1);
    auto sigA = consensus::signDer(1, sighash);
    sigA.push_back(1);
    auto sigB = consensus::signDer(2, sighash);
    sigB.push_back(1);
    auto badScriptSig = tests::pushData(sigB);
    const auto pushA = tests::pushData(sigA);
    badScriptSig.insert(badScriptSig.end(), pushA.begin(), pushA.end());
    const auto pushRedeem = tests::pushData(redeem);
    badScriptSig.insert(badScriptSig.end(), pushRedeem.begin(), pushRedeem.end());
    badScriptSig.insert(badScriptSig.begin(), static_cast<std::uint8_t>(0));
    messages::Transaction badTx = unsignedTx;
    badTx.inputs[0].scriptSig = std::move(badScriptSig);
    EXPECT_THROW_MSG(consensus::script::verifyTransactionInput(badTx, 0, scriptPubkey, 5'000'000'000),
                     "script verification failed");
}

void testCltvRedeemScriptShape() {
    const auto pk = compressedPubkey(1);
    const auto script = tests::cltvRedeemScript(100, pk);
    EXPECT_EQ(script[0], 0x01);
    EXPECT_EQ(script[1], 100);
    EXPECT_TRUE(std::find(script.begin(), script.end(), consensus::script::OP_CHECKLOCKTIMEVERIFY) != script.end());
    EXPECT_EQ(script.back(), consensus::script::OP_CHECKSIG);
}

void testP2wshCltvRoundtrip() {
    const auto pk = compressedPubkey(1);
    const auto [signedTx, scriptPubkey] = tests::makeSignedP2wshCltvSpend(
        1, pk, 100, 100, 0xFFFFFFFE, repeatByte(0x08, 32), 0, 5'000'000'000, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(signedTx, 0, scriptPubkey, 5'000'000'000));
}

void testP2shCltvRejectsUnsatisfiedLocktime() {
    const auto pk = compressedPubkey(1);
    const auto [signedTx, scriptPubkey] = tests::makeSignedP2shCltvSpend(
        1, pk, 200, 100, 0xFFFFFFFE, repeatByte(0x09, 32), 0, 5'000'000'000, 4'900'000'000);
    EXPECT_THROW_MSG(consensus::script::verifyTransactionInput(signedTx, 0, scriptPubkey, 5'000'000'000),
                     "script verification failed");
}

void testP2wshCsvRoundtrip() {
    const auto pk = compressedPubkey(1);
    const auto [signedTx, scriptPubkey] = tests::makeSignedP2wshCsvSpend(
        1, pk, 10, 10, repeatByte(0x0B, 32), 0, 5'000'000'000, 4'900'000'000);
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(signedTx, 0, scriptPubkey, 5'000'000'000));
}

void testP2shCsvRejectsInsufficientSequence() {
    const auto pk = compressedPubkey(1);
    const auto [signedTx, scriptPubkey] = tests::makeSignedP2shCsvSpend(
        1, pk, 20, 10, repeatByte(0x0C, 32), 0, 5'000'000'000, 4'900'000'000);
    EXPECT_THROW_MSG(consensus::script::verifyTransactionInput(signedTx, 0, scriptPubkey, 5'000'000'000),
                     "script verification failed");
}

void testTaprootUnknownLeafAcceptedWithoutTapscriptInterpreter() {
    const auto [secret, pkXonly] = normalizedXonlyPubkey(333);
    constexpr int leafVersion = 0xFE;
    std::vector<std::uint8_t> tapscript = {0xFF};
    tapscript.insert(tapscript.end(), 200, 0x00);
    const auto leafDigest = consensus::script::tapleafHash(leafVersion, tapscript);
    const auto [parity, outputX] = consensus::taprootTweakPubkeyXonly(pkXonly, leafDigest);
    std::vector<std::uint8_t> controlBlock = {static_cast<std::uint8_t>(leafVersion | (parity & 1))};
    controlBlock.insert(controlBlock.end(), pkXonly.begin(), pkXonly.end());
    std::vector<std::uint8_t> prevSpk = {consensus::script::OP_1, consensus::script::WITNESS_V1_TAPROOT_XONLY_PK_LEN};
    prevSpk.insert(prevSpk.end(), outputX.begin(), outputX.end());

    messages::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0xFE, 32), 12}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(messages::TxOut{1000, {0x51}});
    tx.witness = {{tapscript, controlBlock}};
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts = {{8'888'888, prevSpk}};
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(tx, 0, prevSpk, 8'888'888, &spentPrevouts));
    (void)secret;
}

void testTapscriptMerkleMismatchRejected() {
    const auto [secret, pkXonly] = normalizedXonlyPubkey(444);
    constexpr int leafVersion = 0xC0;
    std::vector<std::uint8_t> tapscript = tests::pushData(pkXonly);
    tapscript.push_back(consensus::script::OP_CHECKSIG);
    const auto [parity, outputX] = consensus::taprootTweakPubkeyXonly(
        pkXonly, consensus::script::tapleafHash(leafVersion, tapscript));
    const auto wrongSibling = repeatByte(0xAA, 32);
    std::vector<std::uint8_t> controlBlock = {static_cast<std::uint8_t>(leafVersion | (parity & 1))};
    controlBlock.insert(controlBlock.end(), pkXonly.begin(), pkXonly.end());
    controlBlock.insert(controlBlock.end(), wrongSibling.begin(), wrongSibling.end());
    std::vector<std::uint8_t> prevSpk = {consensus::script::OP_1, consensus::script::WITNESS_V1_TAPROOT_XONLY_PK_LEN};
    prevSpk.insert(prevSpk.end(), outputX.begin(), outputX.end());

    messages::Transaction dummy;
    dummy.version = 2;
    dummy.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0xF0, 32), 8}, {}, 0xFFFFFFFF});
    dummy.outputs.push_back(messages::TxOut{1, {0x51}});
    const auto leafDigest = consensus::script::tapleafHash(leafVersion, tapscript);
    const std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts = {{20'000'000, prevSpk}};
    const auto digest =
        consensus::script::taprootSignatureHash(dummy, 0, spentPrevouts, 0, nullptr, 1, leafDigest, 0xFFFFFFFF);
    const auto sig = consensus::signBip340Schnorr(secret, digest);
    messages::Transaction corrupt = dummy;
    corrupt.witness = {{sig, tapscript, controlBlock}};
    EXPECT_THROW(consensus::script::verifyTransactionInput(corrupt, 0, prevSpk, 20'000'000, &spentPrevouts));
}

void testTaprootScriptPathTapscriptCltvRejectsUnsatisfiedLocktime() {
    const auto [_, pkXonly] = normalizedXonlyPubkey(8765432);
    auto tapscript = tests::pushScriptNum(200);
    tapscript.push_back(consensus::script::OP_CHECKLOCKTIMEVERIFY);
    tapscript.push_back(consensus::script::OP_DROP);
    const auto pkPush = tests::pushData(pkXonly);
    tapscript.insert(tapscript.end(), pkPush.begin(), pkPush.end());
    tapscript.push_back(consensus::script::OP_CHECKSIG);
    const auto [signedTx, prevSpk, spentPrevouts] =
        makeTapscriptCltvOrCsvSpend(8765432, tapscript, 100, 0xFFFFFFFE, repeatByte(0x0E, 32));
    EXPECT_THROW_MSG(consensus::script::verifyTransactionInput(signedTx, 0, prevSpk, 100'000'000, &spentPrevouts),
                     "CHECKLOCKTIMEVERIFY");
}

void testTaprootScriptPathTapscriptCsvRejectsInsufficientSequence() {
    const auto [_, pkXonly] = normalizedXonlyPubkey(1112223);
    auto tapscript = tests::pushScriptNum(20);
    tapscript.push_back(consensus::script::OP_CHECKSEQUENCEVERIFY);
    tapscript.push_back(consensus::script::OP_DROP);
    const auto pkPush = tests::pushData(pkXonly);
    tapscript.insert(tapscript.end(), pkPush.begin(), pkPush.end());
    tapscript.push_back(consensus::script::OP_CHECKSIG);
    const auto [signedTx, prevSpk, spentPrevouts] =
        makeTapscriptCltvOrCsvSpend(1112223, tapscript, 0, 10, repeatByte(0x10, 32));
    EXPECT_THROW_MSG(consensus::script::verifyTransactionInput(signedTx, 0, prevSpk, 100'000'000, &spentPrevouts),
                     "CHECKSEQUENCEVERIFY");
}

void testLegacyEvaluateScriptHashOpcodes() {
    const std::vector<std::uint8_t> data = {'8', '1', '0', '8', '9', '9', '0', '5', '5'};
    messages::Transaction tx;
    tx.version = 1;

    struct Case {
        std::uint8_t opcode;
        std::vector<std::uint8_t> expected;
    };
    const std::vector<Case> cases = {
        {0xA6, consensus::ripemd160Digest(data)},
        {0xA7, consensus::sha1Digest(data)},
        {0xA8, consensus::sha256Digest(data)},
        {0xA9, consensus::hash160(data)},
        {0xAA, consensus::doubleSha256(data)},
    };

    const std::vector<std::uint8_t> emptyScriptCode;
    for (const auto& testCase : cases) {
        consensus::script::ScriptStack stack = {data};
        const std::vector<std::uint8_t> script = {testCase.opcode};
        EXPECT_NO_THROW(consensus::script::evaluateScript(script, stack, tx, 0, emptyScriptCode, 0, false));
        EXPECT_TRUE(!stack.empty());
        EXPECT_BYTES_EQ(stack.back(), testCase.expected);
    }

    const auto digest = consensus::sha256Digest(data);
    consensus::script::ScriptStack stack = {std::vector<std::uint8_t>{'l', 'e', 'f', 't'}, data};
    std::vector<std::uint8_t> script = {0xA8};
    script.push_back(static_cast<std::uint8_t>(digest.size()));
    script.insert(script.end(), digest.begin(), digest.end());
    script.push_back(consensus::script::OP_EQUALVERIFY);
    EXPECT_NO_THROW(consensus::script::evaluateScript(script, stack, tx, 0, emptyScriptCode, 0, false));
    EXPECT_EQ(stack.size(), 1u);
    EXPECT_BYTES_EQ(stack[0], (std::vector<std::uint8_t>{'l', 'e', 'f', 't'}));
}

void testLegacyEvaluateScriptStackArithmeticOpcodes() {
    messages::Transaction tx;
    tx.version = 1;

    const std::vector<std::uint8_t> emptyScriptCode;

    consensus::script::ScriptStack swapStack = {{0x01}, {0x02}};
    const std::vector<std::uint8_t> swapScript = {0x7C};
    EXPECT_NO_THROW(consensus::script::evaluateScript(swapScript, swapStack, tx, 0, emptyScriptCode, 0, false));
    EXPECT_EQ(swapStack.size(), 2u);
    EXPECT_BYTES_EQ(swapStack[0], (std::vector<std::uint8_t>{0x02}));
    EXPECT_BYTES_EQ(swapStack[1], (std::vector<std::uint8_t>{0x01}));

    consensus::script::ScriptStack subStack = {{0xE8, 0x07}, {0xD1, 0x07}};
    const std::vector<std::uint8_t> subScript = {0x94};
    EXPECT_NO_THROW(consensus::script::evaluateScript(subScript, subStack, tx, 0, emptyScriptCode, 0, false));
    EXPECT_EQ(subStack.size(), 1u);
    EXPECT_BYTES_EQ(subStack[0], (std::vector<std::uint8_t>{0x17}));

    consensus::script::ScriptStack gtStack = {{0x17}, {0x12}};
    const std::vector<std::uint8_t> gtScript = {0xA0};
    EXPECT_NO_THROW(consensus::script::evaluateScript(gtScript, gtStack, tx, 0, emptyScriptCode, 0, false));
    EXPECT_EQ(gtStack.size(), 1u);
    EXPECT_BYTES_EQ(gtStack[0], (std::vector<std::uint8_t>{0x01}));
}

void testTaprootScriptPathTapscriptCltvAccepted() {
    const auto [_, pkXonly] = normalizedXonlyPubkey(7654321);
    auto tapscript = tests::pushScriptNum(100);
    tapscript.push_back(consensus::script::OP_CHECKLOCKTIMEVERIFY);
    tapscript.push_back(consensus::script::OP_DROP);
    const auto pkPush = tests::pushData(pkXonly);
    tapscript.insert(tapscript.end(), pkPush.begin(), pkPush.end());
    tapscript.push_back(consensus::script::OP_CHECKSIG);
    const auto [signedTx, prevSpk, spentPrevouts] =
        makeTapscriptCltvOrCsvSpend(7654321, tapscript, 100, 0xFFFFFFFE, repeatByte(0x0D, 32));
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(signedTx, 0, prevSpk, 100'000'000, &spentPrevouts));
}

void testTaprootScriptPathTapscriptCsvAccepted() {
    const auto [_, pkXonly] = normalizedXonlyPubkey(9876543);
    auto tapscript = tests::pushScriptNum(10);
    tapscript.push_back(consensus::script::OP_CHECKSEQUENCEVERIFY);
    tapscript.push_back(consensus::script::OP_DROP);
    const auto pkPush = tests::pushData(pkXonly);
    tapscript.insert(tapscript.end(), pkPush.begin(), pkPush.end());
    tapscript.push_back(consensus::script::OP_CHECKSIG);
    const auto [signedTx, prevSpk, spentPrevouts] =
        makeTapscriptCltvOrCsvSpend(9876543, tapscript, 0, 10, repeatByte(0x0F, 32));
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(signedTx, 0, prevSpk, 100'000'000, &spentPrevouts));
}

void testMultisigRedeemScriptShape() {
    const auto pkA = compressedPubkey(1);
    const auto pkB = compressedPubkey(2);
    const auto script = tests::multisigRedeemScript(2, {pkA, pkB});
    EXPECT_EQ(script.front(), 0x52);
    EXPECT_EQ(script[script.size() - 2], 0x52);
    EXPECT_EQ(script.back(), consensus::script::OP_CHECKMULTISIG);
}

void testVerifyDerSignatureRejectsInvalid() {
    const auto g = consensus::secp256k1Generator();
    const auto pt = consensus::scalarMult(1, g);
    EXPECT_TRUE(pt.has_value());
    std::vector<std::uint8_t> pubkey = {static_cast<std::uint8_t>(0x02 + (pt->y[31] & 1))};
    pubkey.insert(pubkey.end(), pt->x.begin(), pt->x.end());
    const auto digest = hexBytes("abababababababababababababababababababababababababababababababab");
    const auto signature = consensus::signDer(1, digest);
    EXPECT_TRUE(consensus::verifyDerSignature(pubkey, digest, signature));
    auto badSig = signature;
    if (!badSig.empty()) {
        badSig[4] ^= 0xFF;
    }
    EXPECT_TRUE(!consensus::verifyDerSignature(pubkey, digest, badSig));
}

void testSha1DigestKnownVector() {
    const std::vector<std::uint8_t> data{'8', '1', '0', '8', '9', '9', '0', '5', '5'};
    const auto digest = consensus::sha1Digest(data);
    EXPECT_EQ(bytesToHex(digest), "3b8bdd565ef4c1f960f9843f234c5d3c91d703a3");
}

void testEvaluateScriptPushDataEncodings() {
    messages::Transaction tx;
    tx.version = 1;
    const std::vector<std::uint8_t> emptyScriptCode;
    const std::vector<std::uint8_t> payload = {0x01, 0x02, 0x03};

    std::vector<std::uint8_t> push1 = {consensus::script::OP_PUSHDATA1, static_cast<std::uint8_t>(payload.size())};
    push1.insert(push1.end(), payload.begin(), payload.end());
    consensus::script::ScriptStack stack1;
    EXPECT_NO_THROW(consensus::script::evaluateScript(push1, stack1, tx, 0, emptyScriptCode, 0, false));
    EXPECT_BYTES_EQ(stack1.back(), payload);

    std::vector<std::uint8_t> push2 = {consensus::script::OP_PUSHDATA2, 0x03, 0x00};
    push2.insert(push2.end(), payload.begin(), payload.end());
    consensus::script::ScriptStack stack2;
    EXPECT_NO_THROW(consensus::script::evaluateScript(push2, stack2, tx, 0, emptyScriptCode, 0, false));
    EXPECT_BYTES_EQ(stack2.back(), payload);

    std::vector<std::uint8_t> push4 = {consensus::script::OP_PUSHDATA4, 0x03, 0x00, 0x00, 0x00};
    push4.insert(push4.end(), payload.begin(), payload.end());
    consensus::script::ScriptStack stack4;
    EXPECT_NO_THROW(consensus::script::evaluateScript(push4, stack4, tx, 0, emptyScriptCode, 0, false));
    EXPECT_BYTES_EQ(stack4.back(), payload);
}

void testEvaluateScriptVerifyAndEqualVerifyFailures() {
    messages::Transaction tx;
    tx.version = 1;
    const std::vector<std::uint8_t> emptyScriptCode;

    consensus::script::ScriptStack verifyFail = {{0x00}};
    EXPECT_THROW(consensus::script::evaluateScript(std::vector<std::uint8_t>{consensus::script::OP_VERIFY}, verifyFail,
                                                   tx, 0, emptyScriptCode, 0, false));

    consensus::script::ScriptStack equalFail = {{0x01}, {0x02}};
    std::vector<std::uint8_t> equalVerifyScript = {consensus::script::OP_EQUALVERIFY};
    EXPECT_THROW(consensus::script::evaluateScript(equalVerifyScript, equalFail, tx, 0, emptyScriptCode, 0, false));

    consensus::script::ScriptStack equalOk = {{0x01}, {0x01}};
    EXPECT_NO_THROW(
        consensus::script::evaluateScript(equalVerifyScript, equalOk, tx, 0, emptyScriptCode, 0, false));
}

void testEvaluateScriptChecksigVerifyFailure() {
    messages::Transaction tx;
    tx.version = 1;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x11, 32), 0}, {}, 0xFFFFFFFF});
    const std::vector<std::uint8_t> emptyScriptCode;
    const auto pubkey = compressedPubkey(1);
    consensus::script::ScriptStack stack = {std::vector<std::uint8_t>{0x00}, pubkey};
    const std::vector<std::uint8_t> script = {consensus::script::OP_CHECKSIGVERIFY};
    EXPECT_THROW(consensus::script::evaluateScript(script, stack, tx, 0, emptyScriptCode, 0, false));
}

void testEvaluateScriptUnsupportedOpcode() {
    messages::Transaction tx;
    tx.version = 1;
    const std::vector<std::uint8_t> emptyScriptCode;
    consensus::script::ScriptStack stack;
    const std::vector<std::uint8_t> script = {0xFF};
    EXPECT_THROW(consensus::script::evaluateScript(script, stack, tx, 0, emptyScriptCode, 0, false));
}

void testParsePushOnlyScriptSigRejectsNonPush() {
    const std::vector<std::uint8_t> badSig = {consensus::script::OP_DUP};
    EXPECT_THROW(consensus::script::parsePushOnlyScriptSig(badSig));
}

void testParsePushOnlyScriptSigCollectsPushes() {
    const std::vector<std::uint8_t> sig = {consensus::script::OP_0, consensus::script::OP_1};
    const auto pushes = consensus::script::parsePushOnlyScriptSig(sig);
    EXPECT_EQ(pushes.size(), 2u);
    EXPECT_TRUE(pushes[0].empty());
    EXPECT_EQ(pushes[1].size(), 1u);
}

void testP2pkhScriptCodeShape() {
    const auto hash = repeatByte(0xAB, 20);
    const auto scriptCode = consensus::script::p2pkhScriptCode(hash);
    EXPECT_EQ(scriptCode.front(), consensus::script::OP_DUP);
    EXPECT_EQ(scriptCode.back(), consensus::script::OP_CHECKSIG);
}

void testIsTemplateHelpers() {
    const auto hash = repeatByte(0xCD, 20);
    EXPECT_TRUE(consensus::script::isP2pkh(tests::p2pkhScriptPubkey(hash)));
    EXPECT_TRUE(consensus::script::isP2sh(tests::p2shScriptPubkey(hash)));
    std::vector<std::uint8_t> p2wpkh = {0x00, 0x14};
    p2wpkh.insert(p2wpkh.end(), hash.begin(), hash.end());
    EXPECT_TRUE(consensus::script::isP2wpkh(p2wpkh));
    const auto redeem = tests::p2pkhScriptPubkey(hash);
    const auto wshHash = consensus::sha256Digest(redeem);
    std::vector<std::uint8_t> p2wsh = {0x00, 0x20};
    p2wsh.insert(p2wsh.end(), wshHash.begin(), wshHash.end());
    EXPECT_TRUE(consensus::script::isP2wsh(p2wsh));
    EXPECT_TRUE(!consensus::script::isP2tr(tests::p2pkhScriptPubkey(hash)));
}

void testBareOpNPlusPushTemplate41700() {
    EXPECT_TRUE(consensus::script::isBareOpN(std::vector<std::uint8_t>{consensus::script::OP_1}));
    EXPECT_TRUE(consensus::script::isBareOpN(hexBytes("51024e73")));
    EXPECT_TRUE(consensus::script::isBareOpN(std::vector<std::uint8_t>{consensus::script::OP_16}));
    EXPECT_TRUE(!consensus::script::isBareOpN(std::vector<std::uint8_t>{}));
    EXPECT_TRUE(!consensus::script::isBareOpN(std::vector<std::uint8_t>{consensus::script::OP_CHECKSIG}));
    EXPECT_TRUE(!consensus::script::isBareOpN(hexBytes("5100")));
    EXPECT_TRUE(!consensus::script::isBareOpN(hexBytes("51024e")));
    EXPECT_TRUE(!consensus::script::isBareOpN(hexBytes("51024e7300")));
    EXPECT_TRUE(!consensus::script::isBareOpN(hexBytes("51201111111111111111111111111111111111111111111111111111111111111111")));
}

void testBareOpNPlusPush41700Accepted() {
    messages::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0xCE, 32), 1}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(messages::TxOut{19'000, {consensus::script::OP_1}});
    EXPECT_NO_THROW(consensus::script::verifyTransactionInput(tx, 0, hexBytes("51024e73"), 20'000));
}

void testWitnessProgramVersionPushData1Encoding() {
    const auto program = repeatByte(0xBE, 32);
    std::vector<std::uint8_t> spk = {consensus::script::OP_1, consensus::script::OP_PUSHDATA1,
                                     static_cast<std::uint8_t>(program.size())};
    spk.insert(spk.end(), program.begin(), program.end());
    EXPECT_TRUE(consensus::script::witnessProgramVersion(spk).value_or(-1) == 1);
}

void testVerifyScriptRejectsP2pkWithWitness() {
    const auto pubkey = compressedPubkey(1);
    const auto [signedTx, scriptPubkey] =
        tests::makeSignedP2pkSpend(1, repeatByte(0x02, 32), 0, 5'000'000'000, pubkey, 4'900'000'000);
    EXPECT_TRUE(!consensus::script::verifyScript(signedTx.inputs[0].scriptSig, scriptPubkey, signedTx, 0,
                                                 5'000'000'000, {{std::vector<std::uint8_t>{0x01}}}));
}

void testVerifyScriptRejectsP2wpkhWrongWitnessCount() {
    const auto pubkey = compressedPubkey(1);
    const auto hash = consensus::hash160(pubkey);
    std::vector<std::uint8_t> spk = {0x00, 0x14};
    spk.insert(spk.end(), hash.begin(), hash.end());
    messages::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x03, 32), 0}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(messages::TxOut{1, {0x51}});
    tx.witness = {{std::vector<std::uint8_t>{0x01}}};
    EXPECT_TRUE(!consensus::script::verifyScript({}, spk, tx, 0, 5'000'000'000, tx.witness[0]));
}

void testVerifyTransactionInputRejectsOutOfRangeIndex() {
    messages::Transaction tx;
    tx.version = 1;
    EXPECT_THROW(consensus::script::verifyTransactionInput(tx, 0, std::vector<std::uint8_t>{0x51}, 1));
}

void testEvaluateScriptCltvIgnoredWithoutVerifyFlag() {
    messages::Transaction tx;
    tx.version = 2;
    tx.lockTime = 50;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x12, 32), 0}, {}, 0});
    const std::vector<std::uint8_t> emptyScriptCode;
    auto script = tests::pushScriptNum(100);
    script.push_back(consensus::script::OP_CHECKLOCKTIMEVERIFY);
    consensus::script::ScriptStack stack;
    const int noCltv = consensus::script::SCRIPT_VERIFY_CHECKSEQUENCEVERIFY;
    EXPECT_NO_THROW(consensus::script::evaluateScript(script, stack, tx, 0, emptyScriptCode, 0, false, noCltv));
}

void testEvaluateScriptDupDropRoundtrip() {
    messages::Transaction tx;
    tx.version = 1;
    const std::vector<std::uint8_t> emptyScriptCode;
    consensus::script::ScriptStack stack = {{0x42}};
    const std::vector<std::uint8_t> script = {consensus::script::OP_DUP, consensus::script::OP_DROP};
    EXPECT_NO_THROW(consensus::script::evaluateScript(script, stack, tx, 0, emptyScriptCode, 0, false));
    EXPECT_EQ(stack.size(), 1u);
    EXPECT_BYTES_EQ(stack[0], (std::vector<std::uint8_t>{0x42}));
}

void testEvaluateScriptEqualPushTrueFalse() {
    messages::Transaction tx;
    tx.version = 1;
    const std::vector<std::uint8_t> emptyScriptCode;
    consensus::script::ScriptStack stack = {{0x01}, {0x02}};
    EXPECT_NO_THROW(consensus::script::evaluateScript(std::vector<std::uint8_t>{consensus::script::OP_EQUAL}, stack, tx,
                                                      0, emptyScriptCode, 0, false));
    EXPECT_EQ(stack.size(), 1u);
    EXPECT_TRUE(stack.back().empty());
}

void testEvaluateScriptCltvErrorPaths() {
    const std::vector<std::uint8_t> emptyScriptCode;
    const int flags = consensus::script::SCRIPT_VERIFY_DEFAULT;

    auto cltvScript = tests::pushScriptNum(50);
    cltvScript.push_back(consensus::script::OP_CHECKLOCKTIMEVERIFY);

    messages::Transaction oldTx;
    oldTx.version = 1;
    oldTx.lockTime = 100;
    oldTx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x20, 32), 0}, {}, 0});
    consensus::script::ScriptStack stack;
    try {
        consensus::script::evaluateScript(cltvScript, stack, oldTx, 0, emptyScriptCode, 0, false, flags);
    } catch (const std::exception& exc) {
        std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " unexpected throw " << exc.what() << "\n";
        ++g_failures;
    }

    messages::Transaction finalTx;
    finalTx.version = 2;
    finalTx.lockTime = 0;
    finalTx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x21, 32), 0}, {}, 0xFFFFFFFF});
    stack.clear();
    EXPECT_THROW(consensus::script::evaluateScript(cltvScript, stack, finalTx, 0, emptyScriptCode, 0, false, flags));

    messages::Transaction timeTx;
    timeTx.version = 2;
    timeTx.lockTime = 600'000'000;
    timeTx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x22, 32), 0}, {}, 0});
    stack.clear();
    EXPECT_THROW(consensus::script::evaluateScript(cltvScript, stack, timeTx, 0, emptyScriptCode, 0, false, flags));
}

void testEvaluateScriptCsvErrorPaths() {
    const std::vector<std::uint8_t> emptyScriptCode;
    const int flags = consensus::script::SCRIPT_VERIFY_DEFAULT;
    auto csvScript = tests::pushScriptNum(10);
    csvScript.push_back(consensus::script::OP_CHECKSEQUENCEVERIFY);

    messages::Transaction finalSeqTx;
    finalSeqTx.version = 2;
    finalSeqTx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x23, 32), 0}, {}, 0xFFFFFFFF});
    consensus::script::ScriptStack stack;
    EXPECT_THROW(consensus::script::evaluateScript(csvScript, stack, finalSeqTx, 0, emptyScriptCode, 0, false, flags));

    messages::Transaction disabledTx;
    disabledTx.version = 2;
    disabledTx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x24, 32), 0}, {}, 0x80000000});
    stack.clear();
    EXPECT_THROW(consensus::script::evaluateScript(csvScript, stack, disabledTx, 0, emptyScriptCode, 0, false, flags));
}

void testEvaluateScriptCheckmultisigUnderflow() {
    messages::Transaction tx;
    tx.version = 1;
    const std::vector<std::uint8_t> emptyScriptCode;
    consensus::script::ScriptStack emptyStack;
    const std::vector<std::uint8_t> script = {consensus::script::OP_CHECKMULTISIG};
    EXPECT_THROW(consensus::script::evaluateScript(script, emptyStack, tx, 0, emptyScriptCode, 0, false));
}

void testCastToBoolRejectsNegativeZero() {
    messages::Transaction tx;
    tx.version = 1;
    const std::vector<std::uint8_t> emptyScriptCode;
    consensus::script::ScriptStack stack = {{0x80}};
    EXPECT_THROW(consensus::script::evaluateScript(std::vector<std::uint8_t>{consensus::script::OP_VERIFY}, stack, tx,
                                                   0, emptyScriptCode, 0, false));
}

void testWitnessProgramVersionPushData2And4() {
    const auto program = repeatByte(0xAC, 32);
    std::vector<std::uint8_t> spk2 = {consensus::script::OP_1, consensus::script::OP_PUSHDATA2, 0x20, 0x00};
    spk2.insert(spk2.end(), program.begin(), program.end());
    EXPECT_TRUE(consensus::script::witnessProgramVersion(spk2).value_or(-1) == 1);

    std::vector<std::uint8_t> spk4 = {consensus::script::OP_1, consensus::script::OP_PUSHDATA4, 0x20, 0x00, 0x00, 0x00};
    spk4.insert(spk4.end(), program.begin(), program.end());
    EXPECT_TRUE(consensus::script::witnessProgramVersion(spk4).value_or(-1) == 1);
}

}  // namespace

void registerScriptTests() {
    RUN_TEST(testSecp256k1SignVerifyRoundtrip);
    RUN_TEST(testP2pkSpendRoundtrip);
    RUN_TEST(testP2pkhSpendRoundtrip);
    RUN_TEST(testP2wpkhSpendRoundtrip);
    RUN_TEST(testP2shSpendRoundtrip);
    RUN_TEST(testP2wshSpendRoundtrip);
    RUN_TEST(testScriptTemplates);
    RUN_TEST(testVerifyScriptRejectsBadSignature);
    RUN_TEST(testUnsupportedScriptRejected);
    RUN_TEST(testWitnessProgramVersion);
    RUN_TEST(testMultisigRoundtrips);
    RUN_TEST(testCltvCsvRoundtrips);
    RUN_TEST(testTaprootScriptPathOpSuccess);
    RUN_TEST(testRealTestnet4TaprootKeypath);
    RUN_TEST(testFixtureBlock1CoinbaseP2pkh);
    RUN_TEST(testP2pkScriptTemplateSizes);
    RUN_TEST(testWitnessProgramVersionExtended);
    RUN_TEST(testVerifyTransactionInputRejectsWitnessV2Program);
    RUN_TEST(testVerifyTransactionInputRejectsWitnessV16Program);
    RUN_TEST(testP2shScriptPubkeyHashMismatchRejected);
    RUN_TEST(testP2wshWitnessProgramCommitmentMismatchRejected);
    RUN_TEST(testP2pkCorruptedSignatureScriptRejected);
    RUN_TEST(testP2shMultisigRejectsInsufficientSignatures);
    RUN_TEST(testP2shMultisigSignatureOrderMustMatchPubkeys);
    RUN_TEST(testCltvRedeemScriptShape);
    RUN_TEST(testP2wshCltvRoundtrip);
    RUN_TEST(testP2shCltvRejectsUnsatisfiedLocktime);
    RUN_TEST(testP2wshCsvRoundtrip);
    RUN_TEST(testP2shCsvRejectsInsufficientSequence);
    RUN_TEST(testTaprootUnknownLeafAcceptedWithoutTapscriptInterpreter);
    RUN_TEST(testTapscriptMerkleMismatchRejected);
    RUN_TEST(testTaprootScriptPathTapscriptCltvRejectsUnsatisfiedLocktime);
    RUN_TEST(testTaprootScriptPathTapscriptCsvRejectsInsufficientSequence);
    RUN_TEST(testLegacyEvaluateScriptHashOpcodes);
    RUN_TEST(testLegacyEvaluateScriptStackArithmeticOpcodes);
    RUN_TEST(testTaprootScriptPathTapscriptCltvAccepted);
    RUN_TEST(testTaprootScriptPathTapscriptCsvAccepted);
    RUN_TEST(testMultisigRedeemScriptShape);
    RUN_TEST(testVerifyDerSignatureRejectsInvalid);
    RUN_TEST(testSha1DigestKnownVector);
    RUN_TEST(testEvaluateScriptPushDataEncodings);
    RUN_TEST(testEvaluateScriptVerifyAndEqualVerifyFailures);
    RUN_TEST(testEvaluateScriptChecksigVerifyFailure);
    RUN_TEST(testEvaluateScriptUnsupportedOpcode);
    RUN_TEST(testParsePushOnlyScriptSigRejectsNonPush);
    RUN_TEST(testParsePushOnlyScriptSigCollectsPushes);
    RUN_TEST(testP2pkhScriptCodeShape);
    RUN_TEST(testIsTemplateHelpers);
    RUN_TEST(testBareOpNPlusPushTemplate41700);
    RUN_TEST(testBareOpNPlusPush41700Accepted);
    RUN_TEST(testWitnessProgramVersionPushData1Encoding);
    RUN_TEST(testVerifyScriptRejectsP2pkWithWitness);
    RUN_TEST(testVerifyScriptRejectsP2wpkhWrongWitnessCount);
    RUN_TEST(testVerifyTransactionInputRejectsOutOfRangeIndex);
    RUN_TEST(testEvaluateScriptCltvIgnoredWithoutVerifyFlag);
    RUN_TEST(testEvaluateScriptDupDropRoundtrip);
    RUN_TEST(testEvaluateScriptEqualPushTrueFalse);
    RUN_TEST(testEvaluateScriptCltvErrorPaths);
    RUN_TEST(testEvaluateScriptCsvErrorPaths);
    RUN_TEST(testEvaluateScriptCheckmultisigUnderflow);
    RUN_TEST(testCastToBoolRejectsNegativeZero);
    RUN_TEST(testWitnessProgramVersionPushData2And4);
}
