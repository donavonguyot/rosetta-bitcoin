#include "test_support.hpp"
#include "script_helpers.hpp"

#include "cpbitnode/config/settings.hpp"
#include "cpbitnode/consensus/hash.hpp"
#include "cpbitnode/consensus/merkle.hpp"
#include "cpbitnode/consensus/script/sighash.hpp"
#include "cpbitnode/consensus/secp256k1.hpp"
#include "cpbitnode/consensus/witness.hpp"
#include "cpbitnode/db/tracker.hpp"
#include "cpbitnode/messages/inventory.hpp"
#include "cpbitnode/messages/transaction.hpp"
#include "cpbitnode/mempool/mempool.hpp"
#include "cpbitnode/mempool/orphan_pool.hpp"
#include "cpbitnode/mempool/relay.hpp"
#include "cpbitnode/p2p/peer.hpp"

#include "p2p_test_helpers.hpp"

#include <array>
#include <filesystem>
#include <stdexcept>
#include <vector>

void registerMempoolTests();

namespace {
using namespace cpbitnode;

std::vector<std::uint8_t> repeatByte(std::uint8_t b, std::size_t n) {
    return std::vector<std::uint8_t>(n, b);
}

std::vector<std::uint8_t> compressedPubkey(std::uint64_t secret) {
    const auto g = consensus::secp256k1Generator();
    const auto pt = consensus::scalarMult(secret, g);
    EXPECT_TRUE(pt.has_value());
    std::vector<std::uint8_t> out = {static_cast<std::uint8_t>(0x02 + (pt->y[31] & 1))};
    out.insert(out.end(), pt->x.begin(), pt->x.end());
    return out;
}

void fundP2pkhUtxo(db::ProjectTracker& tracker, const std::vector<std::uint8_t>& prevout,
                   const std::vector<std::uint8_t>& pubkey, std::int64_t value) {
    tracker.addUtxo(prevout, 0, 12, value, tests::p2pkhScriptPubkey(consensus::hash160(pubkey)), false);
}

void fundUtxo(db::ProjectTracker& tracker, const std::vector<std::uint8_t>& prevout, std::int64_t value) {
    tracker.addUtxo(prevout, 0, 12, value, {0x51}, false);
}

messages::Transaction signedP2pkhRoundtrip(std::uint64_t privateKey, const std::vector<std::uint8_t>& prevTxid,
                                           std::int64_t inputValue, std::int64_t outputValue) {
    const auto pubkey = compressedPubkey(privateKey);
    return tests::makeSignedP2pkhSpend(privateKey, prevTxid, 0, inputValue, pubkey, outputValue).first;
}

messages::Transaction sampleTx(const std::vector<std::uint8_t>* prev = nullptr) {
    const auto h = prev != nullptr ? *prev : repeatByte(0xAB, 32);
    messages::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{h, 0}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(messages::TxOut{1234, {0x51}});
    tx.lockTime = 0;
    return tx;
}

messages::Transaction spendPrev(const std::vector<std::uint8_t>& prevout, std::int64_t outputValue) {
    messages::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{prevout, 0}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(messages::TxOut{outputValue, {0x51}});
    tx.lockTime = 0;
    return tx;
}

std::pair<messages::Transaction, messages::Transaction> signedParentChildChain(
    const std::vector<std::uint8_t>& prevCoin, std::int64_t coinAmt, std::int64_t parentToChildValue,
    std::int64_t childRemainderValue, std::uint64_t privateKey, const std::vector<std::uint8_t>& pubkey) {
    const auto redeem = tests::p2pkhScriptPubkey(consensus::hash160(pubkey));
    const auto [parentSigned, _] =
        tests::makeSignedP2pkhSpend(privateKey, prevCoin, 0, coinAmt, pubkey, parentToChildValue, redeem);
    const auto pid = consensus::transactionTxid(parentSigned);
    const auto [childSigned, __] =
        tests::makeSignedP2pkhSpend(privateKey, pid, 0, parentToChildValue, pubkey, childRemainderValue);
    return {parentSigned, childSigned};
}

#define EXPECT_THROW(expr) \
    do { \
        bool threw = false; \
        try { \
            expr; \
        } catch (const std::exception&) { \
            threw = true; \
        } \
        if (!threw) { \
            std::cerr << "FAIL: " << __FILE__ << ":" << __LINE__ << " expected throw for " #expr "\n"; \
            ++g_failures; \
        } \
    } while (0)

void testMempoolAcceptTaprootScriptPathSpend() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_tr_script_sp.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0x44, 32);
    constexpr std::int64_t inputValue = 2'250'000;
    const auto g = consensus::secp256k1Generator();
    auto pt = consensus::scalarMult(99, g);
    EXPECT_TRUE(pt.has_value());
    if (pt->y[31] & 1) {
        pt = consensus::scalarMult(99, g);
    }
    std::array<std::uint8_t, 32> internalX = pt->x;
    const std::vector<std::uint8_t> tapscript = {0x51};
    const auto merkle = consensus::script::tapleafHash(0xC0, tapscript);
    const auto [parityQ, outputX] = consensus::taprootTweakPubkeyXonly(internalX, merkle);
    std::vector<std::uint8_t> p2trSpk = {0x51, 0x20};
    p2trSpk.insert(p2trSpk.end(), outputX.begin(), outputX.end());
    std::vector<std::uint8_t> controlBlock = {static_cast<std::uint8_t>(0xC0 | (parityQ & 1))};
    controlBlock.insert(controlBlock.end(), internalX.begin(), internalX.end());

    tracker.addUtxo(prev, 0, 20, inputValue, p2trSpk, false);

    messages::Transaction spendTx;
    spendTx.version = 2;
    spendTx.inputs.push_back(messages::TxIn{messages::OutPoint{prev, 0}, {}, 0xFFFFFFFD});
    spendTx.outputs.push_back(messages::TxOut{2'236'250, {0x51}});
    spendTx.lockTime = 0;
    spendTx.witness = {{tapscript, controlBlock}};

    config::Settings overlaySettings;
    overlaySettings.minRelayFeerateSatVb = 0;
    mempool::AcceptTransactionOptions opts;
    opts.settings = &overlaySettings;
    EXPECT_TRUE(mempool::acceptTransaction(spendTx, tracker, opts));

    mempool::MempoolOptions poolOpts;
    poolOpts.maxSizeBytes = 512 * 1024;
    poolOpts.tracker = &tracker;
    poolOpts.settings = &overlaySettings;
    mempool::Mempool pool(poolOpts);
    EXPECT_TRUE(pool.add(spendTx));
}

