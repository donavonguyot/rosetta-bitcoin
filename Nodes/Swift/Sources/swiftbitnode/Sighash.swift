import Foundation

/// Legacy, BIP143, and Taproot sighash builders; consensus byte-shape must match Shared script fixtures.
enum Sighash {
    static let all: UInt32 = 0x01
    static let none: UInt32 = 0x02
    static let single: UInt32 = 0x03
    static let anyoneCanPay: UInt32 = 0x80
    private static let zeroHash = Data(repeating: 0, count: 32)

    final class Cache: @unchecked Sendable {
        let bip143HashPrevouts: Data
        let bip143HashSequence: Data
        let bip143HashOutputs: Data
        let bip143HashSingle: [Data]
        let taprootHashPrevouts: Data
        let taprootHashAmounts: Data
        let taprootHashScriptPubKeys: Data
        let taprootHashSequences: Data
        let taprootHashOutputs: Data
        let taprootHashSingle: [Data]

        init(tx: Transaction, prevouts: [CorpusPrevout]) {
            var prevoutBytes = Data()
            prevoutBytes.reserveCapacity(tx.inputs.count * 36)
            var sequenceBytes = Data()
            sequenceBytes.reserveCapacity(tx.inputs.count * 4)
            for input in tx.inputs {
                prevoutBytes.append(input.previousTxidInternal)
                prevoutBytes.append(input.vout.littleEndianData)
                sequenceBytes.append(input.sequence.littleEndianData)
            }

            var outputBytes = Data()
            var bip143Singles: [Data] = []
            var taprootSingles: [Data] = []
            bip143Singles.reserveCapacity(tx.outputs.count)
            taprootSingles.reserveCapacity(tx.outputs.count)
            for output in tx.outputs {
                let serialized = Sighash.serializeOutput(output)
                outputBytes.append(serialized)
                bip143Singles.append(SHA256.doubleHash(serialized))
                taprootSingles.append(SHA256.hash(serialized))
            }

            var amountBytes = Data()
            amountBytes.reserveCapacity(prevouts.count * 8)
            var scriptPubKeyBytes = Data()
            for prevout in prevouts {
                amountBytes.append(UInt64(bitPattern: prevout.amount).littleEndianData)
                Sighash.appendCompactSize(&scriptPubKeyBytes, UInt64(prevout.scriptPubKey.count))
                scriptPubKeyBytes.append(prevout.scriptPubKey)
            }

            self.bip143HashPrevouts = SHA256.doubleHash(prevoutBytes)
            self.bip143HashSequence = SHA256.doubleHash(sequenceBytes)
            self.bip143HashOutputs = SHA256.doubleHash(outputBytes)
            self.bip143HashSingle = bip143Singles
            self.taprootHashPrevouts = SHA256.hash(prevoutBytes)
            self.taprootHashAmounts = SHA256.hash(amountBytes)
            self.taprootHashScriptPubKeys = SHA256.hash(scriptPubKeyBytes)
            self.taprootHashSequences = SHA256.hash(sequenceBytes)
            self.taprootHashOutputs = SHA256.hash(outputBytes)
            self.taprootHashSingle = taprootSingles
        }

        func bip143SingleOutput(_ index: Int) -> Data {
            guard index >= 0, index < bip143HashSingle.count else { return Sighash.zeroHash }
            return bip143HashSingle[index]
        }

        func taprootSingleOutput(_ index: Int) -> Data {
            guard index >= 0, index < taprootHashSingle.count else { return Sighash.zeroHash }
            return taprootHashSingle[index]
        }
    }

