import Foundation

enum PerformanceSelfTest {
    static func run() throws -> [String: Any] {
        let checks: [(String, () throws -> Bool)] = [
            ("bip143_cache_matches_uncached", testBIP143SighashCacheMatchesUncached),
            ("taproot_cache_matches_uncached", testTaprootSighashCacheMatchesUncached),
            ("script_runner_first_failure_order", testScriptJobRunnerReportsFirstFailureByJobOrder),
            ("binary_outpoint_key_shape", testOutpointKeyUsesFixedBinaryRocksKey),
            ("same_block_spend_compaction", testSameBlockSpendCompaction),
            ("ordered_utxo_batch_file_store", testOrderedUtxoBatchFileStore),
            ("legacy_utxo_fallback_toggle", testLegacyUtxoFallbackToggle),
            ("worker_local_secp_context", testWorkerLocalSecpContext)
        ]
        var results: [[String: Any]] = []
        var passed = 0
        for (name, check) in checks {
            do {
                let ok = try check()
                if ok { passed += 1 }
                results.append(["name": name, "result": ok ? "passed" : "failed"])
            } catch {
                results.append(["name": name, "result": "failed", "error": error.localizedDescription])
            }
        }
        return [
            "schema": "swiftbitnode.performance_self_test.v1",
            "result": passed == checks.count ? "passed" : "failed",
            "passed": passed,
            "failed": checks.count - passed,
            "checks": results
        ]
    }

    private static func testBIP143SighashCacheMatchesUncached() throws -> Bool {
        let tx = makeTransaction(inputCount: 2, outputCount: 2)
        let prevouts = makePrevouts(count: 2)
        let cache = Sighash.Cache(tx: tx, prevouts: prevouts)
        let scriptCode = Data([0x76, 0xa9, 0x14]) + Data(repeating: 9, count: 20) + Data([0x88, 0xac])

        for sighashType in [Sighash.all, Sighash.single, Sighash.all | Sighash.anyoneCanPay] {
            let uncached = try Sighash.bip143(
                tx: tx,
                inputIndex: 1,
                scriptCode: scriptCode,
                amount: prevouts[1].amount,
                sighashType: sighashType
            )
            let cached = try Sighash.bip143(
                tx: tx,
                inputIndex: 1,
                scriptCode: scriptCode,
                amount: prevouts[1].amount,
                sighashType: sighashType,
                cache: cache
            )
            if cached != uncached { return false }
        }
        return true
    }

    private static func testTaprootSighashCacheMatchesUncached() throws -> Bool {
        let tx = makeTransaction(inputCount: 2, outputCount: 2)
        let prevouts = makePrevouts(count: 2)
        let cache = Sighash.Cache(tx: tx, prevouts: prevouts)
        let tapleaf = Sighash.tapleafHash(script: Data([0x51]), leafVersion: 0xc0)

        for sighashType in [UInt8(0x00), UInt8(0x01), UInt8(0x83)] {
            let uncachedKeyPath = try Sighash.taprootKeyPath(
                tx: tx,
                inputIndex: 1,
                prevouts: prevouts,
                sighashType: sighashType
            )
            let cachedKeyPath = try Sighash.taprootKeyPath(
                tx: tx,
                inputIndex: 1,
                prevouts: prevouts,
                sighashType: sighashType,
                cache: cache
            )
            if cachedKeyPath != uncachedKeyPath { return false }

            let uncachedScriptPath = try Sighash.taprootScriptPath(
                tx: tx,
                inputIndex: 1,
                prevouts: prevouts,
                tapleafHash: tapleaf,
                sighashType: sighashType
            )
            let cachedScriptPath = try Sighash.taprootScriptPath(
                tx: tx,
                inputIndex: 1,
                prevouts: prevouts,
                tapleafHash: tapleaf,
                sighashType: sighashType,
                cache: cache
            )
            if cachedScriptPath != uncachedScriptPath { return false }
        }
        return true
    }

    private static func testScriptJobRunnerReportsFirstFailureByJobOrder() -> Bool {
        let tx = makeTransaction(inputCount: 1, outputCount: 1)
        let prevouts = [CorpusPrevout(amount: 1_000, scriptPubKey: Data([0x51]))]
        let firstFailure = ScriptVerifyJob(
            txIndex: 1,
            inputIndex: 0,
            fixture: fixture(tx: tx, inputIndex: 0, prevScript: Data([0xff]), prevouts: prevouts),
            cache: nil
        )
        let laterFailure = ScriptVerifyJob(
            txIndex: 1,
            inputIndex: 1,
            fixture: fixture(tx: tx, inputIndex: 0, prevScript: Data([0xfe]), prevouts: prevouts),
            cache: nil
        )

        let result = ScriptJobRunner.verify([firstFailure, laterFailure])
        return result.failure?.job.txIndex == 1 && result.failure?.job.inputIndex == 0
    }

