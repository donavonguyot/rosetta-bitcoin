#include "cpbitnode/wire/frame.hpp"

#include "cpbitnode/wire/serialize.hpp"

#include <algorithm>
#include <cstring>
#include <stdexcept>

namespace cpbitnode::wire {

namespace {

std::string padCommand(const std::string& command) {
    std::string cmd = command.substr(0, 12);
    cmd.resize(12, '\0');
    return cmd;
}

}  // namespace

std::vector<std::uint8_t> headerToBytes(const MessageHeader& header) {
    if (header.magic.size() != 4 || header.checksum.size() != 4) {
        throw std::runtime_error("invalid header field sizes");
    }
    std::vector<std::uint8_t> out(kHeaderSize);
    std::memcpy(out.data(), header.magic.data(), 4);
    const auto cmd = padCommand(header.command);
    std::memcpy(out.data() + 4, cmd.data(), 12);
    std::uint32_t len = header.length;
    std::memcpy(out.data() + 16, &len, 4);
    std::memcpy(out.data() + 20, header.checksum.data(), 4);
    return out;
}

MessageHeader parseHeader(std::span<const std::uint8_t> data) {
    if (data.size() < kHeaderSize) {
        throw std::runtime_error("header requires 24 bytes");
    }
    MessageHeader header;
    header.magic.assign(data.begin(), data.begin() + 4);
    const char* cmdRaw = reinterpret_cast<const char*>(data.data() + 4);
    std::string cmd(cmdRaw, cmdRaw + 12);
    while (!cmd.empty() && cmd.back() == '\0') {
        cmd.pop_back();
    }
    header.command = cmd;
    std::memcpy(&header.length, data.data() + 16, 4);
    header.checksum.assign(data.begin() + 20, data.begin() + 24);
    return header;
}

std::vector<std::uint8_t> buildMessage(std::span<const std::uint8_t> magic, const std::string& command,
                                       std::span<const std::uint8_t> payload) {
    MessageHeader header;
    header.magic.assign(magic.begin(), magic.end());
    header.command = command;
    header.length = static_cast<std::uint32_t>(payload.size());
    header.checksum = messageChecksum(payload);
    auto out = headerToBytes(header);
    out.insert(out.end(), payload.begin(), payload.end());
    return out;
}

bool verifyChecksum(std::span<const std::uint8_t> payload, std::span<const std::uint8_t> checksum) {
    const auto expected = messageChecksum(payload);
    return checksum.size() == 4 && std::equal(expected.begin(), expected.end(), checksum.begin(), checksum.end());
}

}  // namespace cpbitnode::wire
