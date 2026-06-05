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

enum BlockConnector {
    static func connect(raw: Data, height: Int, store: ChainStore, timing: inout TimingCollector) throws -> Bool {
        let state = try store.load()
        return try connect(raw: raw, height: height, state: state, store: store, timing: &timing).connected
    }

    static func connect(raw: Data, height: Int, state: StoreState, store: ChainStore, timing: inout TimingCollector) throws -> (connected: Bool, state: StoreState) {
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
        var externalPrevoutKeys = Set<OutpointKey>()
        for tx in block.transactions.dropFirst() {
            for input in tx.inputs {
                if !txidsInBlock.contains(input.previousTxidInternal) {
                    externalPrevoutKeys.insert(outpointKey(txidInternal: input.previousTxidInternal, vout: input.vout))
                }
            }
        }
        let loaded = try timing.measure("prevout_batch_load") {
            try store.getUtxos(Array(externalPrevoutKeys), state: state)
        }

        var spent: [(OutpointKey, StoredUtxo)] = []
        var spentKeysInBlock = Set<OutpointKey>()
        var created: [(OutpointKey, StoredUtxo)] = []
        var createdInBlock: [OutpointKey: StoredUtxo] = [:]
        var scriptJobs: [ScriptVerifyJob] = []
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
                addOutputs(tx: tx, height: height, coinbase: true, created: &created, createdInBlock: &createdInBlock)
                continue
            }
            scriptInputCount += tx.inputs.count
            var prevouts: [CorpusPrevout] = []
            for input in tx.inputs {
                let key = outpointKey(txidInternal: input.previousTxidInternal, vout: input.vout)
                guard let prev = createdInBlock[key] ?? loaded[key] else {
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
                guard txInputKeys.insert(key).inserted, !spentKeysInBlock.contains(key) else {
                    try store.setBlocker(height: height, failure: "duplicate input spend \(key.display)", txid: tx.txid, inputIndex: inputIndex)
                    return (false, state)
                }
                let prev = (createdInBlock[key] ?? loaded[key])!
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
                if createdInBlock.removeValue(forKey: key) != nil {
                    created.removeAll { $0.0 == key }
                } else {
                    spent.append((key, prev))
                }
                spentKeysInBlock.insert(key)
            }
            addOutputs(tx: tx, height: height, coinbase: false, created: &created, createdInBlock: &createdInBlock)
        }

        let verifyStart = DispatchTime.now().uptimeNanoseconds
        let scriptResult = ScriptJobRunner.verify(scriptJobs)
        timing.addElapsed("script_verify", since: verifyStart)
        timing.addMicros("script_verify_worker_cpu", scriptResult.workerMicros)
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

        let newState = try timing.measure("commit") {
            try store.commitConnectedBlock(state: state, raw: raw, height: height, hash: block.hash, created: created, spent: spent)
        }
        timing.recordSlowBlock(SlowBlockTiming(
            height: height,
            blockConnectStoreCommitMs: Int((DispatchTime.now().uptimeNanoseconds - connectStarted) / 1_000_000),
            txCount: block.transactions.count,
            vinCount: vinCount,
            voutCount: voutCount,
            scriptInputCount: scriptInputCount,
            inputShapeCounts: inputShapeCounts,
            spentPrevoutScriptTypes: spentPrevoutScriptTypes,
            outputScriptTypes: outputScriptTypes
        ))
        return (true, newState)
    }

    private static func addOutputs(tx: Transaction, height: Int, coinbase: Bool, created: inout [(OutpointKey, StoredUtxo)], createdInBlock: inout [OutpointKey: StoredUtxo]) {
        if height == 0, coinbase {
            return
        }
        for (index, output) in tx.outputs.enumerated() where output.isSpendableCoreV1 {
            let key = OutpointKey(txidInternal: tx.txidInternal, vout: UInt32(index))
            let utxo = StoredUtxo(value: output.value, scriptPubKey: output.scriptPubKey, height: height, coinbase: coinbase)
            created.append((key, utxo))
            createdInBlock[key] = utxo
        }
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
