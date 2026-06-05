import Foundation

struct CorpusPrevout: Sendable {
    let amount: Int64
    let scriptPubKey: Data
}

struct CorpusFixture: Sendable {
    let fixtureID: String
    let height: Int
    let blockHash: String
    let txid: String
    let inputIndex: Int
    let transaction: Transaction
    let prevouts: [CorpusPrevout]
    let prevScriptPubKey: Data
    let loadedFiles: Int
    let fileHashes: [String: String]
}

enum ScriptTemplate: String {
    case p2pkh
    case p2sh
    case p2wpkh
    case p2wsh
    case p2tr
    case bareOpN
    case bareMultisig
    case bareLegacy
    case unknown
}

enum ScriptVerifier {
    static func verify(_ fixture: CorpusFixture) -> (passed: Bool, stage: String, type: String, message: String) {
        guard fixture.inputIndex >= 0, fixture.inputIndex < fixture.transaction.inputs.count else {
            return (false, "loader", "input_index", "input index out of range")
        }
        let template = classify(fixture.prevScriptPubKey)
        switch template {
        case .p2wpkh:
            return verifyP2WPKH(fixture)
        case .p2pkh:
            return verifyP2PKH(fixture)
        case .p2sh:
            return verifyP2SH(fixture)
        case .p2wsh:
            return verifyP2WSH(fixture, initialStack: nil)
        case .p2tr:
            return verifyP2TR(fixture)
        case .bareOpN, .bareMultisig, .bareLegacy:
            return verifyBare(fixture)
        case .unknown:
            return (false, "template", "unknown_template", "unsupported scriptPubKey template: \(fixture.prevScriptPubKey.hex)")
        }
    }

    static func classify(_ script: Data) -> ScriptTemplate {
        let b = [UInt8](script)
        if b.count == 25, b[0] == 0x76, b[1] == 0xa9, b[2] == 0x14, b[23] == 0x88, b[24] == 0xac {
            return .p2pkh
        }
        if b.count == 23, b[0] == 0xa9, b[1] == 0x14, b[22] == 0x87 {
            return .p2sh
        }
        if b.count == 22, b[0] == 0x00, b[1] == 0x14 {
            return .p2wpkh
        }
        if b.count == 34, b[0] == 0x00, b[1] == 0x20 {
            return .p2wsh
        }
        if b.count == 34, b[0] == 0x51, b[1] == 0x20 {
            return .p2tr
        }
        if b.count == 1, b[0] >= 0x51, b[0] <= 0x60 {
            return .bareOpN
        }
        if isBareMultisig(b) {
            return .bareMultisig
        }
        return .bareLegacy
    }

    private static func isBareMultisig(_ b: [UInt8]) -> Bool {
        guard b.count >= 3, b[0] >= 0x51, b[0] <= 0x60, b.last == 0xae else {
            return false
        }
        return true
    }

    private static func verifyP2WPKH(_ fixture: CorpusFixture, witnessProgramOverride: Data? = nil) -> (Bool, String, String, String) {
        let tx = fixture.transaction
        if witnessProgramOverride == nil, !tx.inputs[fixture.inputIndex].scriptSig.isEmpty {
            return (false, "stack", "native_segwit_scriptsig_nonempty", "native P2WPKH scriptSig must be empty")
        }
        guard fixture.inputIndex < tx.witness.count else {
            return (false, "loader", "missing_witness", "missing witness stack")
        }
        let witness = tx.witness[fixture.inputIndex]
        guard witness.count == 2 else {
            return (false, "stack", "p2wpkh_witness_shape", "P2WPKH witness expected 2 items, got \(witness.count)")
        }
        let programScript = witnessProgramOverride ?? fixture.prevScriptPubKey
        guard programScript.count == 22 else {
            return (false, "template", "p2wpkh_program_length", "invalid P2WPKH witness program length")
        }
        guard NativeSecp256k1.available else {
            return (false, "crypto", "native_secp256k1_unavailable", "native secp256k1 verifier is unavailable")
        }
        guard let prevout = currentPrevout(fixture) else {
            return (false, "loader", "missing_prevout", "missing prevout for P2WPKH")
        }
        guard witness[0].count > 1 else {
            return (false, "stack", "missing_sighash_type", "signature missing sighash byte")
        }
        let signature = witness[0].dropLast()
        let sighashType = UInt32(witness[0].last ?? 1)
        do {
            let program = programScript.subdata(in: 2..<22)
            let scriptCode = Sighash.p2wpkhScriptCode(program20: program)
            let digest = try Sighash.bip143(tx: tx, inputIndex: fixture.inputIndex, scriptCode: scriptCode, amount: prevout.amount, sighashType: sighashType)
            let result = NativeSecp256k1.verifyECDSAResult(pubkey: witness[1], msg32: digest, derSignature: Data(signature))
            if result != "valid" {
                return (false, "crypto", "ecdsa_\(result)", "P2WPKH ECDSA verification returned \(result)")
            }
            guard Hash.hash160(witness[1]) == program else {
                return (false, "stack", "p2wpkh_pubkey_hash_mismatch", "P2WPKH pubkey HASH160 mismatch")
            }
            return (true, "ok", "", "")
        } catch {
            return (false, "sighash", "bip143_error", error.localizedDescription)
        }
    }

