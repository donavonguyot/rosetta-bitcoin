#include "cpbitnode/p2p/headerServing.hpp"

#include "cpbitnode/chain/genesis.hpp"
#include "cpbitnode/messages/block.hpp"

#include <algorithm>

namespace cpbitnode::p2p {
namespace {

std::string internalHashToDisplayHex(std::span<const std::uint8_t> hash) {
    static const char* kHex = "0123456789abcdef";
    std::string out;
    out.reserve(64);
    for (auto it = hash.rbegin(); it != hash.rend(); ++it) {
        out.push_back(kHex[(*it >> 4) & 0xf]);
        out.push_back(kHex[*it & 0xf]);
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

bool isZeroHash(std::span<const std::uint8_t> hash) {
    return std::all_of(hash.begin(), hash.end(), [](std::uint8_t b) { return b == 0; });
}

}  // namespace

int findCommonForkHeight(const db::NodeStateStore& tracker,
                         const std::vector<std::vector<std::uint8_t>>& locatorHashes) {
    for (const auto& internalHash : locatorHashes) {
        if (internalHash.size() != 32) {
            continue;
        }
        const auto display = internalHashToDisplayHex(internalHash);
        if (const auto height = tracker.lookupHeaderHeight(display)) {
            return *height;
        }
    }
    return -1;
}

std::optional<messages::BlockHeader> resolveHeaderRecord(const db::NodeStateStore& tracker,
                                                         const chain::ChainParams& chain, int height,
                                                         const storage::BlockStore* blockStore) {
    const auto hashHex = tracker.getHeaderHash(height);
    if (!hashHex.has_value()) {
        return std::nullopt;
    }
    const std::string storedHashHex = *hashHex;

    if (const auto serializedHex = tracker.getHeaderSerializedHex(height)) {
        const auto blob = hexToBytes(*serializedHex);
        if (blob.size() != messages::kHeaderSize) {
            return std::nullopt;
        }
        const auto [header, consumed] = messages::deserializeBlockHeader(blob, 0);
        if (consumed != messages::kHeaderSize || messages::blockHashHex(header) != storedHashHex) {
            return std::nullopt;
        }
        return header;
    }

    if (height == 0) {
        const auto genesis = chain::genesisHeaderFor(chain.name);
        if (storedHashHex == messages::blockHashHex(genesis)) {
            return genesis;
        }
        return std::nullopt;
    }

    const auto blockRow = tracker.getBlock(height);
    if (blockStore == nullptr || !blockRow.has_value()) {
        return std::nullopt;
    }
    try {
        const auto raw = blockStore->read(blockRow->fileName, static_cast<std::size_t>(blockRow->fileOffset),
                                          static_cast<std::size_t>(blockRow->size));
        const auto [header, consumed] = messages::deserializeBlockHeader(raw, 0);
        if (consumed != messages::kHeaderSize || messages::blockHashHex(header) != storedHashHex) {
            return std::nullopt;
        }
        return header;
    } catch (const std::exception&) {
        return std::nullopt;
    }
}

messages::HeadersMessage buildHeadersResponse(const db::NodeStateStore& tracker, const chain::ChainParams& chain,
                                              const messages::GetHeadersMessage& message,
                                              const storage::BlockStore* blockStore) {
    const bool zeroStop = message.hashStop.size() == 32 && isZeroHash(message.hashStop);

    if (message.locatorHashes.empty()) {
        if (zeroStop) {
            return {};
        }
        const auto stopHex = internalHashToDisplayHex(message.hashStop);
        const auto stopHeight = tracker.lookupHeaderHeight(stopHex);
        if (!stopHeight.has_value()) {
            return {};
        }
        const auto resolved = resolveHeaderRecord(tracker, chain, *stopHeight, blockStore);
        if (!resolved.has_value() || resolved->blockHash() != message.hashStop) {
            return {};
        }
        return messages::HeadersMessage{{*resolved}};
    }

    const int forkHeight = findCommonForkHeight(tracker, message.locatorHashes);
    const int start = std::max(forkHeight + 1, 0);
    const int tip = tracker.maxHeaderHeight();
    const std::vector<std::uint8_t>* explicitStop = zeroStop ? nullptr : &message.hashStop;
    if (explicitStop != nullptr) {
        const auto stopHeight = tracker.lookupHeaderHeight(internalHashToDisplayHex(*explicitStop));
        if (stopHeight.has_value() && *stopHeight < start) {
            return {};
        }
    }

    messages::HeadersMessage reply;
    for (int height = start; height <= tip; ++height) {
        if (static_cast<int>(reply.headers.size()) >= kHeaderBatchMax) {
            break;
        }
        const auto resolved = resolveHeaderRecord(tracker, chain, height, blockStore);
        if (!resolved.has_value()) {
            break;
        }
        reply.headers.push_back(*resolved);
        if (explicitStop != nullptr && resolved->blockHash() == *explicitStop) {
            break;
        }
    }
    return reply;
}

}  // namespace cpbitnode::p2p
