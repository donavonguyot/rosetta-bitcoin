#include "test_support.hpp"
#include "blocks_fixture.hpp"

#include "cpbitnode/chain/genesis.hpp"
#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/consensus/block.hpp"
#include "cpbitnode/consensus/coinbase.hpp"
#include "cpbitnode/consensus/hash.hpp"
#include "cpbitnode/consensus/merkle.hpp"
#include "cpbitnode/consensus/subsidy.hpp"
#include "cpbitnode/consensus/witness.hpp"
#include "cpbitnode/messages/block_header.hpp"
#include "cpbitnode/messages/transaction.hpp"
#include "cpbitnode/sync/validate.hpp"
#include <algorithm>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

void registerConsensusTests();

namespace {

std::vector<std::uint8_t> readFixtureBlock() {
    return cpbitnode::testfixtures::readFixtureBlock(0);
}

std::string bytesToHex(std::span<const std::uint8_t> data) {
    std::ostringstream oss;
    for (const auto b : data) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(b);
    }
    return oss.str();
}

std::vector<std::uint8_t> fromHex(const std::string& hex) {
    std::vector<std::uint8_t> out;
    out.reserve(hex.size() / 2);
    for (std::size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoi(hex.substr(i, 2), nullptr, 16)));
    }
    return out;
}

bool transactionsEqual(const cpbitnode::messages::Transaction& a, const cpbitnode::messages::Transaction& b) {
    return cpbitnode::messages::serializeTransaction(a, true) == cpbitnode::messages::serializeTransaction(b, true);
}

void testBlockSubsidyAtHeightOne() {
    EXPECT_EQ(cpbitnode::consensus::blockSubsidy(1), 50LL * 100'000'000);
}

void testBlockSubsidyZeroForNegativeHeight() {
    EXPECT_EQ(cpbitnode::consensus::blockSubsidy(-1), 0);
}

void testBlockSubsidyZeroAfter64Halvings() {
    EXPECT_EQ(cpbitnode::consensus::blockSubsidy(64 * 210000), 0);
}

void testBlockSubsidyHalvingAt210000() {
    EXPECT_EQ(cpbitnode::consensus::blockSubsidy(210000), 25LL * 100'000'000);
}

void testSha256DigestKnownVector() {
    const std::vector<std::uint8_t> data{'h', 'e', 'l', 'l', 'o'};
    const auto digest = cpbitnode::consensus::sha256Digest(data);
    EXPECT_EQ(bytesToHex(digest), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
}

void testHash160KnownVector() {
    const std::vector<std::uint8_t> data{'h', 'e', 'l', 'l', 'o'};
    const auto digest = cpbitnode::consensus::hash160(data);
    EXPECT_EQ(bytesToHex(digest), "b6a9c8c230722b7c748331a8b450f05566dc7d0f");
}

void testMerkleRootDuplicatesLastHash() {
    const std::vector<std::uint8_t> left(32, 0x01);
    const std::vector<std::uint8_t> right(32, 0x02);
    const std::vector<std::vector<std::uint8_t>> pairHashes{left, right};
    const std::vector<std::vector<std::uint8_t>> singleHash{left};
    EXPECT_TRUE(cpbitnode::consensus::merkleRoot(pairHashes) != cpbitnode::consensus::merkleRoot(singleHash));
    EXPECT_TRUE(cpbitnode::consensus::merkleRoot(singleHash) == left);
}

void testBlock1MerkleRootMatchesHeader() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    const auto computed = cpbitnode::consensus::blockMerkleRoot(block.transactions);
    EXPECT_TRUE(computed == block.header.merkleRoot);
}

void testTransactionRoundtripCoinbase() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    EXPECT_EQ(block.transactions.size(), 1u);
    EXPECT_TRUE(cpbitnode::messages::transactionIsCoinbase(block.transactions[0]));
    const auto [restored, offset] = cpbitnode::messages::deserializeTransaction(payload, 81);
    EXPECT_EQ(offset, payload.size());
    EXPECT_TRUE(transactionsEqual(restored, block.transactions[0]));
}

void testDecodeBip34HeightFromBlock1() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    const auto height = cpbitnode::consensus::decodeBip34Height(block.transactions[0].inputs[0].scriptSig);
    EXPECT_TRUE(height.has_value());
    EXPECT_EQ(*height, 1);
}

void testWitnessCommitmentBlock1() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    bool threw = false;
    try {
        cpbitnode::consensus::validateWitnessCommitment(block.transactions[0], block.transactions);
    } catch (const std::exception&) {
        threw = true;
    }
    EXPECT_TRUE(!threw);
}

void testBlock1HeaderHashAndSubsidy() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    EXPECT_EQ(cpbitnode::messages::blockHashHex(block.header),
              "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28");
    EXPECT_EQ(block.transactions[0].outputs[0].value, 50LL * 100'000'000);

    auto genesisHash = fromHex(cpbitnode::chain::testnet4().genesisHash);
    std::reverse(genesisHash.begin(), genesisHash.end());
    EXPECT_TRUE(block.header.prevBlock == genesisHash);
}

