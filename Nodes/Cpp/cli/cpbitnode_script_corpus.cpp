#include "cpbitnode/conformance/script_corpus.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

namespace {

std::string argValue(int argc, char** argv, const std::string& name, const std::string& fallback) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (argv[i] == name) {
            return argv[i + 1];
        }
    }
    return fallback;
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const auto manifestArg = argValue(argc, argv, "--manifest", "");
        const auto manifestPath = manifestArg.empty() ? cpbitnode::conformance::defaultManifestPath()
                                                      : std::filesystem::path(manifestArg);
        const auto resultArg = argValue(argc, argv, "--result-path", "");
        const auto resultPath =
            resultArg.empty()
                ? (cpbitnode::conformance::repoRoot() /
                   "Nodes/Shared/conformance/results/cpp_script_corpus_2026-06-03.json")
                      .string()
                : resultArg;

        auto run = cpbitnode::conformance::runCorpus(manifestPath);
        run.runtimeSurface = argValue(argc, argv, "--runtime-surface", "host");
        const auto json = cpbitnode::conformance::runCorpusJson(run);

        std::filesystem::create_directories(std::filesystem::path(resultPath).parent_path());
        std::ofstream out(resultPath);
        if (!out) {
            throw std::runtime_error("failed to write result file: " + resultPath);
        }
        out << json;

        std::cout << "{\n";
        std::cout << "  \"fixture_count\": " << run.fixtureCount << ",\n";
        std::cout << "  \"passed\": " << run.passed << ",\n";
        std::cout << "  \"failed\": " << run.failed << ",\n";
        std::cout << "  \"result\": \"" << run.result << "\"\n";
        std::cout << "}\n";
        return run.failed == 0 ? 0 : 1;
    } catch (const std::exception& error) {
        std::cerr << "error: " << error.what() << '\n';
        return 1;
    }
}
