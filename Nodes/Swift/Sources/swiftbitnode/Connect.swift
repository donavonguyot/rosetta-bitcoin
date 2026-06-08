import Foundation
import Dispatch

struct TimingCollector {
    private var stageMicros: [String: Int64] = [:]
    private var slowBlocks: [SlowBlockTiming] = []

    mutating func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try body()
        addElapsed(name, since: start)
        return result
    }

    mutating func addElapsed(_ name: String, since startNanos: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startNanos
        stageMicros[name, default: 0] += Int64(elapsed / 1_000)
    }

    mutating func addMicros(_ name: String, _ micros: Int64) {
        stageMicros[name, default: 0] += micros
    }

    func stageTotalsMs(required: [String] = []) -> [String: Int] {
        var out = stageMicros.mapValues { Int(($0 + 999) / 1_000) }
        if out["utxo_load"] == nil, let prevout = out["prevout_batch_load"] {
            out["utxo_load"] = prevout
        }
        if out["script_wall_ms"] == nil, let script = out["script_verify"] {
            out["script_wall_ms"] = script
        }
        if out["script_worker_cpu_ms"] == nil, let worker = out["script_verify_worker_cpu"] {
            out["script_worker_cpu_ms"] = worker
        }
        for name in required {
            out[name, default: 0] += 0
        }
        return out
    }

    func totalMs(_ name: String) -> Int {
        Int(((stageMicros[name] ?? 0) + 999) / 1_000)
    }

    mutating func recordSlowBlock(_ block: SlowBlockTiming) {
        slowBlocks.append(block)
        slowBlocks.sort { $0.blockConnectStoreCommitMs > $1.blockConnectStoreCommitMs }
        if slowBlocks.count > 10 {
            slowBlocks.removeLast(slowBlocks.count - 10)
        }
    }

    func slowBlocksJson() -> [[String: Any]] {
        slowBlocks.enumerated().map { index, block in
            [
                "rank": index + 1,
                "height": block.height,
                "block_connect_store_commit_ms": block.blockConnectStoreCommitMs,
                "commit_ms": block.commitMs,
                "utxo_load_ms": block.utxoLoadMs,
                "script_verify_ms": block.scriptVerifyMs,
                "script_verify_worker_cpu_ms": block.scriptVerifyWorkerCpuMs,
                "same_block_spends": block.sameBlockSpends,
                "created_utxos": block.createdUtxos,
                "spent_external": block.spentExternal,
                "tx_count": block.txCount,
                "vin_count": block.vinCount,
                "vout_count": block.voutCount,
                "script_input_count": block.scriptInputCount,
                "input_shape_counts": block.inputShapeCounts,
                "spent_prevout_script_types": block.spentPrevoutScriptTypes,
                "output_script_types": block.outputScriptTypes
            ]
        }
    }
}

struct SlowBlockTiming: Sendable {
    let height: Int
    let blockConnectStoreCommitMs: Int
    let commitMs: Int
    let utxoLoadMs: Int
    let scriptVerifyMs: Int
    let scriptVerifyWorkerCpuMs: Int
    let sameBlockSpends: Int
    let createdUtxos: Int
    let spentExternal: Int
    let txCount: Int
    let vinCount: Int
    let voutCount: Int
    let scriptInputCount: Int
    let inputShapeCounts: [String: Int]
    let spentPrevoutScriptTypes: [String: Int]
    let outputScriptTypes: [String: Int]
}

private struct SpendInput: Sendable {
    let inputIndex: Int
    let key: OutpointKey
    let prev: StoredUtxo
}

/// Block-local UTXO view, script verification, then atomic chainstate commit. Missing rules become validation blockers.
enum BlockConnector {
    static func connect(raw: Data, height: Int, store: ChainStore, timing: inout TimingCollector) throws -> Bool {
        let state = try store.load()
        return try connect(raw: raw, height: height, state: state, store: store, timing: &timing).connected
    }

