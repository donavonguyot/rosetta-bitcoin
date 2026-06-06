#include "cpbitnode/messages/reject.hpp"

#include "cpbitnode/wire/serialize.hpp"

#include <stdexcept>
#include <tuple>

namespace cpbitnode::messages {
namespace {

std::pair<std::vector<std::uint8_t>, std::size_t> readCompactString(std::span<const std::uint8_t> payload,
                                                                    std::size_t offset) {
    auto [length, next] = wire::readVarint(payload, offset);
    const auto end = next + length;
    if (end > payload.size()) {
        throw std::runtime_error("truncated compact-string in reject");
    }
    return {std::vector<std::uint8_t>(payload.begin() + static_cast<std::ptrdiff_t>(next),
                                      payload.begin() + static_cast<std::ptrdiff_t>(end)),
            end};
}

std::vector<std::uint8_t> writeCompactString(std::span<const std::uint8_t> data) {
    auto out = wire::writeVarint(data.size());
    out.insert(out.end(), data.begin(), data.end());
    return out;
}

}  // namespace

std::vector<std::uint8_t> RejectMessage::serialize() const {
    if (ccode > 0xFF) {
        throw std::runtime_error("ccode out of uint8 range");
    }
    std::vector<std::uint8_t> messageBytes(message.begin(), message.end());
    std::vector<std::uint8_t> reasonBytes(reason.begin(), reason.end());
    std::vector<std::uint8_t> buf;
    auto append = [&](const std::vector<std::uint8_t>& chunk) {
        buf.insert(buf.end(), chunk.begin(), chunk.end());
    };
    append(writeCompactString(messageBytes));
    buf.push_back(ccode);
    append(writeCompactString(reasonBytes));
    buf.insert(buf.end(), data.begin(), data.end());
    return buf;
}

RejectMessage RejectMessage::deserialize(std::span<const std::uint8_t> payload) {
    if (payload.empty()) {
        throw std::runtime_error("empty reject payload");
    }
    std::size_t offset = 0;
    std::vector<std::uint8_t> messageRaw;
    std::tie(messageRaw, offset) = readCompactString(payload, offset);
    if (offset >= payload.size()) {
        throw std::runtime_error("truncated reject (missing code)");
    }
    const auto ccode = payload[offset++];
    std::vector<std::uint8_t> reasonRaw;
    std::tie(reasonRaw, offset) = readCompactString(payload, offset);
    RejectMessage msg;
    msg.message.assign(messageRaw.begin(), messageRaw.end());
    msg.ccode = ccode;
    msg.reason.assign(reasonRaw.begin(), reasonRaw.end());
    msg.data.assign(payload.begin() + static_cast<std::ptrdiff_t>(offset), payload.end());
    return msg;
}

bool RejectMessage::operator==(const RejectMessage& other) const {
    return message == other.message && ccode == other.ccode && reason == other.reason && data == other.data;
}

}  // namespace cpbitnode::messages
