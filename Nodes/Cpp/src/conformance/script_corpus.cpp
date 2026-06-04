#include "cpbitnode/conformance/script_corpus.hpp"

#include "cpbitnode/consensus/script/verify.hpp"
#include "cpbitnode/util/json.hpp"

#include <array>
#include <cctype>
#include <ctime>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace cpbitnode::conformance {
namespace {

std::string readFile(const std::filesystem::path& path) {
    std::ifstream in(path);
    if (!in) {
        throw std::runtime_error("failed to read file: " + path.string());
    }
    std::ostringstream out;
    out << in.rdbuf();
    return out.str();
}

void skipWs(const std::string& json, std::size_t& pos) {
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos])) != 0) {
        ++pos;
    }
}

void expectChar(const std::string& json, std::size_t& pos, char ch) {
    skipWs(json, pos);
    if (pos >= json.size() || json[pos] != ch) {
        throw std::runtime_error("unexpected JSON token");
    }
    ++pos;
}

std::string parseJsonString(const std::string& json, std::size_t& pos) {
    skipWs(json, pos);
    if (pos >= json.size() || json[pos] != '"') {
        throw std::runtime_error("expected JSON string");
    }
    ++pos;
    std::string out;
    while (pos < json.size()) {
        const char ch = json[pos++];
        if (ch == '"') {
            return out;
        }
        if (ch == '\\') {
            if (pos >= json.size()) {
                throw std::runtime_error("truncated JSON escape");
            }
            const char esc = json[pos++];
            switch (esc) {
                case '"':
                    out.push_back('"');
                    break;
                case '\\':
                    out.push_back('\\');
                    break;
                case 'n':
                    out.push_back('\n');
                    break;
                case 'r':
                    out.push_back('\r');
                    break;
                case 't':
                    out.push_back('\t');
                    break;
                default:
                    out.push_back(esc);
                    break;
            }
            continue;
        }
        out.push_back(ch);
    }
    throw std::runtime_error("unterminated JSON string");
}

bool trySkipJsonNull(const std::string& json, std::size_t& pos) {
    skipWs(json, pos);
    if (pos + 4 <= json.size() && json.compare(pos, 4, "null") == 0) {
        pos += 4;
        return true;
    }
    return false;
}

std::int64_t parseJsonNumber(const std::string& json, std::size_t& pos) {
    skipWs(json, pos);
    if (trySkipJsonNull(json, pos)) {
        return 0;
    }
    const std::size_t start = pos;
    if (pos < json.size() && (json[pos] == '-' || json[pos] == '+')) {
        ++pos;
    }
    while (pos < json.size() && std::isdigit(static_cast<unsigned char>(json[pos])) != 0) {
        ++pos;
    }
    return std::stoll(json.substr(start, pos - start));
}

void skipJsonValue(const std::string& json, std::size_t& pos) {
    skipWs(json, pos);
    if (pos >= json.size()) {
        throw std::runtime_error("unexpected end of JSON");
    }
    const char ch = json[pos];
    if (ch == '"') {
        parseJsonString(json, pos);
        return;
    }
    if (ch == '{') {
        ++pos;
        skipWs(json, pos);
        if (pos < json.size() && json[pos] == '}') {
            ++pos;
            return;
        }
        while (pos < json.size()) {
            parseJsonString(json, pos);
            expectChar(json, pos, ':');
            skipJsonValue(json, pos);
            skipWs(json, pos);
            if (pos < json.size() && json[pos] == ',') {
                ++pos;
                continue;
            }
            break;
        }
        expectChar(json, pos, '}');
        return;
    }
    if (ch == '[') {
        ++pos;
        skipWs(json, pos);
        if (pos < json.size() && json[pos] == ']') {
            ++pos;
            return;
        }
        while (pos < json.size()) {
            skipJsonValue(json, pos);
            skipWs(json, pos);
            if (pos < json.size() && json[pos] == ',') {
                ++pos;
                continue;
            }
            break;
        }
        expectChar(json, pos, ']');
        return;
    }
    if (ch == 't' || ch == 'f' || ch == 'n') {
        while (pos < json.size() && std::isalpha(static_cast<unsigned char>(json[pos])) != 0) {
            ++pos;
        }
        return;
    }
    parseJsonNumber(json, pos);
}