    private static func testOutpointKeyUsesFixedBinaryRocksKey() -> Bool {
        let txidInternal = Data((0..<32).map(UInt8.init))
        let key = OutpointKey(txidInternal: txidInternal, vout: 0x01020304)
        return key.display == "\(txidInternal.reversedHex):16909060"
            && key.legacyRocksKey == "utxo:\(key.display)"
            && key.rocksKey.count == 37
            && key.rocksKey.first == 0x55
            && Data(key.rocksKey.dropFirst().prefix(32)) == txidInternal
            && Array(key.rocksKey.suffix(4)) == [0x04, 0x03, 0x02, 0x01]
    }

    private static func testSameBlockSpendCompaction() -> Bool {
        let first = OutpointKey(txidInternal: Data(repeating: 1, count: 32), vout: 0)
        let second = OutpointKey(txidInternal: Data(repeating: 2, count: 32), vout: 1)
        let utxo = StoredUtxo(value: 1, scriptPubKey: Data([0x51]), height: 1, coinbase: false)
        let compacted = BlockConnector.compactCreatedForCommit([(first, utxo), (second, utxo)], spentCreated: Set([first]))
        return compacted.count == 1 && compacted.first?.0 == second
    }

    private static func testOrderedUtxoBatchFileStore() throws -> Bool {
        let dir = temporaryDirectory("swiftbitnode-ordered-utxo")
        let store = try ChainStore(datadir: dir.path, acquireLock: false)
        let first = OutpointKey(txidInternal: Data(repeating: 3, count: 32), vout: 0)
        let second = OutpointKey(txidInternal: Data(repeating: 4, count: 32), vout: 1)
        var state = StoreState()
        state.utxos[first.display] = StoredUtxo(value: 11, scriptPubKey: Data([0x51]), height: 1, coinbase: false)
        state.utxos[second.display] = StoredUtxo(value: 22, scriptPubKey: Data([0x52]), height: 2, coinbase: true)
        let loaded = try store.getUtxosOrdered([second, first], state: state)
        return loaded.values.count == 2
            && loaded.values[0]?.value == 22
            && loaded.values[1]?.value == 11
    }

    private static func testLegacyUtxoFallbackToggle() throws -> Bool {
        let key = OutpointKey(txidInternal: Data(repeating: 5, count: 32), vout: 7)
        let utxo = StoredUtxo(value: 33, scriptPubKey: Data([0x53]), height: 3, coinbase: false)
        guard let rocksStore = try? ChainStore(datadir: temporaryDirectory("swiftbitnode-legacy-on").path, acquireLock: false, legacyUtxoFallback: true),
              let rocks = rocksStore.rocks else {
            return true
        }
        try rocks.put(key: key.legacyRocksKey, value: JSONEncoder().encode(utxo))
        let fallbackOn = try rocksStore.getUtxosOrdered([key], state: StoreState())
        let fallbackOff = try ChainStore(datadir: rocksStore.datadir.path, acquireLock: false, legacyUtxoFallback: false)
            .getUtxosOrdered([key], state: StoreState())
        let onValue = fallbackOn.values.first.flatMap { $0 }?.value
        let offValue = fallbackOff.values.first.flatMap { $0 }
        return onValue == 33 && offValue == nil
    }

    private static func testWorkerLocalSecpContext() -> Bool {
        let runner = ScriptJobRunner(workerCount: 2)
        return !NativeSecp256k1.available || runner.usesWorkerLocalSecp
    }

    private static func makeTransaction(inputCount: Int, outputCount: Int) -> Transaction {
        var inputs: [TxInput] = []
        for index in 0..<inputCount {
            inputs.append(TxInput(
                previousTxidInternal: Data(repeating: UInt8(index + 1), count: 32),
                vout: UInt32(index),
                scriptSig: Data([UInt8(index)]),
                sequence: UInt32(0xffff_fffe - index)
            ))
        }
        var outputs: [TxOutput] = []
        for index in 0..<outputCount {
            outputs.append(TxOutput(
                value: Int64(1_000 + index),
                scriptPubKey: Data([0x51, UInt8(index)])
            ))
        }
        let txidInternal = Data(repeating: 0xaa, count: 32)
        let wtxidInternal = Data(repeating: 0xbb, count: 32)
        return Transaction(
            version: 2,
            inputs: inputs,
            outputs: outputs,
            witness: Array(repeating: [], count: inputCount),
            locktime: 99,
            txidInternal: txidInternal,
            wtxidInternal: wtxidInternal,
            hasWitness: false
        )
    }

    private static func makePrevouts(count: Int) -> [CorpusPrevout] {
        (0..<count).map { index in
            CorpusPrevout(
                amount: Int64(2_000 + index),
                scriptPubKey: Data([0x00, 0x20]) + Data(repeating: UInt8(index), count: 32)
            )
        }
    }

    private static func fixture(tx: Transaction, inputIndex: Int, prevScript: Data, prevouts: [CorpusPrevout]) -> CorpusFixture {
        CorpusFixture(
            fixtureID: "performance-self-test.\(inputIndex)",
            height: 0,
            blockHash: "",
            txid: tx.txid,
            inputIndex: inputIndex,
            transaction: tx,
            prevouts: prevouts,
            prevScriptPubKey: prevScript,
            loadedFiles: 0,
            fileHashes: [:]
        )
    }

    private static func temporaryDirectory(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
