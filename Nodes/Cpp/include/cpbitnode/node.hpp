#pragma once

#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/p2p/peer.hpp"

#include <functional>
#include <memory>
#include <string>

namespace cpbitnode {

/** Run cpbitnode until signal/shutdown. Returns process exit code. */
int runNode(
    const config::Settings& settings,
    std::function<std::unique_ptr<p2p::PeerConnection>(const std::string&, int, db::NodeStateStore&)>
        peerFactoryForTest = {});

}  // namespace cpbitnode
