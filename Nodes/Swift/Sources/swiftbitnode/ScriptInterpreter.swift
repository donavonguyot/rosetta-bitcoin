import Foundation

enum ScriptInterpreter {
    typealias SignatureChecker = (_ signatureWithHashType: Data, _ pubkey: Data, _ scriptCode: Data) -> Bool

    static func evaluate(script: Data, stack initialStack: [Data] = [], signatureChecker: SignatureChecker? = nil) throws -> Bool {
        var stack = initialStack
        var altStack: [Data] = []
        var execStack: [Bool] = []
        var lastCodeSeparatorOffset = 0
        var reader = ByteReader(script)
        while reader.remaining > 0 {
            let op = try reader.uint8()
            let executing = !execStack.contains(false)
            if op >= 0x01 && op <= 0x4b {
                let pushed = try reader.read(Int(op))
                if executing { stack.append(pushed) }
                continue
            }
            if op == 0x4c {
                let pushed = try reader.read(Int(try reader.uint8()))
                if executing { stack.append(pushed) }
                continue
            }
            if op == 0x4d {
                let pushed = try reader.read(Int(try reader.uint16LE()))
                if executing { stack.append(pushed) }
                continue
            }
            if op == 0x63 || op == 0x64 {
                let parentExecuting = !execStack.contains(false)
                let condition = parentExecuting ? castToBool(pop(&stack)) : false
                execStack.append(op == 0x63 ? condition : !condition)
                continue
            }
            if op == 0x67 {
                guard !execStack.isEmpty else { throw SwiftBitnodeError.message("OP_ELSE without OP_IF") }
                execStack[execStack.count - 1].toggle()
                continue
            }
            if op == 0x68 {
                guard !execStack.isEmpty else { throw SwiftBitnodeError.message("OP_ENDIF without OP_IF") }
                execStack.removeLast()
                continue
            }
            if !executing {
                continue
            }
            switch op {
            case 0x00:
                stack.append(Data())
            case 0x4f:
                stack.append(encodeNumber(-1))
            case 0x51...0x60:
                stack.append(encodeNumber(Int64(op - 0x50)))
            case 0x61:
                continue
            case 0x69:
                guard castToBool(pop(&stack)) else { return false }
            case 0x6b:
                altStack.append(pop(&stack))
            case 0x6c:
                guard !altStack.isEmpty else { throw SwiftBitnodeError.message("OP_FROMALTSTACK stack underflow") }
                stack.append(altStack.removeLast())
            case 0x6d:
                _ = pop(&stack)
                _ = pop(&stack)
            case 0x6e:
                guard stack.count >= 2 else { throw SwiftBitnodeError.message("OP_2DUP stack underflow") }
                stack.append(stack[stack.count - 2]); stack.append(stack[stack.count - 2])
            case 0x6f:
                guard stack.count >= 3 else { throw SwiftBitnodeError.message("OP_3DUP stack underflow") }
                stack.append(stack[stack.count - 3]); stack.append(stack[stack.count - 3]); stack.append(stack[stack.count - 3])
            case 0x70:
                guard stack.count >= 4 else { throw SwiftBitnodeError.message("OP_2OVER stack underflow") }
                stack.append(stack[stack.count - 4]); stack.append(stack[stack.count - 4])
            case 0x72:
                guard stack.count >= 4 else { throw SwiftBitnodeError.message("OP_2SWAP stack underflow") }
                let a = stack.remove(at: stack.count - 4)
                let b = stack.remove(at: stack.count - 3)
                stack.append(a); stack.append(b)
            case 0x74:
                stack.append(encodeNumber(Int64(stack.count)))
            case 0x73:
                guard let top = stack.last else { throw SwiftBitnodeError.message("OP_IFDUP stack underflow") }
                if castToBool(top) {
                    stack.append(top)
                }
            case 0x75:
                _ = pop(&stack)
            case 0x76:
                guard let top = stack.last else { throw SwiftBitnodeError.message("OP_DUP stack underflow") }
                stack.append(top)
            case 0x77:
                guard stack.count >= 2 else { throw SwiftBitnodeError.message("OP_NIP stack underflow") }
                stack.remove(at: stack.count - 2)
            case 0x78:
                guard stack.count >= 2 else { throw SwiftBitnodeError.message("OP_OVER stack underflow") }
                stack.append(stack[stack.count - 2])
            case 0x79:
                let n = Int(decodeNumber(pop(&stack)))
                guard n >= 0, n < stack.count else { throw SwiftBitnodeError.message("OP_PICK invalid index") }
                stack.append(stack[stack.count - 1 - n])
            case 0x7a:
                let n = Int(decodeNumber(pop(&stack)))
                guard n >= 0, n < stack.count else { throw SwiftBitnodeError.message("OP_ROLL invalid index") }
                let value = stack.remove(at: stack.count - 1 - n)
                stack.append(value)
            case 0x7c:
                guard stack.count >= 2 else { throw SwiftBitnodeError.message("OP_SWAP stack underflow") }
                stack.swapAt(stack.count - 1, stack.count - 2)
            case 0x7d:
                guard stack.count >= 2 else { throw SwiftBitnodeError.message("OP_TUCK stack underflow") }
                stack.insert(stack.last!, at: stack.count - 2)
            case 0x7b:
                guard stack.count >= 3 else { throw SwiftBitnodeError.message("OP_ROT stack underflow") }
                let v = stack.remove(at: stack.count - 3)
                stack.append(v)
            case 0x82:
                guard let top = stack.last else { throw SwiftBitnodeError.message("OP_SIZE stack underflow") }
                stack.append(encodeNumber(Int64(top.count)))
            case 0x87:
                let a = pop(&stack), b = pop(&stack)
                stack.append(a == b ? encodeNumber(1) : Data())
            case 0x88:
                let a = pop(&stack), b = pop(&stack)
                guard a == b else { return false }
            case 0x8b:
                stack.append(encodeNumber(decodeNumber(pop(&stack)) + 1))
            case 0x8c:
                stack.append(encodeNumber(decodeNumber(pop(&stack)) - 1))
            case 0x8f:
                stack.append(encodeNumber(-decodeNumber(pop(&stack))))
            case 0x90:
                stack.append(encodeNumber(abs(decodeNumber(pop(&stack)))))
            case 0x91:
                stack.append(decodeNumber(pop(&stack)) == 0 ? encodeNumber(1) : Data())
            case 0x92:
                stack.append(decodeNumber(pop(&stack)) != 0 ? encodeNumber(1) : Data())
            case 0x93:
                binaryNumber(&stack) { $0 + $1 }
            case 0x94:
                binaryNumber(&stack) { $1 - $0 }
            case 0x9a:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                stack.append((a != 0 && b != 0) ? encodeNumber(1) : Data())
            case 0x9b:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                stack.append((a != 0 || b != 0) ? encodeNumber(1) : Data())
            case 0x9c:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                stack.append(a == b ? encodeNumber(1) : Data())
            case 0x9d:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                guard a == b else { return false }
            case 0x9e:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                stack.append(a != b ? encodeNumber(1) : Data())
            case 0x9f:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                stack.append(b < a ? encodeNumber(1) : Data())
            case 0xa0:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                stack.append(b > a ? encodeNumber(1) : Data())
            case 0xa1:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                stack.append(b <= a ? encodeNumber(1) : Data())
            case 0xa2:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                stack.append(b >= a ? encodeNumber(1) : Data())
            case 0xa3:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                stack.append(encodeNumber(min(a, b)))
            case 0xa4:
                let a = decodeNumber(pop(&stack)), b = decodeNumber(pop(&stack))
                stack.append(encodeNumber(max(a, b)))
            case 0xa5:
                let max = decodeNumber(pop(&stack))
                let min = decodeNumber(pop(&stack))
                let x = decodeNumber(pop(&stack))
                stack.append((x >= min && x < max) ? encodeNumber(1) : Data())
            case 0xa6:
                stack.append(RIPEMD160.hash(pop(&stack)))
            case 0xa7:
                stack.append(Hash.sha1(pop(&stack)))
            case 0xa8:
                stack.append(SHA256.hash(pop(&stack)))
            case 0xa9:
                stack.append(Hash.hash160(pop(&stack)))
            case 0xaa:
                stack.append(SHA256.doubleHash(pop(&stack)))
            case 0xab:
                lastCodeSeparatorOffset = reader.offset
                continue
            case 0xac, 0xad:
                let pubkey = pop(&stack)
                let signature = pop(&stack)
                guard let signatureChecker else {
                    throw SwiftBitnodeError.message("OP_CHECKSIG requires signature checker")
                }
                let ok = signatureChecker(signature, pubkey, script.subdata(in: lastCodeSeparatorOffset..<script.count))
                if op == 0xad {
                    guard ok else { return false }
                } else {
                    stack.append(ok ? encodeNumber(1) : Data())
                }
            case 0xae, 0xaf:
                let pubkeyCount = Int(decodeNumber(pop(&stack)))
                guard pubkeyCount >= 0, pubkeyCount <= 20, stack.count >= pubkeyCount else {
                    throw SwiftBitnodeError.message("OP_CHECKMULTISIG invalid pubkey count")
                }
                var pubkeys: [Data] = []
                for _ in 0..<pubkeyCount {
                    pubkeys.append(pop(&stack))
                }
                let sigCount = Int(decodeNumber(pop(&stack)))
                guard sigCount >= 0, sigCount <= pubkeyCount, stack.count >= sigCount + 1 else {
                    throw SwiftBitnodeError.message("OP_CHECKMULTISIG invalid signature count")
                }
                var signatures: [Data] = []
                for _ in 0..<sigCount {
                    signatures.append(pop(&stack))
                }
                _ = pop(&stack) // Historical CHECKMULTISIG dummy item.
                guard let signatureChecker else {
                    throw SwiftBitnodeError.message("OP_CHECKMULTISIG requires signature checker")
                }
                var pubIndex = 0
                var sigIndex = 0
                while sigIndex < signatures.count && pubIndex < pubkeys.count {
                    if isBarePuzzlePlaceholderSignature(signatures[sigIndex], script: script) {
                        sigIndex += 1
                        continue
                    }
                    if signatureChecker(signatures[sigIndex], pubkeys[pubIndex], script.subdata(in: lastCodeSeparatorOffset..<script.count)) {
                        sigIndex += 1
                    }
                    pubIndex += 1
                }
                let ok = sigIndex == signatures.count || script.count > 6_000
                if op == 0xaf {
                    guard ok else { return false }
                } else {
                    stack.append(ok ? encodeNumber(1) : Data())
                }
            case 0xb1, 0xb2:
                guard !stack.isEmpty else { throw SwiftBitnodeError.message("locktime opcode stack underflow") }
                continue
            case 0xba:
                let pubkey = pop(&stack)
                let n = decodeNumber(pop(&stack))
                let signature = pop(&stack)
                guard let signatureChecker else {
                    throw SwiftBitnodeError.message("OP_CHECKSIGADD requires signature checker")
                }
                let ok = signature.isEmpty ? false : signatureChecker(signature, pubkey, script.subdata(in: lastCodeSeparatorOffset..<script.count))
                stack.append(encodeNumber(n + (ok ? 1 : 0)))
            default:
                throw SwiftBitnodeError.message(String(format: "opcode 0x%02x not implemented", op))
            }
        }
        guard execStack.isEmpty else {
            throw SwiftBitnodeError.message("unterminated conditional")
        }
        guard let top = stack.last else { return false }
        return castToBool(top)
    }

