#include "cpbitnode/db/tracker.hpp"

#include "cpbitnode/db/schema.hpp"
#include "cpbitnode/util/json.hpp"
#include "cpbitnode/wire/capabilities.hpp"

#include <chrono>
#include <algorithm>
#include <cctype>
#include <ctime>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <stdexcept>

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

std::map<std::string, std::string> rowToMap(sqlite3_stmt* stmt) {
    std::map<std::string, std::string> row;
    const int cols = sqlite3_column_count(stmt);
    for (int i = 0; i < cols; ++i) {
        const char* name = sqlite3_column_name(stmt, i);
        const char* text = reinterpret_cast<const char*>(sqlite3_column_text(stmt, i));
        row[name ? name : ""] = text ? text : "";
    }
    return row;
}

std::string jsonRowObject(const std::map<std::string, std::string>& row) {
    std::map<std::string, std::string> fields;
    for (const auto& [k, v] : row) {
        fields[k] = util::jsonString(v);
    }
    return util::jsonObject(fields);
}

std::string txidToDisplayHex(const std::vector<std::uint8_t>& txid) {
    std::string txidHex;
    txidHex.reserve(64);
    for (auto it = txid.rbegin(); it != txid.rend(); ++it) {
        static const char* kHex = "0123456789abcdef";
        txidHex.push_back(kHex[(*it >> 4) & 0xf]);
        txidHex.push_back(kHex[*it & 0xf]);
    }
    return txidHex;
}

std::string bytesToHex(const std::vector<std::uint8_t>& bytes) {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.reserve(bytes.size() * 2);
    for (const auto byte : bytes) {
        out.push_back(kHex[(byte >> 4) & 0xf]);
        out.push_back(kHex[byte & 0xf]);
    }
    return out;
}

std::vector<std::uint8_t> hexToBytes(const std::string& hex) {
    std::vector<std::uint8_t> out;
    out.reserve(hex.size() / 2);
    for (std::size_t index = 0; index + 1 < hex.size(); index += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoi(hex.substr(index, 2), nullptr, 16)));
    }
    return out;
}

std::string encodeUndoEntries(const std::vector<StoredUtxo>& entries) {
    std::vector<std::string> items;
    for (const auto& entry : entries) {
        std::map<std::string, std::string> fields;
        fields["txid"] = util::jsonString(entry.txid);
        fields["vout"] = std::to_string(entry.vout);
        fields["height"] = std::to_string(entry.height);
        fields["value"] = std::to_string(entry.value);
        fields["script_pubkey"] = util::jsonString(bytesToHex(entry.scriptPubkey));
        fields["coinbase"] = std::to_string(entry.coinbase ? 1 : 0);
        items.push_back(util::jsonObject(fields));
    }
    return util::jsonArray(items);
}

void skipWs(const std::string& json, std::size_t& pos) {
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos])) != 0) {
        ++pos;
    }
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

std::int64_t parseJsonNumber(const std::string& json, std::size_t& pos) {
    skipWs(json, pos);
    const std::size_t start = pos;
    if (pos < json.size() && (json[pos] == '-' || json[pos] == '+')) {
        ++pos;
    }
    while (pos < json.size() && std::isdigit(static_cast<unsigned char>(json[pos])) != 0) {
        ++pos;
    }
    return std::stoll(json.substr(start, pos - start));
}

void expectChar(const std::string& json, std::size_t& pos, char ch) {
    skipWs(json, pos);
    if (pos >= json.size() || json[pos] != ch) {
        throw std::runtime_error("unexpected JSON token");
    }
    ++pos;
}

StoredUtxo parseUndoObject(const std::string& json, std::size_t& pos) {
    expectChar(json, pos, '{');
    StoredUtxo entry;
    skipWs(json, pos);
    if (pos < json.size() && json[pos] == '}') {
        ++pos;
        return entry;
    }
    while (pos < json.size()) {
        const std::string key = parseJsonString(json, pos);
        expectChar(json, pos, ':');
        if (key == "txid") {
            entry.txid = parseJsonString(json, pos);
        } else if (key == "vout") {
            entry.vout = static_cast<int>(parseJsonNumber(json, pos));
        } else if (key == "height") {
            entry.height = static_cast<int>(parseJsonNumber(json, pos));
        } else if (key == "value") {
            entry.value = parseJsonNumber(json, pos);
        } else if (key == "script_pubkey") {
            entry.scriptPubkey = hexToBytes(parseJsonString(json, pos));
        } else if (key == "coinbase") {
            entry.coinbase = parseJsonNumber(json, pos) != 0;
        } else {
            throw std::runtime_error("unknown undo entry field");
        }
        skipWs(json, pos);
        if (pos < json.size() && json[pos] == ',') {
            ++pos;
            continue;
        }
        break;
    }
    expectChar(json, pos, '}');
    return entry;
}

std::vector<StoredUtxo> decodeUndoEntries(const std::string& json) {
    std::size_t pos = 0;
    skipWs(json, pos);
    expectChar(json, pos, '[');
    skipWs(json, pos);
    std::vector<StoredUtxo> entries;
    if (pos < json.size() && json[pos] == ']') {
        ++pos;
        return entries;
    }
    while (pos < json.size()) {
        entries.push_back(parseUndoObject(json, pos));
        skipWs(json, pos);
        if (pos < json.size() && json[pos] == ',') {
            ++pos;
            continue;
        }
        break;
    }
    expectChar(json, pos, ']');
    return entries;
}

}  // namespace