    static func bip143(
        tx: Transaction,
        inputIndex: Int,
        scriptCode: Data,
        amount: Int64,
        sighashType: UInt32,
        cache: Cache? = nil
    ) throws -> Data {
        guard inputIndex >= 0, inputIndex < tx.inputs.count else {
            throw SwiftBitnodeError.message("input index out of range")
        }
        let baseType = sighashType & 0x1f
        let anyone = (sighashType & anyoneCanPay) != 0
        let hashPrevouts: Data
        if anyone {
            hashPrevouts = zeroHash
        } else if let cache {
            hashPrevouts = cache.bip143HashPrevouts
        } else {
            hashPrevouts = SHA256.doubleHash(tx.inputs.reduce(into: Data()) { out, input in
                out.append(input.previousTxidInternal)
                out.append(input.vout.littleEndianData)
            })
        }
        let hashSequence: Data
        if anyone || baseType == single || baseType == none {
            hashSequence = zeroHash
        } else if let cache {
            hashSequence = cache.bip143HashSequence
        } else {
            hashSequence = SHA256.doubleHash(tx.inputs.reduce(into: Data()) { out, input in
                out.append(input.sequence.littleEndianData)
            })
        }
        let hashOutputs: Data
        if baseType == all {
            hashOutputs = cache?.bip143HashOutputs ?? SHA256.doubleHash(tx.outputs.reduce(into: Data()) { out, output in
                out.append(serializeOutput(output))
            })
        } else if baseType == single && inputIndex < tx.outputs.count {
            hashOutputs = cache?.bip143SingleOutput(inputIndex) ?? SHA256.doubleHash(serializeOutput(tx.outputs[inputIndex]))
        } else {
            hashOutputs = zeroHash
        }
        let input = tx.inputs[inputIndex]
        var preimage = Data()
        preimage.append(UInt32(bitPattern: tx.version).littleEndianData)
        preimage.append(hashPrevouts)
        preimage.append(hashSequence)
        preimage.append(input.previousTxidInternal)
        preimage.append(input.vout.littleEndianData)
        appendCompactSize(&preimage, UInt64(scriptCode.count))
        preimage.append(scriptCode)
        preimage.append(UInt64(bitPattern: amount).littleEndianData)
        preimage.append(input.sequence.littleEndianData)
        preimage.append(hashOutputs)
        preimage.append(tx.locktime.littleEndianData)
        preimage.append(sighashType.littleEndianData)
        return SHA256.doubleHash(preimage)
    }

    static func p2wpkhScriptCode(program20: Data) -> Data {
        Data([0x76, 0xa9, 0x14]) + program20 + Data([0x88, 0xac])
    }

    static func legacy(tx: Transaction, inputIndex: Int, scriptCode: Data, sighashType: UInt32, signature: Data? = nil) throws -> Data {
        guard inputIndex >= 0, inputIndex < tx.inputs.count else {
            throw SwiftBitnodeError.message("input index out of range")
        }
        let baseType = sighashType & 0x1f
        if baseType == single && inputIndex >= tx.outputs.count {
            return Data([0x01] + Array(repeating: 0x00, count: 31))
        }
        let anyone = (sighashType & anyoneCanPay) != 0
        var preimage = Data()
        preimage.append(UInt32(bitPattern: tx.version).littleEndianData)

        let inputIndices = anyone ? [inputIndex] : Array(tx.inputs.indices)
        appendCompactSize(&preimage, UInt64(inputIndices.count))
        let cleanedScript = signature.map { removeSignature($0, from: scriptCode) } ?? scriptCode
        for index in inputIndices {
            let input = tx.inputs[index]
            preimage.append(input.previousTxidInternal)
            preimage.append(input.vout.littleEndianData)
            let script = index == inputIndex ? cleanedScript : Data()
            appendCompactSize(&preimage, UInt64(script.count))
            preimage.append(script)
            let sequence = (index != inputIndex && (baseType == none || baseType == single)) ? UInt32(0) : input.sequence
            preimage.append(sequence.littleEndianData)
        }

        if baseType == none {
            appendCompactSize(&preimage, 0)
        } else if baseType == single {
            appendCompactSize(&preimage, UInt64(inputIndex + 1))
            for index in 0...inputIndex {
                if index == inputIndex {
                    preimage.append(serializeOutput(tx.outputs[index]))
                } else {
                    preimage.append(UInt64.max.littleEndianData)
                    preimage.append(UInt8(0))
                }
            }
        } else {
            appendCompactSize(&preimage, UInt64(tx.outputs.count))
            for output in tx.outputs {
                preimage.append(serializeOutput(output))
            }
        }
        preimage.append(tx.locktime.littleEndianData)
        preimage.append(sighashType.littleEndianData)
        return SHA256.doubleHash(preimage)
    }

