#include "cpbitnode/consensus/block.hpp"

#include "cpbitnode/wire/serialize.hpp"

#include <sstream>
#include <stdexcept>

namespace cpbitnode::consensus {

Block Block::deserialize(std::span<const std::uint8_t> payload) {
    auto [header, offsetAfterHeader] = messages::deserializeBlockHeader(payload, 0);
    std::size_t offset = offsetAfterHeader;
    auto [txCount, afterTxCount] = wire::readVarint(payload, offset);
    offset = afterTxCount;
    if (offset + 1 < payload.size() && payload[offset] == messages::kWitnessMarker0 &&
        payload[offset + 1] == messages::kWitnessMarker1) {
        offset += 2;
    }
    Block block;
    block.header = std::move(header);
    block.transactions.reserve(static_cast<std::size_t>(txCount));
    for (std::uint64_t i = 0; i < txCount; ++i) {
        auto [transaction, nextOffset] = messages::deserializeTransaction(payload, offset);
        offset = nextOffset;
        block.transactions.push_back(std::move(transaction));
    }
    if (offset != payload.size()) {
        std::ostringstream oss;
        oss << "trailing block bytes: " << (payload.size() - offset);
        throw std::runtime_error(oss.str());
    }
    return block;
}

}  // namespace cpbitnode::consensus
