#include "cpbitnode/db/schema.hpp"

#include "cpbitnode/wire/capabilities.hpp"

#include <chrono>
#include <ctime>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>

namespace cpbitnode::db {
namespace {

std::string utcNow() {
    const auto now = std::chrono::system_clock::now();
    const auto t = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
    gmtime_r(&t, &tm);
    std::ostringstream oss;
    oss << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S") << "+00:00";
    return oss.str();
}

void exec(sqlite3* db, const char* sql) {
    char* err = nullptr;
    if (sqlite3_exec(db, sql, nullptr, nullptr, &err) != SQLITE_OK) {
        std::string msg = err ? err : "sqlite error";
        sqlite3_free(err);
        throw std::runtime_error(msg);
    }
}

bool columnExists(sqlite3* db, const char* table, const char* column) {
    std::string sql = "PRAGMA table_info(" + std::string(table) + ")";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
        return false;
    }
    bool found = false;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char* name = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1));
        if (name && column == std::string(name)) {
            found = true;
            break;
        }
    }
    sqlite3_finalize(stmt);
    return found;
}

}  // namespace

void initSchema(sqlite3* db) {
    exec(db, R"SQL(
CREATE TABLE IF NOT EXISTS meta (
  id INTEGER PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS project_phases (
  id INTEGER PRIMARY KEY,
  phase TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  notes TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sync_state (
  id INTEGER PRIMARY KEY,
  chain TEXT NOT NULL UNIQUE,
  best_height INTEGER NOT NULL,
  best_hash TEXT NOT NULL,
  header_count INTEGER NOT NULL,
  sync_status TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS peers (
  id INTEGER PRIMARY KEY,
  host TEXT NOT NULL,
  port INTEGER NOT NULL,
  connected_at TEXT NOT NULL,
  disconnected_at TEXT NOT NULL,
  direction TEXT NOT NULL,
  services INTEGER NOT NULL,
  peer_version INTEGER NOT NULL,
  user_agent TEXT NOT NULL,
  start_height INTEGER NOT NULL,
  last_seen_at TEXT NOT NULL,
  ban_score INTEGER NOT NULL,
  status TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_peers_host_port ON peers(host, port);
CREATE TABLE IF NOT EXISTS headers (
  id INTEGER PRIMARY KEY,
  height INTEGER NOT NULL UNIQUE,
  block_hash TEXT NOT NULL UNIQUE,
  prev_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  received_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS blocks (
  id INTEGER PRIMARY KEY,
  height INTEGER NOT NULL UNIQUE,
  block_hash TEXT NOT NULL UNIQUE,
  file_name TEXT NOT NULL,
  file_offset INTEGER NOT NULL,
  size INTEGER NOT NULL,
  received_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS peer_addresses (
  id INTEGER PRIMARY KEY,
  host TEXT NOT NULL,
  port INTEGER NOT NULL,
  services INTEGER NOT NULL,
  source TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  UNIQUE(host, port)
);
CREATE TABLE IF NOT EXISTS chain_state (
  id INTEGER PRIMARY KEY,
  chain TEXT NOT NULL UNIQUE,
  validated_height INTEGER NOT NULL,
  validated_hash TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS utxos (
  id INTEGER PRIMARY KEY,
  txid TEXT NOT NULL,
  vout INTEGER NOT NULL,
  height INTEGER NOT NULL,
  value INTEGER NOT NULL,
  script_pubkey TEXT NOT NULL,
  coinbase INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(txid, vout)
);
CREATE TABLE IF NOT EXISTS utxo_undo (
  id INTEGER PRIMARY KEY,
  chain TEXT NOT NULL,
  height INTEGER NOT NULL,
  entries_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(chain, height)
);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY,
  category TEXT NOT NULL,
  level TEXT NOT NULL,
  message TEXT NOT NULL,
  details_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_category_created ON events(category, created_at);
CREATE TABLE IF NOT EXISTS wire_capabilities (
  id INTEGER PRIMARY KEY,
  capability_id TEXT NOT NULL UNIQUE,
  checkpoint TEXT NOT NULL,
  category TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  required INTEGER NOT NULL,
  implemented INTEGER NOT NULL,
  verified_by TEXT NOT NULL,
  verified_at TEXT NOT NULL,
  notes TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_wire_capabilities_checkpoint ON wire_capabilities(checkpoint);
)SQL");

    if (!columnExists(db, "headers", "header_serialized_hex")) {
        exec(db, "ALTER TABLE headers ADD COLUMN header_serialized_hex TEXT");
    }
    if (!columnExists(db, "peer_addresses", "ban_score")) {
        exec(db, "ALTER TABLE peer_addresses ADD COLUMN ban_score INTEGER DEFAULT 0");
    }

    sqlite3_stmt* countStmt = nullptr;
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM meta", -1, &countStmt, nullptr);
    int metaCount = 0;
    if (sqlite3_step(countStmt) == SQLITE_ROW) {
        metaCount = sqlite3_column_int(countStmt, 0);
    }
    sqlite3_finalize(countStmt);

    const std::string now = utcNow();
    if (metaCount == 0) {
        sqlite3_stmt* ins = nullptr;
        sqlite3_prepare_v2(db, "INSERT INTO meta(key, value) VALUES(?, ?)", -1, &ins, nullptr);
        sqlite3_bind_text(ins, 1, "schema_version", -1, SQLITE_STATIC);
        sqlite3_bind_text(ins, 2, std::to_string(kSchemaVersion).c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_step(ins);
        sqlite3_reset(ins);
        sqlite3_bind_text(ins, 1, "node_version", -1, SQLITE_STATIC);
        sqlite3_bind_text(ins, 2, "0.1.0", -1, SQLITE_STATIC);
        sqlite3_step(ins);
        sqlite3_finalize(ins);
    } else {
        sqlite3_stmt* up = nullptr;
        sqlite3_prepare_v2(db, "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           -1, &up, nullptr);
        sqlite3_bind_text(up, 1, "schema_version", -1, SQLITE_STATIC);
        sqlite3_bind_text(up, 2, std::to_string(kSchemaVersion).c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_step(up);
        sqlite3_finalize(up);
    }

    sqlite3_stmt* phaseCount = nullptr;
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM project_phases", -1, &phaseCount, nullptr);
    int phases = 0;
    if (sqlite3_step(phaseCount) == SQLITE_ROW) {
        phases = sqlite3_column_int(phaseCount, 0);
    }
    sqlite3_finalize(phaseCount);

    if (phases == 0) {
        struct PhaseSeed {
            const char* phase;
            const char* title;
            const char* status;
            const char* notes;
        };
        const PhaseSeed seeds[] = {
            {"phase0", "Wire + handshake", "in_progress",
             "Message framing, version/verack, Docker scaffold"},
            {"phase1", "Header sync", "pending", "Block locator, header chain persistence"},
            {"phase2", "Block download", "pending", "Parallel getdata, raw block storage"},
            {"phase3", "Consensus validation", "pending", "PoW, merkle root, and script verification"},
            {"phase4", "Mempool + relay", "pending", "Tx admission and rebroadcast"},
            {"phase5", "Hardening", "pending", "Metrics, peer banning, optional BIP324"},
        };
        sqlite3_stmt* ins = nullptr;
        sqlite3_prepare_v2(db,
                           "INSERT INTO project_phases(phase, title, status, notes, updated_at) VALUES(?, ?, ?, ?, ?)", -1,
                           &ins, nullptr);
        for (const auto& s : seeds) {
            sqlite3_bind_text(ins, 1, s.phase, -1, SQLITE_STATIC);
            sqlite3_bind_text(ins, 2, s.title, -1, SQLITE_STATIC);
            sqlite3_bind_text(ins, 3, s.status, -1, SQLITE_STATIC);
            sqlite3_bind_text(ins, 4, s.notes, -1, SQLITE_STATIC);
            sqlite3_bind_text(ins, 5, now.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_step(ins);
            sqlite3_reset(ins);
        }
        sqlite3_finalize(ins);
    }

    seedWireCapabilities(db);
}

void seedWireCapabilities(sqlite3* db) {
    const std::string now = utcNow();
    const char* sql = R"SQL(
INSERT INTO wire_capabilities(
  capability_id, checkpoint, category, name, description,
  required, implemented, verified_by, verified_at, notes
) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(capability_id) DO UPDATE SET
  checkpoint=excluded.checkpoint,
  category=excluded.category,
  name=excluded.name,
  description=excluded.description,
  required=excluded.required,
  implemented=excluded.implemented,
  verified_by=excluded.verified_by,
  verified_at=excluded.verified_at,
  notes=excluded.notes
)SQL";
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr);
    for (const auto& cap : wire::capabilities()) {
        sqlite3_bind_text(stmt, 1, cap.id.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 2, cap.checkpoint.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 3, cap.category.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 4, cap.name.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 5, cap.description.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_int(stmt, 6, cap.required ? 1 : 0);
        sqlite3_bind_int(stmt, 7, cap.implemented ? 1 : 0);
        if (cap.implemented) {
            sqlite3_bind_text(stmt, 8, "code", -1, SQLITE_STATIC);
            sqlite3_bind_text(stmt, 9, now.c_str(), -1, SQLITE_TRANSIENT);
        } else {
            sqlite3_bind_text(stmt, 8, "", -1, SQLITE_STATIC);
            sqlite3_bind_text(stmt, 9, "", -1, SQLITE_STATIC);
        }
        sqlite3_bind_text(stmt, 10, "", -1, SQLITE_STATIC);
        sqlite3_step(stmt);
        sqlite3_reset(stmt);
    }
    sqlite3_finalize(stmt);
}

}  // namespace cpbitnode::db