    static func connect(
        raw: Data,
        height: Int,
        state: StoreState,
        store: ChainStore,
        timing: inout TimingCollector,
        scriptRunner: ScriptJobRunner? = nil
    ) throws -> (connected: Bool, state: StoreState) {
        let connectStarted = DispatchTime.now().uptimeNanoseconds
        let block = try timing.measure("block_parse_validate") {
            try Codec.parseBlock(raw, height: height)
        }
        if height > 0, block.previousHash != state.validatedHash {
            try store.setBlocker(height: height, failure: "previous block hash mismatch")
            return (false, state)
        }
        if block.transactions.isEmpty || !block.transactions[0].inputs.allSatisfy(\.isCoinbase) {
            try store.setBlocker(height: height, failure: "missing coinbase transaction")
            return (false, state)
        }

        let txidsInBlock = Set(block.transactions.map(\.txidInternal))
        var externalPrevoutSet = Set<OutpointKey>()
        var externalPrevoutKeys: [OutpointKey] = []
        var expectedSpends = 0
        var expectedCreates = 0
        var expectedScriptJobs = 0
        for tx in block.transactions {
            expectedCreates += tx.outputs.filter(\.isSpendableCoreV1).count
        }
        for tx in block.transactions.dropFirst() {
            expectedSpends += tx.inputs.count
            expectedScriptJobs += tx.inputs.count
            for input in tx.inputs {
                if !txidsInBlock.contains(input.previousTxidInternal) {
                    let key = outpointKey(txidInternal: input.previousTxidInternal, vout: input.vout)
                    if externalPrevoutSet.insert(key).inserted {
                        externalPrevoutKeys.append(key)
                    }
                }
            }
        }
        let utxoLoadStarted = DispatchTime.now().uptimeNanoseconds
        let orderedLoaded = try store.getUtxosOrdered(externalPrevoutKeys, state: state)
        let utxoLoadMicros = Int64((DispatchTime.now().uptimeNanoseconds - utxoLoadStarted) / 1_000)
        timing.addMicros("prevout_batch_load", utxoLoadMicros)
        timing.addMicros("utxo_load", utxoLoadMicros)
        timing.addMicros("prevout_multi_get_call", orderedLoaded.timing.prevoutMultiGetCallMicros)
        timing.addMicros("prevout_legacy_fallback_get", orderedLoaded.timing.prevoutLegacyFallbackGetMicros)
        timing.addMicros("prevout_utxo_decode", orderedLoaded.timing.prevoutUtxoDecodeMicros)
        var loaded: [OutpointKey: StoredUtxo] = [:]
        loaded.reserveCapacity(externalPrevoutKeys.count)
        for index in externalPrevoutKeys.indices {
            if let utxo = orderedLoaded.values[index] {
                loaded[externalPrevoutKeys[index]] = utxo
            }
        }

        var externalSpends: [(OutpointKey, StoredUtxo)] = []
        externalSpends.reserveCapacity(externalPrevoutKeys.count)
        var spentInBlock = Set<OutpointKey>()
        spentInBlock.reserveCapacity(expectedSpends)
        var createdList: [(OutpointKey, StoredUtxo)] = []
        createdList.reserveCapacity(expectedCreates)
        var createdLookup: [OutpointKey: StoredUtxo] = [:]
        createdLookup.reserveCapacity(expectedCreates)
        var createdSpent = Set<OutpointKey>()
        createdSpent.reserveCapacity(expectedSpends)
        var scriptJobs: [ScriptVerifyJob] = []
        scriptJobs.reserveCapacity(expectedScriptJobs)
        var vinCount = 0
        var voutCount = 0
        var scriptInputCount = 0
        var inputShapeCounts: [String: Int] = [:]
        var spentPrevoutScriptTypes: [String: Int] = [:]
        var outputScriptTypes: [String: Int] = [:]
        for (txIndex, tx) in block.transactions.enumerated() {
            let coinbase = txIndex == 0
            vinCount += tx.inputs.count
            voutCount += tx.outputs.count
            for inputIndex in tx.inputs.indices {
                inputShapeCounts[inputShape(tx: tx, inputIndex: inputIndex, coinbase: coinbase), default: 0] += 1
            }
            for output in tx.outputs {
                outputScriptTypes[scriptType(output.scriptPubKey), default: 0] += 1
            }
            if txIndex == 0 {
                addOutputs(tx: tx, height: height, coinbase: true, created: &createdList, createdLookup: &createdLookup)
                continue
            }
            scriptInputCount += tx.inputs.count
            var prevouts: [CorpusPrevout] = []
            for input in tx.inputs {
                let key = outpointKey(txidInternal: input.previousTxidInternal, vout: input.vout)
                guard let prev = createdLookup[key] ?? loaded[key] else {
                    try store.setBlocker(height: height, failure: "missing UTXO \(key.display)", txid: tx.txid, inputIndex: prevouts.count)
                    return (false, state)
                }
                spentPrevoutScriptTypes[scriptType(prev.scriptPubKey), default: 0] += 1
                prevouts.append(CorpusPrevout(amount: prev.value, scriptPubKey: prev.scriptPubKey))
            }
            var spendInputs: [SpendInput] = []
            var inputValue: Int64 = 0
            var txInputKeys = Set<OutpointKey>()
            for (inputIndex, input) in tx.inputs.enumerated() {
                let key = outpointKey(txidInternal: input.previousTxidInternal, vout: input.vout)
                guard txInputKeys.insert(key).inserted, !spentInBlock.contains(key) else {
                    try store.setBlocker(height: height, failure: "duplicate input spend \(key.display)", txid: tx.txid, inputIndex: inputIndex)
                    return (false, state)
                }
                let prev = (createdLookup[key] ?? loaded[key])!
                if prev.coinbase && height - prev.height < 100 {
                    try store.setBlocker(height: height, failure: "coinbase spend before maturity", txid: tx.txid, inputIndex: inputIndex)
                    return (false, state)
                }
                inputValue = try checkedAdd(inputValue, prev.value, height: height, tx: tx, inputIndex: inputIndex, store: store, state: state)
                spendInputs.append(SpendInput(inputIndex: inputIndex, key: key, prev: prev))
            }
            var outputValue: Int64 = 0
            for (outputIndex, output) in tx.outputs.enumerated() {
                if output.value < 0 {
                    try store.setBlocker(height: height, failure: "negative transaction output value", txid: tx.txid, inputIndex: -1)
                    throw SwiftBitnodeError.message("negative transaction output value")
                }
                outputValue = try checkedAdd(outputValue, output.value, height: height, tx: tx, inputIndex: outputIndex, store: store, state: state)
            }
            guard inputValue >= outputValue else {
                try store.setBlocker(height: height, failure: "transaction spends more than inputs", txid: tx.txid, inputIndex: -1)
                return (false, state)
            }

            let cache = Sighash.Cache(tx: tx, prevouts: prevouts)
            for input in spendInputs {
                let inputIndex = input.inputIndex
                let prev = input.prev
                scriptJobs.append(ScriptVerifyJob(
                    txIndex: txIndex,
                    inputIndex: inputIndex,
                    fixture: CorpusFixture(
                        fixtureID: "live.\(height).\(txIndex).\(inputIndex)",
                        height: height,
                        blockHash: block.hash,
                        txid: "",
                        inputIndex: inputIndex,
                        transaction: tx,
                        prevouts: prevouts,
                        prevScriptPubKey: prev.scriptPubKey,
                        loadedFiles: 0,
                        fileHashes: [:]
                    ),
                    cache: cache
                ))
            }

            for input in spendInputs {
                let key = input.key
                let prev = input.prev
                if createdLookup[key] != nil {
                    createdSpent.insert(key)
                } else {
                    externalSpends.append((key, prev))
                }
                spentInBlock.insert(key)
            }
            addOutputs(tx: tx, height: height, coinbase: false, created: &createdList, createdLookup: &createdLookup)
        }

        let verifyStart = DispatchTime.now().uptimeNanoseconds
        let runner = scriptRunner ?? ScriptJobRunner()
        let scriptResult = runner.verify(scriptJobs)
        let scriptVerifyMicros = Int64((DispatchTime.now().uptimeNanoseconds - verifyStart) / 1_000)
        timing.addMicros("script_verify", scriptVerifyMicros)
        timing.addMicros("script_wall_ms", scriptVerifyMicros)
        timing.addMicros("script_verify_worker_cpu", scriptResult.workerMicros)
        timing.addMicros("script_worker_cpu_ms", scriptResult.workerMicros)
        timing.addMicros("script_runner_wait", scriptResult.waitMicros)
        if let failure = scriptResult.failure {
            let result = failure.result
            try store.setBlocker(
                height: height,
                failure: "\(result.stage):\(result.type): \(result.message)",
                txid: failure.job.fixture.txid.isEmpty ? failure.job.fixture.transaction.txid : failure.job.fixture.txid,
                inputIndex: failure.job.inputIndex
            )
            return (false, state)
        }

        let retainedCreated = compactCreatedForCommit(createdList, spentCreated: createdSpent)
        let commitStart = DispatchTime.now().uptimeNanoseconds
        let commit = try store.commitConnectedBlock(state: state, raw: raw, height: height, hash: block.hash, created: retainedCreated, spent: externalSpends)
        let commitMicros = Int64((DispatchTime.now().uptimeNanoseconds - commitStart) / 1_000)
        timing.addMicros("commit", commitMicros)
        timing.addMicros("utxo_apply", commitMicros)
        timing.addMicros("utxo_delete_prepare", commit.timing.utxoDeletePrepareMicros)
        timing.addMicros("utxo_put_prepare", commit.timing.utxoPutPrepareMicros)
        timing.addMicros("undo_put_prepare", commit.timing.undoPutPrepareMicros)
        timing.addMicros("metadata_put_prepare", commit.timing.metadataPutPrepareMicros)
        timing.addMicros("rocksdb_write", commit.timing.rocksdbWriteMicros)
        timing.recordSlowBlock(SlowBlockTiming(
            height: height,
            blockConnectStoreCommitMs: Int((DispatchTime.now().uptimeNanoseconds - connectStarted) / 1_000_000),
            commitMs: Int((commitMicros + 999) / 1_000),
            utxoLoadMs: Int((utxoLoadMicros + 999) / 1_000),
            scriptVerifyMs: Int((scriptVerifyMicros + 999) / 1_000),
            scriptVerifyWorkerCpuMs: Int((scriptResult.workerMicros + 999) / 1_000),
            sameBlockSpends: createdSpent.count,
            createdUtxos: retainedCreated.count,
            spentExternal: externalSpends.count,
            txCount: block.transactions.count,
            vinCount: vinCount,
            voutCount: voutCount,
            scriptInputCount: scriptInputCount,
            inputShapeCounts: inputShapeCounts,
            spentPrevoutScriptTypes: spentPrevoutScriptTypes,
            outputScriptTypes: outputScriptTypes
        ))
        return (true, commit.state)
    }