std::optional<std::string> objectStringField(const std::string& json, std::size_t start, std::size_t end,
                                             const std::string& key) {
    std::size_t pos = start;
    expectChar(json, pos, '{');
    skipWs(json, pos);
    if (pos < end && json[pos] == '}') {
        return std::nullopt;
    }
    while (pos < end) {
        const auto field = parseJsonString(json, pos);
        expectChar(json, pos, ':');
        if (field == key) {
            skipWs(json, pos);
            if (trySkipJsonNull(json, pos)) {
                return std::nullopt;
            }
            return parseJsonString(json, pos);
        }
        skipJsonValue(json, pos);
        skipWs(json, pos);
        if (pos < end && json[pos] == ',') {
            ++pos;
            continue;
        }
        break;
    }
    return std::nullopt;
}

std::optional<std::int64_t> objectNumberField(const std::string& json, std::size_t start, std::size_t end,
                                              const std::string& key) {
    std::size_t pos = start;
    expectChar(json, pos, '{');
    skipWs(json, pos);
    if (pos < end && json[pos] == '}') {
        return std::nullopt;
    }
    while (pos < end) {
        const auto field = parseJsonString(json, pos);
        expectChar(json, pos, ':');
        if (field == key) {
            skipWs(json, pos);
            if (trySkipJsonNull(json, pos)) {
                return std::nullopt;
            }
            return parseJsonNumber(json, pos);
        }
        skipJsonValue(json, pos);
        skipWs(json, pos);
        if (pos < end && json[pos] == ',') {
            ++pos;
            continue;
        }
        break;
    }
    return std::nullopt;
}

std::optional<std::string> extractFilesCategoryPath(std::string_view slice, const std::string& category) {
    const std::string filesKey = "\"files\"";
    const std::string categoryKey = "\"" + category + "\"";
    const auto filesPos = slice.find(filesKey);
    if (filesPos == std::string_view::npos) {
        return std::nullopt;
    }
    const auto categoryPos = slice.find(categoryKey, filesPos);
    if (categoryPos == std::string_view::npos) {
        return std::nullopt;
    }
    const auto arrayStart = slice.find('[', categoryPos);
    if (arrayStart == std::string_view::npos) {
        return std::nullopt;
    }
    const auto firstQuote = slice.find('"', arrayStart + 1);
    if (firstQuote == std::string_view::npos) {
        return std::nullopt;
    }
    const auto secondQuote = slice.find('"', firstQuote + 1);
    if (secondQuote == std::string_view::npos) {
        return std::nullopt;
    }
    return std::string(slice.substr(firstQuote + 1, secondQuote - firstQuote - 1));
}

std::vector<std::uint8_t> hexToBytes(const std::string& hex) {
    std::string cleaned;
    cleaned.reserve(hex.size());
    for (const char ch : hex) {
        if (std::isspace(static_cast<unsigned char>(ch)) == 0) {
            cleaned.push_back(ch);
        }
    }
    if (cleaned.size() % 2 != 0) {
        throw std::runtime_error("invalid hex length");
    }
    std::vector<std::uint8_t> out;
    out.reserve(cleaned.size() / 2);
    auto nybble = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        throw std::runtime_error("invalid hex digit");
    };
    for (std::size_t i = 0; i < cleaned.size(); i += 2) {
        out.push_back(static_cast<std::uint8_t>((nybble(cleaned[i]) << 4) | nybble(cleaned[i + 1])));
    }
    return out;
}

std::pair<std::int64_t, std::vector<std::uint8_t>> prevoutTuple(const std::string& json, std::size_t start,
                                                                std::size_t end) {
    std::size_t pos = start;
    expectChar(json, pos, '{');
    std::optional<std::int64_t> amount;
    std::optional<std::string> spkHex;
    skipWs(json, pos);
    while (pos < end) {
        const auto key = parseJsonString(json, pos);
        expectChar(json, pos, ':');
        if (key == "amount" || key == "amount_sats" || key == "value") {
            amount = parseJsonNumber(json, pos);
        } else if (key == "spk" || key == "script_pubkey" || key == "scriptPubKey") {
            spkHex = parseJsonString(json, pos);
        } else {
            skipJsonValue(json, pos);
        }
        skipWs(json, pos);
        if (pos < end && json[pos] == ',') {
            ++pos;
            continue;
        }
        break;
    }
    expectChar(json, pos, '}');
    if (!amount.has_value() || !spkHex.has_value()) {
        throw std::runtime_error("prevout missing amount or scriptPubKey");
    }
    return {*amount, hexToBytes(*spkHex)};
}

