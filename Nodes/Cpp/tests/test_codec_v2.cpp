#include "test_support.hpp"

#include "cpbitnode/db/codec_v2.hpp"

#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>

#ifndef CPBITNODE_REPO_ROOT
#define CPBITNODE_REPO_ROOT "../.."
#endif

void registerCodecV2Tests();

namespace {

std::string readFixture() {
    const auto path = std::filesystem::path(CPBITNODE_REPO_ROOT) /
                      "NodeCore/conformance/fixtures/chainstate_codec_v2_vectors.json";
    std::ifstream in(path);
    if (!in) {
        throw std::runtime_error("failed to open codec fixture: " + path.string());
    }
    std::ostringstream out;
    out << in.rdbuf();
    return out.str();
}

std::string stringField(const std::string& json, const std::string& name) {
    const std::regex re("\"" + name + "\"\\s*:\\s*\"([^\"]*)\"");
    std::smatch match;
    if (!std::regex_search(json, match, re)) {
        throw std::runtime_error("missing string field " + name);
    }
    return match[1].str();
}

int intField(const std::string& object, const std::string& name) {
    const std::regex re("\"" + name + "\"\\s*:\\s*([0-9]+)");
    std::smatch match;
    if (!std::regex_search(object, match, re)) {
        throw std::runtime_error("missing int field " + name);
    }
    return std::stoi(match[1].str());
}

std::int64_t int64Field(const std::string& object, const std::string& name) {
    const std::regex re("\"" + name + "\"\\s*:\\s*([0-9]+)");
    std::smatch match;
    if (!std::regex_search(object, match, re)) {
        throw std::runtime_error("missing int64 field " + name);
    }
    return std::stoll(match[1].str());
}

bool boolField(const std::string& object, const std::string& name) {
    const std::regex re("\"" + name + "\"\\s*:\\s*(true|false)");
    std::smatch match;
    if (!std::regex_search(object, match, re)) {
        throw std::runtime_error("missing bool field " + name);
    }
    return match[1].str() == "true";
}

std::string hexOfString(const std::string& bytes) {
    return cpbitnode::db::codec_v2::bytesToHex(std::vector<std::uint8_t>(bytes.begin(), bytes.end()));
}

std::string objectFor(const std::string& json, const std::string& name) {
    const auto marker = "\"" + name + "\"";
    const auto start = json.find(marker);
    if (start == std::string::npos) {
        throw std::runtime_error("missing object " + name);
    }
    const auto open = json.find('{', start);
    int depth = 0;
    for (std::size_t pos = open; pos < json.size(); ++pos) {
        if (json[pos] == '{') {
            ++depth;
        } else if (json[pos] == '}') {
            --depth;
            if (depth == 0) {
                return json.substr(open, pos - open + 1);
            }
        }
    }
    throw std::runtime_error("unterminated object " + name);
}

void testCodecV2GoldenVectors() {
    const auto json = readFixture();
    const auto chain = stringField(json, "chain");
    const auto txid = cpbitnode::db::codec_v2::hexToBytes(stringField(json, "txid_internal_hex"));
    const auto blockHash = cpbitnode::db::codec_v2::hexToBytes(stringField(json, "block_hash_internal_hex"));
    const auto script = cpbitnode::db::codec_v2::hexToBytes(stringField(json, "script_pubkey_hex"));

    const auto utxo = objectFor(json, "utxo");
    cpbitnode::db::StoredUtxo stored{txid, intField(utxo, "vout"), intField(utxo, "height"),
                                     int64Field(utxo, "value_sats"), script, boolField(utxo, "coinbase")};
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::keyUtxo(chain, txid, stored.vout)),
              stringField(utxo, "key_hex"));
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::encodeUtxoValue(stored)), stringField(utxo, "value_hex"));

    const auto undo = objectFor(json, "undo");
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::keyUndo(chain, intField(undo, "height"))),
              stringField(undo, "key_hex"));
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::encodeUndoValue({stored})), stringField(undo, "value_hex"));

    const auto tip = objectFor(json, "tip");
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::keyTip(chain)), stringField(tip, "key_hex"));
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::encodeTipValue(intField(tip, "height"), blockHash)),
              stringField(tip, "value_hex"));

    const auto blockIndex = objectFor(json, "block_index");
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::keyBlockIndex(chain, intField(blockIndex, "height"))),
              stringField(blockIndex, "key_hex"));
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::encodeBlockIndexValue(
                  blockHash, intField(blockIndex, "file_number"), intField(blockIndex, "file_offset"),
                  intField(blockIndex, "block_size"))),
              stringField(blockIndex, "value_hex"));

    const auto header = objectFor(json, "header");
    const auto headerBytes = cpbitnode::db::codec_v2::hexToBytes(stringField(header, "serialized_header_hex"));
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::keyHeader(chain, intField(header, "height"))),
              stringField(header, "key_hex"));
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::encodeHeaderValue(headerBytes)), stringField(header, "value_hex"));

    const auto metadata = objectFor(json, "metadata");
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::keyMetadata(stringField(metadata, "name"))),
              stringField(metadata, "key_hex"));
    EXPECT_EQ(hexOfString(cpbitnode::db::codec_v2::encodeMetadataValue(stringField(metadata, "value"))),
              stringField(metadata, "value_hex"));
}

}  // namespace

void registerCodecV2Tests() {
    RUN_TEST(testCodecV2GoldenVectors);
}