    private static func verifyP2SH(_ fixture: CorpusFixture) -> (Bool, String, String, String) {
        let input = fixture.transaction.inputs[fixture.inputIndex]
        do {
            let pushes = try ScriptInterpreter.parsePushes(input.scriptSig)
            guard let redeemScript = pushes.last else {
                return (false, "stack", "empty_p2sh_scriptsig", "P2SH scriptSig did not include a redeem script")
            }
            guard Hash.hash160(redeemScript) == fixture.prevScriptPubKey.subdata(in: 2..<22) else {
                return (false, "template", "p2sh_hash_mismatch", "redeem script HASH160 does not match scriptPubKey")
            }
            if ScriptVerifier.classify(redeemScript) == .p2wsh {
                return verifyP2WSH(fixture, initialStack: nil, witnessProgramOverride: redeemScript)
            }
            if ScriptVerifier.classify(redeemScript) == .p2wpkh {
                guard pushes.count == 1 else {
                    return (false, "stack", "p2sh_nested_witness_scriptsig_shape", "nested segwit P2SH scriptSig must contain only redeem script")
                }
                return verifyP2WPKH(fixture, witnessProgramOverride: redeemScript)
            }
            let context = ScriptInterpreter.Context(
                transaction: fixture.transaction,
                inputIndex: fixture.inputIndex,
                tapscript: false,
                maxScriptElementSize: 520,
                maxScriptNumSize: 4,
                codeSeparatorCallback: nil
            )
            let passed = try ScriptInterpreter.evaluate(script: redeemScript, stack: Array(pushes.dropLast()), context: context) { signatureWithHashType, pubkey, scriptCode in
                verifyLegacySignature(fixture: fixture, signatureWithHashType: signatureWithHashType, pubkey: pubkey, scriptCode: scriptCode)
            }
            return passed
                ? (true, "ok", "", "")
                : (false, "stack", "p2sh_false_result", "P2SH redeem script evaluated false")
        } catch {
            return (false, "opcode", "p2sh_eval_error", error.localizedDescription)
        }
    }

    private static func verifyP2PKH(_ fixture: CorpusFixture) -> (Bool, String, String, String) {
        do {
            let input = fixture.transaction.inputs[fixture.inputIndex]
            let pushes = try ScriptInterpreter.parsePushes(input.scriptSig)
            guard pushes.count >= 2 else {
                return (false, "stack", "p2pkh_scriptsig_shape", "P2PKH scriptSig expected at least signature and pubkey")
            }
            let pubkey = pushes[pushes.count - 1]
            guard Hash.hash160(pubkey) == fixture.prevScriptPubKey.subdata(in: 3..<23) else {
                return (false, "stack", "p2pkh_pubkey_hash_mismatch", "P2PKH pubkey hash mismatch")
            }
            let context = ScriptInterpreter.Context(
                transaction: fixture.transaction,
                inputIndex: fixture.inputIndex,
                tapscript: false,
                maxScriptElementSize: 520,
                maxScriptNumSize: 4,
                codeSeparatorCallback: nil
            )
            let passed = try ScriptInterpreter.evaluate(script: fixture.prevScriptPubKey, stack: pushes, context: context) { signatureWithHashType, pubkey, scriptCode in
                verifyLegacySignature(fixture: fixture, signatureWithHashType: signatureWithHashType, pubkey: pubkey, scriptCode: scriptCode)
            }
            return passed
                ? (true, "ok", "", "")
                : (false, "crypto", "p2pkh_signature_invalid", "P2PKH signature verification failed")
        } catch {
            return (false, "sighash", "legacy_p2pkh_error", error.localizedDescription)
        }
    }

