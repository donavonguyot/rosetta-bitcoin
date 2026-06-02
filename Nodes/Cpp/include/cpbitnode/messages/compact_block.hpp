#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <span>
#include <string>
#include <utility>
#include <vector>

#include "cpbitnode/messages/block_header.hpp"
#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::messages {

struct PrefilledTransaction {
    std::uint64_t index = 0;
    Transaction tx;
};

struct CompactBlockMessage {
    static constexpr const char* kCommand = "cmpctblock";

    BlockHeader header;
    std::uint64_t shortIdNonce = 0;
    std::vector<std::vector<std::uint8_t>> shortids;
    std::vector<PrefilledTransaction> prefilled;

    std::vector<std::uint8_t> serialize() const;
    static CompactBlockMessage deserialize(std::span<const std::uint8_t> payload);
};

struct GetBlockTxnMessage {
    static constexpr const char* kCommand = "getblocktxn";

    std::vector<std::uint8_t> blockHash;
    std::vector<std::uint64_t> txnIndexes;

    std::vector<std::uint8_t> serialize() const;
    static GetBlockTxnMessage deserialize(std::span<const std::uint8_t> payload);

    bool operator==(const GetBlockTxnMessage& other) const;
};

struct BlockTxnMessage {
    static constexpr const char* kCommand = "blocktxn";

    std::vector<std::uint8_t> blockHash;
    std::vector<Transaction> transactions;

    std::vector<std::uint8_t> serialize() const;
    static BlockTxnMessage deserialize(std::span<const std::uint8_t> payload);
};

using CompactShortIdMap = std::map<std::vector<std::uint8_t>, Transaction>;

std::vector<std::uint8_t> bitcoinShortTransactionId(const BlockHeader& header,
                                                    std::uint64_t shortIdNonce,
                                                    const Transaction& tx);

std::vector<Transaction> reconstructCompactTransactions(const CompactBlockMessage& compact,
                                                        const CompactShortIdMap& txsByShortid);

std::vector<std::uint8_t> serializeBlockWire(const BlockHeader& header,
                                              std::span<const Transaction> transactions);

std::vector<std::uint8_t> reconstructCompactBlockWire(const CompactBlockMessage& compact,
                                                      const CompactShortIdMap& txsByShortid);

std::optional<std::vector<Transaction>> tryReconstructCompactBlock(
    const CompactBlockMessage& compact,
    std::span<const Transaction> pooledTransactions);

std::optional<CompactShortIdMap> mempoolShortIdTransactionMap(const CompactBlockMessage& compact,
                                                              std::span<const Transaction> pooledTransactions);

std::optional<std::vector<std::uint64_t>> missingIndexesForGetblocktxn(const CompactBlockMessage& compact,
                                                                       const CompactShortIdMap& txsByShortid);

std::optional<std::vector<Transaction>> completeCompactWithBlockTransactions(
    const CompactBlockMessage& compact,
    const CompactShortIdMap& poolMap,
    std::span<const std::uint64_t> indexesRequestedSorted,
    std::span<const Transaction> replyTransactions);

}  // namespace cpbitnode::messages