ProjectTracker::ProjectTracker(const std::string& dbPath) : dbPath_(dbPath) {
    std::filesystem::create_directories(std::filesystem::path(dbPath).parent_path());
    if (sqlite3_open(dbPath.c_str(), &db_) != SQLITE_OK) {
        throw std::runtime_error(sqlite3_errmsg(db_));
    }
    initSchema(db_);
}

ProjectTracker::~ProjectTracker() {
    if (db_) {
        sqlite3_close(db_);
        db_ = nullptr;
    }
}

NodeStateMetadata ProjectTracker::nodeStateMetadata() const {
    NodeStateMetadata meta;
    meta.backendName = "sqlite-legacy";
    meta.backendPath = dbPath_;
    meta.status = "legacy_non_compliant";
    meta.generationId = "sqlite-legacy";
    meta.schemaVersion = std::to_string(kSchemaVersion);
    return meta;
}

void ProjectTracker::setMeta(const std::string& key, const std::string& value) {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                       -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 2, value.c_str(), -1, SQLITE_STATIC);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

std::optional<std::string> ProjectTracker::getMeta(const std::string& key) const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT value FROM meta WHERE key = ? LIMIT 1", -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_STATIC);
    std::optional<std::string> out;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const char* text = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
        if (text) {
            out = text;
        }
    }
    sqlite3_finalize(stmt);
    return out;
}

void ProjectTracker::updatePhase(const std::string& phase, const std::optional<std::string>& status,
                                 const std::optional<std::string>& notes) {
    sqlite3_stmt* find = nullptr;
    sqlite3_prepare_v2(db_, "SELECT id FROM project_phases WHERE phase = ? LIMIT 1", -1, &find, nullptr);
    sqlite3_bind_text(find, 1, phase.c_str(), -1, SQLITE_STATIC);
    if (sqlite3_step(find) != SQLITE_ROW) {
        sqlite3_finalize(find);
        throw std::runtime_error("Unknown phase " + phase);
    }
    const int id = sqlite3_column_int(find, 0);
    sqlite3_finalize(find);

    std::string sql = "UPDATE project_phases SET updated_at = ?";
    if (status) {
        sql += ", status = ?";
    }
    if (notes) {
        sql += ", notes = ?";
    }
    sql += " WHERE id = ?";

    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, sql.c_str(), -1, &stmt, nullptr);
    int idx = 1;
    const std::string now = utcNow();
    sqlite3_bind_text(stmt, idx++, now.c_str(), -1, SQLITE_TRANSIENT);
    if (status) {
        sqlite3_bind_text(stmt, idx++, status->c_str(), -1, SQLITE_STATIC);
    }
    if (notes) {
        sqlite3_bind_text(stmt, idx++, notes->c_str(), -1, SQLITE_STATIC);
    }
    sqlite3_bind_int(stmt, idx, id);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

std::vector<std::map<std::string, std::string>> ProjectTracker::listPhases() const {
    std::vector<std::map<std::string, std::string>> rows;
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT * FROM project_phases ORDER BY phase", -1, &stmt, nullptr);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        rows.push_back(rowToMap(stmt));
    }
    sqlite3_finalize(stmt);
    return rows;
}