std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> parsePrevoutsLoose(const std::string& json) {
    std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> out;
    std::size_t searchFrom = 0;
    while (searchFrom < json.size()) {
        const auto amountKey = json.find("\"amount\"", searchFrom);
        if (amountKey == std::string::npos) {
            break;
        }
        std::size_t pos = amountKey + 8;
        expectChar(json, pos, ':');
        const auto amount = parseJsonNumber(json, pos);
        const auto spkKey = json.find("\"spk\"", pos);
        if (spkKey == std::string::npos) {
            const auto scriptKey = json.find("\"script_pubkey\"", pos);
            if (scriptKey == std::string::npos) {
                const auto scriptKey2 = json.find("\"scriptPubKey\"", pos);
                if (scriptKey2 == std::string::npos) {
                    break;
                }
                pos = scriptKey2 + 15;
            } else {
                pos = scriptKey + 16;
            }
        } else {
            pos = spkKey + 5;
        }
        expectChar(json, pos, ':');
        const auto spkHex = parseJsonString(json, pos);
        out.push_back({amount, hexToBytes(spkHex)});
        searchFrom = pos;
    }
    return out;
}

std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> parsePrevoutsArray(const std::string& json,
                                                                                   std::size_t start,
                                                                                   std::size_t end) {
    std::size_t pos = start;
    expectChar(json, pos, '[');
    std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> out;
    skipWs(json, pos);
    if (pos < end && json[pos] == ']') {
        ++pos;
        return out;
    }
    while (pos < end) {
        skipWs(json, pos);
        if (pos < end && json[pos] == ']') {
            break;
        }
        out.push_back(prevoutTuple(json, pos, end));
        skipWs(json, pos);
        if (pos < end && json[pos] == ',') {
            ++pos;
            continue;
        }
        break;
    }
    skipWs(json, pos);
    expectChar(json, pos, ']');
    return out;
}

std::vector<std::string> objectStringArrayField(const std::string& json, std::size_t start, std::size_t end,
                                                const std::string& key) {
    std::size_t pos = start;
    expectChar(json, pos, '{');
    skipWs(json, pos);
    while (pos < end) {
        const auto field = parseJsonString(json, pos);
        expectChar(json, pos, ':');
        if (field == key) {
            std::vector<std::string> values;
            expectChar(json, pos, '[');
            skipWs(json, pos);
            if (pos < end && json[pos] == ']') {
                ++pos;
                return values;
            }
            while (pos < end) {
                values.push_back(parseJsonString(json, pos));
                skipWs(json, pos);
                if (pos < end && json[pos] == ',') {
                    ++pos;
                    continue;
                }
                break;
            }
            expectChar(json, pos, ']');
            return values;
        }
        skipJsonValue(json, pos);
        skipWs(json, pos);
        if (pos < end && json[pos] == ',') {
            ++pos;
            continue;
        }
        break;
    }
    return {};
}

struct ManifestEntry {
    std::size_t objectStart = 0;
    std::size_t objectEnd = 0;
};

std::vector<ManifestEntry> parseManifestFixtureObjects(const std::string& json) {
    const auto fixturesKey = json.find("\"fixtures\"");
    if (fixturesKey == std::string::npos) {
        throw std::runtime_error("manifest missing fixtures key");
    }
    std::size_t pos = fixturesKey;
    pos = json.find('[', pos);
    if (pos == std::string::npos) {
        throw std::runtime_error("manifest missing fixtures array");
    }
    ++pos;
    std::vector<ManifestEntry> entries;
    skipWs(json, pos);
    if (pos < json.size() && json[pos] == ']') {
        return entries;
    }
    while (pos < json.size()) {
        skipWs(json, pos);
        if (pos < json.size() && json[pos] == ']') {
            break;
        }
        if (json[pos] != '{') {
            throw std::runtime_error("expected fixture object");
        }
        const std::size_t start = pos;
        skipJsonValue(json, pos);
        entries.push_back({start, pos});
        skipWs(json, pos);
        if (pos < json.size() && json[pos] == ',') {
            ++pos;
            continue;
        }
        break;
    }
    return entries;
}

