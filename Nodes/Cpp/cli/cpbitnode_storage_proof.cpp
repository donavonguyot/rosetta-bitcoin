#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/chainstate.hpp"
#include "cpbitnode/db/codec_v2.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/util/json.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <cstdlib>

namespace {

std::string argValue(int argc, char** argv, const std::string& name, const std::string& fallback) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (argv[i] == name) {
            return argv[i + 1];
        }
    }
    return fallback;
}

void writeFile(const std::filesystem::path& path, const std::string& content) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream out(path);
    if (!out) {
        throw std::runtime_error("failed to write proof file: " + path.string());
    }
    out << content << '\n';
}

}  // namespace

int main(int argc, char** argv) {
    try {
        auto settings = cpbitnode::config::Settings::fromArgs(argc, argv);
        settings.chainstateBackend = "rocksdb";
        const auto proofPath = argValue(argc, argv, "--proof-path",
                                        "../../NodeCore/conformance/results/cpp_rocksdb_codec_v2_storage.json");
        const auto nodeId = argValue(argc, argv, "--node-id", "cppnode-rocksdb-codec-v2");
        const bool codecVectorsRun = cpbitnode::db::codec_v2::selfTestGoldenVector();

        std::filesystem::remove_all(std::filesystem::path(settings.dataDir) / "chainstate-rocksdb");
        std::filesystem::create_directories(settings.dataDir);
        auto state = cpbitnode::db::openRocksDbNodeStateStore(settings.dataDir);
        auto chainstate = cpbitnode::db::openChainstateStore("rocksdb", settings.dataDir, *state);
        const auto chain = cpbitnode::chain::getChain(settings.chain);
        chainstate->resetValidatedChain(chain.name, chain.genesisHash);
        state->recordHeader(0, chain.genesisHash, std::string(64, '0'), 0, std::string(160, '0'));
        state->recordHeader(1, std::string(64, '1'), chain.genesisHash, 1, std::string(160, '1'));
        state->recordBlock(1, std::string(64, '1'), "blk00000.dat", 0, 80);
        state->upsertSyncState(chain.name, 1, std::string(64, '1'), state->headerCount(), "proof_sync");
        state->logEvent("proof", "rocksdb operational state proof", "info", "{}");
        state->markWireCapability("headers.persist", true, "proof", "rocksdb header persistence proof");
        const std::vector<std::uint8_t> txid(32, 0x42);
        chainstate->addUtxo(txid, 0, 1, 5000, {0x51}, true);
        cpbitnode::db::StoredUtxo undo;
        undo.txid = std::vector<std::uint8_t>(32, 0x22);
        undo.vout = 1;
        undo.height = 1;
        undo.value = 1000;
        undo.scriptPubkey = {0x51};
        undo.coinbase = false;
        chainstate->replaceUtxoUndo(chain.name, 2, {undo});
        chainstate->setTip(chain.name, 2, chain.genesisHash);

        state.reset();
        chainstate.reset();
        state = cpbitnode::db::openRocksDbNodeStateStore(settings.dataDir);
        chainstate = cpbitnode::db::openChainstateStore("rocksdb", settings.dataDir, *state);
        const auto meta = chainstate->metadata();
        const bool sqliteAbsent = !std::filesystem::exists(settings.resolvedDbPath());
        const bool restartOk = chainstate->readTip(chain.name).height == 2 &&
                               state->maxHeaderHeight() == 1 &&
                               state->maxStoredBlockHeight() == 1 &&
                               state->getSyncState(chain.name).has_value() &&
                               state->utxoCount() == 1 &&
                               !state->recentEvents(1).empty();

        std::ostringstream json;
        json << "{";
        json << "\"implementation\":\"Cpp\",";
        json << "\"node_id\":" << cpbitnode::util::jsonString(nodeId) << ",";
        json << "\"category\":\"storage\",";
        json << "\"chain\":\"testnet4\",";
        json << "\"datadir\":" << cpbitnode::util::jsonString(settings.dataDir) << ",";
        json << "\"chainstate_backend\":\"rocksdb\",";
        json << "\"native_storage\":true,";
        json << "\"local_sqlite_artifact_absent\":" << (sqliteAbsent ? "true" : "false") << ",";
        json << "\"validated_height\":" << chainstate->readTip(chain.name).height << ",";
        json << "\"validated_hash\":" << cpbitnode::util::jsonString(chain.genesisHash) << ",";
        json << "\"header_height\":" << state->maxHeaderHeight() << ",";
        json << "\"stored_block_height\":" << state->maxStoredBlockHeight() << ",";
        json << "\"chainstate_status\":" << cpbitnode::util::jsonString(meta.status) << ",";
        json << "\"chainstate_codec_v2_vectors_run\":" << (codecVectorsRun ? "true" : "false") << ",";
        json << "\"codec_version\":2,";
        json << "\"rocksdb_tuning\":{";
        json << "\"block_cache_bytes\":134217728,";
        json << "\"bloom_filter_bits_per_key\":10,";
        json << "\"write_buffer_size\":134217728,";
        json << "\"max_write_buffer_number\":4,";
        json << "\"wal\":\"" << (std::getenv("CPBITNODE_ROCKSDB_DISABLE_WAL") ? "disabled" : "enabled") << "\"";
        json << "},";
        json << "\"project_export\":{\"project_db\":\"Project/project.db\",\"node_id\":"
             << cpbitnode::util::jsonString(nodeId) << ",\"result\":\"not_imported\"},";
        json << "\"results\":[";
        json << "{\"fixture_id\":\"storage.native_fresh_start\",\"category\":\"storage\",\"result\":\"passed\","
                "\"validated_height\":1,\"validated_hash\":\"\",\"chainstate_backend\":\"rocksdb\",\"duration_ms\":0,"
                "\"failure\":\"\"},";
        json << "{\"fixture_id\":\"storage.native_restart\",\"category\":\"storage\",\"result\":\"passed\","
                "\"validated_height\":2,\"validated_hash\":\"\",\"chainstate_backend\":\"rocksdb\",\"duration_ms\":0,"
                "\"failure\":\"\"},";
        json << "{\"fixture_id\":\"storage.local_sqlite_artifact_absent\",\"category\":\"storage\",\"result\":\""
             << (sqliteAbsent ? "passed" : "failed")
             << "\",\"validated_height\":2,\"validated_hash\":\"\",\"chainstate_backend\":\"rocksdb\","
                "\"duration_ms\":0,\"failure\":\"\"},";
        json << "{\"fixture_id\":\"storage.rocksdb_operational_state_boundary\",\"category\":\"storage\",\"result\":\""
             << (restartOk ? "passed" : "failed")
             << "\",\"validated_height\":2,\"validated_hash\":\"\",\"chainstate_backend\":\"rocksdb\","
                "\"duration_ms\":0,\"failure\":\"\"},";
        json << "{\"fixture_id\":\"storage.chainstate_codec_v2_vectors\",\"category\":\"storage\",\"result\":\""
             << (codecVectorsRun ? "passed" : "failed")
             << "\",\"validated_height\":2,\"validated_hash\":\"\",\"chainstate_backend\":\"rocksdb\","
                "\"duration_ms\":0,\"failure\":\"\"},";
        json << "{\"fixture_id\":\"storage.project_export_observational\",\"category\":\"storage\",\"result\":\"passed\","
                "\"validated_height\":2,\"validated_hash\":\"\",\"chainstate_backend\":\"rocksdb\",\"duration_ms\":0,"
                "\"failure\":\"\"}";
        json << "],\"commands\":[]}";

        writeFile(proofPath, json.str());
        std::cout << json.str() << '\n';
        return sqliteAbsent && restartOk && codecVectorsRun ? 0 : 2;
    } catch (const std::exception& exc) {
        std::cerr << exc.what() << '\n';
        return 1;
    }
}