void ProjectTracker::logEvent(const std::string& category, const std::string& message, const std::string& level,
                              const std::string& detailsJson) {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "INSERT INTO events(category, level, message, details_json, created_at) VALUES(?, ?, ?, ?, ?)",
                       -1, &stmt, nullptr);
    const std::string now = utcNow();
    sqlite3_bind_text(stmt, 1, category.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 2, level.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 3, message.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 4, detailsJson.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 5, now.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

void ProjectTracker::upsertSyncState(const std::string& chain, std::optional<int> bestHeight,
                                     const std::optional<std::string>& bestHash, std::optional<int> headerCount,
                                     const std::optional<std::string>& syncStatus) {
    auto existing = getSyncState(chain);
    const int height = bestHeight.value_or(existing ? std::stoi((*existing)["best_height"]) : 0);
    const std::string hash = bestHash.value_or(existing ? (*existing)["best_hash"] : "");
    const int headers = headerCount.value_or(existing ? std::stoi((*existing)["header_count"]) : 0);
    const std::string status = syncStatus.value_or(existing ? (*existing)["sync_status"] : "starting");
    const std::string now = utcNow();

    sqlite3_stmt* stmt = nullptr;
    if (existing) {
        sqlite3_prepare_v2(db_,
                           "UPDATE sync_state SET best_height=?, best_hash=?, header_count=?, sync_status=?, updated_at=? "
                           "WHERE chain=?",
                           -1, &stmt, nullptr);
        sqlite3_bind_int(stmt, 1, height);
        sqlite3_bind_text(stmt, 2, hash.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_int(stmt, 3, headers);
        sqlite3_bind_text(stmt, 4, status.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 5, now.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 6, chain.c_str(), -1, SQLITE_STATIC);
    } else {
        sqlite3_prepare_v2(db_,
                           "INSERT INTO sync_state(chain, best_height, best_hash, header_count, sync_status, updated_at) "
                           "VALUES(?, ?, ?, ?, ?, ?)",
                           -1, &stmt, nullptr);
        sqlite3_bind_text(stmt, 1, chain.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_int(stmt, 2, height);
        sqlite3_bind_text(stmt, 3, hash.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_int(stmt, 4, headers);
        sqlite3_bind_text(stmt, 5, status.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 6, now.c_str(), -1, SQLITE_TRANSIENT);
    }
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

std::optional<std::map<std::string, std::string>> ProjectTracker::getSyncState(const std::string& chain) const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT * FROM sync_state WHERE chain = ? LIMIT 1", -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, chain.c_str(), -1, SQLITE_STATIC);
    std::optional<std::map<std::string, std::string>> out;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        out = rowToMap(stmt);
    }
    sqlite3_finalize(stmt);
    return out;
}

int ProjectTracker::recordPeerConnected(const std::string& host, int port, const std::string& userAgent,
                                        const std::string& direction) {
    const std::string now = utcNow();
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "INSERT INTO peers(host, port, connected_at, disconnected_at, direction, services, peer_version, "
                       "user_agent, start_height, last_seen_at, ban_score, status) "
                       "VALUES(?, ?, ?, '', ?, 0, 0, ?, 0, ?, 0, 'connected')",
                       -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, host.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 2, port);
    sqlite3_bind_text(stmt, 3, now.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, direction.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 5, userAgent.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 6, now.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    const int peerId = static_cast<int>(sqlite3_last_insert_rowid(db_));
    logEvent("p2p", "Connected to " + host + ":" + std::to_string(port),
             "info", "{\"peer_id\":" + std::to_string(peerId) + ",\"user_agent\":" + util::jsonString(userAgent) + "}");
    return peerId;
}

void ProjectTracker::recordPeerDisconnected(int peerId) {
    const std::string now = utcNow();
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "UPDATE peers SET disconnected_at = ?, status = 'disconnected', last_seen_at = ? WHERE id = ?",
                       -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, now.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, now.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 3, peerId);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

void ProjectTracker::touchPeer(int peerId) {
    const std::string now = utcNow();
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "UPDATE peers SET last_seen_at = ? WHERE id = ?", -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, now.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 2, peerId);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

void ProjectTracker::recordPeerAddress(const std::string& host, int port, std::uint64_t services,
                                       const std::string& source) {
    sqlite3_stmt* find = nullptr;
    sqlite3_prepare_v2(db_, "SELECT id, ban_score FROM peer_addresses WHERE host = ? AND port = ? LIMIT 1", -1, &find,
                       nullptr);
    sqlite3_bind_text(find, 1, host.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(find, 2, port);
    const bool exists = sqlite3_step(find) == SQLITE_ROW;
    int existingId = 0;
    int banScore = 0;
    if (exists) {
        existingId = sqlite3_column_int(find, 0);
        banScore = sqlite3_column_int(find, 1);
    }
    sqlite3_finalize(find);

    const std::string now = utcNow();
    sqlite3_stmt* stmt = nullptr;
    if (exists) {
        sqlite3_prepare_v2(db_,
                           "UPDATE peer_addresses SET services = ?, source = ?, last_seen_at = ?, ban_score = ? "
                           "WHERE id = ?",
                           -1, &stmt, nullptr);
        sqlite3_bind_int64(stmt, 1, static_cast<sqlite3_int64>(services));
        sqlite3_bind_text(stmt, 2, source.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 3, now.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 4, banScore);
        sqlite3_bind_int(stmt, 5, existingId);
    } else {
        sqlite3_prepare_v2(db_,
                           "INSERT INTO peer_addresses(host, port, services, source, last_seen_at, ban_score) "
                           "VALUES(?, ?, ?, ?, ?, 0)",
                           -1, &stmt, nullptr);
        sqlite3_bind_text(stmt, 1, host.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_int(stmt, 2, port);
        sqlite3_bind_int64(stmt, 3, static_cast<sqlite3_int64>(services));
        sqlite3_bind_text(stmt, 4, source.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 5, now.c_str(), -1, SQLITE_TRANSIENT);
    }
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

int ProjectTracker::getPeerEndpointBanScore(const std::string& host, int port) const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT ban_score FROM peer_addresses WHERE host = ? AND port = ? LIMIT 1", -1, &stmt,
                       nullptr);
    sqlite3_bind_text(stmt, 1, host.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 2, port);
    int score = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        score = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return score;
}

int ProjectTracker::incrementPeerBanScore(const std::string& host, int port, int delta, int peerId) {
    if (delta == 0) {
        return getPeerEndpointBanScore(host, port);
    }
    const int current = getPeerEndpointBanScore(host, port);
    const int newScore = current + delta;
    const std::string now = utcNow();

    sqlite3_stmt* find = nullptr;
    sqlite3_prepare_v2(db_, "SELECT id FROM peer_addresses WHERE host = ? AND port = ? LIMIT 1", -1, &find, nullptr);
    sqlite3_bind_text(find, 1, host.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(find, 2, port);
    const bool exists = sqlite3_step(find) == SQLITE_ROW;
    sqlite3_finalize(find);

    sqlite3_stmt* stmt = nullptr;
    if (exists) {
        sqlite3_prepare_v2(db_,
                           "UPDATE peer_addresses SET ban_score = ?, last_seen_at = ? WHERE host = ? AND port = ?",
                           -1, &stmt, nullptr);
        sqlite3_bind_int(stmt, 1, newScore);
        sqlite3_bind_text(stmt, 2, now.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, host.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_int(stmt, 4, port);
    } else {
        sqlite3_prepare_v2(db_,
                           "INSERT INTO peer_addresses(host, port, services, source, last_seen_at, ban_score) "
                           "VALUES(?, ?, 0, 'ban', ?, ?)",
                           -1, &stmt, nullptr);
        sqlite3_bind_text(stmt, 1, host.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_int(stmt, 2, port);
        sqlite3_bind_text(stmt, 3, now.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 4, newScore);
    }
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    if (peerId > 0) {
        sqlite3_stmt* peerStmt = nullptr;
        sqlite3_prepare_v2(db_, "UPDATE peers SET ban_score = ban_score + ? WHERE id = ?", -1, &peerStmt, nullptr);
        sqlite3_bind_int(peerStmt, 1, delta);
        sqlite3_bind_int(peerStmt, 2, peerId);
        sqlite3_step(peerStmt);
        sqlite3_finalize(peerStmt);
    }
    return newScore;
}

void ProjectTracker::decayPeerBanScore(const std::string& host, int port, int amount, int peerId) {
    if (amount <= 0) {
        return;
    }
    const int current = getPeerEndpointBanScore(host, port);
    if (current <= 0) {
        return;
    }
    const int newScore = std::max(0, current - amount);
    const std::string now = utcNow();
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "UPDATE peer_addresses SET ban_score = ?, last_seen_at = ? WHERE host = ? AND port = ?",
                       -1, &stmt, nullptr);
    sqlite3_bind_int(stmt, 1, newScore);
    sqlite3_bind_text(stmt, 2, now.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, host.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 4, port);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    if (peerId > 0) {
        sqlite3_stmt* peerStmt = nullptr;
        sqlite3_prepare_v2(db_,
                           "UPDATE peers SET ban_score = CASE WHEN ban_score > ? THEN ban_score - ? ELSE 0 END "
                           "WHERE id = ?",
                           -1, &peerStmt, nullptr);
        sqlite3_bind_int(peerStmt, 1, amount);
        sqlite3_bind_int(peerStmt, 2, amount);
        sqlite3_bind_int(peerStmt, 3, peerId);
        sqlite3_step(peerStmt);
        sqlite3_finalize(peerStmt);
    }
}

std::vector<std::pair<std::string, int>> ProjectTracker::listPeerAddressEndpoints(int limit) const {
    std::vector<std::pair<std::string, int>> out;
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "SELECT host, port FROM peer_addresses ORDER BY last_seen_at DESC LIMIT ?",
                       -1, &stmt, nullptr);
    sqlite3_bind_int(stmt, 1, limit * 8);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char* host = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
        const int port = sqlite3_column_int(stmt, 1);
        if (host) {
            out.emplace_back(host, port);
            if (static_cast<int>(out.size()) >= limit) {
                break;
            }
        }
    }
    sqlite3_finalize(stmt);
    return out;
}

void ProjectTracker::recordHeader(int height, const std::string& blockHash, const std::string& prevHash, int timestamp,
                                  const std::string& headerSerializedHex) {
    sqlite3_stmt* stmt = nullptr;
    if (headerSerializedHex.empty()) {
        sqlite3_prepare_v2(db_,
                           "INSERT OR IGNORE INTO headers(height, block_hash, prev_hash, timestamp, received_at) "
                           "VALUES(?, ?, ?, ?, ?)",
                           -1, &stmt, nullptr);
    } else {
        sqlite3_prepare_v2(db_,
                           "INSERT OR IGNORE INTO headers(height, block_hash, prev_hash, timestamp, received_at, "
                           "header_serialized_hex) VALUES(?, ?, ?, ?, ?, ?)",
                           -1, &stmt, nullptr);
    }
    const std::string now = utcNow();
    sqlite3_bind_int(stmt, 1, height);
    sqlite3_bind_text(stmt, 2, blockHash.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 3, prevHash.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 4, timestamp);
    sqlite3_bind_text(stmt, 5, now.c_str(), -1, SQLITE_TRANSIENT);
    if (!headerSerializedHex.empty()) {
        sqlite3_bind_text(stmt, 6, headerSerializedHex.c_str(), -1, SQLITE_STATIC);
    }
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

std::optional<int> ProjectTracker::lookupHeaderHeight(const std::string& blockHashHex) const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT height FROM headers WHERE block_hash = ? LIMIT 1", -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, blockHashHex.c_str(), -1, SQLITE_STATIC);
    std::optional<int> out;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        out = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return out;
}

std::optional<std::string> ProjectTracker::getHeaderSerializedHex(int height) const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT header_serialized_hex FROM headers WHERE height = ? LIMIT 1", -1, &stmt, nullptr);
    sqlite3_bind_int(stmt, 1, height);
    std::optional<std::string> out;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const char* text = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
        if (text && *text) {
            out = text;
        }
    }
    sqlite3_finalize(stmt);
    return out;
}

std::optional<StoredBlockRow> ProjectTracker::getStoredBlockForHashHex(const std::string& blockHashHex) const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "SELECT height, block_hash, file_name, file_offset, size FROM blocks WHERE block_hash = ? "
                       "LIMIT 1",
                       -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, blockHashHex.c_str(), -1, SQLITE_STATIC);
    std::optional<StoredBlockRow> out;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        StoredBlockRow row;
        row.height = sqlite3_column_int(stmt, 0);
        const char* hash = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1));
        const char* file = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 2));
        row.blockHash = hash ? hash : "";
        row.fileName = file ? file : "";
        row.fileOffset = sqlite3_column_int(stmt, 3);
        row.size = sqlite3_column_int(stmt, 4);
        out = row;
    }
    sqlite3_finalize(stmt);
    return out;
}