void testBlockDeserializeRejectsTrailingBytes() {
    auto payload = readFixtureBlock();
    payload.push_back(0x00);
    bool threw = false;
    try {
        (void)cpbitnode::consensus::Block::deserialize(payload);
    } catch (const std::runtime_error&) {
        threw = true;
    }
    EXPECT_TRUE(threw);
}

void testIsOpReturnAndSpendable() {
    const std::vector<std::uint8_t> opReturn{0x6A, 0x00};
    const std::vector<std::uint8_t> p2pkh{0x76, 0xA9, 0x14};
    EXPECT_TRUE(cpbitnode::consensus::isOpReturn(opReturn));
    EXPECT_TRUE(!cpbitnode::consensus::isSpendableOutput(opReturn));
    EXPECT_TRUE(cpbitnode::consensus::isSpendableOutput(p2pkh));
}

void testDecodeBip34HeightVariants() {
    EXPECT_TRUE(cpbitnode::consensus::decodeBip34Height(std::vector<std::uint8_t>{0x51}).value_or(-1) == 1);
    EXPECT_TRUE(cpbitnode::consensus::decodeBip34Height(std::vector<std::uint8_t>{0x01, 0x05}).value_or(-1) == 5);
    EXPECT_TRUE(!cpbitnode::consensus::decodeBip34Height({}).has_value());
    EXPECT_TRUE(!cpbitnode::consensus::decodeBip34Height(std::vector<std::uint8_t>{0x01}).has_value());
}

void testValidateBip34HeightRejectsMismatch() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    bool threw = false;
    try {
        cpbitnode::consensus::validateBip34Height(block.transactions[0], 2);
    } catch (const cpbitnode::consensus::CoinbaseError& ex) {
        threw = true;
        const std::string msg = ex.what();
        EXPECT_TRUE(msg.find("BIP34 height mismatch") != std::string::npos);
    }
    EXPECT_TRUE(threw);
}

void testValidateBip34HeightRejectsMissingInput() {
    cpbitnode::messages::Transaction coinbase;
    coinbase.outputs.push_back(cpbitnode::messages::TxOut{50LL * 100'000'000, {0x51}});
    bool threw = false;
    try {
        cpbitnode::consensus::validateBip34Height(coinbase, 1);
    } catch (const cpbitnode::consensus::CoinbaseError& ex) {
        threw = true;
        const std::string msg = ex.what();
        EXPECT_TRUE(msg.find("coinbase has no inputs") != std::string::npos);
    }
    EXPECT_TRUE(threw);
}

void testValidateBip34HeightSkipsGenesis() {
    cpbitnode::messages::Transaction coinbase;
    coinbase.inputs.push_back(cpbitnode::messages::TxIn{{}, {0x01, 0x02}, 0xFFFFFFFF});
    bool threw = false;
    try {
        cpbitnode::consensus::validateBip34Height(coinbase, 0);
    } catch (const cpbitnode::consensus::CoinbaseError&) {
        threw = true;
    }
    EXPECT_TRUE(!threw);
}

void testWitnessCommitmentRejectsMismatch() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    auto corrupt = block.transactions[0];
    if (!corrupt.witness.empty() && !corrupt.witness[0].empty() && !corrupt.witness[0][0].empty()) {
        corrupt.witness[0][0][0] ^= 0xFF;
    }
    bool threw = false;
    try {
        cpbitnode::consensus::validateWitnessCommitment(corrupt, block.transactions);
    } catch (const std::exception& ex) {
        threw = true;
        const std::string msg = ex.what();
        EXPECT_TRUE(msg.find("witness commitment mismatch") != std::string::npos);
    }
    EXPECT_TRUE(threw);
}

void testWitnessCommitmentRejectsMissingReserved() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    auto corrupt = block.transactions[0];
    corrupt.witness.clear();
    bool threw = false;
    try {
        cpbitnode::consensus::validateWitnessCommitment(corrupt, block.transactions);
    } catch (const std::exception& ex) {
        threw = true;
        const std::string msg = ex.what();
        EXPECT_TRUE(msg.find("coinbase witness stack missing reserved value") != std::string::npos);
    }
    EXPECT_TRUE(threw);
}

void testDecodeBip34HeightOpcodeZeroReturnsZero() {
    EXPECT_TRUE(cpbitnode::consensus::decodeBip34Height(std::vector<std::uint8_t>{0x00}).value_or(-1) == 0);
}

void testDecodeBip34HeightRejectsTruncatedPush() {
    EXPECT_TRUE(!cpbitnode::consensus::decodeBip34Height(std::vector<std::uint8_t>{0x05, 0x01}).has_value());
}

