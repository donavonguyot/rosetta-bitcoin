#include "cpbitnode/p2p/peer.hpp"

#include "cpbitnode/messages/address.hpp"
#include "cpbitnode/messages/block.hpp"
#include "cpbitnode/messages/fee_filter.hpp"
#include "cpbitnode/messages/headers.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/messages/mempool_query.hpp"
#include "cpbitnode/consensus/witness.hpp"
#include "cpbitnode/mempool/mempool.hpp"
#include "cpbitnode/mempool/relay.hpp"
#include "cpbitnode/metrics.hpp"
#include "cpbitnode/p2p/ban_policy.hpp"
#include "cpbitnode/sync/headers.hpp"
#include "cpbitnode/util/json.hpp"
#include "cpbitnode/wire/frame.hpp"

#include <algorithm>
#include <atomic>
#include <random>
#include <stdexcept>

namespace cpbitnode::p2p {
namespace {

using Clock = std::chrono::steady_clock;

std::atomic<std::uint64_t> gP2PFramesRead{0};
std::atomic<std::uint64_t> gP2PBytesRead{0};
std::atomic<std::uint64_t> gP2PHeaderReadUs{0};
std::atomic<std::uint64_t> gP2PPayloadReadUs{0};

double feefilterWireSatKvbFromSettings(const config::Settings& settings) {
    if (settings.minRelayFeerateSatVb <= 0) {
        return 0;
    }
    return static_cast<double>(settings.minRelayFeerateSatVb) * 1000.0;
}

std::uint64_t randomNonce() {
    std::random_device rd;
    std::mt19937_64 gen(rd());
    std::uniform_int_distribution<std::uint64_t> dist;
    return dist(gen);
}

messages::NetworkAddress blankAddress() {
    return messages::NetworkAddress{messages::NODE_NETWORK | messages::NODE_WITNESS, "0.0.0.0", 0};
}

}  // namespace

P2PReadTelemetry p2pReadTelemetrySnapshot() {
    return P2PReadTelemetry{
        gP2PFramesRead.load(std::memory_order_relaxed),
        gP2PBytesRead.load(std::memory_order_relaxed),
        gP2PHeaderReadUs.load(std::memory_order_relaxed),
        gP2PPayloadReadUs.load(std::memory_order_relaxed),
    };
}

PeerConnection::PeerConnection(Options options) : options_(std::move(options)) {
    if (options_.chain == nullptr || options_.tracker == nullptr) {
        throw std::invalid_argument("PeerConnection requires chain and tracker");
    }
    const auto now = Clock::now();
    lastActivity_ = now;
    lastPing_ = now;
}

void PeerConnection::setTransportForTest(std::unique_ptr<Transport> transport) {
    transport_ = std::move(transport);
}

void PeerConnection::setReadMessageOverrideForTest(ReadMessageOverride overrideFn) {
    readOverride_ = std::move(overrideFn);
}

void PeerConnection::setActivityTimestampsForTest(std::chrono::steady_clock::time_point lastActivity,
                                                  std::chrono::steady_clock::time_point lastPing) {
    lastActivity_ = lastActivity;
    lastPing_ = lastPing;
}

bool PeerConnection::isConnected() const { return transport_ != nullptr && transport_->isOpen(); }

bool PeerConnection::lightweightOutboundHandshake() const {
    return options_.settings.lightweightOutboundHandshake();
}

const messages::VersionMessage* PeerConnection::remoteVersion() const {
    return remoteVersion_.has_value() ? &*remoteVersion_ : nullptr;
}

void PeerConnection::connect() {
    if (!transport_) {
        if (options_.transportFactory) {
            transport_ = options_.transportFactory(options_.host, options_.port);
        } else {
            transport_ = connectTcp(options_.host, options_.port);
        }
    }
    const auto now = Clock::now();
    lastActivity_ = now;
    lastPing_ = now;
    handshakeAsInitiator();
    connectedAt_ = Clock::now();
    banDecayApplied_ = false;
    peerId_ = options_.tracker->recordPeerConnected(options_.host, options_.port, options_.userAgent);
}

void PeerConnection::acceptInbound() {
    if (!transport_ || !transport_->isOpen()) {
        throw std::runtime_error("accept_inbound requires transport");
    }
    const auto now = Clock::now();
    lastActivity_ = now;
    lastPing_ = now;
    handshakeAsResponder();
    connectedAt_ = Clock::now();
    banDecayApplied_ = false;
    peerId_ = options_.tracker->recordPeerConnected(options_.host, options_.port, options_.userAgent, "inbound");
}

void PeerConnection::close() {
    running_ = false;
    if (transport_) {
        transport_->close();
        transport_.reset();
    }
    if (peerId_ > 0) {
        options_.tracker->recordPeerDisconnected(peerId_);
        peerId_ = 0;
    }
}

void PeerConnection::send(const std::string& command, std::span<const std::uint8_t> payload) {
    sendInternal(command, payload, true);
}

void PeerConnection::sendInternal(const std::string& command, std::span<const std::uint8_t> payload,
                                  bool recordTrackerEvent) {
    if (!transport_ || !transport_->isOpen()) {
        throw std::runtime_error("Peer is not connected");
    }
    const auto frame = wire::buildMessage(options_.chain->magic, command, payload);
    transport_->write(frame);
    if (recordTrackerEvent) {
        options_.tracker->logEvent("p2p", "Sent " + command,
                                   "info", "{\"host\":" + util::jsonString(options_.host) + ",\"port\":" +
                                               std::to_string(options_.port) + "}");
    }
}

std::pair<std::string, std::vector<std::uint8_t>> PeerConnection::readMessage(double timeoutSeconds) {
    if (readOverride_) {
        return readOverride_(timeoutSeconds);
    }
    if (!transport_ || !transport_->isOpen()) {
        throw std::runtime_error("Peer is not connected");
    }

    const auto deadline = Clock::now() + std::chrono::duration_cast<Clock::duration>(
                                              std::chrono::duration<double>(timeoutSeconds));
    auto remainingSeconds = [&]() {
        const double remaining = std::chrono::duration<double>(deadline - Clock::now()).count();
        if (remaining <= 0) {
            throw std::runtime_error("read timeout");
        }
        return remaining;
    };
    auto ensureBuffered = [&](std::size_t size, bool headerRead) {
        if (buffer_.size() >= size) {
            return;
        }
        const auto started = Clock::now();
        const auto chunk = transport_->readExact(size - buffer_.size(), remainingSeconds());
        const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - started).count();
        if (headerRead) {
            gP2PHeaderReadUs.fetch_add(static_cast<std::uint64_t>(std::max<long long>(0, elapsed)),
                                       std::memory_order_relaxed);
        } else {
            gP2PPayloadReadUs.fetch_add(static_cast<std::uint64_t>(std::max<long long>(0, elapsed)),
                                        std::memory_order_relaxed);
        }
        gP2PBytesRead.fetch_add(static_cast<std::uint64_t>(chunk.size()), std::memory_order_relaxed);
        buffer_.insert(buffer_.end(), chunk.begin(), chunk.end());
    };

