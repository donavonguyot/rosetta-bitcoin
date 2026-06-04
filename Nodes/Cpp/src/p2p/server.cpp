#include "cpbitnode/p2p/server.hpp"

#include "cpbitnode/messages/block.hpp"
#include "cpbitnode/messages/headers.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/mempool/relay.hpp"
#include "cpbitnode/p2p/ban_policy.hpp"
#include "cpbitnode/p2p/headerServing.hpp"
#include "cpbitnode/p2p/transport.hpp"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <iomanip>
#include <sstream>

namespace cpbitnode::p2p {
namespace {

std::string invHashToDisplayHex(const std::vector<std::uint8_t>& hash) {
    std::ostringstream oss;
    for (auto it = hash.rbegin(); it != hash.rend(); ++it) {
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(*it);
    }
    return oss.str();
}

bool isBlockInventoryType(std::uint32_t type) {
    return type == messages::MSG_BLOCK || type == messages::MSG_WITNESS_BLOCK;
}

bool isTxInventoryType(std::uint32_t type) {
    return type == messages::MSG_TX || type == messages::MSG_WITNESS_TX;
}

}  // namespace

void handleInboundGetdata(PeerConnection& peer, db::NodeStateStore& tracker, const chain::ChainParams& chain,
                          storage::BlockStore& blockStore, std::span<const std::uint8_t> payload,
                          mempool::Mempool* mempool) {
    const auto getdata = messages::GetDataMessage::deserialize(payload);
    if (getdata.inventory.empty()) {
        return;
    }

    std::vector<messages::InventoryVector> blockItems;
    std::vector<messages::InventoryVector> txItems;
    std::vector<messages::InventoryVector> forwardItems;
    blockItems.reserve(getdata.inventory.size());
    txItems.reserve(getdata.inventory.size());
    forwardItems.reserve(getdata.inventory.size());

    for (const auto& item : getdata.inventory) {
        if (isBlockInventoryType(item.type)) {
            blockItems.push_back(item);
        } else if (isTxInventoryType(item.type)) {
            txItems.push_back(item);
        } else {
            forwardItems.push_back(item);
        }
    }

    std::vector<messages::InventoryVector> notFoundBlocks;
    bool servedBlock = false;
    for (const auto& item : blockItems) {
        const auto row = tracker.getStoredBlockForHashHex(invHashToDisplayHex(item.hash));
        if (!row.has_value()) {
            notFoundBlocks.push_back(item);
            continue;
        }
        try {
            const auto blockBytes = blockStore.read(row->fileName, row->fileOffset, row->size);
            if (messages::blockHashFromPayload(blockBytes) != item.hash) {
                notFoundBlocks.push_back(item);
                continue;
            }
            peer.send(std::string(messages::BlockMessage::kCommand), blockBytes);
            servedBlock = true;
        } catch (const std::exception&) {
            notFoundBlocks.push_back(item);
        }
    }

    if (servedBlock) {
        tracker.markWireCapability("serve.getdata.blocks", true, "live",
                                   "served MSG_BLOCK / MSG_WITNESS_BLOCK from BlockStore");
    }
    if (!notFoundBlocks.empty()) {
        messages::NotFoundMessage nf;
        nf.inventory = std::move(notFoundBlocks);
        peer.send(messages::NotFoundMessage::kCommand, nf.serialize());
    }

    mempool::replyGetdataTxInventory(peer, mempool, tracker, txItems);

    if (!forwardItems.empty()) {
        messages::GetDataMessage forward;
        forward.inventory = std::move(forwardItems);
        const auto forwardPayload = forward.serialize();
        peer.dispatchMessage(messages::GetDataMessage::kCommand, forwardPayload);
    }
}

void dispatchInboundMessage(PeerConnection& peer, db::NodeStateStore& tracker, const chain::ChainParams& chain,
                            const config::Settings& settings, storage::BlockStore& blockStore,
                            mempool::Mempool* mempool, const std::string& command,
                            std::span<const std::uint8_t> payload) {
    if (command == messages::GetHeadersMessage::kCommand) {
        const auto message = messages::GetHeadersMessage::deserialize(payload);
        const auto reply = buildHeadersResponse(tracker, chain, message, &blockStore);
        const auto serialized = messages::serializeHeadersMessage(reply);
        peer.send(std::string(messages::HeadersMessage::kCommand), serialized);
        tracker.markWireCapability("serve.getheaders", true, "live",
                                   "answered getheaders with " + std::to_string(reply.headers.size()) + " headers");
        return;
    }
    if (command == messages::GetDataMessage::kCommand) {
        handleInboundGetdata(peer, tracker, chain, blockStore, payload, mempool);
        return;
    }
    peer.dispatchMessage(command, payload);
}

void serveInboundSession(std::unique_ptr<Transport> transport, const std::string& host, int port,
                         const chain::ChainParams& chain, db::NodeStateStore& tracker,
                         const config::Settings& settings, storage::BlockStore& blockStore,
                         mempool::Mempool* mempool, RelayTxAcceptedFn relayTxAccepted) {
    PeerConnection::Options options;
    options.host = host;
    options.port = port;
    options.chain = &chain;
    options.tracker = &tracker;
    options.settings = settings;
    options.protocolVersion = settings.protocolVersion;
    options.userAgent = settings.userAgent;
    options.mempool = mempool;
    options.relayTxAccepted = std::move(relayTxAccepted);
    if (const auto sync = tracker.getSyncState(chain.name)) {
        const auto it = sync->find("best_height");
        if (it != sync->end()) {
            options.startHeight = std::stoi(it->second);
        }
    }
    options.pingIntervalSeconds = settings.pingIntervalSeconds;
    options.staleTimeoutSeconds = settings.peerStaleSeconds;

    PeerConnection peer(std::move(options));
    peer.setTransportForTest(std::move(transport));
    try {
        peer.acceptInbound();
    } catch (const std::exception&) {
        if (host != "unknown" && port > 0) {
            tracker.incrementPeerBanScore(host, port, kBanHandshakeFail);
        }
        return;
    }

    peer.consumeMessages([&](const std::string& command, std::span<const std::uint8_t> msgPayload) {
        dispatchInboundMessage(peer, tracker, chain, settings, blockStore, mempool, command, msgPayload);
    });
    peer.close();
}

int startInboundListener(const chain::ChainParams& chain, db::NodeStateStore& tracker,
                         const config::Settings& settings) {
    if (!settings.listen) {
        return -1;
    }
    const int bindPort = settings.p2pPort > 0 ? settings.p2pPort : chain.defaultPort;
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    const int opt = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(static_cast<std::uint16_t>(bindPort));
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        return -1;
    }
    if (::listen(fd, 8) != 0) {
        ::close(fd);
        return -1;
    }
    tracker.logEvent("node", "Inbound TCP listening on 0.0.0.0:" + std::to_string(bindPort), "info",
                     "{\"listen\":true}");
    tracker.markWireCapability("transport.inbound", true, "live", "TCP listener accepting peers");
    return fd;
}

