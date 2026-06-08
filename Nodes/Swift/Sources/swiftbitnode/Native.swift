import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum NativeLibrary {
    static let secp256k1Names = [
        "libsecp256k1.so",
        "libsecp256k1.so.1",
        "libsecp256k1.dylib",
        "/opt/homebrew/lib/libsecp256k1.dylib",
        "/usr/local/lib/libsecp256k1.dylib"
    ]
    static let rocksdbNames = [
        "librocksdb.so",
        "librocksdb.so.7",
        "librocksdb.dylib",
        "/opt/homebrew/lib/librocksdb.dylib",
        "/usr/local/lib/librocksdb.dylib"
    ]

    static func available(_ names: [String]) -> Bool {
        for name in names {
            if let handle = dlopen(name, RTLD_NOW) {
                dlclose(handle)
                return true
            }
        }
        return false
    }
}

enum NativeReport {
    static func build() -> [String: Any] {
        let rocks = NativeLibrary.available(NativeLibrary.rocksdbNames)
        let secp = NativeLibrary.available(NativeLibrary.secp256k1Names)
        return [
            "rocksdb_backend": "rocksdb-c-api",
            "rocksdb_available": rocks,
            "native_crypto_backend": Constants.nativeCryptoBackend,
            "native_crypto_available": secp,
            "ecdsa_bip143_vectors": secp ? "not_implemented" : "native_library_missing",
            "schnorr_bip340_vectors": secp ? "not_implemented" : "native_library_missing"
        ]
    }
}

enum NativeSecp256k1 {
    static var available: Bool {
        shared != nil
    }

