import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct OutpointKey: Hashable, Sendable, Codable {
    let txidInternal: Data
    let vout: UInt32

    var display: String {
        "\(txidInternal.reversedHex):\(vout)"
    }

    var rocksKey: Data {
        var out = Data([0x55])
        out.append(txidInternal)
        out.append(vout.littleEndianData)
        return out
    }

    var legacyRocksKey: String {
        "utxo:\(display)"
    }
}

struct StoredUtxo: Codable, Sendable {
    let value: Int64
    let scriptPubKey: Data
    let height: Int
    let coinbase: Bool
}

struct StoredUndo: Codable, Sendable {
    let key: String
    let utxo: StoredUtxo
}

struct StoreState: Codable {
    var generationID: String = UUID().uuidString
    var syncStatus: String = "empty"
    var chainstateStatus: String = "missing"
    var validatedHeight: Int = -1
    var validatedHash: String = ""
    var headerHeight: Int = -1
    var headerHash: String = ""
    var storedBlockHeight: Int = -1
    var storedBlockHash: String = ""
    var chainstateUtxoCount: Int = 0
    var currentBlocker: [String: String]? = nil
    var lastError: String = ""
    var updatedAt: String = nowIso8601()
    var utxos: [String: StoredUtxo] = [:]
}

final class ChainStore {
    let datadir: URL
    let blocksDir: URL
    let stateURL: URL
    let rocks: RocksDBNative?
    private let lockURL: URL
    private let lockToken: String?
    private let deleteLegacyUtxoKeys: Bool

    init(datadir: String, acquireLock: Bool = true) throws {
        self.datadir = URL(fileURLWithPath: datadir)
        self.blocksDir = self.datadir.appendingPathComponent("blocks")
        self.stateURL = self.datadir.appendingPathComponent("swift-chainstate.json")
        self.lockURL = self.datadir.appendingPathComponent(".swiftbitnode.lock")
        self.deleteLegacyUtxoKeys = (ProcessInfo.processInfo.environment["SWIFTBITNODE_DELETE_LEGACY_UTXO_KEYS"] ?? "false").lowercased() == "true"
        try FileManager.default.createDirectory(at: self.datadir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.blocksDir, withIntermediateDirectories: true)
        self.lockToken = acquireLock ? try Self.acquireLock(lockURL: lockURL) : nil
        let rocksPath = self.datadir.appendingPathComponent("chainstate-rocksdb").path
        self.rocks = RocksDBNative(path: rocksPath)
    }

    deinit {
        guard let lockToken else { return }
        let current = (try? String(contentsOf: lockURL, encoding: .utf8)) ?? ""
        if current.contains(lockToken) {
            try? FileManager.default.removeItem(at: lockURL)
        }
    }

