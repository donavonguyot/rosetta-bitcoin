#include "cpbitnode/sync/headers.hpp"

#include "cpbitnode/chain/genesis.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/p2p/peer.hpp"
#include "cpbitnode/sync/validate.hpp"
#include "cpbitnode/util/json.hpp"

#include <algorithm>
#include <cstdio>

namespace cpbitnode::sync {
namespace {

std::vector<std::uint8_t> hashHexToInternal(const std::string& hex) {
    std::vector<std::uint8_t> out;
    out.reserve(hex.size() / 2);
    for (std::size_t index = 0; index + 1 < hex.size(); index += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoi(hex.substr(index, 2), nullptr, 16)));
    }
    std::reverse(out.begin(), out.end());
    return out;
}

std::vector<std::uint8_t> genesisLocator(const chain::ChainParams& chain) {
    const auto genesis = chain::genesisHeaderFor(chain.name);
    return {genesis.blockHash().begin(), genesis.blockHash().end()};
}

std::string bytesToHex(std::span<const std::uint8_t> bytes) {
    std::string out;
    out.reserve(bytes.size() * 2);
    for (const auto b : bytes) {
        char buf[3];
        std::snprintf(buf, sizeof(buf), "%02x", b);
        out += buf;
    }
    return out;
}

}  // namespace

void repairSyncState(db::NodeStateStore& state, const chain::ChainParams& chain) {
    const int height = state.maxHeaderHeight();
    if (height < 0) {
        return;
    }
    const auto hash = state.getHeaderHash(height).value_or(chain.genesisHash);
    state.upsertSyncState(chain.name, height, hash, state.headerCount(), "headers_syncing");
}

messages::BlockHeader ensureGenesis(db::NodeStateStore& state, const chain::ChainParams& chain) {
    const auto genesis = chain::genesisHeaderFor(chain.name);
    const std::string genesisHash = messages::blockHashHex(genesis);
    const auto existing = state.getHeaderHash(0);
    if (existing.has_value()) {
        if (*existing != genesisHash && *existing != chain.genesisHash) {
            throw HeaderValidationError("Stored genesis hash " + *existing + " does not match chain genesis " +
                                        genesisHash);
        }
        if (state.getValidatedHash(chain.name).empty()) {
            state.setValidatedTip(0, genesisHash, chain.name);
        }
        state.markWireCapability("headers.genesis", true, "code", "genesis header present in RocksDB");
        return genesis;
    }

    state.recordHeader(0, genesisHash, std::string(64, '0'), genesis.timestamp, bytesToHex(genesis.serialize()));
    state.setValidatedTip(0, genesisHash, chain.name);
    state.upsertSyncState(chain.name, 0, genesisHash, state.headerCount(), "genesis_seeded");
    state.markWireCapability("headers.genesis", true, "code", "genesis header seeded");
    return genesis;
}

std::vector<int> locatorHeights(int tip) {
    int cursor = tip;
    int step = 1;
    std::vector<int> heights;
    heights.push_back(tip);
    while (cursor > 0) {
        cursor = std::max(cursor - step, 0);
        heights.push_back(cursor);
        step <<= 1;
    }
    return heights;
}

std::vector<std::vector<std::uint8_t>> nextLocator(db::NodeStateStore& state, const chain::ChainParams& chain) {
    ensureGenesis(state, chain);
    const auto syncState = state.getSyncState(chain.name);
    const int bestHeight = syncState.has_value() ? std::stoi((*syncState).at("best_height")) : 0;
    std::vector<std::vector<std::uint8_t>> hashes;
    for (const int height : locatorHeights(bestHeight)) {
        const auto blockHash = state.getHeaderHash(height);
        if (blockHash.has_value()) {
            hashes.push_back(hashHexToInternal(*blockHash));
        }
    }
    if (hashes.empty()) {
        return {genesisLocator(chain)};
    }
    state.markWireCapability("headers.locator", true, "code",
                             "locator built from height " + std::to_string(bestHeight));
    return hashes;
}

