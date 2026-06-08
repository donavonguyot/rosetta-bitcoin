import Foundation

enum TestCapability {
    struct Outcome {
        let capability: String
        let passed: Int
        let total: Int
        let notes: String

        var json: [String: Any] {
            [
                "capability": capability,
                "status": passed == total ? "pass" : "fail",
                "case_passed": passed,
                "case_total": total,
                "notes": notes
            ]
        }
    }

    static func run(args: Args) throws {
        let kind = args.string("kind", default: "")
        let outcomePath = args.string("outcome-path", default: "")
        guard !kind.isEmpty, !outcomePath.isEmpty else {
            throw SwiftBitnodeError.message("--kind and --outcome-path are required")
        }
        let outcomes: [Outcome]
        switch kind {
        case "crypto-vectors":
            outcomes = try cryptoVectorOutcomes()
        case "block-connect-backend":
            outcomes = try blockConnectOutcomes()
        default:
            throw SwiftBitnodeError.message("unknown capability kind \(kind)")
        }
        try Json.write([
            "port": "swift",
            "backend": Constants.nativeCryptoBackend,
            "outcomes": outcomes.map(\.json)
        ], to: outcomePath)
        print(outcomePath)
    }

    private static func cryptoVectorOutcomes() throws -> [Outcome] {
        let bip = try runBip340(path: sharedPath("testing/fixtures/bip340/test-vectors.csv"))
        let native = runNativeVectors()
        return [
            bip,
            Outcome(
                capability: "crypto_libsecp256k1_equivalence",
                passed: bip.passed + native.passed,
                total: bip.total + native.total,
                notes: "\(bip.notes); \(native.notes)"
            )
        ]
    }

    private static func runBip340(path: String) throws -> Outcome {
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        var passed = 0
        var total = 0
        var failures: [String] = []
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else {
                throw SwiftBitnodeError.message("malformed BIP340 vector row")
            }
            let expected = fields[6] == "TRUE"
            let actual = NativeSecp256k1.verifySchnorrMessageResult(
                xonlyPubkey: try Hex.data(fields[2]),
                message: try Hex.data(fields[4]),
                signature: try Hex.data(fields[5])
            ) == "valid"
            if actual == expected {
                passed += 1
            } else {
                failures.append(fields[0])
            }
            total += 1
        }
        return Outcome(
            capability: "crypto_bip340_vectors",
            passed: passed,
            total: total,
            notes: failures.isEmpty ? "all BIP340 vectors matched expected verification result" : "mismatched BIP340 vector indexes: \(failures.joined(separator: ","))"
        )
    }

    private static func runNativeVectors() -> Outcome {
        let doc = NativeVectors.run()
        let vectors = doc["vectors"] as? [[String: Any]] ?? []
        let passed = vectors.filter { ($0["result"] as? String) == ($0["expected"] as? String) }.count
        let failures = vectors.compactMap { row -> String? in
            (row["result"] as? String) == (row["expected"] as? String) ? nil : "\(row["id"] ?? "")"
        }
        return Outcome(
            capability: "native_crypto_vectors",
            passed: passed,
            total: vectors.count,
            notes: failures.isEmpty ? "native crypto vectors \(passed)/\(vectors.count)" : "native vector failures: \(failures.joined(separator: ","))"
        )
    }

    private static func blockConnectOutcomes() throws -> [Outcome] {
        let fixtures = ["scripts.p2pkh_sighash_single_38010", "scripts.p2tr_scriptpath_44295"]
        var passed = 0
        var notes: [String] = []
        for fixture in fixtures {
            let temp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swiftbitnode_\(fixture.replacingOccurrences(of: ".", with: "_"))_\(UUID().uuidString).json")
                .path
            setenv("SWIFTBITNODE_FIXTURE_FILTER", fixture, 1)
            defer { unsetenv("SWIFTBITNODE_FIXTURE_FILTER") }
            try ScriptCorpus.run(args: Args(["swiftbitnode", "script-corpus", "--manifest", sharedPath("conformance/fixtures/scripts/manifest.json"), "--output", temp]))
            let doc = try Json.loadObject(path: temp)
            try? FileManager.default.removeItem(atPath: temp)
            let result = doc["result"] as? String ?? "failed"
            if result == "passed", (doc["passed"] as? Int ?? 0) == 1 {
                passed += 1
            }
            notes.append("\(fixture) result=\(result)")
        }
        return [Outcome(capability: "block_connect_with_backend", passed: passed, total: fixtures.count, notes: notes.joined(separator: "; "))]
    }

    private static func sharedPath(_ suffix: String) -> String {
        let candidates = [
            "Nodes/Shared/\(suffix)",
            "../Shared/\(suffix)",
            "/workspace/Shared/\(suffix)"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }
}
