#include "test_support.hpp"

#include <sys/wait.h>
#include <filesystem>
#include <sstream>
#include <string>

#ifndef CPBITNODE_BUILD_DIR
#define CPBITNODE_BUILD_DIR "build"
#endif

void registerCliSmokeTests();

namespace {

std::string shellQuote(const std::string& value) {
    return "'" + value + "'";
}

int runCommand(const std::string& command, std::string* combinedOutput = nullptr) {
    std::string cmd = command + " 2>&1";
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) {
        return -1;
    }
    std::string output;
    char buffer[512];
    while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
        output += buffer;
    }
    const int rc = pclose(pipe);
    if (combinedOutput) {
        *combinedOutput = std::move(output);
    }
    return rc;
}

std::string exePath(const char* name) {
    return std::string(CPBITNODE_BUILD_DIR) + "/" + name;
}

void testCpbitnodeHelpExitsNonZero() {
    std::string output;
    const int rc = runCommand(exePath("cpbitnode") + " --help", &output);
    EXPECT_TRUE(WIFEXITED(rc));
    EXPECT_TRUE(WEXITSTATUS(rc) == 1);
    EXPECT_TRUE(output.find("usage:") != std::string::npos);
}

void testCpbitnodeDbPrintsSummaryJson() {
    const auto dir = std::filesystem::temp_directory_path() / "cpbitnode_cli_db_smoke";
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    std::string output;
    std::string cmd = exePath("cpbitnode-db") + " --datadir " + shellQuote(dir.string());
    cmd += " --chainstate-backend rocksdb";
    const int rc = runCommand(cmd, &output);
    EXPECT_TRUE(WIFEXITED(rc));
    EXPECT_EQ(WEXITSTATUS(rc), 0);
    EXPECT_TRUE(output.find("\"chain\"") != std::string::npos);
}

void testCpbitnodeHealthcheckPrintsJson() {
    const auto dir = std::filesystem::temp_directory_path() / "cpbitnode_cli_hc_smoke";
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    std::string output;
    const std::string cmd = exePath("cpbitnode-healthcheck") + " --datadir " + shellQuote(dir.string());
    const int rc = runCommand(cmd, &output);
    EXPECT_TRUE(WIFEXITED(rc));
    EXPECT_EQ(WEXITSTATUS(rc), 0);
    EXPECT_TRUE(output.find("\"sync_status\"") != std::string::npos);
}

void testCpbitnodeSyncHelpExitsNonZero() {
    std::string output;
    const int rc = runCommand(exePath("cpbitnode-sync") + " --help", &output);
    EXPECT_TRUE(WIFEXITED(rc));
    EXPECT_EQ(WEXITSTATUS(rc), 1);
    EXPECT_TRUE(output.find("cpbitnode-sync") != std::string::npos);
}

}  // namespace

void registerCliSmokeTests() {
    RUN_TEST(testCpbitnodeHelpExitsNonZero);
    RUN_TEST(testCpbitnodeDbPrintsSummaryJson);
    RUN_TEST(testCpbitnodeHealthcheckPrintsJson);
    RUN_TEST(testCpbitnodeSyncHelpExitsNonZero);
}
