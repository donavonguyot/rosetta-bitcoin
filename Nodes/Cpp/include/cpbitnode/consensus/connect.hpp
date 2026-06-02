#pragma once

#include <cstdint>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/consensus/block.hpp"
#include "cpbitnode/db/chainstate.hpp"
#include "cpbitnode/db/node_state.hpp"

namespace cpbitnode::consensus {

class ConnectBlockError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct ConnectBlockOptions {
    int height = 0;
    std::vector<std::uint8_t> expectedPrev;
    std::vector<std::uint8_t> expectedHash;
    bool hasExpectedHash = false;
    std::string chainName = "testnet4";
};

Block connectBlock(db::NodeStateStore& tracker, std::span<const std::uint8_t> payload,
                   const ConnectBlockOptions& options);
Block connectBlock(db::NodeStateStore& tracker, db::ChainstateStore& chainstate,
                   std::span<const std::uint8_t> payload, const ConnectBlockOptions& options);
void disconnectBlock(db::NodeStateStore& tracker, int height, const chain::ChainParams& chain);
void disconnectBlock(db::NodeStateStore& tracker, db::ChainstateStore& chainstate, int height,
                     const chain::ChainParams& chain);

}  // namespace cpbitnode::consensus
