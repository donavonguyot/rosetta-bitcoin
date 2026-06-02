#include "cpbitnode/consensus/merkle.hpp"

#include "cpbitnode/consensus/sha256.hpp"
#include "cpbitnode/messages/transaction.hpp"

namespace cpbitnode::consensus {

std::vector<std::uint8_t> merkleRoot(std::span<const std::vector<std::uint8_t>> hashes) {
    if (hashes.empty()) {
        return std::vector<std::uint8_t>(32, 0);
    }
    std::vector<std::vector<std::uint8_t>> layer(hashes.begin(), hashes.end());
    while (layer.size() > 1) {
        if (layer.size() % 2 == 1) {
            layer.push_back(layer.back());
        }
        std::vector<std::vector<std::uint8_t>> nextLayer;
        nextLayer.reserve(layer.size() / 2);
        for (std::size_t i = 0; i < layer.size(); i += 2) {
            std::vector<std::uint8_t> combined;
            combined.reserve(64);
            combined.insert(combined.end(), layer[i].begin(), layer[i].end());
            combined.insert(combined.end(), layer[i + 1].begin(), layer[i + 1].end());
            nextLayer.push_back(doubleSha256(combined));
        }
        layer = std::move(nextLayer);
    }
    return layer[0];
}

std::vector<std::uint8_t> transactionTxid(const messages::Transaction& transaction) {
    return doubleSha256(messages::serializeTransaction(transaction, false));
}

std::vector<std::uint8_t> blockMerkleRoot(std::span<const messages::Transaction> transactions) {
    std::vector<std::vector<std::uint8_t>> hashes;
    hashes.reserve(transactions.size());
    for (const auto& tx : transactions) {
        hashes.push_back(transactionTxid(tx));
    }
    return merkleRoot(hashes);
}

}  // namespace cpbitnode::consensus