std::tuple<int, std::string, int> persistHeaders(db::NodeStateStore& state, const chain::ChainParams& chain,
                                                 const messages::HeadersMessage& message) {
    ensureGenesis(state, chain);
    const auto syncState = state.getSyncState(chain.name);
    int tipHeight = syncState.has_value() ? std::stoi((*syncState).at("best_height")) : 0;
    std::string tipHashHex = state.getHeaderHash(tipHeight).value_or(chain.genesisHash);
    auto tipInternal = hashHexToInternal(tipHashHex);

    int stored = 0;
    std::vector<db::HeaderRecord> records;
    records.reserve(message.headers.size());
    for (const auto& header : message.headers) {
        try {
            validateHeader(header, tipInternal);
        } catch (const HeaderValidationError& exc) {
            state.logEvent("sync", "Header rejected at height " + std::to_string(tipHeight + 1) + ": " + exc.what(),
                           "warning");
            break;
        }

        tipHeight += 1;
        const std::string blockHash = header.blockHashHex();
        std::string prevHash;
        prevHash.reserve(header.prevBlock.size() * 2);
        for (auto it = header.prevBlock.rbegin(); it != header.prevBlock.rend(); ++it) {
            char buf[3];
            std::snprintf(buf, sizeof(buf), "%02x", *it);
            prevHash += buf;
        }
        records.push_back(db::HeaderRecord{tipHeight, blockHash, prevHash, static_cast<int>(header.timestamp),
                                           bytesToHex(header.serialize())});
        tipInternal = header.blockHash();
        stored += 1;
    }

    if (stored > 0) {
        state.recordHeaders(records);
        tipHashHex = records.back().blockHash;
        state.upsertSyncState(chain.name, tipHeight, tipHashHex, state.headerCount(), "headers_syncing");
        state.markWireCapability("headers.pow", true, "code", "header PoW validated");
        state.markWireCapability("headers.chain_link", true, "code", "header chain link validated");
        state.markWireCapability("headers.persist", true, stored > 0 ? "live" : "code",
                                 "stored " + std::to_string(stored) + " headers");
    }
    return {tipHeight, stored > 0 ? records.back().blockHash : state.getHeaderHash(tipHeight).value_or(chain.genesisHash),
            stored};
}

bool headersSyncDone(int bestHeight, int peerHeight, int batchCount) {
    if (batchCount == 0) {
        return true;
    }
    return peerHeight >= 0 && bestHeight >= peerHeight;
}

int localHeaderTipHeight(const db::NodeStateStore& state, const chain::ChainParams& chain) {
    const auto syncState = state.getSyncState(chain.name);
    const int bestState = syncState.has_value() ? std::stoi((*syncState).at("best_height")) : 0;
    return std::max(bestState, state.maxHeaderHeight());
}

int requiredHeaderTipForBlockFollowup(const db::NodeStateStore& state, const chain::ChainParams& chain,
                                      int blocksTargetHeight) {
    const int validated = state.getValidatedHeight(chain.name);
    int need = validated + 1;
    if (blocksTargetHeight > 0) {
        need = std::max(need, blocksTargetHeight);
    }
    return std::max(need, validated + 1);
}

bool localHeadersCoverBlockFollowup(const db::NodeStateStore& state, const chain::ChainParams& chain,
                                    int blocksTargetHeight) {
    const int needThrough = requiredHeaderTipForBlockFollowup(state, chain, blocksTargetHeight);
    const int tip = std::max(localHeaderTipHeight(state, chain), state.maxHeaderHeight());
    if (tip < needThrough) {
        return false;
    }
    return state.getHeaderHash(needThrough).has_value();
}

bool shouldSkipHeaderDownload(const db::NodeStateStore& state, const chain::ChainParams& chain, int peerTipHeight) {
    if (peerTipHeight < 0) {
        return false;
    }
    const int tipLocal = localHeaderTipHeight(state, chain);
    return tipLocal >= peerTipHeight - kHeaderSyncNearPeerTip;
}

