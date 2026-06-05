import Foundation

enum PerformanceSelfTest {
    static func run() throws -> [String: Any] {
        let checks: [(String, () throws -> Bool)] = [
            ("bip143_cache_matches_uncached", testBIP143SighashCacheMatchesUncached),
            ("taproot_cache_matches_uncached", testTaprootSighashCacheMatchesUncached),
            ("script_runner_first_failure_order", testScriptJobRunnerReportsFirstFailureByJobOrder),
            ("binary_outpoint_key_shape", testOutpointKeyUsesFixedBinaryRocksKey)
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
}
