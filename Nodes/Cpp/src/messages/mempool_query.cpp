#include "cpbitnode/messages/mempool_query.hpp"

namespace cpbitnode::messages {

std::vector<std::uint8_t> MempoolRequestMessage::serialize() const { return {}; }

MempoolRequestMessage MempoolRequestMessage::deserialize(std::span<const std::uint8_t> /*payload*/) {
    return {};
}

}  // namespace cpbitnode::messages