    private static func verifyBare(_ fixture: CorpusFixture) -> (Bool, String, String, String) {
        do {
            let input = fixture.transaction.inputs[fixture.inputIndex]
            let stack = try ScriptInterpreter.parsePushes(input.scriptSig)
            let context = ScriptInterpreter.Context(
                transaction: fixture.transaction,
                inputIndex: fixture.inputIndex,
                tapscript: false,
                maxScriptElementSize: 520,
                maxScriptNumSize: 4,
                codeSeparatorCallback: nil
            )
            let passed = try ScriptInterpreter.evaluate(script: fixture.prevScriptPubKey, stack: stack, context: context) { signatureWithHashType, pubkey, scriptCode in
                verifyLegacySignature(fixture: fixture, signatureWithHashType: signatureWithHashType, pubkey: pubkey, scriptCode: scriptCode)
            }
            return passed
                ? (true, "ok", "", "")
                : (false, "stack", "bare_script_false", "bare script evaluated false")
        } catch {
            return (false, "opcode", "bare_script_error", error.localizedDescription)
        }
    }

    private static func verifyP2TR(_ fixture: CorpusFixture) -> (Bool, String, String, String) {
        guard fixture.transaction.inputs[fixture.inputIndex].scriptSig.isEmpty else {
            return (false, "stack", "p2tr_scriptsig_nonempty", "P2TR scriptSig must be empty")
        }
        guard fixture.inputIndex < fixture.transaction.witness.count else {
            return (false, "loader", "missing_witness", "missing taproot witness stack")
        }
        var witness = fixture.transaction.witness[fixture.inputIndex]
        let annex: Data?
        if witness.count >= 2, let last = witness.last, last.first == 0x50 {
            annex = witness.removeLast()
        } else {
            annex = nil
        }
        if witness.count == 1 {
            return verifyTaprootKeyPath(fixture, signatureWithHashType: witness[0], annex: annex)
        }
        guard witness.count >= 2 else {
            return (false, "stack", "taproot_witness_shape", "taproot script path requires script and control block")
        }
        let tapscript = witness[witness.count - 2]
        let controlBlock = witness[witness.count - 1]
        guard controlBlock.count >= 33, controlBlock.count <= 33 + 128 * 32, (controlBlock.count - 33) % 32 == 0 else {
            return (false, "template", "taproot_control_block_shape", "invalid taproot control block length")
        }
        do {
            let initialStack = Array(witness.dropLast(2))
            let leafVersion = controlBlock[0] & 0xfe
            let tapleafHash = Sighash.tapleafHash(script: tapscript, leafVersion: leafVersion)
            var merkleRoot = tapleafHash
            var offset = 33
            while offset < controlBlock.count {
                merkleRoot = Sighash.tapbranchHash(merkleRoot, controlBlock.subdata(in: offset..<(offset + 32)))
                offset += 32
            }
            let internalKey = controlBlock.subdata(in: 1..<33)
            guard let tweaked = NativeSecp256k1.taprootTweakXOnly(xonlyPubkey: internalKey, merkleRoot: merkleRoot),
                  fixture.prevScriptPubKey.subdata(in: 2..<34) == tweaked.outputXOnly,
                  controlBlock[0] == (leafVersion | UInt8(tweaked.parity)) else {
                return (false, "crypto", "taproot_control_block_tweak_mismatch", "taproot control block does not match output key")
            }
            if leafVersion != 0xc0 {
                return (true, "ok", "", "")
            }
            var codeSeparatorPos = UInt32.max
            let context = ScriptInterpreter.Context(
                transaction: fixture.transaction,
                inputIndex: fixture.inputIndex,
                tapscript: true,
                maxScriptElementSize: 520,
                maxScriptNumSize: 4,
                codeSeparatorCallback: { codeSeparatorPos = UInt32($0) }
            )
            let passed = try ScriptInterpreter.evaluate(script: tapscript, stack: initialStack, context: context) { signatureWithHashType, pubkey, _ in
                verifyTaprootSignature(fixture: fixture, signatureWithHashType: signatureWithHashType, pubkey: pubkey, tapleafHash: tapleafHash, annex: annex, codeSeparatorPos: codeSeparatorPos)
            }
            return passed
                ? (true, "ok", "", "")
                : (false, "stack", "taproot_script_false", "taproot script evaluated false")
        } catch {
            return (false, "opcode", "taproot_eval_error", error.localizedDescription)
        }
    }

