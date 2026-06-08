#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/consensus/block.hpp"
#include "cpbitnode/consensus/script/verify.hpp"
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
    std::optional<db::StoredBlockRow> blockIndex;
    script::ScriptVerifyRunner* scriptRunner = nullptr;
};

// Validation boundary: block-local UTXO view, script verification, then atomic chainstate commit.
// Missing rules must stop as validation blockers, not implicit success.
Block connectBlock(db::NodeStateStore& tracker, std::span<const std::uint8_t> payload,
                   const ConnectBlockOptions& options);
Block connectBlock(db::NodeStateStore& tracker, db::ChainstateStore& chainstate,
                   std::span<const std::uint8_t> payload, const ConnectBlockOptions& options);
Block connectDecodedBlock(db::NodeStateStore& tracker, db::ChainstateStore& chainstate, const Block& block,
                          const ConnectBlockOptions& options);
void disconnectBlock(db::NodeStateStore& tracker, int height, const chain::ChainParams& chain);
void disconnectBlock(db::NodeStateStore& tracker, db::ChainstateStore& chainstate, int height,
                     const chain::ChainParams& chain);

}  // namespace cpbitnode::consensus