void testMempoolAddRemoveRoundtrip() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_roundtrip.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    mempool::Mempool pool({.maxSizeBytes = 256 * 1024});

    const auto prev = repeatByte(0xAA, 32);
    constexpr std::int64_t inputValue = 2'500'000;
    const auto pubkey = compressedPubkey(1);
    fundP2pkhUtxo(tracker, prev, pubkey, inputValue);

    const auto signedTx = signedP2pkhRoundtrip(1, prev, inputValue, 100'000);
    const auto tid = consensus::transactionTxid(signedTx);
    EXPECT_TRUE(mempool::acceptTransaction(signedTx, tracker));
    EXPECT_TRUE(pool.add(signedTx));
    EXPECT_TRUE(pool.get(tid).has_value());
    EXPECT_TRUE(pool.totalSizeBytes() > 0);
    EXPECT_TRUE(pool.remove(tid));
    EXPECT_TRUE(!pool.get(tid).has_value());
    EXPECT_EQ(pool.totalSizeBytes(), 0u);
}

void testMempoolRejectsDuplicate() {
    mempool::Mempool pool;
    const auto tx = sampleTx();
    EXPECT_TRUE(pool.add(tx));
    EXPECT_TRUE(!pool.add(tx));
}

void testMempoolRespectsCapacity() {
    messages::Transaction txSmall;
    txSmall.version = 1;
    txSmall.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x01, 32), 0}, {}, 0xFFFFFFFF});
    txSmall.outputs.push_back(messages::TxOut{1, {}});
    txSmall.lockTime = 0;

    messages::Transaction txOther;
    txOther.version = 1;
    txOther.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x02, 32), 0}, {}, 0xFFFFFFFF});
    txOther.outputs.push_back(messages::TxOut{1, {}});
    txOther.lockTime = 0;

    const auto oneSize = txSmall.serialize(true).size();
    mempool::Mempool pool({.maxSizeBytes = oneSize});
    const auto tidSmall = consensus::transactionTxid(txSmall);
    const auto tidOther = consensus::transactionTxid(txOther);
    EXPECT_TRUE(pool.add(txSmall));
    EXPECT_TRUE(pool.add(txOther));
    EXPECT_TRUE(!pool.get(tidSmall).has_value());
    EXPECT_TRUE(pool.get(tidOther).has_value());
    EXPECT_TRUE(pool.totalSizeBytes() <= oneSize);
}

void testMempoolGetForInvWitnessVsTxHash() {
    mempool::Mempool pool;
    messages::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x11, 32), 3}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(messages::TxOut{555, {0x51}});
    tx.lockTime = 0;
    tx.witness = {{{0xAA, 0xBB}}};
    EXPECT_TRUE(pool.add(tx));
    const auto tid = consensus::transactionTxid(tx);
    const auto wid = consensus::transactionWtxid(tx);
    EXPECT_TRUE(tid != wid);
    EXPECT_TRUE(pool.getForInv(messages::MSG_TX, tid).has_value());
    EXPECT_TRUE(pool.getForInv(messages::MSG_WITNESS_TX, wid).has_value());
}

