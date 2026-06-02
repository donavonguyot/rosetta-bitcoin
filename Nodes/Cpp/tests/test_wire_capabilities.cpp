#include "test_support.hpp"

#include "cpbitnode/db/schema.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/wire/capabilities.hpp"

#include <algorithm>
#include <filesystem>
#include <sqlite3.h>

void registerWireCapabilityTests();

namespace {

void testCapabilityRegistryIsBinary() {
    for (const auto& cap : cpbitnode::wire::capabilities()) {
        EXPECT_TRUE(cap.required || !cap.required);
        EXPECT_TRUE(cap.implemented || !cap.implemented);
    }
}

void testCheckpointPassRequiresAllRequired() {
    std::map<std::string, int> capMap;
    for (const auto& cap : cpbitnode::wire::capabilities()) {
        capMap[cap.id] = 1;
    }
    const auto statuses = cpbitnode::wire::checkpointStatus(capMap);
    for (const auto& [_, row] : statuses) {
        EXPECT_EQ(row.at("required_pass"), "true");
    }
}

void testWireCapabilitiesTableSeeded() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_caps_test.db";
    std::filesystem::remove(path);
    sqlite3* db = nullptr;
    sqlite3_open(path.string().c_str(), &db);
    cpbitnode::db::initSchema(db);

    sqlite3_stmt* count = nullptr;
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM wire_capabilities", -1, &count, nullptr);
    sqlite3_step(count);
    EXPECT_EQ(sqlite3_column_int(count, 0), static_cast<int>(cpbitnode::wire::capabilities().size()));
    sqlite3_finalize(count);

    sqlite3_stmt* row = nullptr;
    sqlite3_prepare_v2(db, "SELECT implemented FROM wire_capabilities WHERE capability_id = 'frame.build'", -1,
                       &row, nullptr);
    sqlite3_step(row);
    EXPECT_EQ(sqlite3_column_int(row, 0), 1);
    sqlite3_finalize(row);

    sqlite3_stmt* meta = nullptr;
    sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'schema_version'", -1, &meta, nullptr);
    sqlite3_step(meta);
    const char* ver = reinterpret_cast<const char*>(sqlite3_column_text(meta, 0));
    EXPECT_EQ(std::string(ver), std::to_string(cpbitnode::db::kSchemaVersion));
    sqlite3_finalize(meta);

    sqlite3_close(db);
    std::filesystem::remove(path);
}

void testFullNodeWireProgressCounts() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_progress_test.db";
    std::filesystem::remove(path);
    cpbitnode::db::ProjectTracker tracker(path.string());
    const auto capMap = tracker.wireCapabilityMap();
    const auto progress = cpbitnode::wire::fullNodeWireProgress(capMap);
    const int required = static_cast<int>(std::count_if(cpbitnode::wire::capabilities().begin(),
                                                        cpbitnode::wire::capabilities().end(),
                                                        [](const auto& c) { return c.required; }));
    EXPECT_EQ(std::stoi(progress.at("required_total")), required);
    EXPECT_EQ(std::stoi(progress.at("checkpoints_total")),
              static_cast<int>(cpbitnode::wire::checkpoints().size()));
    EXPECT_TRUE(std::stoi(progress.at("required_done")) < required);
}

void testCheckpointStatusPartialMapMarksRequiredFail() {
    std::map<std::string, int> capMap;
    for (const auto& cap : cpbitnode::wire::capabilities()) {
        if (cap.required) {
            capMap[cap.id] = 0;
        }
    }
    const auto statuses = cpbitnode::wire::checkpointStatus(capMap);
    bool sawRequiredFail = false;
    for (const auto& [_, row] : statuses) {
        if (row.at("required_pass") == "false") {
            sawRequiredFail = true;
        }
    }
    EXPECT_TRUE(sawRequiredFail);
}

