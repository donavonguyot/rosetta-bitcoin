#include "test_support.hpp"

#include "cpbitnode/conformance/script_corpus.hpp"
#include "cpbitnode/consensus/script/sighash.hpp"

#include <array>
#include <vector>

void registerNodecoreScriptCorpusTests();

namespace {

#ifdef CPBITNODE_USE_NATIVE_SECP256K1
void testNodecoreScriptCorpusLoads() {
    const auto cases = cpbitnode::conformance::loadCases();
    EXPECT_TRUE(!cases.empty());
    for (const auto& case_ : cases) {
        EXPECT_TRUE(!case_.transaction.inputs.empty());
        EXPECT_TRUE(case_.amount >= 0);
        EXPECT_TRUE(!case_.scriptPubkey.empty());
        EXPECT_TRUE(!case_.spentPrevouts.empty());
    }
}

void testP2wshNipBip143DigestMatchesPythonOracle() {
    const auto cases = cpbitnode::conformance::loadCases();
    const cpbitnode::conformance::ScriptCorpusCase* target = nullptr;
    for (const auto& case_ : cases) {
        if (case_.fixtureId == "scripts.p2wsh_nip_98631") {
            target = &case_;
            break;
        }
    }
    EXPECT_TRUE(target != nullptr);
    if (target == nullptr) {
        return;
    }
    const auto& witness = target->transaction.witness[0];
    const auto& script = witness.back();
    const auto sighashType = static_cast<int>(witness[0].back());
    const auto digest =
        cpbitnode::consensus::script::bip143Sighash(target->transaction, 0, script, target->amount, sighashType);
    std::array<std::uint8_t, 32> expected{};
    const char* hex = "7d07cd988b45fc177cf7940b713818fbe041669ef860c1e6c8faea8061a3d18e";
    for (std::size_t i = 0; i < expected.size(); ++i) {
        const auto byte = std::stoi(std::string(hex + 2 * i, 2), nullptr, 16);
        expected[i] = static_cast<std::uint8_t>(byte);
    }
    EXPECT_BYTES_EQ(digest, std::vector<std::uint8_t>(expected.begin(), expected.end()));
}

void testNodecoreScriptCorpusVerify() {
    const auto cases = cpbitnode::conformance::loadCases();
    for (const auto& case_ : cases) {
        try {
            cpbitnode::conformance::verifyCase(case_);
        } catch (const std::exception& error) {
            std::cerr << "FAIL corpus fixture " << case_.fixtureId << ": " << error.what() << '\n';
            ++g_failures;
        }
    }
}
#else
void testNodecoreScriptCorpusSkippedWithoutNativeSecp() {
    std::cerr << "SKIP shared script corpus (CPBITNODE_USE_NATIVE_SECP256K1=OFF)\n";
}
#endif

}  // namespace

void registerNodecoreScriptCorpusTests() {
#ifdef CPBITNODE_USE_NATIVE_SECP256K1
    RUN_TEST(testNodecoreScriptCorpusLoads);
    RUN_TEST(testP2wshNipBip143DigestMatchesPythonOracle);
    RUN_TEST(testNodecoreScriptCorpusVerify);
#else
    RUN_TEST(testNodecoreScriptCorpusSkippedWithoutNativeSecp);
#endif
}