    func load() throws -> StoreState {
        if let rocks, let data = try rocks.get(key: "meta:state") {
            return try JSONDecoder().decode(StoreState.self, from: data)
        }
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return StoreState()
        }
        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder().decode(StoreState.self, from: data)
    }

    func save(_ state: StoreState) throws {
        var copy = state
        copy.updatedAt = nowIso8601()
        let data = try JSONEncoder().encode(copy)
        if let rocks {
            try rocks.put(key: "meta:state", value: data)
        } else {
            try data.write(to: stateURL)
        }
    }

    func recordBlock(height: Int, hash: String, raw: Data) throws {
        if let rocks {
            try rocks.writeBatch(
                puts: [
                    ("block:raw:height:\(height)", raw),
                    ("block:index:height:\(height)", Data(hash.utf8)),
                    ("block:index:hash:\(hash)", Data("\(height)".utf8))
                ],
                deletes: []
            )
        } else {
            let path = blocksDir.appendingPathComponent(String(format: "block_%08d.dat", height))
            try raw.write(to: path)
        }
    }

    var backendName: String {
        rocks == nil ? "swift-file-diagnostic" : "rocksdb"
    }

    var backendPath: String {
        rocks?.path ?? stateURL.path
    }

    func markStored(height: Int, hash: String) throws {
        var state = try load()
        state.storedBlockHeight = height
        state.storedBlockHash = hash
        state.headerHeight = max(state.headerHeight, height)
        state.headerHash = hash
        state.syncStatus = "blocks_stored"
        state.chainstateStatus = backendName == "rocksdb" ? "usable" : "diagnostic_file_store"
        try save(state)
    }

    func getUtxo(_ key: String, state: StoreState) throws -> StoredUtxo? {
        if let rocks, let data = try rocks.get(key: "utxo:\(key)") {
            return try decodeUtxo(data)
        }
        return state.utxos[key]
    }

    func getUtxos(_ keys: [String], state: StoreState) throws -> [String: StoredUtxo] {
        if let rocks {
            let raw = try rocks.get(keys: keys.map { "utxo:\($0)" })
            var out: [String: StoredUtxo] = [:]
            for key in keys {
                if let data = raw["utxo:\(key)"] {
                    out[key] = try decodeUtxo(data)
                }
            }
            return out
        }
        var out: [String: StoredUtxo] = [:]
        for key in keys {
            if let utxo = state.utxos[key] {
                out[key] = utxo
            }
        }
        return out
    }

    func getUtxos(_ keys: [OutpointKey], state: StoreState) throws -> [OutpointKey: StoredUtxo] {
        if let rocks {
            let raw = try rocks.get(keys: keys.map(\.rocksKey))
            var out: [OutpointKey: StoredUtxo] = [:]
            var missingLegacy: [OutpointKey] = []
            for key in keys {
                if let data = raw[key.rocksKey] {
                    out[key] = try decodeUtxo(data)
                } else {
                    missingLegacy.append(key)
                }
            }
            if !missingLegacy.isEmpty {
                let legacyRaw = try rocks.get(keys: missingLegacy.map(\.legacyRocksKey))
                for key in missingLegacy {
                    if let data = legacyRaw[key.legacyRocksKey] {
                        out[key] = try decodeUtxo(data)
                    }
                }
            }
            return out
        }
        var out: [OutpointKey: StoredUtxo] = [:]
        for key in keys {
            if let utxo = state.utxos[key.display] {
                out[key] = utxo
            }
        }
        return out
    }

    func commitConnectedBlock(
        state: StoreState,
        raw: Data,
        height: Int,
        hash: String,
        created: [(OutpointKey, StoredUtxo)],
        spent: [(OutpointKey, StoredUtxo)]
    ) throws -> StoreState {
        var copy = state
        if rocks == nil {
            for (key, _) in spent {
                copy.utxos.removeValue(forKey: key.display)
            }
            for (key, utxo) in created {
                copy.utxos[key.display] = utxo
            }
        } else {
            copy.utxos.removeAll(keepingCapacity: false)
        }
        copy.validatedHeight = height
        copy.validatedHash = hash
        copy.headerHeight = height
        copy.headerHash = hash
        copy.storedBlockHeight = max(copy.storedBlockHeight, height)
        copy.storedBlockHash = hash
        copy.chainstateUtxoCount = rocks == nil ? copy.utxos.count : max(0, state.chainstateUtxoCount - spent.count + created.count)
        copy.syncStatus = "blocks_current"
        copy.chainstateStatus = backendName == "rocksdb" ? "usable" : "diagnostic_file_store"
        copy.currentBlocker = nil
        copy.lastError = ""
        copy.updatedAt = nowIso8601()

        let stateData = try JSONEncoder().encode(copy)
        guard let rocks else {
            try stateData.write(to: stateURL)
            return copy
        }
        let undoPayload = encodeUndo(spent)
        var puts: [(Data, Data)] = [
            (Data("meta:state".utf8), stateData),
            (Data("block:raw:height:\(height)".utf8), raw),
            (Data("block:index:height:\(height)".utf8), Data(hash.utf8)),
            (Data("block:index:hash:\(hash)".utf8), Data("\(height)".utf8)),
            (Data("undo:height:\(height)".utf8), undoPayload)
        ]
        for (key, utxo) in created {
            puts.append((key.rocksKey, encodeUtxo(utxo)))
        }
        var deletes = spent.map { $0.0.rocksKey }
        if deleteLegacyUtxoKeys {
            deletes.append(contentsOf: spent.map { Data($0.0.legacyRocksKey.utf8) })
        }
        try rocks.writeBatch(puts: puts, deletes: deletes)
        return copy
    }

    func setBlocker(height: Int, failure: String, txid: String = "", inputIndex: Int = -1) throws {
        var state = try load()
        state.syncStatus = "blocks_blocked"
        state.chainstateStatus = "blocked"
        state.currentBlocker = [
            "height": "\(height)",
            "txid": txid,
            "input_index": "\(inputIndex)",
            "failure": failure
        ]
        state.lastError = failure
        try save(state)
    }

    private static func acquireLock(lockURL: URL) throws -> String {
        let token = UUID().uuidString
        if let existing = try? String(contentsOf: lockURL, encoding: .utf8),
           let pidLine = existing.split(separator: "\n").first(where: { $0.hasPrefix("pid=") }),
           let pid = Int32(pidLine.dropFirst(4)),
           kill(pid, 0) == 0 {
            throw SwiftBitnodeError.message("another swiftbitnode process holds lock (pid \(pid)): \(lockURL.path)")
        }
        let body = "pid=\(ProcessInfo.processInfo.processIdentifier)\ntoken=\(token)\ncreated_at=\(nowIso8601())\n"
        try body.write(to: lockURL, atomically: true, encoding: .utf8)
        return token
    }

    private func encodeUtxo(_ utxo: StoredUtxo) -> Data {
        var out = Data()
        out.append(UInt64(bitPattern: utxo.value).littleEndianData)
        out.append(UInt32(utxo.height).littleEndianData)
        out.append(utxo.coinbase ? 1 : 0)
        appendCompactSize(&out, UInt64(utxo.scriptPubKey.count))
        out.append(utxo.scriptPubKey)
        return out
    }

    private func encodeUndo(_ spent: [(OutpointKey, StoredUtxo)]) -> Data {
        var out = Data()
        appendCompactSize(&out, UInt64(spent.count))
        for (key, utxo) in spent {
            out.append(key.txidInternal)
            out.append(key.vout.littleEndianData)
            let encoded = encodeUtxo(utxo)
            appendCompactSize(&out, UInt64(encoded.count))
            out.append(encoded)
        }
        return out
    }

    private func decodeUtxo(_ data: Data) throws -> StoredUtxo {
        do {
            var reader = ByteReader(data)
            let value = Int64(bitPattern: try reader.uint64LE())
            let height = Int(try reader.uint32LE())
            let coinbase = try reader.uint8() != 0
            let scriptLen = Int(try reader.compactSize())
            let script = try reader.read(scriptLen)
            guard reader.remaining == 0 else {
                throw SwiftBitnodeError.message("utxo value has trailing bytes")
            }
            return StoredUtxo(value: value, scriptPubKey: script, height: height, coinbase: coinbase)
        } catch {
            return try JSONDecoder().decode(StoredUtxo.self, from: data)
        }
    }

    private func appendCompactSize(_ out: inout Data, _ value: UInt64) {
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

enum Status {
    static func build(datadir: String, runtimeSurface: String) -> [String: Any] {
        let native = NativeReport.build()
        let state: StoreState
        var store: ChainStore?
        do {
            let opened = try ChainStore(datadir: datadir, acquireLock: false)
            store = opened
            state = try opened.load()
        } catch {
            store = nil
            state = StoreState(syncStatus: "status_error", chainstateStatus: "missing", lastError: error.localizedDescription)
        }
        let blocker: Any = state.currentBlocker ?? NSNull()
        return [
            "node_id": Constants.nodeID,
            "implementation": Constants.implementation,
            "runtime_surface": runtimeSurface,
            "runtime_status": "not_running",
            "chain": Constants.chain,
            "network": Constants.chain,
            "datadir": datadir,
            "sync_status": state.syncStatus,
            "binary_gate_status": "not_attempted",
            "header_height": state.headerHeight,
            "header_hash": state.headerHash,
            "stored_block_height": state.storedBlockHeight,
            "stored_block_hash": state.storedBlockHash,
            "validated_height": state.validatedHeight,
            "validated_hash": state.validatedHash,
            "chainstate_backend": store?.backendName ?? "missing",
            "chainstate_backend_path": store?.backendPath ?? "\(datadir)/chainstate-rocksdb",
            "chainstate_generation_id": state.generationID,
            "chainstate_status": state.chainstateStatus,
            "utxo_accounting_policy": "core_spendable_v1",
            "chainstate_utxo_count": state.chainstateUtxoCount,
            "native_crypto_backend": Constants.nativeCryptoBackend,
            "native_crypto_available": native["native_crypto_available"] ?? false,
            "native_dependency_report": native,
            "rocksdb_library_available": native["rocksdb_available"] ?? false,
            "current_blocker": blocker,
            "last_error": state.lastError,
            "updated_at": state.updatedAt
        ]
    }
}
