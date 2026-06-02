#pragma once

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/mempool/mempool.hpp"
#include "cpbitnode/p2p/peer.hpp"
#include "cpbitnode/storage/blocks.hpp"

#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace cpbitnode::p2p {

void handleInboundGetdata(PeerConnection& peer, db::ProjectTracker& tracker, const chain::ChainParams& chain,
                          storage::BlockStore& blockStore, std::span<const std::uint8_t> payload,
                          mempool::Mempool* mempool = nullptr);

void dispatchInboundMessage(PeerConnection& peer, db::ProjectTracker& tracker, const chain::ChainParams& chain,
                            const config::Settings& settings, storage::BlockStore& blockStore,
                            mempool::Mempool* mempool, const std::string& command,
                            std::span<const std::uint8_t> payload);

void serveInboundSession(std::unique_ptr<Transport> transport, const std::string& host, int port,
                         const chain::ChainParams& chain, db::ProjectTracker& tracker,
                         const config::Settings& settings, storage::BlockStore& blockStore,
                         mempool::Mempool* mempool = nullptr, RelayTxAcceptedFn relayTxAccepted = {});

/** Start TCP listener when settings.listen is true. Returns listen fd or -1. */
int startInboundListener(const chain::ChainParams& chain, db::ProjectTracker& tracker,
                         const config::Settings& settings);

struct InboundServerHandle {
    int listenFd = -1;
    std::thread acceptThread;
    std::atomic<bool> stop{false};

    InboundServerHandle() = default;
    InboundServerHandle(InboundServerHandle&& other) noexcept
        : listenFd(other.listenFd), acceptThread(std::move(other.acceptThread)), stop(other.stop.load()) {
        other.listenFd = -1;
        other.stop.store(false);
    }
    InboundServerHandle& operator=(InboundServerHandle&& other) noexcept {
        if (this == &other) {
            return *this;
        }
        stop.store(true);
        if (acceptThread.joinable()) {
            acceptThread.join();
        }
        if (listenFd >= 0) {
            ::close(listenFd);
        }
        listenFd = other.listenFd;
        acceptThread = std::move(other.acceptThread);
        stop.store(other.stop.load());
        other.listenFd = -1;
        other.stop.store(false);
        return *this;
    }
    InboundServerHandle(const InboundServerHandle&) = delete;
    InboundServerHandle& operator=(const InboundServerHandle&) = delete;
};

InboundServerHandle startInboundServer(const chain::ChainParams& chain, db::ProjectTracker& tracker,
                                       const config::Settings& settings, storage::BlockStore& blockStore,
                                       mempool::Mempool* mempool, RelayTxAcceptedFn relayTxAccepted);

void stopInboundServer(InboundServerHandle& handle);

}  // namespace cpbitnode::p2p
