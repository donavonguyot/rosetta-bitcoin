#pragma once

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/messages/headers.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/storage/blocks.hpp"

#include <optional>

namespace cpbitnode::p2p {

inline constexpr int kHeaderBatchMax = 2000;

int findCommonForkHeight(const db::ProjectTracker& tracker,
                         const std::vector<std::vector<std::uint8_t>>& locatorHashes);

std::optional<messages::BlockHeader> resolveHeaderRecord(const db::ProjectTracker& tracker,
                                                         const chain::ChainParams& chain, int height,
                                                         const storage::BlockStore* blockStore);

messages::HeadersMessage buildHeadersResponse(const db::ProjectTracker& tracker, const chain::ChainParams& chain,
                                              const messages::GetHeadersMessage& message,
                                              const storage::BlockStore* blockStore = nullptr);

}  // namespace cpbitnode::p2p
