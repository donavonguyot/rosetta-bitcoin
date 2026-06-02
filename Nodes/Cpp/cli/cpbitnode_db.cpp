#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/chainstate.hpp"
#include "cpbitnode/db/node_state.hpp"
#ifndef CPBITNODE_USE_ROCKSDB
#include "cpbitnode/db/tracker.hpp"
#endif
#include "cpbitnode/util/json.hpp"

#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <sstream>

namespace {

std::unique_ptr<cpbitnode::db::NodeStateStore> openNodeState(const cpbitnode::config::Settings& settings) {
    if (settings.chainstateBackend == "rocksdb") {
        const auto sqlitePath = std::filesystem::path(settings.resolvedDbPath());
        if (std::filesystem::exists(sqlitePath)) {
            throw std::runtime_error("rocksdb mode refuses legacy SQLite artifact: " + sqlitePath.string());
        }
        return cpbitnode::db::openRocksDbNodeStateStore(settings.dataDir);
    }
#ifdef CPBITNODE_USE_ROCKSDB
    throw std::runtime_error("native RocksDB build only supports --chainstate-backend rocksdb");
#else
    return std::make_unique<cpbitnode::db::ProjectTracker>(settings.resolvedDbPath());
#endif
}

std::string syncStatus(const cpbitnode::db::NodeStateStore& tracker, const std::string& chain) {
    const auto sync = tracker.getSyncState(chain);
    if (!sync.has_value() || !sync->contains("sync_status")) {
        return "starting";
    }
    return sync->at("sync_status");
}

std::string binaryGateStatus(const std::string& syncStatus, int validatedHeight, int headerHeight) {
    if (syncStatus == "blocks_blocked" || syncStatus == "error") {
        return "failed";
    }
    if (syncStatus == "blocks_current" && headerHeight >= 0 && validatedHeight >= headerHeight) {
        return "passed";
    }
    return "not_attempted";
}

std::string nowUnknown() {
    return "";
}

std::string statusJson(const cpbitnode::config::Settings& settings, cpbitnode::db::NodeStateStore& tracker,
                       cpbitnode::db::ChainstateStore& chainstate) {
    const auto meta = chainstate.metadata();
    const auto tip = chainstate.readTip(settings.chain);
    const int headerHeight = tracker.maxHeaderHeight();
    const int storedHeight = tracker.maxStoredBlockHeight();
    const auto headerHash = headerHeight >= 0 ? tracker.getHeaderHash(headerHeight).value_or("") : "";
    const auto storedHash = storedHeight >= 0 ? tracker.getHeaderHash(storedHeight).value_or("") : "";
    const auto sync = syncStatus(tracker, settings.chain);
    const std::filesystem::path lockPath = std::filesystem::path(settings.dataDir) / ".cpbitnode_sync.lock";
    const bool lockExists = std::filesystem::exists(lockPath);

    std::ostringstream out;
    out << "{";
    out << "\"node_id\":\"cpp\",";
    out << "\"implementation\":\"Cpp\",";
    out << "\"runtime_surface\":\"host\",";
    out << "\"chain\":" << cpbitnode::util::jsonString(settings.chain) << ",";
    out << "\"network\":\"testnet4\",";
    out << "\"sync_status\":" << cpbitnode::util::jsonString(sync) << ",";
    out << "\"runtime_status\":\"not_running\",";
    out << "\"binary_gate_status\":"
        << cpbitnode::util::jsonString(binaryGateStatus(sync, tip.height, headerHeight)) << ",";
    out << "\"header_height\":" << headerHeight << ",";
    out << "\"header_hash\":" << cpbitnode::util::jsonString(headerHash) << ",";
    out << "\"stored_block_height\":" << storedHeight << ",";
    out << "\"stored_block_hash\":" << cpbitnode::util::jsonString(storedHash) << ",";
    out << "\"validated_height\":" << tip.height << ",";
    out << "\"validated_hash\":" << cpbitnode::util::jsonString(tip.hash) << ",";
    out << "\"chainstate_backend\":" << cpbitnode::util::jsonString(meta.backendName) << ",";
    out << "\"chainstate_backend_path\":" << cpbitnode::util::jsonString(meta.backendPath) << ",";
    out << "\"chainstate_generation_id\":" << cpbitnode::util::jsonString(meta.generationId) << ",";
    out << "\"chainstate_status\":" << cpbitnode::util::jsonString(meta.status) << ",";
    out << "\"chainstate_utxo_count\":" << chainstate.utxoCount() << ",";
    out << "\"native_crypto_backend\":\"" <<
#ifdef CPBITNODE_USE_NATIVE_SECP256K1
        "libsecp256k1"
#else
        "in_tree"
#endif
        << "\",";
    out << "\"native_crypto_available\":" <<
#ifdef CPBITNODE_USE_NATIVE_SECP256K1
        "true"
#else
        "false"
#endif
        << ",";
    out << "\"taproot_tweak_backend\":\"" <<
#ifdef CPBITNODE_USE_NATIVE_SECP256K1
        "libsecp256k1"
#else
        "in_tree"
#endif
        << "\",";
    out << "\"block_gap_count\":" << static_cast<int>(tracker.listMissingBlockHeights(1000000).size()) << ",";
    out << "\"current_blocker\":null,";
    out << "\"last_error\":\"\",";
    out << "\"active_writer_pid\":null,";
    out << "\"lock_status\":\"" << (lockExists ? "locked" : "unlocked") << "\",";
    out << "\"updated_at\":" << cpbitnode::util::jsonString(nowUnknown()) << ",";
    out << "\"header_count\":" << tracker.headerCount() << ",";
    out << "\"block_count\":" << tracker.blockCount() << ",";
    out << "\"utxo_count\":" << chainstate.utxoCount();
    out << "}";
    return out.str();
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const auto settings = cpbitnode::config::Settings::fromArgs(argc, argv);
        auto state = openNodeState(settings);
        auto chainstate = cpbitnode::db::openChainstateStore(settings.chainstateBackend, settings.dataDir, *state);
        std::cout << statusJson(settings, *state, *chainstate) << '\n';
        return 0;
    } catch (const std::exception& ex) {
        std::cerr << ex.what() << '\n';
        return 1;
    }
}