InboundServerHandle startInboundServer(const chain::ChainParams& chain, db::NodeStateStore& tracker,
                                       const config::Settings& settings, storage::BlockStore& blockStore,
                                       mempool::Mempool* mempool, RelayTxAcceptedFn relayTxAccepted) {
    InboundServerHandle handle;
    handle.listenFd = startInboundListener(chain, tracker, settings);
    if (handle.listenFd < 0) {
        return std::move(handle);
    }
    const RelayTxAcceptedFn relayHandler = std::move(relayTxAccepted);
    handle.acceptThread = std::thread([&handle, listenFd = handle.listenFd, chainPtr = &chain, trackerPtr = &tracker,
                                       settingsCopy = settings, blockStorePtr = &blockStore, mempoolPtr = mempool,
                                       relayHandler]() {
        while (!handle.stop.load()) {
            pollfd pfd{};
            pfd.fd = listenFd;
            pfd.events = POLLIN;
            const int ready = ::poll(&pfd, 1, 200);
            if (handle.stop.load()) {
                break;
            }
            if (ready <= 0) {
                continue;
            }
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                break;
            }
            sockaddr_in clientAddr{};
            socklen_t clientLen = sizeof(clientAddr);
            const int clientFd = ::accept(listenFd, reinterpret_cast<sockaddr*>(&clientAddr), &clientLen);
            if (clientFd < 0) {
                continue;
            }
            char hostBuf[INET_ADDRSTRLEN] = {};
            ::inet_ntop(AF_INET, &clientAddr.sin_addr, hostBuf, sizeof(hostBuf));
            const std::string host = hostBuf;
            const int port = ntohs(clientAddr.sin_port);
            trackerPtr->logEvent("node", "Inbound connection from " + host + ":" + std::to_string(port), "info", "{}");
            std::thread([host, port, clientFd, chainPtr, trackerPtr, settingsCopy, blockStorePtr, mempoolPtr,
                         relayHandler]() mutable {
                try {
                    serveInboundSession(wrapTcpFd(clientFd), host, port, *chainPtr, *trackerPtr, settingsCopy,
                                        *blockStorePtr, mempoolPtr, relayHandler);
                } catch (const std::exception&) {
                    ::close(clientFd);
                }
            }).detach();
        }
    });
    return std::move(handle);
}

void stopInboundServer(InboundServerHandle& handle) {
    handle.stop.store(true);
    if (handle.listenFd >= 0) {
        ::shutdown(handle.listenFd, SHUT_RDWR);
        ::close(handle.listenFd);
        handle.listenFd = -1;
    }
    if (handle.acceptThread.joinable()) {
        handle.acceptThread.join();
    }
}

}  // namespace cpbitnode::p2p
