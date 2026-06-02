#pragma once

#include "cpbitnode/messages/block_header.hpp"

#include <string>

namespace cpbitnode::chain {

using BlockHeader = messages::BlockHeader;

BlockHeader testnet4Genesis();
BlockHeader regtestGenesis();
BlockHeader genesisHeaderFor(const std::string& chainName);

inline std::vector<std::uint8_t> serializeHeader(const BlockHeader& header) {
    return messages::serializeBlockHeader(header);
}

inline std::string blockHeaderHashHex(const BlockHeader& header) {
    return messages::blockHashHex(header);
}

}  // namespace cpbitnode::chain
