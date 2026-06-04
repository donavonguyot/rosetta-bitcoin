#pragma once

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/db/node_state.hpp"
#include "cpbitnode/messages/handshake.hpp"
#include "cpbitnode/messages/headers.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/messages/transaction.hpp"
#include "cpbitnode/p2p/transport.hpp"

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace cpbitnode::mempool {
class Mempool;
}

namespace cpbitnode::p2p {

class PeerConnection;

inline constexpr std::size_t kMaxGetdataTxBatch = 1024;

using MessageHandler = std::function<void(const std::string& command, std::span<const std::uint8_t> payload)>;
using RelayTxAcceptedFn = std::function<void(const messages::Transaction&, PeerConnection&)>;

struct BlockRequestOptions {
    bool recordTrackerEvents = true;
};

struct BlockRequestStats {
    bool sentGetData = false;
    bool receivedBlock = false;
    bool receivedNotFound = false;
};

struct P2PReadTelemetry {
    std::uint64_t framesRead = 0;
    std::uint64_t bytesRead = 0;
    std::uint64_t headerReadUs = 0;
    std::uint64_t payloadReadUs = 0;
};

using StreamingBlockCallback =
    std::function<bool(std::size_t index, std::vector<std::uint8_t> payload, long long fetchWaitUs)>;

P2PReadTelemetry p2pReadTelemetrySnapshot();

void broadcastWitnessBlockInv(const std::vector<PeerConnection*>& peers, const std::vector<std::uint8_t>& blockHash,
                              db::NodeStateStore& tracker);

class PeerConnection {
public:
    struct Options {
        std::string host;
        int port = 0;
        const chain::ChainParams* chain = nullptr;
        db::NodeStateStore* tracker = nullptr;
        config::Settings settings{};
        int protocolVersion = 70016;
        std::string userAgent = "/cpbitnode:0.1.0/";
        int startHeight = 0;
        double pingIntervalSeconds = 1200.0;
        double staleTimeoutSeconds = 5400.0;
        ::cpbitnode::mempool::Mempool* mempool = nullptr;
        RelayTxAcceptedFn relayTxAccepted;
        std::function<std::unique_ptr<Transport>(const std::string&, int)> transportFactory;
    };

    explicit PeerConnection(Options options);

    virtual void connect();
    virtual void acceptInbound();
    virtual void close();

    virtual bool isConnected() const;
    bool lightweightOutboundHandshake() const;

    void send(const std::string& command, std::span<const std::uint8_t> payload = {});
    std::pair<std::string, std::vector<std::uint8_t>> readMessage(double timeoutSeconds = 60.0);
    void keepaliveTick();
    virtual void discoverPeers();
    virtual int syncHeaders(std::optional<int> stopHeight = std::nullopt);

    messages::HeadersMessage requestHeaders(const std::vector<std::vector<std::uint8_t>>& locator,
                                            const std::vector<std::uint8_t>& hashStop = std::vector<std::uint8_t>(32, 0));
    virtual std::optional<std::vector<std::uint8_t>> requestBlock(const std::vector<std::uint8_t>& blockHash,
                                                                  double timeoutSeconds = 120.0);
    virtual std::vector<std::optional<std::vector<std::uint8_t>>> requestBlocks(
        const std::vector<std::vector<std::uint8_t>>& blockHashes, double timeoutSeconds = 120.0,
        BlockRequestOptions options = {}, BlockRequestStats* stats = nullptr);
    virtual bool requestBlocksStreaming(const std::vector<std::vector<std::uint8_t>>& blockHashes,
                                        std::size_t windowSize, const StreamingBlockCallback& onBlock,
                                        double timeoutSeconds = 120.0, BlockRequestOptions options = {},
                                        BlockRequestStats* stats = nullptr);

    const chain::ChainParams& chain() const { return *options_.chain; }
    db::NodeStateStore& tracker() { return *options_.tracker; }
    const config::Settings& settings() const { return options_.settings; }

    void consumeMessages(const MessageHandler& handler, double readTimeoutSeconds = 30.0);
    void dispatchMessage(const std::string& command, std::span<const std::uint8_t> payload);
    void run();
    void completeDeferredHandshake();

    const std::string& host() const { return options_.host; }
    int port() const { return options_.port; }
    int peerId() const { return peerId_; }
    const messages::VersionMessage* remoteVersion() const;
    const Options& options() const { return options_; }
    std::optional<std::int64_t> peerFeeFilterSatKvb() const { return peerFeeFilterSatKvb_; }

    /** Test hook: inject transport after construction (must be before connect). */
    void setTransportForTest(std::unique_ptr<Transport> transport);

    /** Test hook: override readMessage for scripted responses. */
    using ReadMessageOverride =
        std::function<std::pair<std::string, std::vector<std::uint8_t>>(double timeoutSeconds)>;
    void setReadMessageOverrideForTest(ReadMessageOverride overrideFn);

    void setActivityTimestampsForTest(std::chrono::steady_clock::time_point lastActivity,
                                       std::chrono::steady_clock::time_point lastPing);

    void setPeerFeeFilterSatKvbForTest(std::int64_t value) { peerFeeFilterSatKvb_ = value; }

    /** Test hook: pretend verack completed with this remote version. */
    void setRemoteVersionForTest(messages::VersionMessage version) { remoteVersion_ = std::move(version); }

private:
    void handshakeAsInitiator();
    void handshakeAsResponder();
    void postVerackNegotiation(bool outbound);
    bool deferAdvancedNegotiation() const;
    void runAdvancedNegotiation(bool outbound);
    void sendInternal(const std::string& command, std::span<const std::uint8_t> payload, bool recordTrackerEvent);
    std::vector<std::uint8_t> readUntilCommand(const std::string& command, double timeoutSeconds);
    std::optional<std::vector<std::uint8_t>> requestBlockOnce(const std::vector<std::uint8_t>& blockHash,
                                                              std::uint32_t invType, double timeoutSeconds);
    void touchActivity();
    void maybeDecayBanAfterLongUptime();
    bool banEligibleEndpoint() const;
    bool isTxInventoryType(std::uint32_t type) const;

    Options options_;
    std::unique_ptr<Transport> transport_;
    std::vector<std::uint8_t> buffer_;
    bool running_ = false;
    int peerId_ = 0;
    std::optional<messages::VersionMessage> remoteVersion_;
    std::optional<std::int64_t> peerFeeFilterSatKvb_;
    std::chrono::steady_clock::time_point lastActivity_{};
    std::chrono::steady_clock::time_point lastPing_{};
    std::chrono::steady_clock::time_point connectedAt_{};
    bool banDecayApplied_ = false;
    bool advancedNegotiationComplete_ = false;
    ReadMessageOverride readOverride_;
};

}  // namespace cpbitnode::p2p