int ProjectTracker::headerCount() const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT COUNT(*) FROM headers", -1, &stmt, nullptr);
    int count = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        count = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return count;
}

int ProjectTracker::blockCount() const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT COUNT(*) FROM blocks", -1, &stmt, nullptr);
    int count = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        count = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return count;
}

int ProjectTracker::utxoCount() const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT COUNT(*) FROM utxos", -1, &stmt, nullptr);
    int count = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        count = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return count;
}

int ProjectTracker::getValidatedHeight(const std::string& chain) const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT validated_height FROM chain_state WHERE chain = ? LIMIT 1", -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, chain.c_str(), -1, SQLITE_STATIC);
    int height = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        height = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return height;
}

std::string ProjectTracker::getValidatedHash(const std::string& chain) const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT validated_hash FROM chain_state WHERE chain = ? LIMIT 1", -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, chain.c_str(), -1, SQLITE_STATIC);
    std::string hash;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const char* text = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
        if (text) {
            hash = text;
        }
    }
    sqlite3_finalize(stmt);
    return hash;
}

int ProjectTracker::maxHeaderHeight() const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT MAX(height) FROM headers", -1, &stmt, nullptr);
    int height = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL) {
        height = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return height;
}

void ProjectTracker::setValidatedTip(int height, const std::string& blockHashHex, const std::string& chain) {
    const std::string now = utcNow();
    sqlite3_stmt* find = nullptr;
    sqlite3_prepare_v2(db_, "SELECT id FROM chain_state WHERE chain = ? LIMIT 1", -1, &find, nullptr);
    sqlite3_bind_text(find, 1, chain.c_str(), -1, SQLITE_STATIC);
    const bool exists = sqlite3_step(find) == SQLITE_ROW;
    sqlite3_finalize(find);

    sqlite3_stmt* stmt = nullptr;
    if (exists) {
        sqlite3_prepare_v2(db_,
                           "UPDATE chain_state SET validated_height=?, validated_hash=?, updated_at=? WHERE chain=?",
                           -1, &stmt, nullptr);
        sqlite3_bind_int(stmt, 1, height);
        sqlite3_bind_text(stmt, 2, blockHashHex.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 3, now.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 4, chain.c_str(), -1, SQLITE_STATIC);
    } else {
        sqlite3_prepare_v2(db_,
                           "INSERT INTO chain_state(chain, validated_height, validated_hash, updated_at) VALUES(?, ?, ?, ?)",
                           -1, &stmt, nullptr);
        sqlite3_bind_text(stmt, 1, chain.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_int(stmt, 2, height);
        sqlite3_bind_text(stmt, 3, blockHashHex.c_str(), -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 4, now.c_str(), -1, SQLITE_TRANSIENT);
    }
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

void ProjectTracker::recordBlock(int height, const std::string& blockHash, const std::string& fileName, int fileOffset,
                                 int size) {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "INSERT OR IGNORE INTO blocks(height, block_hash, file_name, file_offset, size, received_at) "
                       "VALUES(?, ?, ?, ?, ?, ?)",
                       -1, &stmt, nullptr);
    const std::string now = utcNow();
    sqlite3_bind_int(stmt, 1, height);
    sqlite3_bind_text(stmt, 2, blockHash.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 3, fileName.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 4, fileOffset);
    sqlite3_bind_int(stmt, 5, size);
    sqlite3_bind_text(stmt, 6, now.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

void ProjectTracker::addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height, std::int64_t value,
                             const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) {
    if (txid.size() != 32) {
        throw std::invalid_argument("txid must be 32 bytes");
    }
    const std::string txidHex = txidToDisplayHex(txid);
    const std::string scriptHex = bytesToHex(scriptPubkey);

    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "INSERT INTO utxos(txid, vout, height, value, script_pubkey, coinbase, created_at) "
                       "VALUES(?, ?, ?, ?, ?, ?, ?)",
                       -1, &stmt, nullptr);
    const std::string now = utcNow();
    sqlite3_bind_text(stmt, 1, txidHex.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 2, vout);
    sqlite3_bind_int(stmt, 3, height);
    sqlite3_bind_int64(stmt, 4, value);
    sqlite3_bind_text(stmt, 5, scriptHex.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 6, coinbase ? 1 : 0);
    sqlite3_bind_text(stmt, 7, now.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

std::optional<StoredUtxo> ProjectTracker::getUtxo(const std::vector<std::uint8_t>& txid, int vout) const {
    if (txid.size() != 32) {
        return std::nullopt;
    }
    const std::string txidHex = txidToDisplayHex(txid);
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "SELECT txid, vout, height, value, script_pubkey, coinbase FROM utxos "
                       "WHERE txid = ? AND vout = ? LIMIT 1",
                       -1, &stmt, nullptr);
    sqlite3_bind_text(stmt, 1, txidHex.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(stmt, 2, vout);
    std::optional<StoredUtxo> out;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        StoredUtxo entry;
        entry.txid = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
        entry.vout = sqlite3_column_int(stmt, 1);
        entry.height = sqlite3_column_int(stmt, 2);
        entry.value = sqlite3_column_int64(stmt, 3);
        entry.scriptPubkey = hexToBytes(reinterpret_cast<const char*>(sqlite3_column_text(stmt, 4)));
        entry.coinbase = sqlite3_column_int(stmt, 5) != 0;
        out = std::move(entry);
    }
    sqlite3_finalize(stmt);
    return out;
}

void ProjectTracker::spendUtxo(const std::vector<std::uint8_t>& txid, int vout) {
    if (txid.size() != 32) {
        throw std::invalid_argument("txid must be 32 bytes");
    }
    const std::string txidHex = txidToDisplayHex(txid);
    sqlite3_stmt* find = nullptr;
    sqlite3_prepare_v2(db_, "SELECT id FROM utxos WHERE txid = ? AND vout = ? LIMIT 1", -1, &find, nullptr);
    sqlite3_bind_text(find, 1, txidHex.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(find, 2, vout);
    if (sqlite3_step(find) != SQLITE_ROW) {
        sqlite3_finalize(find);
        throw std::runtime_error("UTXO not found: " + txidHex + ":" + std::to_string(vout));
    }
    const int id = sqlite3_column_int(find, 0);
    sqlite3_finalize(find);

    sqlite3_stmt* del = nullptr;
    sqlite3_prepare_v2(db_, "DELETE FROM utxos WHERE id = ?", -1, &del, nullptr);
    sqlite3_bind_int(del, 1, id);
    sqlite3_step(del);
    sqlite3_finalize(del);
}

void ProjectTracker::replaceUtxoUndo(const std::string& chain, int height, const std::vector<StoredUtxo>& entries) {
    sqlite3_stmt* del = nullptr;
    sqlite3_prepare_v2(db_, "DELETE FROM utxo_undo WHERE chain = ? AND height = ?", -1, &del, nullptr);
    sqlite3_bind_text(del, 1, chain.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(del, 2, height);
    sqlite3_step(del);
    sqlite3_finalize(del);

    const std::string encoded = encodeUndoEntries(entries);
    sqlite3_stmt* ins = nullptr;
    sqlite3_prepare_v2(db_,
                       "INSERT INTO utxo_undo(chain, height, entries_json, created_at) VALUES(?, ?, ?, ?)", -1, &ins,
                       nullptr);
    const std::string now = utcNow();
    sqlite3_bind_text(ins, 1, chain.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(ins, 2, height);
    sqlite3_bind_text(ins, 3, encoded.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(ins, 4, now.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(ins);
    sqlite3_finalize(ins);
}

std::vector<StoredUtxo> ProjectTracker::takeUtxoUndo(const std::string& chain, int height) {
    sqlite3_stmt* find = nullptr;
    sqlite3_prepare_v2(db_, "SELECT id, entries_json FROM utxo_undo WHERE chain = ? AND height = ? LIMIT 1", -1,
                       &find, nullptr);
    sqlite3_bind_text(find, 1, chain.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_int(find, 2, height);
    if (sqlite3_step(find) != SQLITE_ROW) {
        sqlite3_finalize(find);
        throw std::runtime_error("No UTXO undo journal for " + chain + " height " + std::to_string(height));
    }
    const int id = sqlite3_column_int(find, 0);
    const char* json = reinterpret_cast<const char*>(sqlite3_column_text(find, 1));
    const std::string entriesJson = json ? json : "[]";
    sqlite3_finalize(find);

    sqlite3_stmt* del = nullptr;
    sqlite3_prepare_v2(db_, "DELETE FROM utxo_undo WHERE id = ?", -1, &del, nullptr);
    sqlite3_bind_int(del, 1, id);
    sqlite3_step(del);
    sqlite3_finalize(del);

    return decodeUndoEntries(entriesJson);
}

void ProjectTracker::deleteUtxosCreatedAtHeight(int height) {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "DELETE FROM utxos WHERE height = ?", -1, &stmt, nullptr);
    sqlite3_bind_int(stmt, 1, height);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

void ProjectTracker::resetValidatedChain(const std::string& chain, const std::string& genesisHash) {
    sqlite3_stmt* utxos = nullptr;
    sqlite3_prepare_v2(db_, "DELETE FROM utxos", -1, &utxos, nullptr);
    sqlite3_step(utxos);
    sqlite3_finalize(utxos);

    sqlite3_stmt* undo = nullptr;
    sqlite3_prepare_v2(db_, "DELETE FROM utxo_undo WHERE chain = ?", -1, &undo, nullptr);
    sqlite3_bind_text(undo, 1, chain.c_str(), -1, SQLITE_STATIC);
    sqlite3_step(undo);
    sqlite3_finalize(undo);

    setValidatedTip(0, genesisHash, chain);
}

std::optional<std::string> ProjectTracker::getHeaderHash(int height) const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT block_hash FROM headers WHERE height = ? LIMIT 1", -1, &stmt, nullptr);
    sqlite3_bind_int(stmt, 1, height);
    std::optional<std::string> out;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const char* text = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
        if (text) {
            out = text;
        }
    }
    sqlite3_finalize(stmt);
    return out;
}

std::optional<StoredBlockRow> ProjectTracker::getBlock(int height) const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "SELECT height, block_hash, file_name, file_offset, size FROM blocks WHERE height = ? LIMIT 1",
                       -1, &stmt, nullptr);
    sqlite3_bind_int(stmt, 1, height);
    std::optional<StoredBlockRow> out;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        StoredBlockRow row;
        row.height = sqlite3_column_int(stmt, 0);
        row.blockHash = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1));
        row.fileName = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 2));
        row.fileOffset = sqlite3_column_int(stmt, 3);
        row.size = sqlite3_column_int(stmt, 4);
        out = std::move(row);
    }
    sqlite3_finalize(stmt);
    return out;
}