void markHeadersCurrent(db::NodeStateStore& state, const chain::ChainParams& chain) {
    const auto syncState = state.getSyncState(chain.name);
    const int bestHeight = syncState.has_value() ? std::stoi((*syncState).at("best_height")) : 0;
    const std::string bestHash = syncState.has_value() ? (*syncState).at("best_hash") : chain.genesisHash;
    state.upsertSyncState(chain.name, bestHeight, bestHash, state.headerCount(), "headers_current");
    state.markWireCapability("headers.sync_to_tip", true, "live", "header chain at network tip");
    state.markWireCapability("headers.resume", true, "code", "resume header sync from RocksDB");
}

int resolveBootstrapStartHeight(const db::NodeStateStore& state, const chain::ChainParams& chain,
                                const config::Settings& settings) {
    const bool skipHeaderNetwork = settings.noHeaderRefresh || settings.syncSkipHeaders;
    if (skipHeaderNetwork) {
        return state.getValidatedHeight(chain.name);
    }
    const auto syncState = state.getSyncState(chain.name);
    const std::string status = syncState.has_value() ? (*syncState).at("sync_status") : "starting";
    if (status != "headers_current" && status != "running") {
        return state.getValidatedHeight(chain.name);
    }
    return localHeaderTipHeight(state, chain);
}

int syncHeadersToTip(p2p::PeerConnection& connection, std::optional<int> peerHeight, std::optional<int> stopHeight) {
    const auto& chain = connection.chain();
    auto& tracker = connection.tracker();
    int targetHeight =
        peerHeight.has_value() ? *peerHeight
                               : (connection.remoteVersion() ? connection.remoteVersion()->startHeight : -1);
    const bool boundedTarget = stopHeight.has_value() && *stopHeight > 0 &&
                               (targetHeight < 0 || *stopHeight < targetHeight);
    if (boundedTarget) {
        targetHeight = *stopHeight;
    }
    auto targetCovered = [&]() {
        if (!boundedTarget) {
            return shouldSkipHeaderDownload(tracker, chain, targetHeight);
        }
        return localHeaderTipHeight(tracker, chain) >= targetHeight && tracker.getHeaderHash(targetHeight).has_value();
    };

    ensureGenesis(tracker, chain);

    if (targetCovered()) {
        if (!boundedTarget) {
            markHeadersCurrent(tracker, chain);
        }
        return 0;
    }

    int totalStored = 0;
    while (true) {
        const auto state = tracker.getSyncState(chain.name);
        const int bestHeight = state.has_value() ? std::stoi((*state).at("best_height")) : 0;
        const auto locator = nextLocator(tracker, chain);

        if (targetCovered()) {
            if (!boundedTarget) {
                markHeadersCurrent(tracker, chain);
            }
            return totalStored;
        }

        auto message = connection.requestHeaders(locator);
        if (boundedTarget && bestHeight < targetHeight &&
            bestHeight + static_cast<int>(message.headers.size()) > targetHeight) {
            message.headers.resize(static_cast<std::size_t>(targetHeight - bestHeight));
        }
        const int batchCount = static_cast<int>(message.headers.size());

        if (headersSyncDone(bestHeight, targetHeight, batchCount)) {
            if (!boundedTarget) {
                markHeadersCurrent(tracker, chain);
            }
            break;
        }

        const auto [_, __, stored] = persistHeaders(tracker, chain, message);
        (void)_;
        (void)__;
        totalStored += stored;

        if (stored == 0) {
            if (!boundedTarget) {
                markHeadersCurrent(tracker, chain);
            }
            break;
        }

        const auto refreshed = tracker.getSyncState(chain.name);
        const int updatedHeight = refreshed.has_value() ? std::stoi((*refreshed).at("best_height")) : bestHeight;
        if (boundedTarget && updatedHeight >= targetHeight) {
            break;
        }
        if (headersSyncDone(updatedHeight, targetHeight, batchCount)) {
            if (!boundedTarget) {
                markHeadersCurrent(tracker, chain);
            }
            break;
        }
    }

    return totalStored;
}

}  // namespace cpbitnode::sync
