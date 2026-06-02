#include "test_support.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/wire/frame.hpp"
#include "cpbitnode/wire/serialize.hpp"

#include <cstdint>
#include <cstring>
#include <functional>
#include <stdexcept>
#include <vector>

void registerWireTests();

namespace {

bool expectRuntimeError(const std::function<void()>& fn) {
    try {
        fn();
    } catch (const std::runtime_error&) {
        return true;
    }
    return false;
}

void testMessageFramingRoundtrip() {
    std::vector<std::uint8_t> payload(8);
    const std::uint64_t nonce = 123456789;
    std::memcpy(payload.data(), &nonce, 8);

    const auto& chain = cpbitnode::chain::testnet4();
    const auto frame = cpbitnode::wire::buildMessage(chain.magic, "ping", payload);
    const auto header = cpbitnode::wire::parseHeader(
        std::span<const std::uint8_t>(frame.data(), cpbitnode::wire::kHeaderSize));
    const auto body = std::span<const std::uint8_t>(frame.data() + cpbitnode::wire::kHeaderSize,
                                                    frame.size() - cpbitnode::wire::kHeaderSize);

    EXPECT_EQ(header.command, "ping");
    EXPECT_EQ(header.length, static_cast<std::uint32_t>(payload.size()));
    EXPECT_TRUE(cpbitnode::wire::verifyChecksum(body, header.checksum));

    std::uint64_t restored = 0;
    std::memcpy(&restored, body.data(), 8);
    EXPECT_EQ(restored, nonce);
}

void testSendheadersEmptyPayload() {
    const auto& chain = cpbitnode::chain::testnet4();
    const std::vector<std::uint8_t> payload;
    const auto frame = cpbitnode::wire::buildMessage(chain.magic, "sendheaders", payload);
    const auto header = cpbitnode::wire::parseHeader(
        std::span<const std::uint8_t>(frame.data(), cpbitnode::wire::kHeaderSize));
    EXPECT_EQ(header.command, "sendheaders");
    EXPECT_EQ(header.length, 0u);
}

void testPackUnpackIntegersRoundtrip() {
    const auto i32 = cpbitnode::wire::packInt32Le(-42);
    const auto [ri32, o32] = cpbitnode::wire::unpackInt32Le(i32, 0);
    EXPECT_EQ(ri32, -42);
    EXPECT_EQ(o32, 4u);

    const auto i64 = cpbitnode::wire::packInt64Le(-9876543210LL);
    const auto [ri64, o64] = cpbitnode::wire::unpackInt64Le(i64, 0);
    EXPECT_EQ(ri64, -9876543210LL);
    EXPECT_EQ(o64, 8u);

    const auto u32 = cpbitnode::wire::packUint32Le(0xDEADBEEFu);
    const auto [ru32, ou32] = cpbitnode::wire::unpackUint32Le(u32, 0);
    EXPECT_EQ(ru32, 0xDEADBEEFu);
    EXPECT_EQ(ou32, 4u);

    const auto u64 = cpbitnode::wire::packUint64Le(0x0123456789ABCDEFull);
    const auto [ru64, ou64] = cpbitnode::wire::unpackUint64Le(u64, 0);
    EXPECT_EQ(ru64, 0x0123456789ABCDEFull);
    EXPECT_EQ(ou64, 8u);
}

void testUnpackInt32PastEnd() {
    EXPECT_TRUE(expectRuntimeError([] {
        cpbitnode::wire::unpackInt32Le(std::vector<std::uint8_t>{0x01, 0x02}, 0);
    }));
}

void testUnpackInt64PastEnd() {
    EXPECT_TRUE(expectRuntimeError([] {
        cpbitnode::wire::unpackInt64Le(std::vector<std::uint8_t>(7, 0x00), 0);
    }));
}

void testUnpackUint32PastEnd() {
    EXPECT_TRUE(expectRuntimeError([] {
        cpbitnode::wire::unpackUint32Le(std::vector<std::uint8_t>{0x01}, 1);
    }));
}

void testUnpackUint64PastEnd() {
    EXPECT_TRUE(expectRuntimeError([] {
        cpbitnode::wire::unpackUint64Le(std::vector<std::uint8_t>(4, 0x00), 0);
    }));
}

void testWriteVarintSingleByteEncoding() {
    EXPECT_BYTES_EQ(cpbitnode::wire::writeVarint(0xFC), std::vector<std::uint8_t>{0xFC});
}

void testWriteVarintTwoByteEncoding() {
    const auto encoded = cpbitnode::wire::writeVarint(0x1234);
    EXPECT_EQ(encoded.size(), 3u);
    EXPECT_EQ(encoded[0], 0xFD);
}

void testWriteVarintFourByteEncoding() {
    const auto encoded = cpbitnode::wire::writeVarint(0x12345678);
    EXPECT_EQ(encoded.size(), 5u);
    EXPECT_EQ(encoded[0], 0xFE);
}

void testWriteVarintEightByteEncoding() {
    const auto encoded = cpbitnode::wire::writeVarint(0x123456789ABCDEF0ull);
    EXPECT_EQ(encoded.size(), 9u);
    EXPECT_EQ(encoded[0], 0xFF);
}

void testReadVarintSingleByte() {
    const auto [value, offset] = cpbitnode::wire::readVarint(std::vector<std::uint8_t>{0x7B}, 0);
    EXPECT_EQ(value, 0x7Bu);
    EXPECT_EQ(offset, 1u);
}

void testReadVarintFdEncoding() {
    const std::vector<std::uint8_t> data{0xFD, 0x34, 0x12};
    const auto [value, offset] = cpbitnode::wire::readVarint(data, 0);
    EXPECT_EQ(value, 0x1234u);
    EXPECT_EQ(offset, 3u);
}

void testReadVarintFeEncoding() {
    const auto body = cpbitnode::wire::packUint32Le(0x89ABCDEFu);
    std::vector<std::uint8_t> data{0xFE};
    data.insert(data.end(), body.begin(), body.end());
    const auto [value, offset] = cpbitnode::wire::readVarint(data, 0);
    EXPECT_EQ(value, 0x89ABCDEFu);
    EXPECT_EQ(offset, 5u);
}

void testReadVarintFfEncoding() {
    const auto body = cpbitnode::wire::packUint64Le(0x0123456789ABCDEFull);
    std::vector<std::uint8_t> data{0xFF};
    data.insert(data.end(), body.begin(), body.end());
    const auto [value, offset] = cpbitnode::wire::readVarint(data, 0);
    EXPECT_EQ(value, 0x0123456789ABCDEFull);
    EXPECT_EQ(offset, 9u);
}

void testReadVarintPastEndOnPrefix() {
    EXPECT_TRUE(expectRuntimeError([] {
        cpbitnode::wire::readVarint(std::vector<std::uint8_t>{}, 0);
    }));
}

void testReadVarintFdTruncated() {
    EXPECT_TRUE(expectRuntimeError([] {
        cpbitnode::wire::readVarint(std::vector<std::uint8_t>{0xFD, 0x01}, 0);
    }));
}

void testMessageChecksumMatchesPayload() {
    const std::vector<std::uint8_t> payload{0x01, 0x02, 0x03};
    const auto checksum = cpbitnode::wire::messageChecksum(payload);
    EXPECT_EQ(checksum.size(), 4u);
    EXPECT_TRUE(cpbitnode::wire::verifyChecksum(payload, checksum));
}

void testVerifyChecksumRejectsMismatch() {
    const std::vector<std::uint8_t> payload{0x0A, 0x0B};
    const std::vector<std::uint8_t> bad{0x00, 0x00, 0x00, 0x00};
    EXPECT_TRUE(!cpbitnode::wire::verifyChecksum(payload, bad));
}

void testVerifyChecksumRejectsWrongLength() {
    const std::vector<std::uint8_t> payload{0x01};
    const std::vector<std::uint8_t> shortChecksum{0x01, 0x02};
    EXPECT_TRUE(!cpbitnode::wire::verifyChecksum(payload, shortChecksum));
}

void testParseHeaderTruncated() {
    EXPECT_TRUE(expectRuntimeError([] {
        cpbitnode::wire::parseHeader(std::vector<std::uint8_t>(cpbitnode::wire::kHeaderSize - 1, 0x00));
    }));
}

void testParseHeaderStripsNullPadding() {
    std::vector<std::uint8_t> frame(24, 0x00);
    const char cmd[] = "ping";
    std::memcpy(frame.data() + 4, cmd, 4);
    const auto header = cpbitnode::wire::parseHeader(frame);
    EXPECT_EQ(header.command, "ping");
}

void testParseHeaderTruncatesLongCommand() {
    const auto& chain = cpbitnode::chain::testnet4();
    const auto frame = cpbitnode::wire::buildMessage(chain.magic, "verylongcommandname", {});
    const auto header = cpbitnode::wire::parseHeader(
        std::span<const std::uint8_t>(frame.data(), cpbitnode::wire::kHeaderSize));
    EXPECT_EQ(header.command, "verylongcomm");
}

void testHeaderToBytesInvalidMagicSize() {
    cpbitnode::wire::MessageHeader header;
    header.magic = {0x01, 0x02};
    header.checksum = {0x00, 0x00, 0x00, 0x00};
    EXPECT_TRUE(expectRuntimeError([&] { cpbitnode::wire::headerToBytes(header); }));
}

void testHeaderToBytesInvalidChecksumSize() {
    cpbitnode::wire::MessageHeader header;
    header.magic = {0x01, 0x02, 0x03, 0x04};
    header.checksum = {0x00, 0x00};
    EXPECT_TRUE(expectRuntimeError([&] { cpbitnode::wire::headerToBytes(header); }));
}

void testHeaderToBytesRoundtrip() {
    const auto& chain = cpbitnode::chain::testnet4();
    const auto frame = cpbitnode::wire::buildMessage(chain.magic, "verack", {});
    const auto parsed = cpbitnode::wire::parseHeader(
        std::span<const std::uint8_t>(frame.data(), cpbitnode::wire::kHeaderSize));
    const auto bytes = cpbitnode::wire::headerToBytes(parsed);
    EXPECT_BYTES_EQ(bytes, std::vector<std::uint8_t>(frame.begin(), frame.begin() + 24));
}

void testUnpackWithNonZeroOffset() {
    std::vector<std::uint8_t> data{0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09};
    const auto [i32, o32] = cpbitnode::wire::unpackInt32Le(data, 1);
    EXPECT_EQ(o32, 5u);
    const auto [i64, o64] = cpbitnode::wire::unpackInt64Le(data, 1);
    EXPECT_EQ(o64, 9u);
    const auto [u32, ou32] = cpbitnode::wire::unpackUint32Le(data, 1);
    EXPECT_EQ(ou32, 5u);
    const auto [u64, ou64] = cpbitnode::wire::unpackUint64Le(data, 1);
    EXPECT_EQ(ou64, 9u);
}

void testReadVarintRoundtripAllEncodings() {
    for (const std::uint64_t value : {0xFCull, 0x1234ull, 0x12345678ull, 0x123456789ABCDEF0ull}) {
        const auto encoded = cpbitnode::wire::writeVarint(value);
        const auto [decoded, offset] = cpbitnode::wire::readVarint(encoded, 0);
        EXPECT_EQ(decoded, value);
        EXPECT_EQ(offset, encoded.size());
    }
}

}  // namespace