int ProjectTracker::maxStoredBlockHeight() const {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT MAX(height) FROM blocks", -1, &stmt, nullptr);
    int height = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL) {
        height = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return height;
}

std::vector<int> ProjectTracker::listMissingBlockHeights(int limit) const {
    std::vector<int> heights;
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "SELECT h.height FROM headers h LEFT JOIN blocks b ON b.height = h.height "
                       "WHERE h.height > 0 AND b.height IS NULL ORDER BY h.height LIMIT ?",
                       -1, &stmt, nullptr);
    sqlite3_bind_int(stmt, 1, limit);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        heights.push_back(sqlite3_column_int(stmt, 0));
    }
    sqlite3_finalize(stmt);
    return heights;
}

std::vector<std::map<std::string, std::string>> ProjectTracker::listWireCapabilities() const {
    std::vector<std::map<std::string, std::string>> rows;
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT * FROM wire_capabilities ORDER BY capability_id", -1, &stmt, nullptr);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        rows.push_back(rowToMap(stmt));
    }
    sqlite3_finalize(stmt);
    return rows;
}

std::string ProjectTracker::wireProgressJson() const {
    const auto caps = listWireCapabilities();
    const auto capMap = wireCapabilityMap();
    const auto summary = wireProgressSummary();
    const auto checkpoints = wireProgressCheckpoints();

    std::vector<std::string> capItems;
    for (const auto& row : caps) {
        capItems.push_back(jsonRowObject(row));
    }

    std::map<std::string, std::string> cpObj;
    for (const auto& [id, row] : checkpoints) {
        std::map<std::string, std::string> fields;
        for (const auto& [k, v] : row) {
            if (k == "required_pass") {
                fields[k] = v == "true" ? "true" : "false";
            } else if (k.ends_with("_total") || k.ends_with("_done")) {
                fields[k] = v;
            } else {
                fields[k] = util::jsonString(v);
            }
        }
        cpObj[id] = util::jsonObject(fields);
    }

    std::map<std::string, std::string> summaryFields;
    for (const auto& [k, v] : summary) {
        if (k == "required_percent" || k == "checkpoints_percent") {
            summaryFields[k] = v;
        } else if (k == "full_node_wire_ready") {
            summaryFields[k] = v == "true" ? "true" : "false";
        } else {
            summaryFields[k] = v;
        }
    }

    std::ostringstream out;
    out << "{";
    out << util::jsonString("capabilities") << ":" << util::jsonArray(capItems) << ",";
    out << util::jsonString("checkpoints") << ":" << util::jsonObject(cpObj) << ",";
    out << util::jsonString("summary") << ":" << util::jsonObject(summaryFields);
    out << "}";
    return out.str();
}