    private static func verifyP2WSH(
        _ fixture: CorpusFixture,
        initialStack: [Data]?,
        witnessProgramOverride: Data? = nil
    ) -> (Bool, String, String, String) {
        if witnessProgramOverride == nil, !fixture.transaction.inputs[fixture.inputIndex].scriptSig.isEmpty {
            return (false, "stack", "native_segwit_scriptsig_nonempty", "native P2WSH scriptSig must be empty")
        }
        guard fixture.inputIndex < fixture.transaction.witness.count else {
            return (false, "loader", "missing_witness", "missing witness stack")
        }
        let witness = fixture.transaction.witness[fixture.inputIndex]
        guard let witnessScript = witness.last else {
            return (false, "stack", "missing_witness_script", "P2WSH witness stack is empty")
        }
        let programScript = witnessProgramOverride ?? fixture.prevScriptPubKey
        guard programScript.count == 34, programScript[0] == 0x00, programScript[1] == 0x20 else {
            return (false, "template", "p2wsh_program_shape", "invalid P2WSH program")
        }
        guard SHA256.hash(witnessScript) == programScript.subdata(in: 2..<34) else {
            return (false, "template", "p2wsh_hash_mismatch", "witness script SHA256 does not match witness program")
        }
        do {
            let stack = initialStack ?? Array(witness.dropLast())
            let context = ScriptInterpreter.Context(
                transaction: fixture.transaction,
                inputIndex: fixture.inputIndex,
                tapscript: false,
                maxScriptElementSize: 520,
                maxScriptNumSize: 4,
                codeSeparatorCallback: nil
            )
            let passed = try ScriptInterpreter.evaluate(script: witnessScript, stack: stack, context: context) { signatureWithHashType, pubkey, scriptCode in
                verifySegwitV0Signature(fixture: fixture, signatureWithHashType: signatureWithHashType, pubkey: pubkey, scriptCode: scriptCode)
            }
            return passed
                ? (true, "ok", "", "")
                : (false, "stack", "p2wsh_false_result", "P2WSH witness script evaluated false")
        } catch {
            return (false, "opcode", "p2wsh_eval_error", error.localizedDescription)
        }
    }

    private static func verifySegwitV0Signature(fixture: CorpusFixture, signatureWithHashType: Data, pubkey: Data, scriptCode: Data) -> Bool {
        guard signatureWithHashType.count > 1,
              let prevout = currentPrevout(fixture) else {
            return false
        }
        let der = Data(signatureWithHashType.dropLast())
        let sighashType = UInt32(signatureWithHashType.last ?? 1)
        guard let digest = try? Sighash.bip143(
            tx: fixture.transaction,
            inputIndex: fixture.inputIndex,
            scriptCode: scriptCode,
            amount: prevout.amount,
            sighashType: sighashType
        ) else {
            return false
        }
        return NativeSecp256k1.verifyECDSA(pubkey: pubkey, msg32: digest, derSignature: der)
    }

