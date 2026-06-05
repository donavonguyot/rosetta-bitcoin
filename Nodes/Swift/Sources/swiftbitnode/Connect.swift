import Foundation
import Dispatch

struct TimingCollector {
    private var stageMicros: [String: Int64] = [:]

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
}

private struct SpendInput: Sendable {
    let inputIndex: Int
    let key: String
    let prev: StoredUtxo
}

private struct VerificationResult: Sendable {
    let passed: Bool
    let stage: String
    let type: String
    let message: String

    init(_ result: (passed: Bool, stage: String, type: String, message: String)) {
        self.passed = result.passed
        self.stage = result.stage
        self.type = result.type
        self.message = result.message
    }
}

private final class VerificationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [VerificationResult?]

    init(count: Int) {
        self.results = Array(repeating: nil, count: count)
    }

    func set(_ result: VerificationResult, at index: Int) {
        lock.lock()
        results[index] = result
        lock.unlock()
    }

    func get(_ index: Int) -> VerificationResult? {
        lock.lock()
        let result = results[index]
        lock.unlock()
        return result
    }
}

enum BlockConnector {
    static func connect(raw: Data, height: Int, store: ChainStore, timing: inout TimingCollector) throws -> Bool {
        let state = try store.load()
        return try connect(raw: raw, height: height, state: state, store: store, timing: &timing).connected
    }

