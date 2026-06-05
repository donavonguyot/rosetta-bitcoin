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
        var state = try store.load()
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

        let spent: [String] = []
        var created: [(String, StoredUtxo)] = []
        for (txIndex, tx) in block.transactions.enumerated() {
            if txIndex == 0 {
                addOutputs(tx: tx, height: height, coinbase: true, created: &created)
                continue
            }
            for (inputIndex, input) in tx.inputs.enumerated() {
                let key = outpointKey(txidInternal: input.previousTxidInternal, vout: input.vout)
                guard let prev = state.utxos[key] else {
                    try store.setBlocker(height: height, failure: "missing UTXO \(key)", txid: tx.txid, inputIndex: inputIndex)
                    return false
                }
                if prev.coinbase && height - prev.height < 100 {
                    try store.setBlocker(height: height, failure: "coinbase spend before maturity", txid: tx.txid, inputIndex: inputIndex)
                    return false
                }
                try store.setBlocker(height: height, failure: "script verification not implemented", txid: tx.txid, inputIndex: inputIndex)
                return false
            }
            addOutputs(tx: tx, height: height, coinbase: false, created: &created)
        }

        timing.measure("utxo_apply") {
            for key in spent {
                state.utxos.removeValue(forKey: key)
            }
            for (key, utxo) in created {
                state.utxos[key] = utxo
            }
        }
        try timing.measure("commit") {
            state.validatedHeight = height
            state.validatedHash = block.hash
            state.headerHeight = height
            state.headerHash = block.hash
            state.storedBlockHeight = max(state.storedBlockHeight, height)
            state.storedBlockHash = block.hash
            state.chainstateUtxoCount = state.utxos.count
            state.syncStatus = "blocks_current"
            state.chainstateStatus = store.backendName == "rocksdb" ? "usable" : "diagnostic_file_store"
            state.currentBlocker = nil
            state.lastError = ""
            try store.save(state)
        }
        return true
    }

    private static func addOutputs(tx: Transaction, height: Int, coinbase: Bool, created: inout [(String, StoredUtxo)]) {
        if height == 0, coinbase {
            return
        }
        for (index, output) in tx.outputs.enumerated() where output.isSpendableCoreV1 {
            let key = "\(tx.txid):\(index)"
            created.append((key, StoredUtxo(value: output.value, scriptPubKeyHex: output.scriptPubKey.hex, height: height, coinbase: coinbase)))
        }
    }

    private static func outpointKey(txidInternal: Data, vout: UInt32) -> String {
        "\(txidInternal.reversedHex):\(vout)"
    }
}