    private static func verifyLegacySignature(fixture: CorpusFixture, signatureWithHashType: Data, pubkey: Data, scriptCode: Data) -> Bool {
        guard signatureWithHashType.count > 1 else { return false }
        let der = Data(signatureWithHashType.dropLast())
        let sighashType = UInt32(signatureWithHashType.last ?? 1)
        guard let digest = try? Sighash.legacy(
            tx: fixture.transaction,
            inputIndex: fixture.inputIndex,
            scriptCode: scriptCode,
            sighashType: sighashType,
            signature: signatureWithHashType
        ) else {
            return false
        }
        return NativeSecp256k1.verifyECDSA(pubkey: pubkey, msg32: digest, derSignature: der)
    }

    private static func verifyTaprootKeyPath(_ fixture: CorpusFixture, signatureWithHashType: Data, annex: Data?) -> (Bool, String, String, String) {
        guard NativeSecp256k1.available else {
            return (false, "crypto", "native_secp256k1_unavailable", "native secp256k1 verifier is unavailable")
        }
        guard fixture.prevScriptPubKey.count == 34, fixture.prevScriptPubKey[0] == 0x51, fixture.prevScriptPubKey[1] == 0x20 else {
            return (false, "template", "p2tr_program_shape", "invalid P2TR witness program")
        }
        guard fixture.prevouts.count >= fixture.transaction.inputs.count else {
            return (false, "loader", "missing_prevouts", "taproot key path requires spent prevouts for every input")
        }
        guard let parsed = parseTaprootSignature(signatureWithHashType) else {
            return (false, "stack", "taproot_keypath_signature_shape", "taproot key path witness must be 64-byte sig or 65-byte sig+hashtype")
        }
        do {
            let digest = try Sighash.taprootKeyPath(
                tx: fixture.transaction,
                inputIndex: fixture.inputIndex,
                prevouts: fixture.prevouts,
                sighashType: parsed.sighashType,
                annex: annex
            )
            let pubkey = fixture.prevScriptPubKey.subdata(in: 2..<34)
            let result = NativeSecp256k1.verifySchnorrResult(xonlyPubkey: pubkey, msg32: digest, signature: parsed.signature)
            return result == "valid"
                ? (true, "ok", "", "")
                : (false, "crypto", "schnorr_\(result)", "P2TR key-path Schnorr verification returned \(result)")
        } catch {
            return (false, "sighash", "taproot_keypath_sighash_error", error.localizedDescription)
        }
    }

    private static func verifyTaprootSignature(fixture: CorpusFixture, signatureWithHashType: Data, pubkey: Data, tapleafHash: Data, annex: Data?, codeSeparatorPos: UInt32) -> Bool {
        guard pubkey.count == 32 else { return false }
        guard let parsed = parseTaprootSignature(signatureWithHashType) else { return false }
        guard let digest = try? Sighash.taprootScriptPath(
            tx: fixture.transaction,
            inputIndex: fixture.inputIndex,
            prevouts: fixture.prevouts,
            tapleafHash: tapleafHash,
            sighashType: parsed.sighashType,
            annex: annex,
            codeSeparatorPos: codeSeparatorPos
        ) else {
            return false
        }
        return NativeSecp256k1.verifySchnorr(xonlyPubkey: pubkey, msg32: digest, signature: parsed.signature)
    }

    private static func parseTaprootSignature(_ signatureWithHashType: Data) -> (signature: Data, sighashType: UInt8)? {
        if signatureWithHashType.count == 64 {
            return (signatureWithHashType, 0x00)
        }
        if signatureWithHashType.count == 65 {
            let sighashType = signatureWithHashType.last ?? 0x00
            guard sighashType != 0x00 else { return nil }
            return (Data(signatureWithHashType.dropLast()), sighashType)
        }
        return nil
    }

    private static func currentPrevout(_ fixture: CorpusFixture) -> CorpusPrevout? {
        if fixture.inputIndex >= 0, fixture.inputIndex < fixture.prevouts.count {
            return fixture.prevouts[fixture.inputIndex]
        }
        return fixture.prevouts.first
    }
}

enum Hex {
    static func data(_ text: String) throws -> Data {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count % 2 == 0 else {
            throw SwiftBitnodeError.message("hex string has odd length")
        }
        return Data(compact.hexToBytes())
    }
}
