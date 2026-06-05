#include "test_support.hpp"

#include "blocks_fixture.hpp"

#include "cpbitnode/chain/params.hpp"
#include "cpbitnode/consensus/connect.hpp"
#include "cpbitnode/consensus/merkle.hpp"
#include "cpbitnode/db/codec_v2.hpp"
#include "cpbitnode/db/node_state.hpp"

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <vector>

void registerConnectTimingTests();

namespace {

std::vector<std::uint8_t> filledTxid(std::uint8_t value) {
    return std::vector<std::uint8_t>(32, value);
}

class SpyChainstateStore final : public cpbitnode::db::ChainstateStore {
public:
    cpbitnode::db::ChainstateMetadata metadata() const override { return {}; }
    cpbitnode::db::ChainstateTip readTip(const std::string& chain) const override {
        (void)chain;
        return tip_;
    }
    void setTip(const std::string& chain, int height, const std::string& blockHashHex) override {
        (void)chain;
        tip_ = cpbitnode::db::ChainstateTip{height, blockHashHex};
    }
    int utxoCount() const override { return static_cast<int>(utxos_.size()); }
    std::optional<cpbitnode::db::StoredUtxo> getUtxo(const std::vector<std::uint8_t>& txid, int vout) const override {
        ++singleGetCalls;
        for (const auto& utxo : utxos_) {
            if (utxo.txid == txid && utxo.vout == vout) {
                return utxo;
            }
        }
        return std::nullopt;
    }
    std::vector<std::optional<cpbitnode::db::StoredUtxo>>
    getUtxos(const std::vector<cpbitnode::db::Outpoint>& outpoints) const override {
        preloadRequests.push_back(outpoints);
        std::vector<std::optional<cpbitnode::db::StoredUtxo>> out;
        out.reserve(outpoints.size());
        for (const auto& outpoint : outpoints) {
            out.push_back(getUtxoWithoutCounting(outpoint.txid, outpoint.vout));
        }
        return out;
    }
    void addUtxo(const std::vector<std::uint8_t>& txid, int vout, int height, std::int64_t value,
                 const std::vector<std::uint8_t>& scriptPubkey, bool coinbase) override {
        utxos_.push_back(cpbitnode::db::StoredUtxo{txid, vout, height, value, scriptPubkey, coinbase});
    }
    void spendUtxo(const std::vector<std::uint8_t>& txid, int vout) override {
        std::erase_if(utxos_, [&](const auto& utxo) { return utxo.txid == txid && utxo.vout == vout; });
    }
    void replaceUtxoUndo(const std::string& chain, int height,
                         const std::vector<cpbitnode::db::StoredUtxo>& entries) override {
        (void)chain;
        undoHeight = height;
        undoEntries = entries;
    }
    std::vector<cpbitnode::db::StoredUtxo> takeUtxoUndo(const std::string& chain, int height) override {
        (void)chain;
        (void)height;
        return undoEntries;
    }
    void deleteUtxosCreatedAtHeight(int height) override { deletedHeight = height; }
    void resetValidatedChain(const std::string& chain, const std::string& genesisHash) override {
        (void)chain;
        tip_ = cpbitnode::db::ChainstateTip{0, genesisHash};
        utxos_.clear();
    }
    void commitBlock(const cpbitnode::db::BlockCommit& commit) override {
        commits.push_back(commit);
        for (const auto& spend : commit.spends) {
            spendUtxo(spend.txid, spend.vout);
        }
        for (const auto& create : commit.creates) {
            addUtxo(create.txid, create.vout, create.height, create.value, create.scriptPubkey, create.coinbase);
        }
        tip_ = cpbitnode::db::ChainstateTip{commit.height, commit.blockHash};
    }

    mutable std::vector<std::vector<cpbitnode::db::Outpoint>> preloadRequests;
    mutable int singleGetCalls = 0;
    std::vector<cpbitnode::db::BlockCommit> commits;
    int undoHeight = -1;
    int deletedHeight = -1;
    std::vector<cpbitnode::db::StoredUtxo> undoEntries;

private:
    std::optional<cpbitnode::db::StoredUtxo> getUtxoWithoutCounting(const std::vector<std::uint8_t>& txid,
                                                                    int vout) const {
        for (const auto& utxo : utxos_) {
            if (utxo.txid == txid && utxo.vout == vout) {
                return utxo;
            }
        }
        return std::nullopt;
    }

