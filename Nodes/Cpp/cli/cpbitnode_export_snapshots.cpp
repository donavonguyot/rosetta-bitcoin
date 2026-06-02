#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/util/json.hpp"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

std::string utcNowIso() {
    const auto now = std::chrono::system_clock::now();
    const auto t = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
    gmtime_r(&t, &tm);
    std::ostringstream oss;
    oss << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S") << "+00:00";
    return oss.str();
}

void writeJsonFile(const std::filesystem::path& path, const std::string& json) {
    std::ofstream out(path);
    if (!out) {
        throw std::runtime_error("failed to write " + path.string());
    }
    out << json;
    if (!json.empty() && json.back() != '\n') {
        out << '\n';
    }
}

std::string jsonRowObject(const std::map<std::string, std::string>& row) {
    std::map<std::string, std::string> fields;
    for (const auto& [k, v] : row) {
        fields[k] = cpbitnode::util::jsonString(v);
    }
    return cpbitnode::util::jsonObject(fields);
}

std::string prettyJsonArray(const std::vector<std::string>& items, int indent = 2) {
    const std::string pad(indent, ' ');
    std::ostringstream out;
    out << "[\n";
    for (std::size_t i = 0; i < items.size(); ++i) {
        if (i > 0) {
            out << ",\n";
        }
        out << pad << items[i];
    }
    if (!items.empty()) {
        out << '\n';
    }
    out << "]";
    return out.str();
}

void printUsage(const char* argv0) {
    std::cerr << "usage: " << argv0 << " [--db PATH] [--out DIR] [--chain NAME]\n";
}

}  // namespace

int main(int argc, char** argv) {
    try {
        cpbitnode::config::Settings settings = cpbitnode::config::Settings::fromEnv();
        std::string outDir = "snapshots";
        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            if (arg == "--db" && i + 1 < argc) {
                settings.dbPath = argv[++i];
            } else if (arg == "--out" && i + 1 < argc) {
                outDir = argv[++i];
            } else if (arg == "--chain" && i + 1 < argc) {
                settings.chain = argv[++i];
            } else if (arg == "--help" || arg == "-h") {
                printUsage(argv[0]);
                return 0;
            } else {
                printUsage(argv[0]);
                return 1;
            }
        }

        const std::filesystem::path outPath = std::filesystem::absolute(outDir);
        std::filesystem::create_directories(outPath);
        const std::string dbPath = settings.resolvedDbPath();
        cpbitnode::db::ProjectTracker tracker(dbPath);

        const std::string exportedAt = utcNowIso();
        const std::string summary = tracker.summaryJson(settings.chain);
        std::string statusJson = summary;
        if (!statusJson.empty() && statusJson.back() == '}') {
            statusJson.pop_back();
            statusJson += ",\"exported_at\":" + cpbitnode::util::jsonString(exportedAt) + "}";
        }
        writeJsonFile(outPath / "status.json", statusJson);

        std::vector<std::string> phaseItems;
        for (const auto& phase : tracker.listPhases()) {
            phaseItems.push_back(jsonRowObject(phase));
        }
        writeJsonFile(outPath / "phases.json", prettyJsonArray(phaseItems));

        writeJsonFile(outPath / "wire.json", tracker.wireProgressJson());

        std::vector<std::string> capItems;
        for (const auto& cap : tracker.listWireCapabilities()) {
            capItems.push_back(jsonRowObject(cap));
        }
        writeJsonFile(outPath / "capabilities.json", prettyJsonArray(capItems));

        const auto schemaVersion = tracker.getMeta("schema_version").value_or("0");
        std::ostringstream manifest;
        manifest << "{\n";
        manifest << "  \"exported_at\": " << cpbitnode::util::jsonString(exportedAt) << ",\n";
        manifest << "  \"db_path\": " << cpbitnode::util::jsonString(dbPath) << ",\n";
        manifest << "  \"chain\": " << cpbitnode::util::jsonString(settings.chain) << ",\n";
        manifest << "  \"schema_version\": " << cpbitnode::util::jsonString(schemaVersion) << ",\n";
        manifest << "  \"files\": [\n";
        manifest << "    \"status.json\",\n";
        manifest << "    \"phases.json\",\n";
        manifest << "    \"wire.json\",\n";
        manifest << "    \"capabilities.json\"\n";
        manifest << "  ]\n";
        manifest << "}";
        writeJsonFile(outPath / "manifest.json", manifest.str());

        std::cout << "Exported snapshots to " << outPath.string() << '\n';
        return 0;
    } catch (const std::exception& ex) {
        std::cerr << ex.what() << '\n';
        return 1;
    }
}