    ensureBuffered(wire::kHeaderSize, true);
    const auto header = wire::parseHeader(buffer_);
    const std::size_t total = wire::kHeaderSize + header.length;
    ensureBuffered(total, false);

    std::vector<std::uint8_t> frame(buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(total));
    buffer_.erase(buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(total));
    const auto payload = std::span<const std::uint8_t>(frame.data() + wire::kHeaderSize, header.length);
    if (header.magic != options_.chain->magic) {
        throw std::runtime_error("Unexpected network magic");
    }
    if (!wire::verifyChecksum(payload, header.checksum)) {
        throw std::runtime_error("Checksum mismatch");
    }
    gP2PFramesRead.fetch_add(1, std::memory_order_relaxed);
    return {header.command, std::vector<std::uint8_t>(payload.begin(), payload.end())};
}

void PeerConnection::keepaliveTick() {
    const auto now = Clock::now();
    const double idleSeconds = std::chrono::duration<double>(now - lastActivity_).count();
    if (idleSeconds > options_.staleTimeoutSeconds) {
        throw std::runtime_error("Peer stale");
    }
    const double sincePing = std::chrono::duration<double>(now - lastPing_).count();
    if (sincePing >= options_.pingIntervalSeconds) {
        lastPing_ = now;
        const auto ping = messages::PingMessage{randomNonce()};
        send(messages::PingMessage::kCommand, ping.serialize());
    }
}

void PeerConnection::discoverPeers() {
    try {
        send(messages::GetAddrMessage::kCommand, messages::GetAddrMessage{}.serialize());
        const auto [command, payload] = readMessage(4.0);
        if (command != messages::AddrMessage::kCommand) {
            return;
        }
        const auto message = messages::AddrMessage::deserialize(payload);
        for (const auto& address : message.addresses) {
            options_.tracker->recordPeerAddress(address.ip, address.port, address.services, "getaddr");
        }
    } catch (const std::exception&) {
        // Best-effort; retain peer for sync.
    }
}