    cpbitnode::db::ChainstateTip tip_{0, std::string(64, '0')};
    std::vector<cpbitnode::db::StoredUtxo> utxos_;
};

cpbitnode::messages::Transaction makeCoinbaseTx() {
    cpbitnode::messages::Transaction tx;
    tx.version = 1;
    tx.inputs.push_back(cpbitnode::messages::TxIn{
        cpbitnode::messages::OutPoint{std::vector<std::uint8_t>(32, 0), 0xffffffffu}, {0x51}, 0xffffffffu});
    tx.outputs.push_back(cpbitnode::messages::TxOut{50'0000'0000LL, {0x51}});
    return tx;
}

cpbitnode::messages::Transaction makeSpendTx(const std::vector<std::uint8_t>& prevTxid) {
    cpbitnode::messages::Transaction tx;
    tx.version = 1;
    tx.inputs.push_back(
        cpbitnode::messages::TxIn{cpbitnode::messages::OutPoint{prevTxid, 0}, {}, 0xffffffffu});
    tx.outputs.push_back(cpbitnode::messages::TxOut{10, {0x51}});
    return tx;
}

cpbitnode::consensus::Block makeTinyConnectableBlock(const std::vector<std::uint8_t>& prevTxid) {
    cpbitnode::consensus::Block block;
    block.transactions = {makeCoinbaseTx(), makeSpendTx(prevTxid)};
    block.header.version = 1;
    block.header.prevBlock = std::vector<std::uint8_t>(32, 0);
    block.header.merkleRoot = cpbitnode::consensus::blockMerkleRoot(block.transactions);
    block.header.timestamp = 1;
    block.header.bits = 0x2100ffff;
    block.header.nonce = 0;
    return block;
}

std::string connectFixtureBlockWithTimingEnv(bool enabled) {
    const auto dir = std::filesystem::temp_directory_path() /
                     (enabled ? "cpbitnode_connect_timing_on" : "cpbitnode_connect_timing_off");
    std::filesystem::remove_all(dir);
    auto store = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    const auto& chain = cpbitnode::chain::testnet4();
    store->resetValidatedChain(chain.name, chain.genesisHash);

    if (enabled) {
        setenv("CPBITNODE_SYNC_TIMING", "1", 1);
    } else {
        unsetenv("CPBITNODE_SYNC_TIMING");
    }
    std::ostringstream captured;
    auto* old = std::cerr.rdbuf(captured.rdbuf());
    cpbitnode::consensus::ConnectBlockOptions options;
    options.height = 1;
    options.chainName = chain.name;
    options.expectedPrev = cpbitnode::db::codec_v2::displayHexToInternal(chain.genesisHash);
    cpbitnode::consensus::connectBlock(*store, cpbitnode::testfixtures::readFixtureBlock(0), options);
    std::cerr.rdbuf(old);
    unsetenv("CPBITNODE_SYNC_TIMING");
    std::filesystem::remove_all(dir);
    return captured.str();
}

void testConnectTimingOnlyWhenEnabled() {
    const auto disabled = connectFixtureBlockWithTimingEnv(false);
    EXPECT_TRUE(disabled.find("cpbitnode_sync_timing") == std::string::npos);

    const auto enabled = connectFixtureBlockWithTimingEnv(true);
    EXPECT_TRUE(enabled.find("cpbitnode_sync_timing") != std::string::npos);
    EXPECT_TRUE(enabled.find("utxo_load=") != std::string::npos);
    EXPECT_TRUE(enabled.find("script_verify=") != std::string::npos);
    EXPECT_TRUE(enabled.find("utxo_apply=") != std::string::npos);
    EXPECT_TRUE(enabled.find("commit=") != std::string::npos);
    EXPECT_TRUE(enabled.find("block_connect_store_commit=") != std::string::npos);
}

void testConnectDecodedBlockPreloadsSpendPrevoutsOnly() {
    const auto dir = std::filesystem::temp_directory_path() / "cpbitnode_connect_preload_spends_only";
    std::filesystem::remove_all(dir);
    auto tracker = cpbitnode::db::openRocksDbNodeStateStore(dir.string());
    SpyChainstateStore chainstate;
    const auto prevTxid = filledTxid(0x9a);
    chainstate.addUtxo(prevTxid, 0, 0, 20, {0x51}, false);

    cpbitnode::consensus::ConnectBlockOptions options;
    options.height = 1;
    options.chainName = "testnet4";
    options.expectedPrev = std::vector<std::uint8_t>(32, 0);
    const auto block = makeTinyConnectableBlock(prevTxid);
    cpbitnode::consensus::connectDecodedBlock(*tracker, chainstate, block, options);

    EXPECT_EQ(static_cast<int>(chainstate.preloadRequests.size()), 1);
    EXPECT_EQ(static_cast<int>(chainstate.preloadRequests.front().size()), 1);
    EXPECT_BYTES_EQ(chainstate.preloadRequests.front().front().txid, prevTxid);
    EXPECT_EQ(chainstate.preloadRequests.front().front().vout, 0);
    EXPECT_EQ(static_cast<int>(chainstate.commits.size()), 1);
    EXPECT_EQ(static_cast<int>(chainstate.commits.front().creates.size()), 2);
    EXPECT_EQ(static_cast<int>(chainstate.commits.front().spends.size()), 1);
    std::filesystem::remove_all(dir);
}

}  // namespace

void registerConnectTimingTests() {
    RUN_TEST(testConnectTimingOnlyWhenEnabled);
    RUN_TEST(testConnectDecodedBlockPreloadsSpendPrevoutsOnly);
}