    static func taprootScriptPath(
        tx: Transaction,
        inputIndex: Int,
        prevouts: [CorpusPrevout],
        tapleafHash: Data,
        sighashType: UInt8,
        annex: Data? = nil,
        codeSeparatorPos: UInt32 = UInt32.max,
        cache: Cache? = nil
    ) throws -> Data {
        guard inputIndex >= 0, inputIndex < tx.inputs.count, prevouts.count >= tx.inputs.count else {
            throw SwiftBitnodeError.message("taproot sighash missing prevouts")
        }
        guard taprootAllowedHashType(sighashType) else {
            throw SwiftBitnodeError.message("unsupported taproot sighash type")
        }
        let baseType = sighashType & 0x03
        let anyone = (sighashType & 0x80) != 0
        var msg = Data()
        msg.append(sighashType)
        msg.append(UInt32(bitPattern: tx.version).littleEndianData)
        msg.append(tx.locktime.littleEndianData)
        if !anyone {
            if let cache {
                msg.append(cache.taprootHashPrevouts)
                msg.append(cache.taprootHashAmounts)
                msg.append(cache.taprootHashScriptPubKeys)
                msg.append(cache.taprootHashSequences)
            } else {
                msg.append(SHA256.hash(tx.inputs.reduce(into: Data()) { out, input in
                    out.append(input.previousTxidInternal)
                    out.append(input.vout.littleEndianData)
                }))
                msg.append(SHA256.hash(prevouts.reduce(into: Data()) { out, prevout in
                    out.append(UInt64(bitPattern: prevout.amount).littleEndianData)
                }))
                msg.append(SHA256.hash(prevouts.reduce(into: Data()) { out, prevout in
                    appendCompactSize(&out, UInt64(prevout.scriptPubKey.count))
                    out.append(prevout.scriptPubKey)
                }))
                msg.append(SHA256.hash(tx.inputs.reduce(into: Data()) { out, input in
                    out.append(input.sequence.littleEndianData)
                }))
            }
        }
        if baseType != none && baseType != single {
            msg.append(cache?.taprootHashOutputs ?? SHA256.hash(tx.outputs.reduce(into: Data()) { out, output in
                out.append(serializeOutput(output))
            }))
        }
        msg.append(UInt8(2 + (annex == nil ? 0 : 1))) // ext_flag=1 plus annex bit.
        if anyone {
            let input = tx.inputs[inputIndex]
            let prevout = prevouts[inputIndex]
            msg.append(input.previousTxidInternal)
            msg.append(input.vout.littleEndianData)
            msg.append(UInt64(bitPattern: prevout.amount).littleEndianData)
            appendCompactSize(&msg, UInt64(prevout.scriptPubKey.count))
            msg.append(prevout.scriptPubKey)
            msg.append(input.sequence.littleEndianData)
        } else {
            msg.append(UInt32(inputIndex).littleEndianData)
        }
        if let annex {
            var serializedAnnex = Data()
            appendCompactSize(&serializedAnnex, UInt64(annex.count))
            serializedAnnex.append(annex)
            msg.append(SHA256.hash(serializedAnnex))
        }
        if baseType == single {
            guard inputIndex < tx.outputs.count else {
                throw SwiftBitnodeError.message("taproot SIGHASH_SINGLE missing matching output")
            }
            msg.append(cache?.taprootSingleOutput(inputIndex) ?? SHA256.hash(serializeOutput(tx.outputs[inputIndex])))
        }
        msg.append(tapleafHash)
        msg.append(UInt8(0x00)) // key_version
        msg.append(codeSeparatorPos.littleEndianData)
        return taggedHash(tag: "TapSighash", Data([0x00]) + msg)
    }

