import Foundation

enum ScriptCorpus {
    static func run(args: Args) throws {
        let manifest = args.string("manifest", default: "../Shared/conformance/fixtures/scripts/manifest.json")
        let output = args.string("output", default: args.string("result-path", default: ""))
        var fixtures = try loadManifest(path: manifest)
        if let filter = ProcessInfo.processInfo.environment["SWIFTBITNODE_FIXTURE_FILTER"], !filter.isEmpty {
            fixtures = fixtures.filter { ($0["fixture_id"] as? String ?? "").contains(filter) }
        }
        var results: [[String: Any]] = []
        for fixture in fixtures {
            results.append(inspectFixture(fixture: fixture, manifestPath: manifest))
        }
        let passed = results.filter { ($0["result"] as? String) == "passed" }.count
        let failed = results.count - passed
        let doc: [String: Any] = [
            "schema": "port.script_corpus_result.v1",
            "category": "script_corpus",
            "result": failed == 0 ? "passed" : "failed",
            "implementation": Constants.implementation,
            "node_id": Constants.nodeID,
            "port": Constants.nodeID,
            "runtime_surface": Constants.runtimeSurface,
            "verifier": [
                "engine": "swiftbitnode-script",
                "crypto_backend": Constants.nativeCryptoBackend,
                "source": "Nodes/Swift/Sources/swiftbitnode",
                "delegated": false,
                "note": "Swift fixture loader is active; script verification intentionally reports not_implemented until implemented."
            ],
            "native_crypto_backend": Constants.nativeCryptoBackend,
            "fixture_count": results.count,
            "passed": passed,
            "failed": failed,
            "not_implemented": failed,
            "captured_at": nowIso8601(),
            "results": results
        ]
        try Json.write(doc, to: output.isEmpty ? nil : output)
    }

    private static func loadManifest(path: String) throws -> [[String: Any]] {
        let object = try Json.loadObject(path: path)
        guard let fixtures = object["fixtures"] as? [[String: Any]] else {
            throw SwiftBitnodeError.message("invalid script manifest")
        }
        return fixtures
    }

    private static func inspectFixture(fixture: [String: Any], manifestPath: String) -> [String: Any] {
        let base = URL(fileURLWithPath: manifestPath).deletingLastPathComponent()
        let files = fixture["files"] as? [String: [String]] ?? [:]
        var loaded = 0
        var hashes: [String: String] = [:]
        var failures: [String] = []
        for (_, paths) in files {
            for relative in paths {
                let path = base.appendingPathComponent(relative)
                do {
                    let data = try Data(contentsOf: path)
                    hashes[relative] = SHA256.hash(data).hex
                    loaded += 1
                } catch {
                    failures.append("\(relative): \(error.localizedDescription)")
                }
            }
        }
        do {
            let loadedFixture = try buildCorpusFixture(fixture: fixture, files: files, base: base, loadedFiles: loaded, fileHashes: hashes)
            let result = ScriptVerifier.verify(loadedFixture)
            return [
                "fixture_id": loadedFixture.fixtureID,
                "height": loadedFixture.height,
                "block_hash": loadedFixture.blockHash,
                "txid": loadedFixture.txid,
                "input_index": loadedFixture.inputIndex,
                "expected_result": fixture["expected_result"] ?? "",
                "template": ScriptVerifier.classify(loadedFixture.prevScriptPubKey).rawValue,
                "result": result.passed ? "passed" : "failed",
                "failure": result.passed ? "" : result.message,
                "failure_stage": result.stage,
                "failure_type": result.type,
                "loaded_files": loadedFixture.loadedFiles,
                "file_sha256": loadedFixture.fileHashes
            ]
        } catch {
            failures.append(error.localizedDescription)
            return [
                "fixture_id": fixture["fixture_id"] ?? "",
                "height": fixture["height"] ?? -1,
                "block_hash": fixture["block_hash"] ?? "",
                "txid": fixture["txid"] ?? "",
                "input_index": fixture["input_index"] ?? -1,
                "expected_result": fixture["expected_result"] ?? "",
                "result": "failed",
                "failure": failures.joined(separator: "; "),
                "failure_stage": "loader",
                "failure_type": "fixture_load",
                "loaded_files": loaded,
                "file_sha256": hashes
            ]
        }
    }

