#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::conformance {

struct ScriptCorpusCase {
    std::string fixtureId;
    int height = 0;
    std::string txid;
    std::size_t inputIndex = 0;
    std::vector<std::string> requiredRules;
    std::string expectedResult;
    std::string missingRule;
    messages::Transaction transaction;
    std::vector<std::uint8_t> scriptPubkey;
    std::int64_t amount = 0;
    std::vector<std::pair<std::int64_t, std::vector<std::uint8_t>>> spentPrevouts;
};

struct ScriptCorpusFixtureResult {
    std::string fixtureId;
    std::string result;
    int height = 0;
    std::string txid;
    std::size_t inputIndex = 0;
    std::vector<std::string> requiredRules;
    std::string missingRule;
    std::string failure;
    std::string failureType;
};

struct ScriptCorpusRunResult {
    std::string implementation = "CppNode";
    std::string category = "script_corpus";
    std::string runtimeSurface = "host";
    std::string capturedAt;
    std::string commit;
    std::string manifest;
    int fixtureCount = 0;
    int passed = 0;
    int failed = 0;
    std::string result;
    std::vector<ScriptCorpusFixtureResult> results;
};

std::filesystem::path repoRoot();
std::filesystem::path defaultManifestPath();
std::vector<ScriptCorpusCase> loadCases(const std::filesystem::path& manifestPath = defaultManifestPath());
void verifyCase(const ScriptCorpusCase& case_);
ScriptCorpusFixtureResult runCase(const ScriptCorpusCase& case_);
ScriptCorpusRunResult runCorpus(const std::filesystem::path& manifestPath = defaultManifestPath());
std::string runCorpusJson(const ScriptCorpusRunResult& run);
std::string gitCommit();

}  // namespace cpbitnode::conformance