void testAcceptTransactionRejectsInvalidStructure() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_structure.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());

    messages::Transaction coinbase;
    coinbase.version = 2;
    coinbase.inputs.push_back(
        messages::TxIn{messages::OutPoint{repeatByte(0x00, 32), 0xFFFFFFFF}, {0x03}, 0xFFFFFFFF});
    coinbase.outputs.push_back(messages::TxOut{1234, {0x51}});
    EXPECT_TRUE(!mempool::acceptTransaction(coinbase, tracker));

    messages::Transaction noInputs;
    noInputs.version = 1;
    noInputs.outputs.push_back(messages::TxOut{1, {0x51}});
    EXPECT_TRUE(!mempool::acceptTransaction(noInputs, tracker));

    messages::Transaction noOutputs;
    noOutputs.version = 1;
    noOutputs.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x01, 32), 0}, {}, 0xFFFFFFFF});
    EXPECT_TRUE(!mempool::acceptTransaction(noOutputs, tracker));
}

void testAcceptTransactionAcceptsValidP2pkhSpend() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_good_p2pkh.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0x12, 32);
    constexpr std::int64_t inputValue = 1'234'568;
    fundP2pkhUtxo(tracker, prev, compressedPubkey(1), inputValue);
    const auto signedTx = signedP2pkhRoundtrip(1, prev, inputValue, 50'000);
    EXPECT_TRUE(mempool::acceptTransaction(signedTx, tracker));
}

void testAcceptTransactionMinRelayRejectsUnknownPrevouts() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_relay_prev.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    config::Settings policies;
    policies.minRelayFeerateSatVb = 1;
    mempool::AcceptTransactionOptions opts;
    opts.settings = &policies;
    EXPECT_TRUE(!mempool::acceptTransaction(spendPrev(repeatByte(0xBB, 32), 1), tracker, opts));
}

void testAcceptTransactionMinRelayRejectsBelowThreshold() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_relay_below.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0xCC, 32);
    constexpr std::int64_t inputValue = 500'000;
    fundP2pkhUtxo(tracker, prev, compressedPubkey(1), inputValue);

    constexpr int minRate = 50;
    config::Settings policies;
    policies.minRelayFeerateSatVb = minRate;
    mempool::AcceptTransactionOptions opts;
    opts.settings = &policies;

    const auto placeholder = signedP2pkhRoundtrip(1, prev, inputValue, inputValue / 2);
    const int vbytes = mempool::estimateTxVirtualSizeScaffold(placeholder);
    const auto requiredFee = static_cast<std::int64_t>(minRate) * vbytes;
    const auto stingyFee = requiredFee - 1;
    const auto stingyTx = signedP2pkhRoundtrip(1, prev, inputValue, inputValue - stingyFee);
    EXPECT_TRUE(mempool::acceptTransaction(stingyTx, tracker, opts) == false);
}

void testAcceptTransactionRejectsDuplicatePrevoutsWithinSameTx() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_dup_prev.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0xDA, 32);
    constexpr std::int64_t inputValue = 90'000;
    fundP2pkhUtxo(tracker, prev, compressedPubkey(1), inputValue);
    const auto signedTx = signedP2pkhRoundtrip(1, prev, inputValue, 50'000);
    messages::Transaction dupTx = signedTx;
    dupTx.inputs.push_back(signedTx.inputs[0]);
    EXPECT_TRUE(!mempool::acceptTransaction(dupTx, tracker));
}

void testAcceptTransactionSecondSpendConflictWhenMempoolClaimsPrevout() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_ds.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0xDB, 32);
    constexpr std::int64_t inputValue = 400'000;
    fundP2pkhUtxo(tracker, prev, compressedPubkey(1), inputValue);
    const auto txA = signedP2pkhRoundtrip(1, prev, inputValue, 300'000);
    const auto txB = signedP2pkhRoundtrip(1, prev, inputValue, 250'000);
    mempool::Mempool pool;
    EXPECT_TRUE(mempool::acceptTransaction(txA, tracker));
    pool.add(txA);
    mempool::AcceptTransactionOptions opts;
    const auto claimed = pool.claimedPrevoutsFrozen();
    opts.mempoolClaimedPrevouts = &claimed;
    EXPECT_TRUE(!mempool::acceptTransaction(txB, tracker, opts));
}

void testMempoolClaimedPrevoutsRoundtripWhenAddThenRemove() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_claim_round.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    mempool::Mempool pool;
    const auto prev = repeatByte(0xDC, 32);
    constexpr std::int64_t inputValue = 800'000;
    fundP2pkhUtxo(tracker, prev, compressedPubkey(1), inputValue);
    const auto tx = signedP2pkhRoundtrip(1, prev, inputValue, 750'000);
    EXPECT_TRUE(pool.add(tx));
    EXPECT_TRUE(pool.claimedPrevoutsFrozen().contains({prev, 0}));
    EXPECT_TRUE(pool.remove(consensus::transactionTxid(tx)));
    EXPECT_TRUE(!pool.claimedPrevoutsFrozen().contains({prev, 0}));
}

void testTransactionMeetsPeerFeefilterPassesUntilPeerAnnounces() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_ff_utxo.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0xEE, 32);
    fundUtxo(tracker, prev, 600'000);
    const auto tx = spendPrev(prev, 599'990);
    EXPECT_TRUE(mempool::transactionMeetsPeerFeefilter(tx, tracker, std::nullopt));
    EXPECT_TRUE(mempool::transactionMeetsPeerFeefilter(tx, tracker, 0));
}

void testTransactionMeetsPeerFeefilterBelowPeerMinimum() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_ff_below.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0xFF, 32);
    constexpr std::int64_t inputValue = 700'000;
    fundUtxo(tracker, prev, inputValue);
    const auto placeholder = spendPrev(prev, inputValue / 2);
    const int vbytes = mempool::estimateTxVirtualSizeScaffold(placeholder);
    const std::int64_t peerFilterSatKvb = 100 * 1000;
    const auto stingyFee = (peerFilterSatKvb * vbytes) / 1000 - 1;
    const auto stingyTx = spendPrev(prev, inputValue - stingyFee);
    EXPECT_TRUE(!mempool::transactionMeetsPeerFeefilter(stingyTx, tracker, peerFilterSatKvb));
    const auto tightFee = (peerFilterSatKvb * vbytes + 999) / 1000;
    const auto okTx = spendPrev(prev, inputValue - tightFee);
    EXPECT_TRUE(mempool::transactionMeetsPeerFeefilter(okTx, tracker, peerFilterSatKvb));
}

