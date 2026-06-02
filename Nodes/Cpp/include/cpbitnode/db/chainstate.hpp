#pragma once

#include "cpbitnode/db/node_state.hpp"

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace cpbitnode::db {

struct ChainstateTip {
    int height = -1;
    std::string hash;
};

struct ChainstateMetadata {
    std::string backendName = "sqlite";
    std::string backendPath;
    std::string status = "usable";
    std::string generationId;
    std::string schemaVersion = "1";
};

class ChainstateStore {
public:
    virtual ~ChainstateStore() = default;

    virtual ChainstateMetadata metadata() const = 0;
    virtual ChainstateTip readTip(const std::string& chain) const = 0;
    virtual void setTip(const std::string& chain, int height, const std::string& blockHashHex) = 0;
    virtual int utxoCount() const = 0;
    virtual std::optional<StoredUtxo> getUtxo(const std::vector<std::uint8_t>& txid, int vout) const = 0;
    virtual void addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height, std::int64_t value,
                         const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) = 0;
    virtual void spendUtxo(const std::vector<std::uint8_t>& txid, int vout) = 0;
    virtual void replaceUtxoUndo(const std::string& chain, int height, const std::vector<StoredUtxo>& entries) = 0;
    virtual std::vector<StoredUtxo> takeUtxoUndo(const std::string& chain, int height) = 0;
    virtual void deleteUtxosCreatedAtHeight(int height) = 0;
    virtual void resetValidatedChain(const std::string& chain, const std::string& genesisHash) = 0;
};

class NodeStateChainstateStore final : public ChainstateStore {
public:
    explicit NodeStateChainstateStore(NodeStateStore& state);

    ChainstateMetadata metadata() const override;
    ChainstateTip readTip(const std::string& chain) const override;
    void setTip(const std::string& chain, int height, const std::string& blockHashHex) override;
    int utxoCount() const override;
    std::optional<StoredUtxo> getUtxo(const std::vector<std::uint8_t>& txid, int vout) const override;
    void addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height, std::int64_t value,
                 const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) override;
    void spendUtxo(const std::vector<std::uint8_t>& txid, int vout) override;
    void replaceUtxoUndo(const std::string& chain, int height, const std::vector<StoredUtxo>& entries) override;
    std::vector<StoredUtxo> takeUtxoUndo(const std::string& chain, int height) override;
    void deleteUtxosCreatedAtHeight(int height) override;
    void resetValidatedChain(const std::string& chain, const std::string& genesisHash) override;

private:
    NodeStateStore& state_;
};

std::unique_ptr<ChainstateStore> openChainstateStore(const std::string& backend, const std::string& dataDir,
                                                     NodeStateStore& state);

std::string defaultChainstateBackend();
std::string chainstateBackendName(const ChainstateStore& store);

}  // namespace cpbitnode::db
