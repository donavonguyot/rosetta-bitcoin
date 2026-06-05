#include "cpbitnode/db/chainstate.hpp"

#include <memory>
#include <stdexcept>

namespace cpbitnode::db {

std::vector<std::optional<StoredUtxoRef>> ChainstateStore::getUtxos(
    std::span<const DbOutpointKey> outpoints) const {
    std::vector<Outpoint> legacy;
    legacy.reserve(outpoints.size());
    for (const auto& outpoint : outpoints) {
        legacy.push_back(Outpoint{txidVector(outpoint), static_cast<int>(outpoint.vout)});
    }
    const auto loaded = getUtxos(legacy);
    std::vector<std::optional<StoredUtxoRef>> out;
    out.reserve(loaded.size());
    for (const auto& utxo : loaded) {
        out.push_back(utxo ? std::optional<StoredUtxoRef>(toStoredUtxoRef(*utxo)) : std::nullopt);
    }
    return out;
}

void ChainstateStore::commitBlock(const BlockCommitNative& commit) {
    BlockCommit legacy;
    legacy.chain = commit.chain;
    legacy.height = commit.height;
    legacy.blockHash = commit.blockHash;
    legacy.blockIndex = commit.blockIndex;
    legacy.spends.reserve(commit.spends.size());
    for (const auto& spend : commit.spends) {
        legacy.spends.push_back(Outpoint{txidVector(spend), static_cast<int>(spend.vout)});
    }
    legacy.creates.reserve(commit.creates.size());
    for (const auto& create : commit.creates) {
        legacy.creates.push_back(UtxoCreate{txidVector(create.outpoint), static_cast<int>(create.outpoint.vout),
                                            create.height, create.value, create.scriptPubkey, create.coinbase});
    }
    legacy.undo.reserve(commit.undo.size());
    for (const auto& undo : commit.undo) {
        legacy.undo.push_back(toStoredUtxo(undo));
    }
    commitBlock(legacy);
}

NodeStateChainstateStore::NodeStateChainstateStore(NodeStateStore& state) : state_(state) {}

ChainstateMetadata NodeStateChainstateStore::metadata() const {
    const auto stateMeta = state_.nodeStateMetadata();
    ChainstateMetadata meta;
    meta.backendName = stateMeta.backendName;
    meta.backendPath = stateMeta.backendPath;
    meta.status = stateMeta.status;
    meta.generationId = stateMeta.generationId;
    meta.schemaVersion = stateMeta.schemaVersion;
    return meta;
}

ChainstateTip NodeStateChainstateStore::readTip(const std::string& chain) const {
    return ChainstateTip{state_.getValidatedHeight(chain), state_.getValidatedHash(chain)};
}

void NodeStateChainstateStore::setTip(const std::string& chain, int height, const std::string& blockHashHex) {
    state_.setValidatedTip(height, blockHashHex, chain);
}

int NodeStateChainstateStore::utxoCount() const {
    return state_.utxoCount();
}

std::optional<StoredUtxo> NodeStateChainstateStore::getUtxo(const std::vector<std::uint8_t>& txid, int vout) const {
    return state_.getUtxo(txid, vout);
}

std::vector<std::optional<StoredUtxo>> NodeStateChainstateStore::getUtxos(
    const std::vector<Outpoint>& outpoints) const {
    return state_.getUtxos(outpoints);
}

std::vector<std::optional<StoredUtxoRef>> NodeStateChainstateStore::getUtxos(
    std::span<const DbOutpointKey> outpoints) const {
    return state_.getUtxos(outpoints);
}

void NodeStateChainstateStore::addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height,
                                       std::int64_t value, const std::vector<std::uint8_t>& scriptPubkey,
                                       bool coinbase) {
    state_.addUtxo(txid, vout, height, value, scriptPubkey, coinbase);
}

void NodeStateChainstateStore::spendUtxo(const std::vector<std::uint8_t>& txid, int vout) {
    state_.spendUtxo(txid, vout);
}

void NodeStateChainstateStore::replaceUtxoUndo(const std::string& chain, int height,
                                               const std::vector<StoredUtxo>& entries) {
    state_.replaceUtxoUndo(chain, height, entries);
}

std::vector<StoredUtxo> NodeStateChainstateStore::takeUtxoUndo(const std::string& chain, int height) {
    return state_.takeUtxoUndo(chain, height);
}

void NodeStateChainstateStore::deleteUtxosCreatedAtHeight(int height) {
    state_.deleteUtxosCreatedAtHeight(height);
}

void NodeStateChainstateStore::resetValidatedChain(const std::string& chain, const std::string& genesisHash) {
    state_.resetValidatedChain(chain, genesisHash);
}

void NodeStateChainstateStore::commitBlock(const BlockCommit& commit) {
    state_.commitBlock(commit);
}

void NodeStateChainstateStore::commitBlock(const BlockCommitNative& commit) {
    state_.commitBlock(commit);
}

std::unique_ptr<ChainstateStore> openChainstateStore(const std::string& backend, const std::string& dataDir,
                                                     NodeStateStore& state) {
    (void)dataDir;
    if (backend != "rocksdb") {
        throw std::runtime_error("Cpp Core-native mode only supports RocksDB chainstate");
    }
    return std::make_unique<NodeStateChainstateStore>(state);
}

std::string defaultChainstateBackend() {
    return "rocksdb";
}

std::string chainstateBackendName(const ChainstateStore& store) {
    return store.metadata().backendName;
}

}  // namespace cpbitnode::db