void testAcceptTransactionMinRelayAcceptsExactThreshold() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_relay_ok.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0xDD, 32);
    constexpr std::int64_t inputValue = 800'000;
    fundP2pkhUtxo(tracker, prev, compressedPubkey(1), inputValue);

    constexpr int minRate = 50;
    config::Settings policies;
    policies.minRelayFeerateSatVb = minRate;
    mempool::AcceptTransactionOptions opts;
    opts.settings = &policies;

    const auto placeholder = signedP2pkhRoundtrip(1, prev, inputValue, inputValue / 2);
    const int vbytes = mempool::estimateTxVirtualSizeScaffold(placeholder);
    const auto fee = static_cast<std::int64_t>(minRate) * vbytes;
    const auto okTx = signedP2pkhRoundtrip(1, prev, inputValue, inputValue - fee);
    EXPECT_TRUE(mempool::acceptTransaction(okTx, tracker, opts));

    mempool::Mempool mempool({.tracker = &tracker});
    EXPECT_TRUE(mempool.add(okTx));
    EXPECT_EQ(std::stoi(tracker.getMeta("mempool_tx_count").value_or("0")), 1);
}

void testMempoolInvalidCapacity() {
    EXPECT_THROW((mempool::Mempool({.maxSizeBytes = 0})));
}

void testMempoolInvalidMempoolMaxCount() {
    EXPECT_THROW((mempool::Mempool({.mempoolMaxCount = -1})));
}

void testMempoolEvictOverCapacityRemovesOldestFirst() {
    auto makeTx = [](std::uint8_t tag, std::int64_t value) {
        messages::Transaction tx;
        tx.version = 1;
        tx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(tag, 32), 0}, {}, 0xFFFFFFFF});
        tx.outputs.push_back(messages::TxOut{value, {0x51}});
        tx.lockTime = 0;
        return tx;
    };
    mempool::Mempool pool({.maxSizeBytes = 64 * 1024, .mempoolMaxCount = 2});
    const auto txA = makeTx(0x71, 1);
    const auto txB = makeTx(0x72, 2);
    const auto txC = makeTx(0x73, 3);
    EXPECT_TRUE(pool.add(txA));
    EXPECT_TRUE(pool.add(txB));
    EXPECT_TRUE(pool.add(txC));
    EXPECT_EQ(pool.size(), 2u);
    EXPECT_TRUE(!pool.get(consensus::transactionTxid(txA)).has_value());
    EXPECT_TRUE(pool.get(consensus::transactionTxid(txB)).has_value());
    EXPECT_TRUE(pool.get(consensus::transactionTxid(txC)).has_value());
}

void testMempoolEvictExpiredDropsStaleTx() {
    messages::Transaction tx;
    tx.version = 1;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x81, 32), 0}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(messages::TxOut{9, {0x51}});
    tx.lockTime = 0;
    mempool::Mempool pool({.maxSizeBytes = 64 * 1024, .mempoolMaxCount = 500, .mempoolMaxAgeSeconds = 60});
    const auto tid = consensus::transactionTxid(tx);
    EXPECT_TRUE(pool.add(tx));
    const auto addedAt = pool.entryAddedAt(tid);
    EXPECT_TRUE(addedAt.has_value());
    EXPECT_EQ(pool.evictExpired(*addedAt + 30.0), 0);
    EXPECT_TRUE(pool.contains(tid));
    EXPECT_EQ(pool.evictExpired(*addedAt + 61.0), 1);
    EXPECT_TRUE(!pool.contains(tid));
}