int PeerConnection::syncHeaders(std::optional<int> stopHeight) {
    if (!isConnected()) {
        throw std::runtime_error("Peer is not connected");
    }
    const int peerHeight = remoteVersion_.has_value() ? remoteVersion_->startHeight : -1;
    const int stored = sync::syncHeadersToTip(*this, peerHeight, stopHeight);
    if (stored > 0) {
        const auto state = options_.tracker->getSyncState(options_.chain->name);
        const int tip = state.has_value() ? std::stoi((*state).at("best_height")) : 0;
        options_.tracker->logEvent("sync", "Header sync stored " + std::to_string(stored) + " headers (tip height " +
                                             std::to_string(tip) + ")",
                                   "info", "{\"host\":" + util::jsonString(options_.host) + ",\"port\":" +
                                               std::to_string(options_.port) + "}");
    }
    return stored;
}

messages::HeadersMessage PeerConnection::requestHeaders(const std::vector<std::vector<std::uint8_t>>& locatorHashes,
                                                        const std::vector<std::uint8_t>& hashStop) {
    if (!isConnected()) {
        throw std::runtime_error("Peer is not connected");
    }
    messages::GetHeadersMessage request;
    request.version = options_.protocolVersion;
    request.locatorHashes = locatorHashes;
    request.hashStop = hashStop;
    send(messages::GetHeadersMessage::kCommand, request.serialize());
    options_.tracker->markWireCapability("headers.getheaders.send", true, "live",
                                         "sent getheaders to " + options_.host + ":" + std::to_string(options_.port));
    const auto payload = readUntilCommand(std::string(messages::HeadersMessage::kCommand), 120.0);
    options_.tracker->markWireCapability("headers.headers.recv", true, "live",
                                         "received headers from " + options_.host + ":" + std::to_string(options_.port));
    return messages::deserializeHeadersMessage(payload);
}

std::optional<std::vector<std::uint8_t>> PeerConnection::requestBlock(const std::vector<std::uint8_t>& blockHash,
                                                                     double timeoutSeconds) {
    if (!isConnected()) {
        throw std::runtime_error("Peer is not connected");
    }
    for (const auto invType : {messages::MSG_WITNESS_BLOCK, messages::MSG_BLOCK}) {
        try {
            const auto payload = requestBlockOnce(blockHash, invType, timeoutSeconds);
            if (payload.has_value()) {
                return payload;
            }
        } catch (const std::runtime_error&) {
            continue;
        }
    }
    return std::nullopt;
}

std::optional<std::vector<std::uint8_t>> PeerConnection::requestBlockOnce(const std::vector<std::uint8_t>& blockHash,
                                                                          std::uint32_t invType,
                                                                          double timeoutSeconds) {
    messages::InventoryVector inv;
    inv.type = invType;
    inv.hash = blockHash;
    messages::GetDataMessage getdata;
    getdata.inventory.push_back(std::move(inv));
    send(messages::GetDataMessage::kCommand, getdata.serialize());
    options_.tracker->markWireCapability("blocks.getdata.send", true, "live",
                                         "sent getdata to " + options_.host + ":" + std::to_string(options_.port));

    const auto deadline = Clock::now() + std::chrono::duration_cast<Clock::duration>(
                                              std::chrono::duration<double>(timeoutSeconds));
    while (Clock::now() < deadline) {
        const double remaining = std::chrono::duration<double>(deadline - Clock::now()).count();
        if (remaining <= 0) {
            break;
        }
        const auto [command, payload] = readMessage(remaining);
        touchActivity();
        if (command == messages::BlockMessage::kCommand) {
            const auto receivedHash = messages::blockHashFromPayload(payload);
            if (receivedHash != blockHash) {
                options_.tracker->logEvent("sync", "Block hash mismatch on download", "warning",
                                           "{\"host\":" + util::jsonString(options_.host) + "}");
                return std::nullopt;
            }
            options_.tracker->markWireCapability("blocks.block.recv", true, "live",
                                                 "received block from " + options_.host + ":" +
                                                     std::to_string(options_.port));
            return std::vector<std::uint8_t>(payload.begin(), payload.end());
        }
        if (command == messages::NotFoundMessage::kCommand) {
            const auto missing = messages::NotFoundMessage::deserialize(payload);
            for (const auto& item : missing.inventory) {
                if (item.hash == blockHash) {
                    options_.tracker->markWireCapability("blocks.notfound", true, "live", "peer returned notfound");
                    options_.tracker->logEvent("sync", "Peer returned notfound for block", "warning",
                                               "{\"host\":" + util::jsonString(options_.host) + ",\"port\":" +
                                                   std::to_string(options_.port) + "}");
                    return std::nullopt;
                }
            }
            continue;
        }
        if (command == messages::GetHeadersMessage::kCommand) {
            continue;
        }
        if (command == messages::PingMessage::kCommand) {
            const auto ping = messages::PingMessage::deserialize(payload);
            const auto pong = messages::PongMessage{ping.nonce};
            send(messages::PongMessage::kCommand, pong.serialize());
            continue;
        }
        dispatchMessage(command, payload);
    }
    return std::nullopt;
}