    private static func addOutputs(tx: Transaction, height: Int, coinbase: Bool, created: inout [(OutpointKey, StoredUtxo)], createdLookup: inout [OutpointKey: StoredUtxo]) {
        if height == 0, coinbase {
            return
        }
        for (index, output) in tx.outputs.enumerated() where output.isSpendableCoreV1 {
            let key = OutpointKey(txidInternal: tx.txidInternal, vout: UInt32(index))
            let utxo = StoredUtxo(value: output.value, scriptPubKey: output.scriptPubKey, height: height, coinbase: coinbase)
            created.append((key, utxo))
            createdLookup[key] = utxo
        }
    }

    static func compactCreatedForCommit(_ created: [(OutpointKey, StoredUtxo)], spentCreated: Set<OutpointKey>) -> [(OutpointKey, StoredUtxo)] {
        guard !spentCreated.isEmpty else {
            return created
        }
        return created.filter { !spentCreated.contains($0.0) }
    }

    private static func outpointKey(txidInternal: Data, vout: UInt32) -> OutpointKey {
        OutpointKey(txidInternal: txidInternal, vout: vout)
    }

    private static func inputShape(tx: Transaction, inputIndex: Int, coinbase: Bool) -> String {
        if coinbase {
            return "coinbase"
        }
        if inputIndex < tx.witness.count, !tx.witness[inputIndex].isEmpty {
            return "witness"
        }
        if !tx.inputs[inputIndex].scriptSig.isEmpty {
            return "legacy_scriptsig"
        }
        return "empty_scriptsig"
    }

