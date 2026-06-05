import Foundation

struct ByteReader {
    let data: Data
    var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw SwiftBitnodeError.message("short read at offset \(offset), need \(count)")
        }
        let result = data.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    mutating func uint8() throws -> UInt8 {
        try read(1)[0]
    }

    mutating func uint16LE() throws -> UInt16 {
        let bytes = [UInt8](try read(2))
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    mutating func uint32LE() throws -> UInt32 {
        let bytes = [UInt8](try read(4))
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    mutating func int32LE() throws -> Int32 {
        Int32(bitPattern: try uint32LE())
    }

    mutating func uint64LE() throws -> UInt64 {
        let bytes = [UInt8](try read(8))
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[i]) << UInt64(i * 8)
        }
        return value
    }

    mutating func compactSize() throws -> UInt64 {
        let first = try uint8()
        if first < 0xfd { return UInt64(first) }
        if first == 0xfd { return UInt64(try uint16LE()) }
        if first == 0xfe { return UInt64(try uint32LE()) }
        return try uint64LE()
    }
}

struct TxInput {
    let previousTxidInternal: Data
    let vout: UInt32
    let scriptSig: Data
    let sequence: UInt32
    var isCoinbase: Bool {
        previousTxidInternal == Data(repeating: 0, count: 32) && vout == UInt32.max
    }
}

struct TxOutput {
    let value: Int64
    let scriptPubKey: Data
    var isSpendableCoreV1: Bool {
        scriptPubKey.first != 0x6a
    }
}

struct Transaction {
    let version: Int32
    let rawNoWitness: Data
    let rawWithWitness: Data
    let inputs: [TxInput]
    let outputs: [TxOutput]
    let witness: [[Data]]
    let locktime: UInt32
    let txid: String
    let wtxid: String
    let hasWitness: Bool
}

struct BlockInfo {
    let height: Int
    let header: Data
    let hash: String
    let previousHash: String
    let merkleRootInternal: Data
    let transactions: [Transaction]
}

enum Codec {
    static func parseBlock(_ raw: Data, height: Int) throws -> BlockInfo {
        guard raw.count >= 81 else {
            throw SwiftBitnodeError.message("short block")
        }
        var reader = ByteReader(raw)
        let header = try reader.read(80)
        let hash = SHA256.doubleHash(header).reversedHex
        let previousHash = header.subdata(in: 4..<36).reversedHex
        let merkle = header.subdata(in: 36..<68)
        let count = Int(try reader.compactSize())
        var txs: [Transaction] = []
        for _ in 0..<count {
            txs.append(try parseTransaction(&reader))
        }
        guard reader.remaining == 0 else {
            throw SwiftBitnodeError.message("block has trailing bytes: \(reader.remaining)")
        }
        try verifyMerkleRoot(txs: txs, expectedInternal: merkle)
        return BlockInfo(height: height, header: header, hash: hash, previousHash: previousHash, merkleRootInternal: merkle, transactions: txs)
    }

    static func parseTransaction(_ raw: Data) throws -> Transaction {
        var reader = ByteReader(raw)
        let tx = try parseTransaction(&reader)
        guard reader.remaining == 0 else {
            throw SwiftBitnodeError.message("transaction has trailing bytes: \(reader.remaining)")
        }
        return tx
    }

    static func parseTransaction(_ reader: inout ByteReader) throws -> Transaction {
        let txStart = reader.offset
        let versionBytes = try reader.read(4)
        var versionReader = ByteReader(versionBytes)
        let version = try versionReader.int32LE()
        var hasWitness = false
        var markerFlag = Data()
        let marker = try reader.uint8()
        if marker == 0x00 {
            let flag = try reader.uint8()
            if flag != 0x00 {
                hasWitness = true
                markerFlag = Data([marker, flag])
            } else {
                throw SwiftBitnodeError.message("invalid transaction marker/flag")
            }
        } else {
            reader.offset -= 1
        }

        let vinStart = reader.offset
        let inputCount = Int(try reader.compactSize())
        var inputs: [TxInput] = []
        for _ in 0..<inputCount {
            let prevTxid = try reader.read(32)
            let vout = try reader.uint32LE()
            let scriptLen = Int(try reader.compactSize())
            let script = try reader.read(scriptLen)
            let sequence = try reader.uint32LE()
            inputs.append(TxInput(previousTxidInternal: prevTxid, vout: vout, scriptSig: script, sequence: sequence))
        }
        let inputsAndOutputsStart = vinStart
        let outputCount = Int(try reader.compactSize())
        var outputs: [TxOutput] = []
        for _ in 0..<outputCount {
            let value = Int64(bitPattern: try reader.uint64LE())
            let scriptLen = Int(try reader.compactSize())
            let script = try reader.read(scriptLen)
            outputs.append(TxOutput(value: value, scriptPubKey: script))
        }
        let noWitnessMiddleEnd = reader.offset
        var witness: [[Data]] = Array(repeating: [], count: inputCount)
        if hasWitness {
            for inputIndex in 0..<inputCount {
                let itemCount = Int(try reader.compactSize())
                var items: [Data] = []
                for _ in 0..<itemCount {
                    let len = Int(try reader.compactSize())
                    items.append(try reader.read(len))
                }
                witness[inputIndex] = items
            }
        }
        let locktimeBytes = try reader.read(4)
        var locktimeReader = ByteReader(locktimeBytes)
        let locktime = try locktimeReader.uint32LE()
        let txEnd = reader.offset
        let noWitness = versionBytes + reader.data.subdata(in: inputsAndOutputsStart..<noWitnessMiddleEnd) + locktimeBytes
        let withWitness = versionBytes + markerFlag + reader.data.subdata(in: inputsAndOutputsStart..<txEnd)
        return Transaction(
            version: version,
            rawNoWitness: noWitness,
            rawWithWitness: reader.data.subdata(in: txStart..<txEnd),
            inputs: inputs,
            outputs: outputs,
            witness: witness,
            locktime: locktime,
            txid: SHA256.doubleHash(noWitness).reversedHex,
            wtxid: SHA256.doubleHash(withWitness).reversedHex,
            hasWitness: hasWitness
        )
    }

    private static func verifyMerkleRoot(txs: [Transaction], expectedInternal: Data) throws {
        var layer = txs.map { Data($0.txid.hexToBytes().reversed()) }
        guard !layer.isEmpty else {
            throw SwiftBitnodeError.message("block has no transactions")
        }
        while layer.count > 1 {
            if layer.count % 2 == 1 {
                layer.append(layer.last!)
            }
            var next: [Data] = []
            for index in stride(from: 0, to: layer.count, by: 2) {
                next.append(SHA256.doubleHash(layer[index] + layer[index + 1]))
            }
            layer = next
        }
        guard layer[0] == expectedInternal else {
            throw SwiftBitnodeError.message("merkle root mismatch")
        }
    }
}

extension String {
    func hexToBytes() -> [UInt8] {
        var bytes: [UInt8] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            bytes.append(UInt8(self[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
}