std::vector<std::optional<std::vector<std::uint8_t>>> PeerConnection::requestBlocks(
    const std::vector<std::vector<std::uint8_t>>& blockHashes, double timeoutSeconds,
    BlockRequestOptions options, BlockRequestStats* stats) {
    if (!isConnected()) {
        throw std::runtime_error("Peer is not connected");
    }
    std::vector<std::optional<std::vector<std::uint8_t>>> results(blockHashes.size());
    if (blockHashes.empty()) {
        return results;
    }

    for (const auto invType : {messages::MSG_WITNESS_BLOCK, messages::MSG_BLOCK}) {
        messages::GetDataMessage getdata;
        std::vector<bool> pending(blockHashes.size(), false);
        std::size_t pendingCount = 0;
        for (std::size_t index = 0; index < blockHashes.size(); ++index) {
            if (results[index].has_value()) {
                continue;
            }
            messages::InventoryVector inv;
            inv.type = invType;
            inv.hash = blockHashes[index];
            getdata.inventory.push_back(std::move(inv));
            pending[index] = true;
            pendingCount += 1;
        }
        if (pendingCount == 0) {
            break;
        }

        sendInternal(messages::GetDataMessage::kCommand, getdata.serialize(), options.recordTrackerEvents);
        if (stats != nullptr) {
            stats->sentGetData = true;
        }
        if (options.recordTrackerEvents) {
            options_.tracker->markWireCapability("blocks.getdata.send", true, "live",
                                                 "sent batched getdata to " + options_.host + ":" +
                                                     std::to_string(options_.port));
        }

        const auto deadline = Clock::now() + std::chrono::duration_cast<Clock::duration>(
                                                  std::chrono::duration<double>(timeoutSeconds));
        while (pendingCount > 0 && Clock::now() < deadline) {
            const double remaining = std::chrono::duration<double>(deadline - Clock::now()).count();
            if (remaining <= 0) {
                break;
            }
            const auto [command, payload] = readMessage(remaining);
            touchActivity();
            if (command == messages::BlockMessage::kCommand) {
                const auto receivedHash = messages::blockHashFromPayload(payload);
                bool matched = false;
                for (std::size_t index = 0; index < blockHashes.size(); ++index) {
                    if (!pending[index] || receivedHash != blockHashes[index]) {
                        continue;
                    }
                    results[index] = std::vector<std::uint8_t>(payload.begin(), payload.end());
                    pending[index] = false;
                    pendingCount -= 1;
                    matched = true;
                    if (stats != nullptr) {
                        stats->receivedBlock = true;
                    }
                    if (options.recordTrackerEvents) {
                        options_.tracker->markWireCapability("blocks.block.recv", true, "live",
                                                             "received batched block from " + options_.host + ":" +
                                                                 std::to_string(options_.port));
                    }
                    break;
                }
                if (!matched) {
                    if (options.recordTrackerEvents) {
                        options_.tracker->logEvent("sync", "Unexpected block hash in batched download", "warning",
                                                   "{\"host\":" + util::jsonString(options_.host) + "}");
                    }
                }
                continue;
            }
            if (command == messages::NotFoundMessage::kCommand) {
                const auto missing = messages::NotFoundMessage::deserialize(payload);
                for (const auto& item : missing.inventory) {
                    for (std::size_t index = 0; index < blockHashes.size(); ++index) {
                        if (!pending[index] || item.hash != blockHashes[index]) {
                            continue;
                        }
                        pending[index] = false;
                        pendingCount -= 1;
                        if (stats != nullptr) {
                            stats->receivedNotFound = true;
                        }
                        if (options.recordTrackerEvents) {
                            options_.tracker->markWireCapability("blocks.notfound", true, "live",
                                                                 "peer returned batched notfound");
                        }
                        break;
                    }
                }
                continue;
            }
            if (command == messages::GetHeadersMessage::kCommand) {
                continue;
            }
            if (command == messages::PingMessage::kCommand) {
                const auto ping = messages::PingMessage::deserialize(payload);
                const auto pong = messages::PongMessage{ping.nonce};
                sendInternal(messages::PongMessage::kCommand, pong.serialize(), options.recordTrackerEvents);
                continue;
            }
            if (options.recordTrackerEvents) {
                dispatchMessage(command, payload);
            }
        }
    }
    return results;
}