void ProjectTracker::markWireCapability(const std::string& capabilityId, bool implemented,
                                          const std::string& verifiedBy, const std::string& notes) {
    bool found = false;
    for (const auto& cap : wire::capabilities()) {
        if (cap.id == capabilityId) {
            found = true;
            break;
        }
    }
    if (!found) {
        throw std::runtime_error("Unknown wire capability " + capabilityId);
    }
    const std::string now = utcNow();
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
                       "UPDATE wire_capabilities SET implemented=?, verified_by=?, verified_at=?, notes=? "
                       "WHERE capability_id=?",
                       -1, &stmt, nullptr);
    sqlite3_bind_int(stmt, 1, implemented ? 1 : 0);
    sqlite3_bind_text(stmt, 2, implemented ? verifiedBy.c_str() : "", -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 3, implemented ? now.c_str() : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, notes.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 5, capabilityId.c_str(), -1, SQLITE_STATIC);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

std::map<std::string, int> ProjectTracker::wireCapabilityMap() const {
    std::map<std::string, int> out;
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT capability_id, implemented FROM wire_capabilities", -1, &stmt, nullptr);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char* id = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
        out[id ? id : ""] = sqlite3_column_int(stmt, 1);
    }
    sqlite3_finalize(stmt);
    return out;
}

