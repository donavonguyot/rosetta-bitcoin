#pragma once

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/chainstate.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/mempool/mempool.hpp"
#include "cpbitnode/p2p/peer.hpp"
#include "cpbitnode/storage/blocks.hpp"

#include <atomic>
#include <functional>
#include <memory>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace cpbitnode::p2p {

class PeerManager {
public:
    PeerManager(const chain::ChainParams& chain, db::NodeStateStore& tracker, config::Settings settings);

    void connectPeers(const std::vector<std::pair<std::string, int>>& targets, int startHeight = 0,
                      bool discoverPeerAddresses = true);
    void bootstrap(const std::vector<std::pair<std::string, int>>& manualPeers, int startHeight = 0);
    int syncHeaders(bool bestEffortIfHeadersCoverFollowupBlocks = false, std::optional<int> stopHeight = std::nullopt);
    int syncBlocks(storage::BlockStore& blockStore);
    int syncBlocks(storage::BlockStore& blockStore, db::ChainstateStore& chainstate);
    void completeDeferredHandshake();
    void relayAcceptedTransaction(const messages::Transaction& tx, PeerConnection& source);
    void run();
    void close();

    mempool::Mempool& mempool() { return *mempool_; }
    const mempool::Mempool& mempool() const { return *mempool_; }
    const std::vector<std::unique_ptr<PeerConnection>>& connections() const { return connections_; }

    /** Test hook: replace peer factory. */
    using PeerFactory = std::function<std::unique_ptr<PeerConnection>(const std::string&, int)>;
    void setPeerFactoryForTest(PeerFactory factory);

private:
    std::vector<PeerConnection*> orderedSyncPeers() const;
    std::unique_ptr<PeerConnection> makePeer(const std::string& host, int port, int startHeight);

    const chain::ChainParams& chain_;
    db::NodeStateStore& tracker_;
    config::Settings settings_;
    std::unique_ptr<mempool::Mempool> mempool_;
    std::vector<std::unique_ptr<PeerConnection>> connections_;
    std::vector<std::thread> runThreads_;
    int effectiveMaxOutbound_ = 0;
    std::set<std::pair<std::string, int>> manualSyncPeers_;
    PeerFactory peerFactory_;
};

}  // namespace cpbitnode::p2p
