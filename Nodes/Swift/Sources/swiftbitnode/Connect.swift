import Foundation

struct TimingCollector {
    var stages: [String: Int] = [:]

    mutating func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try body()
        let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
        stages[name, default: 0] += ms
        return result
    }
}

enum BlockConnector {
    static func connect(raw: Data, height: Int, store: ChainStore, timing: inout TimingCollector) throws -> Bool {
        let state = try store.load()
        let block = try timing.measure("block_parse_validate") {
            try Codec.parseBlock(raw, height: height)
        }
        if height > 0, block.previousHash != state.validatedHash {
            try store.setBlocker(height: height, failure: "previous block hash mismatch")
            return false
        }
        if block.transactions.isEmpty || !block.transactions[0].inputs.allSatisfy(\.isCoinbase) {
            try store.setBlocker(height: height, failure: "missing coinbase transaction")
            return false
        }

        var spent: [(String, StoredUtxo)] = []
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
                guard let prev = try timing.measure("utxo_load", { try createdInBlock[key] ?? store.getUtxo(key, state: state) }) else {
                    try store.setBlocker(height: height, failure: "missing UTXO \(key)", txid: tx.txid, inputIndex: prevouts.count)
                    return false
                }
                prevouts.append(CorpusPrevout(amount: prev.value, scriptPubKey: Data(prev.scriptPubKeyHex.hexToBytes())))
            }
            for (inputIndex, input) in tx.inputs.enumerated() {
                let key = outpointKey(txidInternal: input.previousTxidInternal, vout: input.vout)
                let prev = try timing.measure("utxo_load", { try createdInBlock[key] ?? store.getUtxo(key, state: state) })!
                if prev.coinbase && height - prev.height < 100 {
                    try store.setBlocker(height: height, failure: "coinbase spend before maturity", txid: tx.txid, inputIndex: inputIndex)
                    return false
                }
                let result = timing.measure("script_verify") {
                    ScriptVerifier.verify(CorpusFixture(
                        fixtureID: "live.\(height).\(tx.txid).\(inputIndex)",
                        height: height,
                        blockHash: block.hash,
                        txid: tx.txid,
                        inputIndex: inputIndex,
                        transaction: tx,
                        prevouts: prevouts,
                        prevScriptPubKey: Data(prev.scriptPubKeyHex.hexToBytes()),
                        loadedFiles: 0,
                        fileHashes: [:]
                    ))
                }
                guard result.passed else {
                    try store.setBlocker(height: height, failure: "\(result.stage):\(result.type): \(result.message)", txid: tx.txid, inputIndex: inputIndex)
                    return false
                }
                if createdInBlock.removeValue(forKey: key) != nil {
                    created.removeAll { $0.0 == key }
                } else {
                    spent.append((key, prev))
                }
            }
            addOutputs(tx: tx, height: height, coinbase: false, created: &created, createdInBlock: &createdInBlock)
        }

        try timing.measure("commit") {
            try store.commitConnectedBlock(state: state, raw: raw, height: height, hash: block.hash, created: created, spent: spent)
        }
        return true
    }

    private static func addOutputs(tx: Transaction, height: Int, coinbase: Bool, created: inout [(String, StoredUtxo)], createdInBlock: inout [String: StoredUtxo]) {
        if height == 0, coinbase {
            return
        }
        for (index, output) in tx.outputs.enumerated() where output.isSpendableCoreV1 {
            let key = "\(tx.txid):\(index)"
            let utxo = StoredUtxo(value: output.value, scriptPubKeyHex: output.scriptPubKey.hex, height: height, coinbase: coinbase)
            created.append((key, utxo))
            createdInBlock[key] = utxo
        }
    }

    private static func outpointKey(txidInternal: Data, vout: UInt32) -> String {
        "\(txidInternal.reversedHex):\(vout)"
    }
}