void testDecodeBip34HeightRejectsUnknownOpcode() {
    EXPECT_TRUE(!cpbitnode::consensus::decodeBip34Height(std::vector<std::uint8_t>{0x76}).has_value());
}

void testValidateBip34HeightRejectsUndecodableHeight() {
    cpbitnode::messages::Transaction coinbase;
    coinbase.inputs.push_back(cpbitnode::messages::TxIn{{}, {0x76, 0x01}, 0xFFFFFFFF});
    bool threw = false;
    try {
        cpbitnode::consensus::validateBip34Height(coinbase, 1);
    } catch (const cpbitnode::consensus::CoinbaseError& ex) {
        threw = true;
        const std::string msg = ex.what();
        EXPECT_TRUE(msg.find("null") != std::string::npos);
    }
    EXPECT_TRUE(threw);
}

void testWitnessCommitmentRejectsWrongReservedSize() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    auto corrupt = block.transactions[0];
    if (!corrupt.witness.empty() && !corrupt.witness[0].empty()) {
        corrupt.witness[0][0] = {0x01, 0x02};
    }
    bool threw = false;
    try {
        cpbitnode::consensus::validateWitnessCommitment(corrupt, block.transactions);
    } catch (const std::exception& ex) {
        threw = true;
        const std::string msg = ex.what();
        EXPECT_TRUE(msg.find("reserved value must be 32 bytes") != std::string::npos);
    }
    EXPECT_TRUE(threw);
}

void testWitnessCommitmentRejectsMissingCommitmentOutput() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    auto corrupt = block.transactions[0];
    for (auto& output : corrupt.outputs) {
        if (cpbitnode::consensus::extractWitnessCommitment(output.scriptPubkey).has_value()) {
            output.scriptPubkey = {0x51};
        }
    }
    bool threw = false;
    try {
        cpbitnode::consensus::validateWitnessCommitment(corrupt, block.transactions);
    } catch (const std::exception& ex) {
        threw = true;
        const std::string msg = ex.what();
        EXPECT_TRUE(msg.find("coinbase missing witness commitment output") != std::string::npos);
    }
    EXPECT_TRUE(threw);
}

void testExtractWitnessCommitmentReturnsNulloptForNonCommitment() {
    EXPECT_TRUE(!cpbitnode::consensus::extractWitnessCommitment(std::vector<std::uint8_t>{0x51}).has_value());
}

void testHeaderMeetsTargetAcceptsBlock1() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    EXPECT_TRUE(cpbitnode::sync::headerMeetsTarget(block.header));
}

void testCompactToTargetLEBlock1Bits() {
    const auto payload = readFixtureBlock();
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    const auto target = cpbitnode::sync::compactToTargetLE(block.header.bits);
    EXPECT_TRUE(!target.empty());
}

}  // namespace

void registerConsensusTests() {
    RUN_TEST(testBlockSubsidyAtHeightOne);
    RUN_TEST(testBlockSubsidyZeroForNegativeHeight);
    RUN_TEST(testBlockSubsidyZeroAfter64Halvings);
    RUN_TEST(testBlockSubsidyHalvingAt210000);
    RUN_TEST(testSha256DigestKnownVector);
    RUN_TEST(testHash160KnownVector);
    RUN_TEST(testMerkleRootDuplicatesLastHash);
    RUN_TEST(testBlock1MerkleRootMatchesHeader);
    RUN_TEST(testTransactionRoundtripCoinbase);
    RUN_TEST(testDecodeBip34HeightFromBlock1);
    RUN_TEST(testWitnessCommitmentBlock1);
    RUN_TEST(testBlock1HeaderHashAndSubsidy);
    RUN_TEST(testBlockDeserializeRejectsTrailingBytes);
    RUN_TEST(testIsOpReturnAndSpendable);
    RUN_TEST(testDecodeBip34HeightVariants);
    RUN_TEST(testValidateBip34HeightRejectsMismatch);
    RUN_TEST(testValidateBip34HeightRejectsMissingInput);
    RUN_TEST(testValidateBip34HeightSkipsGenesis);
    RUN_TEST(testWitnessCommitmentRejectsMismatch);
    RUN_TEST(testWitnessCommitmentRejectsMissingReserved);
    RUN_TEST(testDecodeBip34HeightOpcodeZeroReturnsZero);
    RUN_TEST(testDecodeBip34HeightRejectsTruncatedPush);
    RUN_TEST(testDecodeBip34HeightRejectsUnknownOpcode);
    RUN_TEST(testValidateBip34HeightRejectsUndecodableHeight);
    RUN_TEST(testWitnessCommitmentRejectsWrongReservedSize);
    RUN_TEST(testWitnessCommitmentRejectsMissingCommitmentOutput);
    RUN_TEST(testExtractWitnessCommitmentReturnsNulloptForNonCommitment);
    RUN_TEST(testHeaderMeetsTargetAcceptsBlock1);
    RUN_TEST(testCompactToTargetLEBlock1Bits);
}