void registerWireTests() {
    RUN_TEST(testMessageFramingRoundtrip);
    RUN_TEST(testSendheadersEmptyPayload);
    RUN_TEST(testPackUnpackIntegersRoundtrip);
    RUN_TEST(testUnpackInt32PastEnd);
    RUN_TEST(testUnpackInt64PastEnd);
    RUN_TEST(testUnpackUint32PastEnd);
    RUN_TEST(testUnpackUint64PastEnd);
    RUN_TEST(testWriteVarintSingleByteEncoding);
    RUN_TEST(testWriteVarintTwoByteEncoding);
    RUN_TEST(testWriteVarintFourByteEncoding);
    RUN_TEST(testWriteVarintEightByteEncoding);
    RUN_TEST(testReadVarintSingleByte);
    RUN_TEST(testReadVarintFdEncoding);
    RUN_TEST(testReadVarintFeEncoding);
    RUN_TEST(testReadVarintFfEncoding);
    RUN_TEST(testReadVarintPastEndOnPrefix);
    RUN_TEST(testReadVarintFdTruncated);
    RUN_TEST(testMessageChecksumMatchesPayload);
    RUN_TEST(testVerifyChecksumRejectsMismatch);
    RUN_TEST(testVerifyChecksumRejectsWrongLength);
    RUN_TEST(testParseHeaderTruncated);
    RUN_TEST(testParseHeaderStripsNullPadding);
    RUN_TEST(testParseHeaderTruncatesLongCommand);
    RUN_TEST(testHeaderToBytesInvalidMagicSize);
    RUN_TEST(testHeaderToBytesInvalidChecksumSize);
    RUN_TEST(testHeaderToBytesRoundtrip);
    RUN_TEST(testUnpackWithNonZeroOffset);
    RUN_TEST(testReadVarintRoundtripAllEncodings);
}