    private static func scriptType(_ script: Data) -> String {
        if script.isEmpty { return "empty" }
        if script.first == 0x6a { return "op_return" }
        let b = [UInt8](script)
        if b.count == 25, b[0] == 0x76, b[1] == 0xa9, b[2] == 0x14, b[23] == 0x88, b[24] == 0xac {
            return "p2pkh"
        }
        if b.count == 23, b[0] == 0xa9, b[1] == 0x14, b[22] == 0x87 {
            return "p2sh"
        }
        if b.count == 22, b[0] == 0x00, b[1] == 0x14 {
            return "p2wpkh"
        }
        if b.count == 34, b[0] == 0x00, b[1] == 0x20 {
            return "p2wsh"
        }
        if b.count == 34, b[0] == 0x51, b[1] == 0x20 {
            return "p2tr"
        }
        return "other"
    }

    private static func checkedAdd(_ left: Int64, _ right: Int64, height: Int, tx: Transaction, inputIndex: Int, store: ChainStore, state: StoreState) throws -> Int64 {
        guard right <= Int64.max - left else {
            try store.setBlocker(height: height, failure: "transaction value overflow", txid: tx.txid, inputIndex: inputIndex)
            throw SwiftBitnodeError.message("transaction value overflow")
        }
        return left + right
    }
}