bool PeerConnection::requestBlocksStreaming(const std::vector<std::vector<std::uint8_t>>& blockHashes,
                                            std::size_t windowSize, const StreamingBlockCallback& onBlock,
                                            double timeoutSeconds, BlockRequestOptions options,
                                            BlockRequestStats* stats) {
    if (!isConnected()) {
        throw std::runtime_error("Peer is not connected");
    }
    if (blockHashes.empty()) {
        return true;
    }
    if (!onBlock) {
        throw std::invalid_argument("requestBlocksStreaming requires a callback");
    }

    const std::size_t window = std::max<std::size_t>(1, std::min<std::size_t>(16, windowSize));
    std::vector<bool> completed(blockHashes.size(), false);
    std::size_t completedCount = 0;

    for (const auto invType : {messages::MSG_WITNESS_BLOCK, messages::MSG_BLOCK}) {
        std::vector<bool> pending(blockHashes.size(), false);
        std::size_t nextToRequest = 0;
        std::size_t pendingCount = 0;

        auto queueWindow = [&]() {
            messages::GetDataMessage getdata;
            while (pendingCount < window && nextToRequest < blockHashes.size()) {
                const std::size_t index = nextToRequest++;
                if (completed[index]) {
                    continue;
                }
                messages::InventoryVector inv;
                inv.type = invType;
                inv.hash = blockHashes[index];
                getdata.inventory.push_back(std::move(inv));
                pending[index] = true;
                pendingCount += 1;
            }
            if (getdata.inventory.empty()) {
                return;
            }
            sendInternal(messages::GetDataMessage::kCommand, getdata.serialize(), options.recordTrackerEvents);
            if (stats != nullptr) {
                stats->sentGetData = true;
            }
            if (options.recordTrackerEvents) {
                options_.tracker->markWireCapability("blocks.getdata.send", true, "live",
                                                     "sent streaming getdata to " + options_.host + ":" +
                                                         std::to_string(options_.port));
            }
        };

        queueWindow();
        const auto deadline = Clock::now() + std::chrono::duration_cast<Clock::duration>(
                                                  std::chrono::duration<double>(timeoutSeconds));
        while (completedCount < blockHashes.size() && Clock::now() < deadline) {
            if (pendingCount == 0) {
                queueWindow();
                if (pendingCount == 0) {
                    break;
                }
            }

            const double remaining = std::chrono::duration<double>(deadline - Clock::now()).count();
            if (remaining <= 0) {
                break;
            }
            const auto readStarted = Clock::now();
            const auto [command, payload] = readMessage(remaining);
            const long long readWaitUs = std::chrono::duration_cast<std::chrono::microseconds>(
                                             Clock::now() - readStarted)
                                             .count();
            touchActivity();
            if (command == messages::BlockMessage::kCommand) {
                const auto receivedHash = messages::blockHashFromPayload(payload);
                bool matched = false;
                for (std::size_t index = 0; index < blockHashes.size(); ++index) {
                    if (!pending[index] || receivedHash != blockHashes[index]) {
                        continue;
                    }
                    pending[index] = false;
                    pendingCount -= 1;
                    completed[index] = true;
                    completedCount += 1;
                    matched = true;
                    if (stats != nullptr) {
                        stats->receivedBlock = true;
                    }
                    if (options.recordTrackerEvents) {
                        options_.tracker->markWireCapability("blocks.block.recv", true, "live",
                                                             "received streaming block from " + options_.host + ":" +
                                                                 std::to_string(options_.port));
                    }
                    if (!onBlock(index, std::vector<std::uint8_t>(payload.begin(), payload.end()), readWaitUs)) {
                        return false;
                    }
                    queueWindow();
                    break;
                }
                if (!matched && options.recordTrackerEvents) {
                    options_.tracker->logEvent("sync", "Unexpected block hash in streaming download", "warning",
                                               "{\"host\":" + util::jsonString(options_.host) + "}");
                }
                continue;
            }
            if (command == messages::NotFoundMessage::kCommand) {
                const auto missing = messages::NotFoundMessage::deserialize(payload);
                for (const auto& item : missing.inventory) {
                    for (std::size_t index = 0; index < blockHashes.size(); ++index) {
                        if (!pending[index] || item.hash != blockHashes[index]) {
                            continue;
                        }
                        pending[index] = false;
                        pendingCount -= 1;
                        if (stats != nullptr) {
                            stats->receivedNotFound = true;
                        }
                        if (options.recordTrackerEvents) {
                            options_.tracker->markWireCapability("blocks.notfound", true, "live",
                                                                 "peer returned streaming notfound");
                        }
                        break;
                    }
                }
                queueWindow();
                continue;
            }
            if (command == messages::GetHeadersMessage::kCommand) {
                continue;
            }
            if (command == messages::PingMessage::kCommand) {
                const auto ping = messages::PingMessage::deserialize(payload);
                const auto pong = messages::PongMessage{ping.nonce};
                sendInternal(messages::PongMessage::kCommand, pong.serialize(), options.recordTrackerEvents);
                continue;
            }
            if (options.recordTrackerEvents) {
                dispatchMessage(command, payload);
            }
        }

        if (completedCount == blockHashes.size()) {
            return true;
        }
    }
    return completedCount == blockHashes.size();
}

