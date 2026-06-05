import Foundation

struct CorpusPrevout {
    let amount: Int64
    let scriptPubKey: Data
}

struct CorpusFixture {
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

    private static func verifyP2WPKH(_ fixture: CorpusFixture) -> (Bool, String, String, String) {
        let tx = fixture.transaction
        guard fixture.inputIndex < tx.witness.count else {
            return (false, "loader", "missing_witness", "missing witness stack")
        }
        let witness = tx.witness[fixture.inputIndex]
        guard witness.count == 2 else {
            return (false, "stack", "p2wpkh_witness_shape", "P2WPKH witness expected 2 items, got \(witness.count)")
        }
        guard fixture.prevScriptPubKey.count == 22 else {
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
            let program = fixture.prevScriptPubKey.subdata(in: 2..<22)
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
            let passed = try ScriptInterpreter.evaluate(script: redeemScript, stack: Array(pushes.dropLast())) { signatureWithHashType, pubkey, scriptCode in
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
            let passed = try ScriptInterpreter.evaluate(script: fixture.prevScriptPubKey, stack: pushes) { signatureWithHashType, pubkey, scriptCode in
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
            let passed = try ScriptInterpreter.evaluate(script: fixture.prevScriptPubKey, stack: stack) { signatureWithHashType, pubkey, scriptCode in
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
        guard fixture.inputIndex < fixture.transaction.witness.count else {
            return (false, "loader", "missing_witness", "missing taproot witness stack")
        }
        let witness = fixture.transaction.witness[fixture.inputIndex]
        guard witness.count >= 2 else {
            return (false, "stack", "taproot_witness_shape", "taproot script path requires script and control block")
        }
        let tapscript = witness[witness.count - 2]
        let controlBlock = witness[witness.count - 1]
        guard controlBlock.count >= 33, (controlBlock.count - 33) % 32 == 0 else {
            return (false, "template", "taproot_control_block_shape", "invalid taproot control block length")
        }
        do {
            let initialStack = Array(witness.dropLast(2))
            let leafVersion = controlBlock[0] & 0xfe
            let tapleafHash = Sighash.tapleafHash(script: tapscript, leafVersion: leafVersion)
            let passed = try ScriptInterpreter.evaluate(script: tapscript, stack: initialStack) { signatureWithHashType, pubkey, _ in
                verifyTaprootSignature(fixture: fixture, signatureWithHashType: signatureWithHashType, pubkey: pubkey, tapleafHash: tapleafHash)
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
            let passed = try ScriptInterpreter.evaluate(script: witnessScript, stack: stack) { signatureWithHashType, pubkey, scriptCode in
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

    private static func verifyTaprootSignature(fixture: CorpusFixture, signatureWithHashType: Data, pubkey: Data, tapleafHash: Data) -> Bool {
        guard pubkey.count == 32 else { return false }
        if signatureWithHashType.isEmpty { return false }
        let sighashType: UInt8
        let signature: Data
        if signatureWithHashType.count == 64 {
            sighashType = 0x00
            signature = signatureWithHashType
        } else if signatureWithHashType.count == 65 {
            sighashType = signatureWithHashType.last ?? 0x00
            guard sighashType != 0x00 else { return false }
            signature = Data(signatureWithHashType.dropLast())
        } else {
            return false
        }
        guard let digest = try? Sighash.taprootScriptPath(
            tx: fixture.transaction,
            inputIndex: fixture.inputIndex,
            prevouts: fixture.prevouts,
            tapleafHash: tapleafHash,
            sighashType: sighashType
        ) else {
            return false
        }
        return NativeSecp256k1.verifySchnorr(xonlyPubkey: pubkey, msg32: digest, signature: signature)
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