void testMempoolEvictOverCapacityMethodCountsBytes() {
    messages::Transaction txSmall;
    txSmall.version = 1;
    txSmall.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x91, 32), 0}, {}, 0xFFFFFFFF});
    txSmall.outputs.push_back(messages::TxOut{1, {}});
    txSmall.lockTime = 0;
    messages::Transaction txOther;
    txOther.version = 1;
    txOther.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x92, 32), 0}, {}, 0xFFFFFFFF});
    txOther.outputs.push_back(messages::TxOut{1, {}});
    txOther.lockTime = 0;
    const auto oneSize = txSmall.serialize(true).size();
    mempool::Mempool pool({.maxSizeBytes = oneSize, .mempoolMaxCount = 0, .mempoolMaxAgeSeconds = 0});
    EXPECT_TRUE(pool.add(txSmall));
    EXPECT_EQ(pool.size(), 1u);
    EXPECT_EQ(pool.evictOverCapacity(), 0);
    EXPECT_TRUE(pool.add(txOther));
    EXPECT_EQ(pool.size(), 1u);
    EXPECT_TRUE(pool.get(consensus::transactionTxid(txOther)).has_value());
}

void testAcceptTransactionSkipsOrphanWhenDeferOrphansDisabled() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_orp_defer_off.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0xF5, 32);
    const auto txChild = spendPrev(prev, 1);
    mempool::OrphanPool orphans;
    config::Settings settings;
    settings.enableOrphanPool = true;
    mempool::AcceptTransactionOptions opts;
    opts.settings = &settings;
    opts.orphanPool = &orphans;
    opts.deferOrphans = false;
    EXPECT_TRUE(!mempool::acceptTransaction(txChild, tracker, opts));
    EXPECT_TRUE(!orphans.contains(consensus::transactionTxid(txChild)));
}

void testOrphanPoolKeepsPartialPendingUntilSecondPrevoutSatisfied() {
    mempool::OrphanPool orphans;
    const mempool::PrevoutKey k1 = {repeatByte(0xE1, 32), 0};
    const mempool::PrevoutKey k2 = {repeatByte(0xE2, 32), 1};
    messages::Transaction txDual;
    txDual.version = 2;
    txDual.inputs.push_back(messages::TxIn{messages::OutPoint{k1.first, static_cast<std::uint32_t>(k1.second)}, {}, 0xFFFFFFFF});
    txDual.inputs.push_back(messages::TxIn{messages::OutPoint{k2.first, static_cast<std::uint32_t>(k2.second)}, {}, 0xFFFFFFFF});
    txDual.outputs.push_back(messages::TxOut{2, {0x51}});
    txDual.lockTime = 0;
    const auto cid = consensus::transactionTxid(txDual);
    EXPECT_TRUE(orphans.tryAdd(txDual, {k1, k2}));
    EXPECT_TRUE(orphans.takeReadyTransactionsForPrevout(k1).empty());
    EXPECT_TRUE(orphans.contains(cid));
    const auto snap = orphans.unresolvedPrevoutsSnapshot(cid);
    EXPECT_TRUE(snap.has_value());
    EXPECT_TRUE(snap->contains(k2));
    EXPECT_TRUE(!snap->contains(k1));
    const auto ready = orphans.takeReadyTransactionsForPrevout(k2);
    EXPECT_EQ(ready.size(), 1u);
    EXPECT_TRUE(!orphans.contains(cid));
}

void testOrphanPoolInvalidConstructor() {
    EXPECT_THROW((mempool::OrphanPool(0)));
    EXPECT_THROW((mempool::OrphanPool(10, 0)));
}

void testAcceptTransactionSkipsOrphanWithoutSettingsToggle() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_orp_no_cfg.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    mempool::OrphanPool orphans;
    config::Settings settings;
    settings.enableOrphanPool = false;
    mempool::AcceptTransactionOptions opts;
    opts.settings = &settings;
    opts.orphanPool = &orphans;
    opts.deferOrphans = true;
    EXPECT_TRUE(!mempool::acceptTransaction(spendPrev(repeatByte(0xF0, 32), 1), tracker, opts));
}

void testAcceptTransactionQueuesOrphansWhenEnabled() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_orp_yes.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    mempool::OrphanPool orphans;
    config::Settings settings;
    settings.enableOrphanPool = true;
    mempool::AcceptTransactionOptions opts;
    opts.settings = &settings;
    opts.orphanPool = &orphans;
    opts.deferOrphans = true;
    const auto txChild = spendPrev(repeatByte(0xF1, 32), 1);
    EXPECT_TRUE(!mempool::acceptTransaction(txChild, tracker, opts));
    const auto cid = consensus::transactionTxid(txChild);
    EXPECT_TRUE(orphans.contains(cid));
    EXPECT_TRUE(orphans.remove(cid));
}