void PeerConnection::consumeMessages(const MessageHandler& handler, double readTimeoutSeconds) {
    running_ = true;
    while (running_) {
        try {
            const auto [command, payload] = readMessage(readTimeoutSeconds);
            touchActivity();
            handler(command, payload);
        } catch (const std::runtime_error& exc) {
            const std::string msg = exc.what();
            if (msg == "read timeout") {
                keepaliveTick();
                continue;
            }
            if (msg == "Peer stale" || msg == "Peer closed connection") {
                if (banEligibleEndpoint()) {
                    options_.tracker->incrementPeerBanScore(options_.host, options_.port, kBanDisconnect, peerId_);
                }
                break;
            }
            if (banEligibleEndpoint()) {
                options_.tracker->incrementPeerBanScore(options_.host, options_.port, kBanProtocolViolation, peerId_);
            }
            break;
        }
    }
}

void PeerConnection::run() {
    consumeMessages([this](const std::string& command, std::span<const std::uint8_t> payload) {
        dispatchMessage(command, payload);
    });
}

bool PeerConnection::isTxInventoryType(std::uint32_t type) const {
    return type == messages::MSG_TX || type == messages::MSG_WITNESS_TX;
}

void PeerConnection::dispatchMessage(const std::string& command, std::span<const std::uint8_t> payload) {
    if (command == messages::PingMessage::kCommand) {
        const auto ping = messages::PingMessage::deserialize(payload);
        const auto pong = messages::PongMessage{ping.nonce};
        send(messages::PongMessage::kCommand, pong.serialize());
        return;
    }
    if (command == messages::PongMessage::kCommand) {
        return;
    }
    if (command == messages::FeeFilterMessage::kCommand) {
        const auto ff = messages::FeeFilterMessage::deserialize(payload);
        peerFeeFilterSatKvb_ = static_cast<std::int64_t>(ff.feerateSatKvb);
        return;
    }
    if (command == messages::AddrMessage::kCommand) {
        const auto message = messages::AddrMessage::deserialize(payload);
        for (const auto& address : message.addresses) {
            options_.tracker->recordPeerAddress(address.ip, address.port, address.services, "addr");
        }
        return;
    }
    if (command == messages::InvMessage::kCommand) {
        const auto inv = messages::InvMessage::deserialize(payload);
        std::vector<messages::InventoryVector> txItems;
        txItems.reserve(inv.inventory.size());
        for (const auto& item : inv.inventory) {
            if (isTxInventoryType(item.type)) {
                txItems.push_back(item);
            }
        }
        if (!txItems.empty()) {
            options_.tracker->markWireCapability("tx.inv.recv", true, "live", "parsed inv with transaction vectors");
            const auto todo = ::cpbitnode::mempool::txInventoryNeedGetdata(txItems, options_.mempool);
            if (!todo.empty()) {
                for (std::size_t index = 0; index < todo.size(); index += kMaxGetdataTxBatch) {
                    messages::GetDataMessage getdata;
                    const auto end = std::min(index + kMaxGetdataTxBatch, todo.size());
                    getdata.inventory.assign(todo.begin() + static_cast<std::ptrdiff_t>(index),
                                             todo.begin() + static_cast<std::ptrdiff_t>(end));
                    send(messages::GetDataMessage::kCommand, getdata.serialize());
                }
                options_.tracker->markWireCapability("tx.getdata.send", true, "live",
                                                     "getdata for tx inv hashes not yet in mempool");
            }
        }
        if (messages::hasBlockInventory(inv)) {
            options_.tracker->logEvent("sync", "Block inv received", "info",
                                       "{\"host\":" + util::jsonString(options_.host) + ",\"port\":" +
                                           std::to_string(options_.port) + ",\"count\":" +
                                           std::to_string(inv.inventory.size()) + "}");
        }
        return;
    }
    if (command == messages::GetDataMessage::kCommand && options_.mempool != nullptr) {
        const auto getdata = messages::GetDataMessage::deserialize(payload);
        std::vector<messages::InventoryVector> txItems;
        txItems.reserve(getdata.inventory.size());
        for (const auto& item : getdata.inventory) {
            if (isTxInventoryType(item.type)) {
                txItems.push_back(item);
            }
        }
        ::cpbitnode::mempool::replyGetdataTxInventory(*this, options_.mempool, *options_.tracker, txItems);
        return;
    }
    if (command == messages::Transaction::kCommand && options_.mempool != nullptr) {
        messages::Transaction tx;
        try {
            std::tie(tx, std::ignore) = messages::deserializeTransaction(payload);
        } catch (const std::exception& exc) {
            options_.tracker->logEvent("p2p", std::string("Malformed tx message: ") + exc.what(), "warning",
                                       "{\"host\":" + util::jsonString(options_.host) + ",\"port\":" +
                                           std::to_string(options_.port) + "}");
            return;
        }
        options_.tracker->markWireCapability("tx.tx.recv", true, "live", "deserialized inbound tx");
        const std::string peerHost = options_.host + ":" + std::to_string(options_.port);
        ::cpbitnode::mempool::AcceptTransactionOptions acceptOptions;
        acceptOptions.settings = &options_.settings;
        acceptOptions.peerHost = peerHost;
        if (options_.mempool->acceptTransaction(tx, acceptOptions)) {
            options_.tracker->logEvent("mempool", "Accepted incoming transaction", "info",
                                       "{\"peer\":" + util::jsonString(peerHost) + "}");
            if (options_.relayTxAccepted) {
                options_.relayTxAccepted(tx, *this);
            }
        } else {
            options_.tracker->logEvent("mempool", "Transaction not pooled (duplicate or capacity)", "debug",
                                       "{\"peer\":" + util::jsonString(peerHost) + "}");
        }
        return;
    }
    (void)payload;
}