std::pair<std::int64_t, std::vector<std::uint8_t>> targetPrevout(
    const std::string& json, std::size_t start, std::size_t end,
    const std::filesystem::path& manifestDir,
    const std::pair<std::int64_t, std::vector<std::uint8_t>>& fallback) {
    const std::string_view slice(json.data() + start, end - start);
    const auto amount = objectNumberField(json, start, end, "prev_amount_sats");
    std::optional<std::string> spkHex;
    if (const auto rel = extractFilesCategoryPath(slice, "prev_spk")) {
        spkHex = readFile(manifestDir / *rel);
        while (!spkHex->empty() && std::isspace(static_cast<unsigned char>(spkHex->back())) != 0) {
            spkHex->pop_back();
        }
    }
    if (!spkHex.has_value() || spkHex->empty()) {
        spkHex = objectStringField(json, start, end, "spent_script_pubkey");
    }
    if (amount.has_value() && spkHex.has_value() && !spkHex->empty()) {
        return {*amount, hexToBytes(*spkHex)};
    }
    return fallback;
}

std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> alignSpentPrevouts(
    const std::string& json, std::size_t start, std::size_t end, const std::filesystem::path& manifestDir,
    const messages::Transaction& tx,
    std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts) {
    const auto inputIndex = static_cast<std::size_t>(*objectNumberField(json, start, end, "input_index"));
    if (spentPrevouts.size() == tx.inputs.size()) {
        return spentPrevouts;
    }
    const auto fallback = spentPrevouts.empty()
                              ? std::pair<std::int64_t, std::vector<std::uint8_t>>{0, {}}
                              : spentPrevouts.front();
    const auto target = targetPrevout(json, start, end, manifestDir, fallback);
    while (spentPrevouts.size() < tx.inputs.size()) {
        spentPrevouts.emplace_back(0, std::vector<std::uint8_t>{});
    }
    if (inputIndex < spentPrevouts.size()) {
        spentPrevouts[inputIndex] = target;
    }
    return spentPrevouts;
}

std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevoutsFromEntry(
    const std::string& json, std::size_t start, std::size_t end, const std::filesystem::path& manifestDir) {
    const std::string_view slice(json.data() + start, end - start);
    if (const auto rel = extractFilesCategoryPath(slice, "prevouts")) {
        const auto prevoutsJson = readFile(manifestDir / *rel);
        return parsePrevoutsLoose(prevoutsJson);
    }
    const auto amount = objectNumberField(json, start, end, "prev_amount_sats");
    std::optional<std::string> spkHex;
    if (const auto rel = extractFilesCategoryPath(slice, "prev_spk")) {
        spkHex = readFile(manifestDir / *rel);
        while (!spkHex->empty() && std::isspace(static_cast<unsigned char>(spkHex->back())) != 0) {
            spkHex->pop_back();
        }
    }
    if (!spkHex.has_value() || spkHex->empty()) {
        spkHex = objectStringField(json, start, end, "spent_script_pubkey");
    }
    if (!amount.has_value() || !spkHex.has_value() || spkHex->empty()) {
        throw std::runtime_error("fixture has no usable prevout data");
    }
    return {{*amount, hexToBytes(*spkHex)}};
}

std::string isoUtcNow() {
    const auto now = std::chrono::system_clock::now();
    const auto t = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
    const std::tm* gmt = std::gmtime(&t);
    if (gmt != nullptr) {
        tm = *gmt;
    }
    std::ostringstream out;
    out << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S+00:00");
    return out.str();
}

}  // namespace

std::filesystem::path repoRoot() {
#ifdef CPBITNODE_REPO_ROOT
    return std::filesystem::path(CPBITNODE_REPO_ROOT);
#else
    auto dir = std::filesystem::current_path();
    for (int depth = 0; depth < 8; ++depth) {
        if (std::filesystem::exists(dir / "Shared") && std::filesystem::exists(dir / "Nodes" / "Cpp")) {
            return dir;
        }
        if (!dir.has_parent_path()) {
            break;
        }
        dir = dir.parent_path();
    }
    throw std::runtime_error("could not locate repository root");
#endif
}

std::filesystem::path defaultManifestPath() {
    return repoRoot() / "Nodes/Shared/conformance/fixtures/scripts/manifest.json";
}