void testMempoolPromotesOrphanWhenParentArrives() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_orp_chain.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prevA = repeatByte(0xF3, 32);
    constexpr std::int64_t parentAmt = 400'000;
    constexpr std::int64_t parentOutToChild = 300'000;
    constexpr std::int64_t childRemainder = 290'000;
    const auto pubkey = compressedPubkey(1);
    fundP2pkhUtxo(tracker, prevA, pubkey, parentAmt);
    const auto [parent, child] =
        signedParentChildChain(prevA, parentAmt, parentOutToChild, childRemainder, 1, pubkey);
    mempool::OrphanPool orphans;
    config::Settings policies;
    policies.enableOrphanPool = true;
    mempool::MempoolOptions poolOpts;
    poolOpts.tracker = &tracker;
    poolOpts.orphanPool = &orphans;
    poolOpts.settings = &policies;
    mempool::Mempool mempool(poolOpts);

    mempool::AcceptTransactionOptions childOpts;
    childOpts.settings = &policies;
    childOpts.orphanPool = &orphans;
    childOpts.deferOrphans = true;
    const auto emptyClaimed = mempool.claimedPrevoutsFrozen();
    childOpts.mempoolClaimedPrevouts = &emptyClaimed;
    EXPECT_TRUE(!mempool::acceptTransaction(child, tracker, childOpts));
    EXPECT_TRUE(mempool.claimedPrevoutsFrozen().empty());
    EXPECT_TRUE(orphans.contains(consensus::transactionTxid(child)));

    mempool::AcceptTransactionOptions parentOpts;
    parentOpts.settings = &policies;
    const auto parentClaimed = mempool.claimedPrevoutsFrozen();
    parentOpts.mempoolClaimedPrevouts = &parentClaimed;
    EXPECT_TRUE(mempool::acceptTransaction(parent, tracker, parentOpts));
    EXPECT_TRUE(mempool.add(parent));

    const auto pid = consensus::transactionTxid(parent);
    const auto cid = consensus::transactionTxid(child);
    EXPECT_EQ(orphans.size(), 0u);
    EXPECT_TRUE(!orphans.contains(cid));
    EXPECT_TRUE(mempool.get(pid).has_value());
    EXPECT_TRUE(mempool.get(cid).has_value());
}

void testOrphanPoolRespectsTransactionLimit() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_orp_limit.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    config::Settings policies;
    policies.enableOrphanPool = true;
    mempool::OrphanPool orphans(1, 256 * 1024);
    mempool::AcceptTransactionOptions opts;
    opts.settings = &policies;
    opts.orphanPool = &orphans;
    opts.deferOrphans = true;
    const auto t1 = spendPrev(repeatByte(0xFC, 32), 1);
    const auto t2 = spendPrev(repeatByte(0xFD, 32), 1);
    EXPECT_TRUE(!mempool::acceptTransaction(t1, tracker, opts));
    EXPECT_TRUE(orphans.contains(consensus::transactionTxid(t1)));
    EXPECT_TRUE(!mempool::acceptTransaction(t2, tracker, opts));
    EXPECT_TRUE(orphans.contains(consensus::transactionTxid(t1)));
    EXPECT_TRUE(!orphans.contains(consensus::transactionTxid(t2)));
}

void testCollectMissingPrevoutsFindsUtxoViaOverlayOnly() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_overlay.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    messages::Transaction parent;
    parent.version = 2;
    parent.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0xEA, 32), 2}, {}, 0xFFFFFFFF});
    parent.outputs.push_back(messages::TxOut{777, {0xAA, 0xBB}});
    parent.outputs.push_back(messages::TxOut{333, {0xCC}});
    parent.lockTime = 0;
    const auto overlayTid = consensus::transactionTxid(parent);

    messages::Transaction spender;
    spender.version = 2;
    spender.inputs.push_back(messages::TxIn{messages::OutPoint{overlayTid, 1}, {}, 0xFFFFFFFF});
    spender.outputs.push_back(messages::TxOut{222, {0x51}});
    spender.lockTime = 0;

    const auto missing = mempool::collectMissingPrevouts(spender, tracker);
    EXPECT_TRUE(missing.has_value());
    EXPECT_TRUE(missing->contains({overlayTid, 1}));

    std::unordered_map<mempool::PrevoutKey, mempool::UtxoOverlayRow, mempool::PrevoutKeyHash> overlay;
    overlay[{overlayTid, 1}] = {parent.outputs[1].value, parent.outputs[1].scriptPubkey};
    const auto resolved = mempool::collectMissingPrevouts(spender, tracker, &overlay);
    EXPECT_TRUE(resolved.has_value());
    EXPECT_TRUE(resolved->empty());
}

void testTxInventoryNeedGetdataSkipsKnownMempoolTx() {
    mempool::Mempool pool;
    const auto tx = sampleTx();
    EXPECT_TRUE(pool.add(tx));
    const auto tid = consensus::transactionTxid(tx);
    messages::InventoryVector known{messages::MSG_WITNESS_TX, tid};
    messages::InventoryVector unknown{messages::MSG_WITNESS_TX, repeatByte(0x99, 32)};
    const std::vector<messages::InventoryVector> items = {known, unknown};
    const auto todo = mempool::txInventoryNeedGetdata(items, &pool);
    EXPECT_EQ(todo.size(), 1u);
    EXPECT_BYTES_EQ(todo[0].hash, unknown.hash);
}