    fileprivate typealias ContextCreate = @convention(c) (UInt32) -> OpaquePointer?
    fileprivate typealias ContextDestroy = @convention(c) (OpaquePointer?) -> Void
    fileprivate typealias EcdsaSignatureParseDer = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, UnsafePointer<UInt8>?, Int) -> Int32
    fileprivate typealias EcdsaSignatureNormalize = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, UnsafePointer<UInt8>?) -> Int32
    fileprivate typealias EcPubkeyParse = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, UnsafePointer<UInt8>?, Int) -> Int32
    fileprivate typealias EcdsaVerify = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, UnsafePointer<UInt8>?, UnsafePointer<UInt8>?) -> Int32
    fileprivate typealias XOnlyPubkeyParse = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, UnsafePointer<UInt8>?) -> Int32
    fileprivate typealias SchnorrsigVerify = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?) -> Int32
    fileprivate typealias XOnlyPubkeyTweakAdd = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, UnsafePointer<UInt8>?, UnsafePointer<UInt8>?) -> Int32
    fileprivate typealias XOnlyPubkeyFromPubkey = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int32>?, UnsafePointer<UInt8>?) -> Int32
    fileprivate typealias EcPubkeySerialize = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int>?, UnsafePointer<UInt8>?, UInt32) -> Int32

    private static let threadContextKey = "swiftbitnode.native_secp256k1_context"
    private static let shared = Context.open()

    final class Context: @unchecked Sendable {
        fileprivate let api: API
        fileprivate let context: OpaquePointer

        fileprivate init(api: API, context: OpaquePointer) {
            self.api = api
            self.context = context
        }

        deinit {
            api.contextDestroy(context)
        }

        fileprivate static func open() -> Context? {
            guard let api = API.open(), let context = api.contextCreate(257) else {
                return nil
            }
            return Context(api: api, context: context)
        }
    }

    static func makeContext() -> Context? {
        Context.open()
    }

    static func withThreadLocalContext<T>(_ context: Context?, _ body: () throws -> T) rethrows -> T {
        guard let context else {
            return try body()
        }
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[threadContextKey]
        dictionary[threadContextKey] = context
        defer {
            if let previous {
                dictionary[threadContextKey] = previous
            } else {
                dictionary.removeObject(forKey: threadContextKey)
            }
        }
        return try body()
    }

    private static func currentContext() -> Context? {
        (Thread.current.threadDictionary[threadContextKey] as? Context) ?? shared
    }

    static func verifyECDSA(pubkey: Data, msg32: Data, derSignature: Data) -> Bool {
        verifyECDSAResult(pubkey: pubkey, msg32: msg32, derSignature: derSignature) == "valid"
    }

    static func verifyECDSAResult(pubkey: Data, msg32: Data, derSignature: Data) -> String {
        guard msg32.count == 32, let shared = currentContext() else {
            return "malformed_input"
        }
        let api = shared.api
        let ctx = shared.context
        var sig = [UInt8](repeating: 0, count: 64)
        var normalized = [UInt8](repeating: 0, count: 64)
        var parsedPubkey = [UInt8](repeating: 0, count: 64)
        let parsed = derSignature.withUnsafeBytes { sigBytes in
            pubkey.withUnsafeBytes { pubBytes in
                api.ecdsaSignatureParseDer(ctx, &sig, sigBytes.bindMemory(to: UInt8.self).baseAddress, derSignature.count) == 1 &&
                    api.ecPubkeyParse(ctx, &parsedPubkey, pubBytes.bindMemory(to: UInt8.self).baseAddress, pubkey.count) == 1
            }
        }
        guard parsed else { return "malformed_input" }
        let valid = msg32.withUnsafeBytes { msgBytes in
            api.ecdsaVerify(ctx, sig, msgBytes.bindMemory(to: UInt8.self).baseAddress, parsedPubkey) == 1
        }
        if valid { return "valid" }
        guard api.ecdsaSignatureNormalize(ctx, &normalized, sig) == 1 else {
            return "consensus_invalid"
        }
        let normalizedValid = msg32.withUnsafeBytes { msgBytes in
            api.ecdsaVerify(ctx, normalized, msgBytes.bindMemory(to: UInt8.self).baseAddress, parsedPubkey) == 1
        }
        return normalizedValid ? "valid" : "consensus_invalid"
    }

    static func verifySchnorr(xonlyPubkey: Data, msg32: Data, signature: Data) -> Bool {
        verifySchnorrResult(xonlyPubkey: xonlyPubkey, msg32: msg32, signature: signature) == "valid"
    }

    static func verifySchnorrResult(xonlyPubkey: Data, msg32: Data, signature: Data) -> String {
        guard msg32.count == 32, signature.count == 64, xonlyPubkey.count == 32,
              let shared = currentContext() else {
            return "malformed_input"
        }
        return verifySchnorrMessageResult(xonlyPubkey: xonlyPubkey, message: msg32, signature: signature, context: shared)
    }

    static func verifySchnorrMessageResult(xonlyPubkey: Data, message: Data, signature: Data) -> String {
        guard signature.count == 64, xonlyPubkey.count == 32, let shared = currentContext() else {
            return "malformed_input"
        }
        return verifySchnorrMessageResult(xonlyPubkey: xonlyPubkey, message: message, signature: signature, context: shared)
    }

    private static func verifySchnorrMessageResult(xonlyPubkey: Data, message: Data, signature: Data, context shared: Context) -> String {
        let api = shared.api
        let ctx = shared.context
        var parsedPubkey = [UInt8](repeating: 0, count: 64)
        let parsed = xonlyPubkey.withUnsafeBytes { pubBytes in
            api.xonlyPubkeyParse(ctx, &parsedPubkey, pubBytes.bindMemory(to: UInt8.self).baseAddress) == 1
        }
        guard parsed else { return "malformed_input" }
        var messageBytes = Array(message)
        let messageCount = messageBytes.count
        if messageBytes.isEmpty {
            messageBytes = [0]
        }
        let valid = signature.withUnsafeBytes { sigBytes in
            messageBytes.withUnsafeBufferPointer { msgBytes in
                api.schnorrsigVerify(
                    ctx,
                    sigBytes.bindMemory(to: UInt8.self).baseAddress,
                    msgBytes.baseAddress,
                    messageCount,
                    parsedPubkey
                ) == 1
            }
        }
        return valid ? "valid" : "consensus_invalid"
    }

    static func taprootTweakResult(xonlyPubkey: Data, merkleRoot: Data, expectedXOnly: String, expectedParity: Int?) -> String {
        guard let tweaked = taprootTweakXOnly(xonlyPubkey: xonlyPubkey, merkleRoot: merkleRoot) else {
            return "malformed_input"
        }
        let parityMatches = expectedParity.map { tweaked.parity == $0 } ?? true
        return tweaked.outputXOnly.hex == expectedXOnly && parityMatches ? "valid" : "consensus_invalid"
    }

    static func taprootTweakXOnly(xonlyPubkey: Data, merkleRoot: Data) -> (outputXOnly: Data, parity: Int)? {
        guard xonlyPubkey.count == 32, let shared = currentContext() else {
            return nil
        }
        let api = shared.api
        let ctx = shared.context
        var internalKey = [UInt8](repeating: 0, count: 64)
        let parsed = xonlyPubkey.withUnsafeBytes { pubBytes in
            api.xonlyPubkeyParse(ctx, &internalKey, pubBytes.bindMemory(to: UInt8.self).baseAddress) == 1
        }
        guard parsed else { return nil }
        let tweak = taggedHash(tag: "TapTweak", xonlyPubkey + merkleRoot)
        var tweakedPubkey = [UInt8](repeating: 0, count: 64)
        let tweaked = tweak.withUnsafeBytes { tweakBytes in
            api.xonlyPubkeyTweakAdd(ctx, &tweakedPubkey, internalKey, tweakBytes.bindMemory(to: UInt8.self).baseAddress) == 1
        }
        guard tweaked else { return nil }
        var compressed = [UInt8](repeating: 0, count: 33)
        var compressedLen = 33
        guard api.ecPubkeySerialize(ctx, &compressed, &compressedLen, tweakedPubkey, 258) == 1, compressedLen == 33 else {
            return nil
        }
        let parity = Int(compressed[0] - 2)
        return (Data(compressed[1..<33]), parity)
    }

    private static func taggedHash(tag: String, _ payload: Data) -> Data {
        let tagHash = SHA256.hash(Data(tag.utf8))
        return SHA256.hash(tagHash + tagHash + payload)
    }

    fileprivate struct API: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer
        let contextCreate: ContextCreate
        let contextDestroy: ContextDestroy
        let ecdsaSignatureParseDer: EcdsaSignatureParseDer
        let ecdsaSignatureNormalize: EcdsaSignatureNormalize
        let ecPubkeyParse: EcPubkeyParse
        let ecdsaVerify: EcdsaVerify
        let xonlyPubkeyParse: XOnlyPubkeyParse
        let schnorrsigVerify: SchnorrsigVerify
        let xonlyPubkeyTweakAdd: XOnlyPubkeyTweakAdd
        let xonlyPubkeyFromPubkey: XOnlyPubkeyFromPubkey
        let ecPubkeySerialize: EcPubkeySerialize

        static func open() -> API? {
            for name in NativeLibrary.secp256k1Names {
                guard let handle = dlopen(name, RTLD_NOW) else { continue }
                guard
                    let contextCreate = symbol(handle, "secp256k1_context_create", ContextCreate.self),
                    let contextDestroy = symbol(handle, "secp256k1_context_destroy", ContextDestroy.self),
                    let ecdsaSignatureParseDer = symbol(handle, "secp256k1_ecdsa_signature_parse_der", EcdsaSignatureParseDer.self),
                    let ecdsaSignatureNormalize = symbol(handle, "secp256k1_ecdsa_signature_normalize", EcdsaSignatureNormalize.self),
                    let ecPubkeyParse = symbol(handle, "secp256k1_ec_pubkey_parse", EcPubkeyParse.self),
                    let ecdsaVerify = symbol(handle, "secp256k1_ecdsa_verify", EcdsaVerify.self),
                    let xonlyPubkeyParse = symbol(handle, "secp256k1_xonly_pubkey_parse", XOnlyPubkeyParse.self),
                    let schnorrsigVerify = symbol(handle, "secp256k1_schnorrsig_verify", SchnorrsigVerify.self),
                    let xonlyPubkeyTweakAdd = symbol(handle, "secp256k1_xonly_pubkey_tweak_add", XOnlyPubkeyTweakAdd.self),
                    let xonlyPubkeyFromPubkey = symbol(handle, "secp256k1_xonly_pubkey_from_pubkey", XOnlyPubkeyFromPubkey.self),
                    let ecPubkeySerialize = symbol(handle, "secp256k1_ec_pubkey_serialize", EcPubkeySerialize.self)
                else {
                    dlclose(handle)
                    continue
                }
                return API(
                    handle: handle,
                    contextCreate: contextCreate,
                    contextDestroy: contextDestroy,
                    ecdsaSignatureParseDer: ecdsaSignatureParseDer,
                    ecdsaSignatureNormalize: ecdsaSignatureNormalize,
                    ecPubkeyParse: ecPubkeyParse,
                    ecdsaVerify: ecdsaVerify,
                    xonlyPubkeyParse: xonlyPubkeyParse,
                    schnorrsigVerify: schnorrsigVerify,
                    xonlyPubkeyTweakAdd: xonlyPubkeyTweakAdd,
                    xonlyPubkeyFromPubkey: xonlyPubkeyFromPubkey,
                    ecPubkeySerialize: ecPubkeySerialize
                )
            }
            return nil
        }

        private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
    }
}