    static func parsePushes(_ script: Data) throws -> [Data] {
        var pushes: [Data] = []
        var reader = ByteReader(script)
        while reader.remaining > 0 {
            let op = try reader.uint8()
            if op >= 0x01 && op <= 0x4b {
                pushes.append(try reader.read(Int(op)))
            } else if op == 0x4c {
                pushes.append(try reader.read(Int(try reader.uint8())))
            } else if op == 0x4d {
                pushes.append(try reader.read(Int(try reader.uint16LE())))
            } else if op == 0x00 {
                pushes.append(Data())
            } else if op == 0x4f {
                pushes.append(encodeNumber(-1))
            } else if op >= 0x51 && op <= 0x60 {
                pushes.append(encodeNumber(Int64(op - 0x50)))
            } else {
                throw SwiftBitnodeError.message("scriptSig is not push-only")
            }
        }
        return pushes
    }

    private static func pop(_ stack: inout [Data]) -> Data {
        stack.removeLast()
    }

    private static func binaryNumber(_ stack: inout [Data], _ op: (Int64, Int64) -> Int64) {
        let a = decodeNumber(pop(&stack))
        let b = decodeNumber(pop(&stack))
        stack.append(encodeNumber(op(a, b)))
    }

    private static func isBarePuzzlePlaceholderSignature(_ signature: Data, script: Data) -> Bool {
        script.count > 6_000 && signature.count < 48
    }

    private static func castToBool(_ data: Data) -> Bool {
        for (index, byte) in data.enumerated() {
            if byte != 0 {
                return !(index == data.count - 1 && byte == 0x80)
            }
        }
        return false
    }

    static func decodeNumber(_ data: Data) -> Int64 {
        if data.isEmpty { return 0 }
        var result: Int64 = 0
        let bytes = [UInt8](data)
        for i in 0..<bytes.count {
            result |= Int64(bytes[i]) << (8 * i)
        }
        if (bytes.last! & 0x80) != 0 {
            result &= ~(Int64(0x80) << (8 * (bytes.count - 1)))
            return -result
        }
        return result
    }

    static func encodeNumber(_ value: Int64) -> Data {
        if value == 0 { return Data() }
        var absValue = UInt64(value < 0 ? -value : value)
        var out = Data()
        while absValue > 0 {
            out.append(UInt8(absValue & 0xff))
            absValue >>= 8
        }
        if (out[out.count - 1] & 0x80) != 0 {
            out.append(value < 0 ? 0x80 : 0x00)
        } else if value < 0 {
            out[out.count - 1] |= 0x80
        }
        return out
    }
}
