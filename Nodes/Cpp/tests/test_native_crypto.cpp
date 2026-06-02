#include "test_support.hpp"

#include "blocks_fixture.hpp"
#include "cpbitnode/consensus/block.hpp"
#include "cpbitnode/consensus/secp256k1.hpp"
#include "cpbitnode/consensus/script/verify.hpp"

#include <array>
#include <algorithm>
#include <string>
#include <vector>

void registerNativeCryptoTests();

namespace {

std::vector<std::uint8_t> hexBytes(const std::string& hex) {
    std::vector<std::uint8_t> out;
    out.reserve(hex.size() / 2);
    for (std::size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoul(hex.substr(i, 2), nullptr, 16)));
    }
    return out;
}

std::array<std::uint8_t, 32> hex32(const std::string& hex) {
    const auto bytes = hexBytes(hex);
    std::array<std::uint8_t, 32> out{};
    std::copy(bytes.begin(), bytes.end(), out.begin());
    return out;
}

std::array<std::uint8_t, 64> hex64(const std::string& hex) {
    const auto bytes = hexBytes(hex);
    std::array<std::uint8_t, 64> out{};
    std::copy(bytes.begin(), bytes.end(), out.begin());
    return out;
}

std::string hexString(const std::array<std::uint8_t, 32>& bytes) {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.reserve(64);
    for (const auto byte : bytes) {
        out.push_back(kHex[(byte >> 4) & 0xf]);
        out.push_back(kHex[byte & 0xf]);
    }
    return out;
}

}  // namespace

void testNativeCryptoEcdsaValidPrivkey1() {
    const auto pubkey = hexBytes("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798");
    const auto msg = hexBytes("281dd50f6f56bc6e867fe73dd614a73c55a647a479704f64804b574cafb0f5c5");
    const auto sig = hexBytes(
        "3044022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4");
    EXPECT_TRUE(cpbitnode::consensus::verifyDerSignature(pubkey, msg, sig));
}

void testNativeCryptoEcdsaWrongMessageInvalid() {
    const auto pubkey = hexBytes("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798");
    const auto msg = hexBytes("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    const auto sig = hexBytes(
        "3044022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4");
    EXPECT_TRUE(!cpbitnode::consensus::verifyDerSignature(pubkey, msg, sig));
}

void testNativeCryptoSchnorrValid() {
    const auto pubkey = hex32("f01d6b9018ab421dd410404cb869072065522bf85734008f105cf385a023a80f");
    const auto msg = hexBytes("3ad22a0437431f2d102505b27048dfce20b1f90b32fe2116130d2bd4b35084b9");
    const auto sig = hex64(
        "632f89d23c32b7d66873d7ef89e730f44f3d063394f8661e4421469979ac5784c80478f3845b4719c92c339fe1032890f9d96b6b0b44a8ea05da6ce88a133b7b");
    EXPECT_TRUE(cpbitnode::consensus::verifySchnorrSignature(pubkey, msg, sig));
}

void testNativeCryptoSchnorrInvalidMutatedSignature() {
    const auto pubkey = hex32("f01d6b9018ab421dd410404cb869072065522bf85734008f105cf385a023a80f");
    const auto msg = hexBytes("3ad22a0437431f2d102505b27048dfce20b1f90b32fe2116130d2bd4b35084b9");
    const auto sig = hex64(
        "622f89d23c32b7d66873d7ef89e730f44f3d063394f8661e4421469979ac5784c80478f3845b4719c92c339fe1032890f9d96b6b0b44a8ea05da6ce88a133b7b");
    EXPECT_TRUE(!cpbitnode::consensus::verifySchnorrSignature(pubkey, msg, sig));
}

void testNativeCryptoTaprootTweakXonly() {
    const auto pubkey = hex32("85a7b790fc9d962493788317e4874a4ab07f1e9c78c773c47f2f6c96df756f05");
    const auto merkleRoot = hexBytes("446ba384864eb34196e08044029fb463d97748e4549dfd0e2612f60d74c4f165");
    const auto [parity, output] = cpbitnode::consensus::taprootTweakPubkeyXonly(pubkey, merkleRoot);
    EXPECT_EQ(parity, 1);
    EXPECT_EQ(hexString(output), std::string("4b3e30f94e0ae82945cbb40d83088b8f3bea370c24c575b7788889ad5e64da8b"));
}

void testBlock739P2wpkhInput142AcceptedWithNativeCrypto() {
    const auto payload = cpbitnode::testfixtures::readFixtureHex("block739.hex");
    const auto block = cpbitnode::consensus::Block::deserialize(payload);
    EXPECT_TRUE(block.transactions.size() > 1);
    const auto& tx = block.transactions[1];
    EXPECT_TRUE(tx.inputs.size() > 142);

    const auto scriptPubkey = hexBytes("0014a54e2a1ec06389203887661535ed118b7d053889");
    std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts(
        tx.inputs.size(), {5000000000LL, scriptPubkey});
    try {
        cpbitnode::consensus::script::verifyTransactionInput(tx, 142, scriptPubkey, 5000000000LL, &spentPrevouts);
    } catch (const std::exception& exc) {
        std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " block 739 input 142 threw " << exc.what() << "\n";
        ++g_failures;
    }
}

void registerNativeCryptoTests() {
    RUN_TEST(testNativeCryptoEcdsaValidPrivkey1);
    RUN_TEST(testNativeCryptoEcdsaWrongMessageInvalid);
    RUN_TEST(testNativeCryptoSchnorrValid);
    RUN_TEST(testNativeCryptoSchnorrInvalidMutatedSignature);
    RUN_TEST(testNativeCryptoTaprootTweakXonly);
    RUN_TEST(testBlock739P2wpkhInput142AcceptedWithNativeCrypto);
}
