#pragma once

#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/p2p/peer.hpp"

#include <functional>
#include <memory>
#include <string>

namespace cpbitnode {

/** Run cpbitnode until signal/shutdown. Returns process exit code. */
int runNode(
    const config::Settings& settings,
    std::function<std::unique_ptr<p2p::PeerConnection>(const std::string&, int, db::ProjectTracker&)>
        peerFactoryForTest = {});

}  // namespace cpbitnode