    static func taprootKeyPath(
        tx: Transaction,
        inputIndex: Int,
        prevouts: [CorpusPrevout],
        sighashType: UInt8,
        annex: Data? = nil,
        cache: Cache? = nil
    ) throws -> Data {
        guard inputIndex >= 0, inputIndex < tx.inputs.count, prevouts.count >= tx.inputs.count else {
            throw SwiftBitnodeError.message("taproot sighash missing prevouts")
        }
        guard taprootAllowedHashType(sighashType) else {
            throw SwiftBitnodeError.message("unsupported taproot sighash type")
        }
        let outputMode = sighashType == 0x00 ? all : UInt32(sighashType & 0x03)
        let anyone = (sighashType & 0x80) != 0
        var msg = Data()
        msg.append(sighashType)
        msg.append(UInt32(bitPattern: tx.version).littleEndianData)
        msg.append(tx.locktime.littleEndianData)
        if !anyone {
            if let cache {
                msg.append(cache.taprootHashPrevouts)
                msg.append(cache.taprootHashAmounts)
                msg.append(cache.taprootHashScriptPubKeys)
                msg.append(cache.taprootHashSequences)
            } else {
                msg.append(SHA256.hash(tx.inputs.reduce(into: Data()) { out, input in
                    out.append(input.previousTxidInternal)
                    out.append(input.vout.littleEndianData)
                }))
                msg.append(SHA256.hash(prevouts.reduce(into: Data()) { out, prevout in
                    out.append(UInt64(bitPattern: prevout.amount).littleEndianData)
                }))
                msg.append(SHA256.hash(prevouts.reduce(into: Data()) { out, prevout in
                    appendCompactSize(&out, UInt64(prevout.scriptPubKey.count))
                    out.append(prevout.scriptPubKey)
                }))
                msg.append(SHA256.hash(tx.inputs.reduce(into: Data()) { out, input in
                    out.append(input.sequence.littleEndianData)
                }))
            }
        }
        if outputMode == all {
            msg.append(cache?.taprootHashOutputs ?? SHA256.hash(tx.outputs.reduce(into: Data()) { out, output in
                out.append(serializeOutput(output))
            }))
        } else if outputMode == single && inputIndex >= tx.outputs.count {
            throw SwiftBitnodeError.message("taproot SIGHASH_SINGLE missing matching output")
        }
        msg.append(UInt8(annex == nil ? 0 : 1)) // ext_flag=0 plus annex bit.
        if anyone {
            let input = tx.inputs[inputIndex]
            let prevout = prevouts[inputIndex]
            msg.append(input.previousTxidInternal)
            msg.append(input.vout.littleEndianData)
            msg.append(UInt64(bitPattern: prevout.amount).littleEndianData)
            appendCompactSize(&msg, UInt64(prevout.scriptPubKey.count))
            msg.append(prevout.scriptPubKey)
            msg.append(input.sequence.littleEndianData)
        } else {
            msg.append(UInt32(inputIndex).littleEndianData)
        }
        if let annex {
            var serializedAnnex = Data()
            appendCompactSize(&serializedAnnex, UInt64(annex.count))
            serializedAnnex.append(annex)
            msg.append(SHA256.hash(serializedAnnex))
        }
        if outputMode == single {
            msg.append(cache?.taprootSingleOutput(inputIndex) ?? SHA256.hash(serializeOutput(tx.outputs[inputIndex])))
        }
        return taggedHash(tag: "TapSighash", Data([0x00]) + msg)
    }

    static func tapleafHash(script: Data, leafVersion: UInt8) -> Data {
        var payload = Data([leafVersion])
        appendCompactSize(&payload, UInt64(script.count))
        payload.append(script)
        return taggedHash(tag: "TapLeaf", payload)
    }

    static func tapbranchHash(_ left: Data, _ right: Data) -> Data {
        let pair = left.lexicographicallyPrecedes(right) ? left + right : right + left
        return taggedHash(tag: "TapBranch", pair)
    }

    static func serializeOutput(_ output: TxOutput) -> Data {
        var out = Data()
        out.append(UInt64(bitPattern: output.value).littleEndianData)
        appendCompactSize(&out, UInt64(output.scriptPubKey.count))
        out.append(output.scriptPubKey)
        return out
    }

    private static func removeSignature(_ signatureWithHashType: Data, from script: Data) -> Data {
        guard !signatureWithHashType.isEmpty else { return script }
        var out = Data(script)
        while let range = out.range(of: signatureWithHashType) {
            out.removeSubrange(range)
        }
        return out
    }

    private static func taggedHash(tag: String, _ payload: Data) -> Data {
        let tagHash = SHA256.hash(Data(tag.utf8))
        return SHA256.hash(tagHash + tagHash + payload)
    }

    private static func taprootAllowedHashType(_ hashType: UInt8) -> Bool {
        hashType <= 0x03 || (hashType >= 0x81 && hashType <= 0x83)
    }

    private static func appendCompactSize(_ out: inout Data, _ value: UInt64) {
        if value < 0xfd {
            out.append(UInt8(value))
        } else if value <= 0xffff {
            out.append(UInt8(0xfd))
            out.append(UInt16(value).littleEndianData)
        } else if value <= 0xffff_ffff {
            out.append(UInt8(0xfe))
            out.append(UInt32(value).littleEndianData)
        } else {
            out.append(UInt8(0xff))
            out.append(value.littleEndianData)
        }
    }
}