std::vector<ScriptCorpusCase> loadCases(const std::filesystem::path& manifestPath) {
    const auto json = readFile(manifestPath);
    const auto entries = parseManifestFixtureObjects(json);
    std::vector<ScriptCorpusCase> cases;
    cases.reserve(entries.size());
    const auto manifestDir = manifestPath.parent_path();

    for (const auto& entry : entries) {
        ScriptCorpusCase case_;
        try {
        case_.fixtureId = *objectStringField(json, entry.objectStart, entry.objectEnd, "fixture_id");
        try {
            if (const auto height = objectNumberField(json, entry.objectStart, entry.objectEnd, "height")) {
                case_.height = static_cast<int>(*height);
            } else {
                throw std::runtime_error("missing height");
            }
        } catch (const std::exception& error) {
            throw std::runtime_error(std::string("height: ") + error.what());
        }
        try {
            case_.txid = *objectStringField(json, entry.objectStart, entry.objectEnd, "txid");
        } catch (const std::exception& error) {
            throw std::runtime_error(std::string("txid: ") + error.what());
        }
        try {
            if (const auto inputIndex = objectNumberField(json, entry.objectStart, entry.objectEnd, "input_index")) {
                case_.inputIndex = static_cast<std::size_t>(*inputIndex);
            } else {
                throw std::runtime_error("missing input_index");
            }
        } catch (const std::exception& error) {
            throw std::runtime_error(std::string("input_index: ") + error.what());
        }
        try {
            case_.requiredRules =
                objectStringArrayField(json, entry.objectStart, entry.objectEnd, "required_rules");
        } catch (const std::exception& error) {
            throw std::runtime_error(std::string("required_rules: ") + error.what());
        }
        try {
            if (const auto expected = objectStringField(json, entry.objectStart, entry.objectEnd, "expected_result")) {
                case_.expectedResult = *expected;
            } else {
                case_.expectedResult = "valid";
            }
        } catch (const std::exception& error) {
            throw std::runtime_error(std::string("expected_result: ") + error.what());
        }
        try {
            if (const auto missing = objectStringField(json, entry.objectStart, entry.objectEnd, "missing_rule")) {
                case_.missingRule = *missing;
            }
        } catch (const std::exception& error) {
            throw std::runtime_error(std::string("missing_rule: ") + error.what());
        }

        std::optional<std::string> txRel;
        const std::string_view entrySlice(json.data() + entry.objectStart, entry.objectEnd - entry.objectStart);
        txRel = extractFilesCategoryPath(entrySlice, "tx");
        if (!txRel.has_value()) {
            throw std::runtime_error("fixture has no transaction file: " + case_.fixtureId);
        }
        const auto payload = hexToBytes(readFile(manifestDir / *txRel));  // step tx_hex
        auto [tx, consumed] = messages::deserializeTransaction(payload);
        if (consumed != payload.size()) {
            throw std::runtime_error("transaction parser consumed partial payload for " + case_.fixtureId);
        }

        std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts;
        try {
            spentPrevouts = spentPrevoutsFromEntry(json, entry.objectStart, entry.objectEnd, manifestDir);
        } catch (const std::exception& error) {
            throw std::runtime_error(std::string("spent_prevouts: ") + error.what());
        }
        try {
            case_.spentPrevouts =
                alignSpentPrevouts(json, entry.objectStart, entry.objectEnd, manifestDir, tx, std::move(spentPrevouts));
        } catch (const std::exception& error) {
            throw std::runtime_error(std::string("align_prevouts: ") + error.what());
        }
        if (case_.inputIndex >= case_.spentPrevouts.size()) {
            throw std::runtime_error("fixture input_index has no matching prevout: " + case_.fixtureId);
        }
        case_.amount = case_.spentPrevouts[case_.inputIndex].first;
        case_.scriptPubkey = case_.spentPrevouts[case_.inputIndex].second;
        case_.transaction = std::move(tx);
        cases.push_back(std::move(case_));
        } catch (const std::exception& error) {
            const auto partial = case_.fixtureId.empty() ? std::string("<unknown>") : case_.fixtureId;
            throw std::runtime_error("loading fixture " + partial + ": " + error.what());
        } catch (...) {
            const auto partial = case_.fixtureId.empty() ? std::string("<unknown>") : case_.fixtureId;
            throw std::runtime_error("loading fixture " + partial + ": unknown error");
        }
    }
    return cases;
}