void testResolveGetdataTxInventoryServesMempoolTx() {
    mempool::Mempool pool;
    messages::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x21, 32), 0}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(messages::TxOut{100, {0x51}});
    tx.lockTime = 0;
    EXPECT_TRUE(pool.add(tx));
    const auto tid = consensus::transactionTxid(tx);
    messages::InventoryVector item{messages::MSG_TX, tid};
    const auto result = mempool::resolveGetdataTxInventory(pool, std::span<const messages::InventoryVector>{&item, 1});
    EXPECT_EQ(result.served.size(), 1u);
    EXPECT_TRUE(result.notFound.empty());
}

void testMempoolWireCapabilitiesMarkedByUnitTests() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_caps.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    tracker.markWireCapability("tx.feefilter", true, "unit", "feefilter gating unit tests");
    tracker.markWireCapability("tx.inv.recv", true, "unit", "tx inv getdata filter unit tests");
    const auto caps = tracker.wireCapabilityMap();
    EXPECT_EQ(caps.at("tx.feefilter"), 1);
    EXPECT_EQ(caps.at("tx.inv.recv"), 1);
}

void testHandleInboundTxMessageRejectsMalformedPayload() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_inbound_bad.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    mempool::Mempool pool;
    config::Settings settings;
    const std::vector<std::uint8_t> garbage = {0xFF, 0xFF, 0x01};
    EXPECT_TRUE(!mempool::handleInboundTxMessage(pool, tracker, settings, garbage, "203.0.113.9"));
}

void testHandleInboundTxMessageAcceptsValidTx() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_inbound_ok.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0x31, 32);
    fundP2pkhUtxo(tracker, prev, compressedPubkey(1), 500'000);
    const auto signedTx = signedP2pkhRoundtrip(1, prev, 500'000, 400'000);
    mempool::Mempool pool({.tracker = &tracker});
    config::Settings settings;
    const auto wire = messages::serializeTransaction(signedTx, true);
    EXPECT_TRUE(mempool::handleInboundTxMessage(pool, tracker, settings, wire, "203.0.113.10"));
    EXPECT_EQ(pool.size(), 1u);
}

void testHandleInboundTxMessageRejectsDuplicate() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_inbound_dup.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    const auto prev = repeatByte(0x32, 32);
    fundP2pkhUtxo(tracker, prev, compressedPubkey(1), 500'000);
    const auto signedTx = signedP2pkhRoundtrip(1, prev, 500'000, 400'000);
    mempool::Mempool pool({.tracker = &tracker});
    config::Settings settings;
    const auto wire = messages::serializeTransaction(signedTx, true);
    EXPECT_TRUE(mempool::handleInboundTxMessage(pool, tracker, settings, wire, "203.0.113.11"));
    EXPECT_TRUE(!mempool::handleInboundTxMessage(pool, tracker, settings, wire, "203.0.113.11"));
}

void testTxInventoryNeedGetdataNullPoolReturnsAll() {
    messages::InventoryVector item{messages::MSG_WITNESS_TX, repeatByte(0x55, 32)};
    const std::vector<messages::InventoryVector> items = {item};
    const auto todo = mempool::txInventoryNeedGetdata(items, nullptr);
    EXPECT_EQ(todo.size(), 1u);
}

void testResolveGetdataTxInventoryNotFoundAndSkipsNonTx() {
    mempool::Mempool pool;
    messages::InventoryVector blockItem{messages::MSG_WITNESS_BLOCK, repeatByte(0x01, 32)};
    messages::InventoryVector missingTx{messages::MSG_TX, repeatByte(0x02, 32)};
    const std::vector<messages::InventoryVector> items = {blockItem, missingTx};
    const auto result = mempool::resolveGetdataTxInventory(pool, items);
    EXPECT_TRUE(result.served.empty());
    EXPECT_EQ(result.notFound.size(), 1u);
    EXPECT_BYTES_EQ(result.notFound[0].hash, missingTx.hash);
}

void testReplyGetdataTxInventoryServesWitnessTxAndNotfound() {
    using cpbitnode::testp2p::MockTransport;
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_reply_getdata.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    mempool::Mempool pool;
    messages::Transaction tx;
    tx.version = 2;
    tx.inputs.push_back(messages::TxIn{messages::OutPoint{repeatByte(0x41, 32), 0}, {}, 0xFFFFFFFF});
    tx.outputs.push_back(messages::TxOut{500, {0x51}});
    EXPECT_TRUE(pool.add(tx));
    const auto tid = consensus::transactionTxid(tx);

    p2p::PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &chain::testnet4();
    options.tracker = &tracker;
    options.mempool = &pool;
    p2p::PeerConnection peer(std::move(options));
    auto transport = std::make_unique<MockTransport>();
    const auto* transportPtr = transport.get();
    peer.setTransportForTest(std::move(transport));

    messages::InventoryVector known{messages::MSG_WITNESS_TX, tid};
    messages::InventoryVector missing{messages::MSG_TX, repeatByte(0x42, 32)};
    const std::vector<messages::InventoryVector> items = {known, missing};
    mempool::replyGetdataTxInventory(peer, &pool, tracker, items);
    EXPECT_TRUE(transportPtr->writes().size() >= 2u);

    p2p::PeerConnection peerNoPool(std::move(p2p::PeerConnection::Options{
        .host = "127.0.0.1",
        .port = 48333,
        .chain = &chain::testnet4(),
        .tracker = &tracker,
    }));
    auto transport2 = std::make_unique<MockTransport>();
    peerNoPool.setTransportForTest(std::move(transport2));
    mempool::replyGetdataTxInventory(peerNoPool, nullptr, tracker, items);
}