std::map<std::string, std::string> ProjectTracker::wireProgressSummary() const {
    return wire::fullNodeWireProgress(wireCapabilityMap());
}

std::map<std::string, std::map<std::string, std::string>> ProjectTracker::wireProgressCheckpoints() const {
    return wire::checkpointStatus(wireCapabilityMap());
}

std::vector<std::map<std::string, std::string>> ProjectTracker::recentEvents(int limit) const {
    std::vector<std::map<std::string, std::string>> rows;
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT * FROM events ORDER BY id DESC LIMIT ?", -1, &stmt, nullptr);
    sqlite3_bind_int(stmt, 1, limit);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        rows.push_back(rowToMap(stmt));
    }
    sqlite3_finalize(stmt);
    return rows;
}

std::string ProjectTracker::summaryJson(const std::string& chain) const {
    const auto sync = getSyncState(chain);
    const auto wireSummary = wireProgressSummary();
    const auto checkpoints = wireProgressCheckpoints();

    std::ostringstream wireJson;
    wireJson << "{";
    bool firstWire = true;
    for (const auto& [k, v] : wireSummary) {
        if (!firstWire) {
            wireJson << ",";
        }
        firstWire = false;
        wireJson << util::jsonString(k) << ":";
        if (k == "required_percent" || k == "checkpoints_percent") {
            wireJson << v;
        } else if (k == "full_node_wire_ready") {
            wireJson << (v == "true" ? "true" : "false");
        } else {
            wireJson << v;
        }
    }
    wireJson << "}";

    std::vector<std::string> cpItems;
    for (const auto& [id, row] : checkpoints) {
        (void)id;
        std::map<std::string, std::string> fields;
        for (const auto& [k, v] : row) {
            if (k == "required_pass") {
                fields[k] = v == "true" ? "true" : "false";
            } else if (k.ends_with("_total") || k.ends_with("_done")) {
                fields[k] = v;
            } else {
                fields[k] = util::jsonString(v);
            }
        }
        cpItems.push_back(util::jsonObject(fields));
    }

    std::vector<std::string> phaseItems;
    for (const auto& phase : listPhases()) {
        phaseItems.push_back(jsonRowObject(phase));
    }

    std::vector<std::string> eventItems;
    for (const auto& ev : recentEvents(5)) {
        eventItems.push_back(jsonRowObject(ev));
    }

    sqlite3_stmt* peerCount = nullptr;
    sqlite3_prepare_v2(db_, "SELECT COUNT(*) FROM peers", -1, &peerCount, nullptr);
    int peers = 0;
    if (sqlite3_step(peerCount) == SQLITE_ROW) {
        peers = sqlite3_column_int(peerCount, 0);
    }
    sqlite3_finalize(peerCount);

    sqlite3_stmt* connected = nullptr;
    sqlite3_prepare_v2(db_, "SELECT COUNT(*) FROM peers WHERE status = 'connected'", -1, &connected, nullptr);
    int connectedPeers = 0;
    if (sqlite3_step(connected) == SQLITE_ROW) {
        connectedPeers = sqlite3_column_int(connected, 0);
    }
    sqlite3_finalize(connected);

    std::ostringstream syncJson;
    if (sync) {
        std::map<std::string, std::string> syncFields;
        for (const auto& [k, v] : *sync) {
            if (k == "id" || k == "best_height" || k == "header_count") {
                syncFields[k] = v;
            } else {
                syncFields[k] = util::jsonString(v);
            }
        }
        syncJson << util::jsonObject(syncFields);
    } else {
        syncJson << "{}";
    }

    std::ostringstream out;
    out << "{";
    out << util::jsonString("chain") << ":" << util::jsonString(chain) << ",";
    out << util::jsonString("sync") << ":" << syncJson.str() << ",";
    out << util::jsonString("header_count") << ":" << headerCount() << ",";
    out << util::jsonString("block_count") << ":" << blockCount() << ",";
    out << util::jsonString("validated_height") << ":" << getValidatedHeight(chain) << ",";
    out << util::jsonString("validated_hash") << ":" << util::jsonString(getValidatedHash(chain)) << ",";
    out << util::jsonString("utxo_count") << ":" << utxoCount() << ",";
    out << util::jsonString("peer_count") << ":" << peers << ",";
    out << util::jsonString("connected_peers") << ":" << connectedPeers << ",";
    out << util::jsonString("phases") << ":" << util::jsonArray(phaseItems) << ",";
    out << util::jsonString("wire") << ":" << wireJson.str() << ",";
    out << util::jsonString("checkpoints") << ":" << util::jsonObject(
               [&]() {
                   std::map<std::string, std::string> cpObj;
                   for (const auto& [id, row] : checkpoints) {
                       std::map<std::string, std::string> fields;
                       for (const auto& [k, v] : row) {
                           if (k == "required_pass") {
                               fields[k] = v == "true" ? "true" : "false";
                           } else if (k.ends_with("_total") || k.ends_with("_done")) {
                               fields[k] = v;
                           } else {
                               fields[k] = util::jsonString(v);
                           }
                       }
                       cpObj[id] = util::jsonObject(fields);
                   }
                   return cpObj;
               }()) << ",";
    out << util::jsonString("recent_events") << ":" << util::jsonArray(eventItems);
    out << "}";
    return out.str();
}

}  // namespace cpbitnode::db