void verifyCase(const ScriptCorpusCase& case_) {
    if (case_.expectedResult != "valid") {
        throw std::runtime_error("unsupported expected result for " + case_.fixtureId + ": " + case_.expectedResult);
    }
    consensus::script::verifyTransactionInput(case_.transaction, case_.inputIndex, case_.scriptPubkey, case_.amount,
                                              &case_.spentPrevouts);
}

ScriptCorpusFixtureResult runCase(const ScriptCorpusCase& case_) {
    ScriptCorpusFixtureResult row;
    row.fixtureId = case_.fixtureId;
    row.height = case_.height;
    row.txid = case_.txid;
    row.inputIndex = case_.inputIndex;
    row.requiredRules = case_.requiredRules;
    row.missingRule = case_.missingRule;
    try {
        verifyCase(case_);
        row.result = "passed";
    } catch (const std::exception& error) {
        row.result = "failed";
        row.failure = error.what();
        row.failureType = typeid(error).name();
    }
    return row;
}

std::string gitCommit() {
    std::array<char, 128> buffer{};
    std::string output;
    const auto root = repoRoot().string();
    const std::string cmd = "git -C " + util::jsonString(root) + " rev-parse HEAD 2>/dev/null";
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) {
        return "";
    }
    while (fgets(buffer.data(), static_cast<int>(buffer.size()), pipe) != nullptr) {
        output += buffer.data();
    }
    pclose(pipe);
    while (!output.empty() && (output.back() == '\n' || output.back() == '\r')) {
        output.pop_back();
    }
    return output;
}

ScriptCorpusRunResult runCorpus(const std::filesystem::path& manifestPath) {
    const auto cases = loadCases(manifestPath);
    ScriptCorpusRunResult run;
    run.capturedAt = isoUtcNow();
    run.commit = gitCommit();
    run.manifest = std::filesystem::relative(manifestPath, repoRoot()).string();
    run.fixtureCount = static_cast<int>(cases.size());
    for (const auto& case_ : cases) {
        auto row = runCase(case_);
        run.results.push_back(std::move(row));
        if (run.results.back().result == "passed") {
            ++run.passed;
        } else {
            ++run.failed;
        }
    }
    run.result = run.failed == 0 ? "passed" : "failed";
    return run;
}

std::string runCorpusJson(const ScriptCorpusRunResult& run) {
    std::ostringstream out;
    out << "{\n";
    out << "  \"captured_at\": " << util::jsonString(run.capturedAt) << ",\n";
    out << "  \"category\": " << util::jsonString(run.category) << ",\n";
    out << "  \"commit\": " << util::jsonString(run.commit) << ",\n";
    out << "  \"failed\": " << run.failed << ",\n";
    out << "  \"fixture_count\": " << run.fixtureCount << ",\n";
    out << "  \"implementation\": " << util::jsonString(run.implementation) << ",\n";
    out << "  \"manifest\": " << util::jsonString(run.manifest) << ",\n";
    out << "  \"passed\": " << run.passed << ",\n";
    out << "  \"result\": " << util::jsonString(run.result) << ",\n";
    out << "  \"runtime_surface\": " << util::jsonString(run.runtimeSurface) << ",\n";
    out << "  \"results\": [\n";
    for (std::size_t i = 0; i < run.results.size(); ++i) {
        const auto& row = run.results[i];
        out << "    {\n";
        out << "      \"failure\": " << util::jsonString(row.failure) << ",\n";
        out << "      \"failure_type\": " << util::jsonString(row.failureType) << ",\n";
        out << "      \"fixture_id\": " << util::jsonString(row.fixtureId) << ",\n";
        out << "      \"height\": " << row.height << ",\n";
        out << "      \"input_index\": " << row.inputIndex << ",\n";
        out << "      \"missing_rule\": " << util::jsonString(row.missingRule) << ",\n";
        out << "      \"required_rules\": " << util::jsonArray(row.requiredRules) << ",\n";
        out << "      \"result\": " << util::jsonString(row.result) << ",\n";
        out << "      \"txid\": " << util::jsonString(row.txid) << "\n";
        out << "    }";
        if (i + 1 < run.results.size()) {
            out << ',';
        }
        out << '\n';
    }
    out << "  ]\n";
    out << "}\n";
    return out.str();
}

}  // namespace cpbitnode::conformance