void broadcastWitnessBlockInv(const std::vector<PeerConnection*>& peers, const std::vector<std::uint8_t>& blockHash,
                              db::NodeStateStore& tracker) {
    messages::InvMessage inv;
    inv.inventory.push_back(messages::InventoryVector{messages::MSG_WITNESS_BLOCK, blockHash});
    const auto payload = inv.serialize();
    bool sent = false;
    for (auto* peer : peers) {
        if (peer == nullptr || !peer->isConnected()) {
            continue;
        }
        try {
            peer->send(messages::InvMessage::kCommand, payload);
            sent = true;
        } catch (const std::exception&) {
            // Best-effort inv broadcast.
        }
    }
    if (sent) {
        tracker.markWireCapability("serve.inv.blocks", true, "live", "broadcast MSG_WITNESS_BLOCK inv on tip advance");
    }
}

bool PeerConnection::deferAdvancedNegotiation() const {
    if (options_.settings.lightweightOutboundHandshake()) {
        return true;
    }
    const auto sync = options_.tracker->getSyncState(options_.chain->name);
    const std::string status = sync ? sync->at("sync_status") : "starting";
    return status != "headers_current" && status != "running";
}

void PeerConnection::runAdvancedNegotiation(bool outbound) {
    if (advancedNegotiationComplete_) {
        return;
    }
    const bool relayOn = !remoteVersion_.has_value() || remoteVersion_->relay;
    if (outbound && remoteVersion_.has_value() && remoteVersion_->version >= messages::FEEFILTER_MIN_VERSION) {
        const auto wireKvb = static_cast<std::uint64_t>(feefilterWireSatKvbFromSettings(options_.settings));
        const messages::FeeFilterMessage ff{wireKvb};
        send(messages::FeeFilterMessage::kCommand, ff.serialize());
        options_.tracker->markWireCapability("tx.feefilter", true, "live",
                                             "sent outbound feefilter (" + std::to_string(wireKvb) + " sat/kvB)");
    }
    if (relayOn) {
        send(messages::MempoolRequestMessage::kCommand, messages::MempoolRequestMessage{}.serialize());
        options_.tracker->markWireCapability("tx.mempool", true, "live", "sent mempool command (BIP35)");
    }
    advancedNegotiationComplete_ = true;
}

