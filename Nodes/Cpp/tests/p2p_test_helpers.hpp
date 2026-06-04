#pragma once

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/messages/handshake.hpp"
#include "cpbitnode/p2p/transport.hpp"
#include "cpbitnode/wire/frame.hpp"

#include <deque>
#include <stdexcept>
#include <string>
#include <vector>

namespace cpbitnode::testp2p {

inline std::vector<std::uint8_t> framedMessage(std::span<const std::uint8_t> magic, const std::string& command,
                                               std::span<const std::uint8_t> payload) {
    return wire::buildMessage(magic, command, payload);
}

inline std::vector<std::uint8_t> remoteVersionVerackFrames(const chain::ChainParams& chain, int startHeight) {
    const messages::NetworkAddress addr{messages::NODE_NETWORK | messages::NODE_WITNESS, "203.0.113.1",
                                        chain.defaultPort};
    const auto remoteVersion =
        messages::VersionMessage::build(70016, messages::NODE_NETWORK | messages::NODE_WITNESS, addr, addr,
                                        "/remote:0.1/", startHeight);
    std::vector<std::uint8_t> out;
    const auto versionFrame =
        framedMessage(chain.magic, messages::VersionMessage::kCommand, remoteVersion.serialize());
    const auto verackFrame =
        framedMessage(chain.magic, messages::VerAckMessage::kCommand, messages::VerAckMessage{}.serialize());
    out.insert(out.end(), versionFrame.begin(), versionFrame.end());
    out.insert(out.end(), verackFrame.begin(), verackFrame.end());
    return out;
}

inline bool writeContainsCommand(const std::vector<std::vector<std::uint8_t>>& writes, const std::string& command) {
    for (const auto& frame : writes) {
        if (frame.size() >= wire::kHeaderSize && wire::parseHeader(frame).command == command) {
            return true;
        }
    }
    return false;
}

inline std::string commandFromWrite(const std::vector<std::uint8_t>& frameBytes) {
    return wire::parseHeader(frameBytes).command;
}

class MockTransport : public p2p::Transport {
public:
    void write(std::span<const std::uint8_t> data) override { writes_.emplace_back(data.begin(), data.end()); }

    std::vector<std::uint8_t> readExact(std::size_t count, double timeoutSeconds) override {
        (void)timeoutSeconds;
        readRequests_.push_back(count);
        if (readQueue_.empty()) {
            throw std::runtime_error("read timeout");
        }
        auto chunk = readQueue_.front();
        readQueue_.pop_front();
        if (chunk.size() < count) {
            throw std::runtime_error("mock read underflow");
        }
        if (chunk.size() > count) {
            readQueue_.push_front(std::vector<std::uint8_t>(chunk.begin() + static_cast<std::ptrdiff_t>(count),
                                                            chunk.end()));
            chunk.resize(count);
        }
        return chunk;
    }

    void close() override { open_ = false; }
    bool isOpen() const override { return open_; }

    void enqueueRead(std::vector<std::uint8_t> bytes) { readQueue_.push_back(std::move(bytes)); }

    const std::vector<std::vector<std::uint8_t>>& writes() const { return writes_; }
    const std::vector<std::size_t>& readRequests() const { return readRequests_; }

private:
    bool open_ = true;
    std::deque<std::vector<std::uint8_t>> readQueue_;
    std::vector<std::vector<std::uint8_t>> writes_;
    std::vector<std::size_t> readRequests_;
};

class FailingWriteTransport final : public MockTransport {
public:
    void write(std::span<const std::uint8_t> data) override {
        (void)data;
        throw std::runtime_error("mock write failed");
    }
};

}  // namespace cpbitnode::testp2p