    static func connect(raw: Data, height: Int, state: StoreState, store: ChainStore, timing: inout TimingCollector) throws -> (connected: Bool, state: StoreState) {
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

        let txidsInBlock = Set(block.transactions.map(\.txid))
        var externalPrevoutKeys = Set<String>()
        for tx in block.transactions.dropFirst() {
            for input in tx.inputs {
                let prevTxid = input.previousTxidInternal.reversedHex
                if !txidsInBlock.contains(prevTxid) {
                    externalPrevoutKeys.insert(outpointKey(txidInternal: input.previousTxidInternal, vout: input.vout))
                }
            }
        }
        let loaded = try timing.measure("prevout_batch_load") {
            try store.getUtxos(Array(externalPrevoutKeys), state: state)
        }

        var spent: [(String, StoredUtxo)] = []
        var spentKeysInBlock = Set<String>()
        var created: [(String, StoredUtxo)] = []
        var createdInBlock: [String: StoredUtxo] = [:]
        for (txIndex, tx) in block.transactions.enumerated() {
            if txIndex == 0 {
                addOutputs(tx: tx, height: height, coinbase: true, created: &created, createdInBlock: &createdInBlock)
                continue
            }
            var prevouts: [CorpusPrevout] = []
            for input in tx.inputs {
                let key = outpointKey(txidInternal: input.previousTxidInternal, vout: input.vout)
                guard let prev = createdInBlock[key] ?? loaded[key] else {
                    try store.setBlocker(height: height, failure: "missing UTXO \(key)", txid: tx.txid, inputIndex: prevouts.count)
                    return (false, state)
                }
                prevouts.append(CorpusPrevout(amount: prev.value, scriptPubKey: prev.scriptPubKey))
            }
            var spendInputs: [SpendInput] = []
            var inputValue: Int64 = 0
            var txInputKeys = Set<String>()
            for (inputIndex, input) in tx.inputs.enumerated() {
                let key = outpointKey(txidInternal: input.previousTxidInternal, vout: input.vout)
                guard txInputKeys.insert(key).inserted, !spentKeysInBlock.contains(key) else {
                    try store.setBlocker(height: height, failure: "duplicate input spend \(key)", txid: tx.txid, inputIndex: inputIndex)
                    return (false, state)
                }
                let prev = (createdInBlock[key] ?? loaded[key])!
                if prev.coinbase && height - prev.height < 100 {
                    try store.setBlocker(height: height, failure: "coinbase spend before maturity", txid: tx.txid, inputIndex: inputIndex)
                    return (false, state)
                }
                inputValue = try checkedAdd(inputValue, prev.value, height: height, txid: tx.txid, inputIndex: inputIndex, store: store, state: state)
                spendInputs.append(SpendInput(inputIndex: inputIndex, key: key, prev: prev))
            }
            let outputValue = try tx.outputs.enumerated().reduce(Int64(0)) { total, item in
                if item.element.value < 0 {
                    try store.setBlocker(height: height, failure: "negative transaction output value", txid: tx.txid, inputIndex: -1)
                    throw SwiftBitnodeError.message("negative transaction output value")
                }
                return try checkedAdd(total, item.element.value, height: height, txid: tx.txid, inputIndex: -1, store: store, state: state)
            }
            guard inputValue >= outputValue else {
                try store.setBlocker(height: height, failure: "transaction spends more than inputs", txid: tx.txid, inputIndex: -1)
                return (false, state)
            }

            let verifyResults = VerificationResults(count: tx.inputs.count)
            let verifyStart = DispatchTime.now().uptimeNanoseconds
            let txForVerify = tx
            let prevoutsForVerify = prevouts
            let spendInputsForVerify = spendInputs
            let verifyOne: (Int) -> Void = { inputIndex in
                let prev = spendInputsForVerify[inputIndex].prev
                verifyResults.set(VerificationResult(ScriptVerifier.verify(CorpusFixture(
                        fixtureID: "live.\(height).\(tx.txid).\(inputIndex)",
                        height: height,
                        blockHash: block.hash,
                        txid: tx.txid,
                        inputIndex: inputIndex,
                        transaction: txForVerify,
                        prevouts: prevoutsForVerify,
                        prevScriptPubKey: prev.scriptPubKey,
                        loadedFiles: 0,
                        fileHashes: [:]
                    )
                )), at: inputIndex)
            }
            if tx.inputs.count >= 2 {
                DispatchQueue.concurrentPerform(iterations: tx.inputs.count) { inputIndex in
                    let prev = spendInputsForVerify[inputIndex].prev
                    let result = VerificationResult(ScriptVerifier.verify(CorpusFixture(
                        fixtureID: "live.\(height).\(tx.txid).\(inputIndex)",
                        height: height,
                        blockHash: block.hash,
                        txid: tx.txid,
                        inputIndex: inputIndex,
                        transaction: txForVerify,
                        prevouts: prevoutsForVerify,
                        prevScriptPubKey: prev.scriptPubKey,
                        loadedFiles: 0,
                        fileHashes: [:]
                    )))
                    verifyResults.set(result, at: inputIndex)
                }
            } else {
                for inputIndex in tx.inputs.indices {
                    verifyOne(inputIndex)
                }
            }
            timing.addElapsed("script_verify", since: verifyStart)

            for input in spendInputs {
                guard let result = verifyResults.get(input.inputIndex) else {
                    try store.setBlocker(height: height, failure: "internal:missing_verify_result", txid: tx.txid, inputIndex: input.inputIndex)
                    return (false, state)
                }
                guard result.passed else {
                    try store.setBlocker(height: height, failure: "\(result.stage):\(result.type): \(result.message)", txid: tx.txid, inputIndex: input.inputIndex)
                    return (false, state)
                }
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

        let newState = try timing.measure("commit") {
            try store.commitConnectedBlock(state: state, raw: raw, height: height, hash: block.hash, created: created, spent: spent)
        }
        return (true, newState)
    }

    private static func addOutputs(tx: Transaction, height: Int, coinbase: Bool, created: inout [(String, StoredUtxo)], createdInBlock: inout [String: StoredUtxo]) {
        if height == 0, coinbase {
            return
        }
        for (index, output) in tx.outputs.enumerated() where output.isSpendableCoreV1 {
            let key = "\(tx.txid):\(index)"
            let utxo = StoredUtxo(value: output.value, scriptPubKey: output.scriptPubKey, height: height, coinbase: coinbase)
            created.append((key, utxo))
            createdInBlock[key] = utxo
        }
    }

    private static func outpointKey(txidInternal: Data, vout: UInt32) -> String {
        "\(txidInternal.reversedHex):\(vout)"
    }

    private static func checkedAdd(_ left: Int64, _ right: Int64, height: Int, txid: String, inputIndex: Int, store: ChainStore, state: StoreState) throws -> Int64 {
        guard right <= Int64.max - left else {
            try store.setBlocker(height: height, failure: "transaction value overflow", txid: txid, inputIndex: inputIndex)
            throw SwiftBitnodeError.message("transaction value overflow")
        }
        return left + right
    }
}