void PeerConnection::completeDeferredHandshake() {
    if (advancedNegotiationComplete_ || !isConnected()) {
        return;
    }
    runAdvancedNegotiation(true);
}

void PeerConnection::postVerackNegotiation(bool outbound) {
    if (outbound && deferAdvancedNegotiation()) {
        return;
    }
    runAdvancedNegotiation(outbound);
}

void PeerConnection::handshakeAsInitiator() {
    const auto recvAddr = blankAddress();
    const auto fromAddr = blankAddress();
    const auto version = messages::VersionMessage::build(options_.protocolVersion,
                                                         messages::NODE_NETWORK | messages::NODE_WITNESS, recvAddr,
                                                         fromAddr, options_.userAgent, options_.startHeight);
    send(messages::VersionMessage::kCommand, version.serialize());
    readUntilCommand(messages::VersionMessage::kCommand, 30.0);
    send(messages::VerAckMessage::kCommand, messages::VerAckMessage{}.serialize());
    readUntilCommand(messages::VerAckMessage::kCommand, 30.0);
    send(messages::SendHeadersMessage::kCommand, messages::SendHeadersMessage{}.serialize());
    postVerackNegotiation(true);
}

void PeerConnection::handshakeAsResponder() {
    readUntilCommand(messages::VersionMessage::kCommand, 30.0);
    const auto recvAddr = blankAddress();
    const auto fromAddr = blankAddress();
    const auto version = messages::VersionMessage::build(options_.protocolVersion,
                                                         messages::NODE_NETWORK | messages::NODE_WITNESS, recvAddr,
                                                         fromAddr, options_.userAgent, options_.startHeight);
    send(messages::VersionMessage::kCommand, version.serialize());
    send(messages::VerAckMessage::kCommand, messages::VerAckMessage{}.serialize());
    readUntilCommand(messages::VerAckMessage::kCommand, 30.0);
    send(messages::SendHeadersMessage::kCommand, messages::SendHeadersMessage{}.serialize());
    postVerackNegotiation(false);
}

std::vector<std::uint8_t> PeerConnection::readUntilCommand(const std::string& command, double timeoutSeconds) {
    const auto deadline = Clock::now() + std::chrono::duration_cast<Clock::duration>(
                                              std::chrono::duration<double>(timeoutSeconds));
    while (true) {
        const double remaining = std::chrono::duration<double>(deadline - Clock::now()).count();
        if (remaining <= 0) {
            throw std::runtime_error("Timed out waiting for " + command);
        }
        const auto [msgCommand, payload] = readMessage(remaining);
        touchActivity();
        if (msgCommand == command) {
            if (command == messages::VersionMessage::kCommand) {
                remoteVersion_ = messages::VersionMessage::deserialize(payload);
            }
            return payload;
        }
        dispatchMessage(msgCommand, payload);
    }
}

void PeerConnection::touchActivity() {
    lastActivity_ = Clock::now();
    if (peerId_ > 0) {
        options_.tracker->touchPeer(peerId_);
    }
    maybeDecayBanAfterLongUptime();
}

void PeerConnection::maybeDecayBanAfterLongUptime() {
    if (banDecayApplied_ || peerId_ <= 0 || !banEligibleEndpoint()) {
        return;
    }
    if (connectedAt_ == Clock::time_point{}) {
        return;
    }
    const double uptime = std::chrono::duration<double>(Clock::now() - connectedAt_).count();
    if (uptime < options_.settings.peerBanDecayUptimeSeconds) {
        return;
    }
    banDecayApplied_ = true;
    options_.tracker->decayPeerBanScore(options_.host, options_.port, options_.settings.peerBanDecayAmount, peerId_);
}

bool PeerConnection::banEligibleEndpoint() const {
    return !options_.host.empty() && options_.port > 0 && options_.host != "unknown";
}

}  // namespace cpbitnode::p2p