void testReplyGetdataTxInventoryEmptyInventoryNoop() {
    const auto path = std::filesystem::temp_directory_path() / "cpbitnode_mempool_reply_empty.db";
    std::filesystem::remove(path);
    db::ProjectTracker tracker(path.string());
    p2p::PeerConnection::Options options;
    options.host = "127.0.0.1";
    options.port = 48333;
    options.chain = &chain::testnet4();
    options.tracker = &tracker;
    p2p::PeerConnection peer(std::move(options));
    auto transport = std::make_unique<cpbitnode::testp2p::MockTransport>();
    const auto* transportPtr = transport.get();
    peer.setTransportForTest(std::move(transport));
    const std::vector<messages::InventoryVector> empty;
    mempool::replyGetdataTxInventory(peer, nullptr, tracker, empty);
    EXPECT_EQ(transportPtr->writes().size(), 0u);
}

}  // namespace

void registerMempoolTests() {
    RUN_TEST(testMempoolAcceptTaprootScriptPathSpend);
    RUN_TEST(testMempoolAddRemoveRoundtrip);
    RUN_TEST(testMempoolRejectsDuplicate);
    RUN_TEST(testMempoolRespectsCapacity);
    RUN_TEST(testMempoolGetForInvWitnessVsTxHash);
    RUN_TEST(testAcceptTransactionRejectsInvalidStructure);
    RUN_TEST(testAcceptTransactionAcceptsValidP2pkhSpend);
    RUN_TEST(testAcceptTransactionMinRelayRejectsUnknownPrevouts);
    RUN_TEST(testAcceptTransactionMinRelayRejectsBelowThreshold);
    RUN_TEST(testAcceptTransactionRejectsDuplicatePrevoutsWithinSameTx);
    RUN_TEST(testAcceptTransactionSecondSpendConflictWhenMempoolClaimsPrevout);
    RUN_TEST(testMempoolClaimedPrevoutsRoundtripWhenAddThenRemove);
    RUN_TEST(testTransactionMeetsPeerFeefilterPassesUntilPeerAnnounces);
    RUN_TEST(testTransactionMeetsPeerFeefilterBelowPeerMinimum);
    RUN_TEST(testAcceptTransactionMinRelayAcceptsExactThreshold);
    RUN_TEST(testMempoolInvalidCapacity);
    RUN_TEST(testMempoolInvalidMempoolMaxCount);
    RUN_TEST(testMempoolEvictOverCapacityRemovesOldestFirst);
    RUN_TEST(testMempoolEvictExpiredDropsStaleTx);
    RUN_TEST(testMempoolEvictOverCapacityMethodCountsBytes);
    RUN_TEST(testAcceptTransactionSkipsOrphanWhenDeferOrphansDisabled);
    RUN_TEST(testOrphanPoolKeepsPartialPendingUntilSecondPrevoutSatisfied);
    RUN_TEST(testOrphanPoolInvalidConstructor);
    RUN_TEST(testAcceptTransactionSkipsOrphanWithoutSettingsToggle);
    RUN_TEST(testAcceptTransactionQueuesOrphansWhenEnabled);
    RUN_TEST(testMempoolPromotesOrphanWhenParentArrives);
    RUN_TEST(testOrphanPoolRespectsTransactionLimit);
    RUN_TEST(testCollectMissingPrevoutsFindsUtxoViaOverlayOnly);
    RUN_TEST(testTxInventoryNeedGetdataSkipsKnownMempoolTx);
    RUN_TEST(testResolveGetdataTxInventoryServesMempoolTx);
    RUN_TEST(testMempoolWireCapabilitiesMarkedByUnitTests);
    RUN_TEST(testHandleInboundTxMessageRejectsMalformedPayload);
    RUN_TEST(testHandleInboundTxMessageAcceptsValidTx);
    RUN_TEST(testHandleInboundTxMessageRejectsDuplicate);
    RUN_TEST(testTxInventoryNeedGetdataNullPoolReturnsAll);
    RUN_TEST(testResolveGetdataTxInventoryNotFoundAndSkipsNonTx);
    RUN_TEST(testReplyGetdataTxInventoryServesWitnessTxAndNotfound);
    RUN_TEST(testReplyGetdataTxInventoryEmptyInventoryNoop);
}