void testCheckpointStatusCountsOptionalCapabilities() {
    std::map<std::string, int> capMap;
    for (const auto& cap : cpbitnode::wire::capabilities()) {
        capMap[cap.id] = cap.required ? 1 : 0;
    }
    const auto statuses = cpbitnode::wire::checkpointStatus(capMap);
    for (const auto& [_, row] : statuses) {
        EXPECT_TRUE(std::stoi(row.at("optional_total")) >= 0);
        EXPECT_TRUE(std::stoi(row.at("capabilities_total")) >= std::stoi(row.at("required_total")));
    }
}

void testFullNodeWireProgressAllRequiredDone() {
    std::map<std::string, int> capMap;
    for (const auto& cap : cpbitnode::wire::capabilities()) {
        capMap[cap.id] = 1;
    }
    const auto progress = cpbitnode::wire::fullNodeWireProgress(capMap);
    EXPECT_EQ(progress.at("full_node_wire_ready"), "true");
    EXPECT_EQ(progress.at("required_done"), progress.at("required_total"));
}

void testWireRegistryAccessorsExposeEntries() {
    EXPECT_TRUE(!cpbitnode::wire::checkpoints().empty());
    EXPECT_TRUE(!cpbitnode::wire::capabilities().empty());
    EXPECT_EQ(cpbitnode::wire::checkpoints().front().id, "cp0_framing");
}

void testCheckpointStatusSkipsUnrelatedCheckpointCapabilities() {
    std::map<std::string, int> capMap{{"frame.build", 1}};
    const auto statuses = cpbitnode::wire::checkpointStatus(capMap);
    const auto& cp0 = statuses.at("cp0_framing");
    EXPECT_EQ(cp0.at("required_pass"), "false");
    const auto& cp6 = statuses.at("cp6_serving");
    EXPECT_EQ(cp6.at("required_pass"), "false");
}

void testFullNodeWireProgressZeroRequiredTotalReportsReady() {
    std::map<std::string, int> capMap;
    for (const auto& cap : cpbitnode::wire::capabilities()) {
        if (!cap.required) {
            capMap[cap.id] = 1;
        }
    }
    const auto progress = cpbitnode::wire::fullNodeWireProgress(capMap);
    EXPECT_TRUE(std::stoi(progress.at("required_total")) > 0);
    EXPECT_EQ(progress.at("full_node_wire_ready"), "false");
}

void testSeedUpdatesRegistryDefaults() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_reseed_test.db";
    std::filesystem::remove(path);
    sqlite3* db = nullptr;
    sqlite3_open(path.string().c_str(), &db);
    cpbitnode::db::initSchema(db);
    sqlite3_exec(db, "UPDATE wire_capabilities SET implemented = 0 WHERE capability_id = 'frame.build'", nullptr,
                 nullptr, nullptr);
    cpbitnode::db::seedWireCapabilities(db);
    sqlite3_stmt* row = nullptr;
    sqlite3_prepare_v2(db, "SELECT implemented FROM wire_capabilities WHERE capability_id = 'frame.build'", -1,
                       &row, nullptr);
    sqlite3_step(row);
    EXPECT_EQ(sqlite3_column_int(row, 0), 1);
    sqlite3_finalize(row);
    sqlite3_close(db);
    std::filesystem::remove(path);
}

}  // namespace

void registerWireCapabilityTests() {
    RUN_TEST(testCapabilityRegistryIsBinary);
    RUN_TEST(testCheckpointPassRequiresAllRequired);
    RUN_TEST(testWireCapabilitiesTableSeeded);
    RUN_TEST(testFullNodeWireProgressCounts);
    RUN_TEST(testCheckpointStatusPartialMapMarksRequiredFail);
    RUN_TEST(testCheckpointStatusCountsOptionalCapabilities);
    RUN_TEST(testFullNodeWireProgressAllRequiredDone);
    RUN_TEST(testWireRegistryAccessorsExposeEntries);
    RUN_TEST(testCheckpointStatusSkipsUnrelatedCheckpointCapabilities);
    RUN_TEST(testFullNodeWireProgressZeroRequiredTotalReportsReady);
    RUN_TEST(testSeedUpdatesRegistryDefaults);
}