    private static func buildCorpusFixture(
        fixture: [String: Any],
        files: [String: [String]],
        base: URL,
        loadedFiles: Int,
        fileHashes: [String: String]
    ) throws -> CorpusFixture {
        guard let txPath = files["tx"]?.first else {
            throw SwiftBitnodeError.message("missing tx fixture file category")
        }
        let meta = try loadMeta(files: files, base: base)
        let txHex = try String(contentsOf: base.appendingPathComponent(txPath), encoding: .utf8)
        let transaction = try Codec.parseTransaction(Hex.data(txHex))
        let prevouts = try loadPrevouts(files: files, base: base, meta: meta)
        let prevSpk = try loadPrevScriptPubKey(files: files, base: base, prevouts: prevouts)
        let fixtureID = fixture["fixture_id"] as? String ?? ""
        let height = fixture["height"] as? Int ?? -1
        let blockHash = fixture["block_hash"] as? String ?? ""
        let inputIndex = fixture["input_index"] as? Int ?? 0
        let txid = (fixture["txid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? transaction.txid
        if !txid.isEmpty, txid != transaction.txid {
            throw SwiftBitnodeError.message("fixture txid mismatch: manifest=\(txid) parsed=\(transaction.txid)")
        }
        return CorpusFixture(
            fixtureID: fixtureID,
            height: height,
            blockHash: blockHash,
            txid: transaction.txid,
            inputIndex: inputIndex,
            transaction: transaction,
            prevouts: prevouts,
            prevScriptPubKey: prevSpk,
            loadedFiles: loadedFiles,
            fileHashes: fileHashes
        )
    }

    private static func loadMeta(files: [String: [String]], base: URL) throws -> [String: Any] {
        guard let path = files["meta"]?.first else {
            return [:]
        }
        let data = try Data(contentsOf: base.appendingPathComponent(path))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func loadPrevouts(files: [String: [String]], base: URL, meta: [String: Any]) throws -> [CorpusPrevout] {
        guard let path = files["prevouts"]?.first else {
            let amount = (meta["prev_amount_sats"] as? Int64)
                ?? Int64(meta["prev_amount_sats"] as? Int ?? -1)
            let spk = meta["spent_script_pubkey"] as? String ?? ""
            if amount >= 0, !spk.isEmpty {
                return [CorpusPrevout(amount: amount, scriptPubKey: try Hex.data(spk))]
            }
            return []
        }
        let data = try Data(contentsOf: base.appendingPathComponent(path))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SwiftBitnodeError.message("prevouts JSON root must be an array")
        }
        return try rows.map { row in
            let amount = (row["amount_sats"] as? Int64)
                ?? (row["amount"] as? Int64)
                ?? Int64(row["amount"] as? Int ?? -1)
            let spk = (row["spk"] as? String)
                ?? (row["script_pubkey"] as? String)
                ?? (row["scriptPubKey"] as? String)
                ?? ""
            guard amount >= 0 else {
                throw SwiftBitnodeError.message("prevout missing amount")
            }
            return CorpusPrevout(amount: amount, scriptPubKey: try Hex.data(spk))
        }
    }

    private static func loadPrevScriptPubKey(files: [String: [String]], base: URL, prevouts: [CorpusPrevout]) throws -> Data {
        if let path = files["prev_spk"]?.first {
            let hex = try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
            return try Hex.data(hex)
        }
        guard let first = prevouts.first else {
            throw SwiftBitnodeError.message("missing prevout scriptPubKey")
        }
        return first.scriptPubKey
    }
}