enum NativeVectors {
    static func run() -> [String: Any] {
        let report = NativeReport.build()
        let fixturePath = "Nodes/Shared/conformance/fixtures/native_crypto_v1_vectors.json"
        let vectors = runSharedVectors(path: fixturePath)
        let failed = vectors.filter { ($0["result"] as? String) != ($0["expected"] as? String) }
        return [
            "schema": "port.native_crypto_vectors.v1",
            "implementation": Constants.implementation,
            "node_id": Constants.nodeID,
            "runtime_surface": Constants.runtimeSurface,
            "result": failed.isEmpty && !vectors.isEmpty ? "passed" : "failed",
            "backend": Constants.nativeCryptoBackend,
            "failure": failed.isEmpty && !vectors.isEmpty ? "" : "one or more native crypto vectors failed or could not be loaded",
            "dependency_report": report,
            "vector_count": vectors.count,
            "vectors": vectors
        ]
    }

    private static func runSharedVectors(path: String) -> [[String: Any]] {
        let candidates = [
            path,
            "../Shared/conformance/fixtures/native_crypto_v1_vectors.json",
            "/workspace/Shared/conformance/fixtures/native_crypto_v1_vectors.json"
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let root = try? Json.loadObject(path: path),
              let rows = root["vectors"] as? [[String: Any]] else {
            return []
        }
        return rows.map { row in
            let operation = row["operation"] as? String ?? ""
            let expected = row["expected"] as? String ?? ""
            let result: String
            switch operation {
            case "verify_ecdsa":
                result = NativeSecp256k1.verifyECDSAResult(
                    pubkey: (try? Hex.data(row["pubkey_hex"] as? String ?? "")) ?? Data(),
                    msg32: (try? Hex.data(row["msg_hash_hex"] as? String ?? "")) ?? Data(),
                    derSignature: (try? Hex.data(row["signature_hex"] as? String ?? "")) ?? Data()
                )
            case "verify_schnorr":
                result = NativeSecp256k1.verifySchnorrResult(
                    xonlyPubkey: (try? Hex.data(row["xonly_pubkey_hex"] as? String ?? "")) ?? Data(),
                    msg32: (try? Hex.data(row["msg_hash_hex"] as? String ?? "")) ?? Data(),
                    signature: (try? Hex.data(row["signature_hex"] as? String ?? "")) ?? Data()
                )
            case "taproot_tweak_xonly":
                result = NativeSecp256k1.taprootTweakResult(
                    xonlyPubkey: (try? Hex.data(row["xonly_pubkey_hex"] as? String ?? "")) ?? Data(),
                    merkleRoot: (try? Hex.data(row["merkle_root_hex"] as? String ?? "")) ?? Data(),
                    expectedXOnly: row["expected_output_xonly_hex"] as? String ?? "",
                    expectedParity: row["expected_parity"] as? Int
                )
            default:
                result = "unsupported"
            }
            return [
                "id": row["id"] ?? "",
                "operation": operation,
                "expected": expected,
                "result": result,
                "failure": result == expected ? "" : "got \(result), expected \(expected)"
            ]
        }
    }
}
