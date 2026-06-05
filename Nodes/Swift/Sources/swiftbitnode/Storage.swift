import Foundation

struct StoredUtxo: Codable {
    let value: Int64
    let scriptPubKeyHex: String
    let height: Int
    let coinbase: Bool
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

    init(datadir: String) throws {
        self.datadir = URL(fileURLWithPath: datadir)
        self.blocksDir = self.datadir.appendingPathComponent("blocks")
        self.stateURL = self.datadir.appendingPathComponent("swift-chainstate.json")
        try FileManager.default.createDirectory(at: self.datadir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.blocksDir, withIntermediateDirectories: true)
        let rocksPath = self.datadir.appendingPathComponent("chainstate-rocksdb").path
        self.rocks = RocksDBNative(path: rocksPath)
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

    var backendName: String {
        rocks == nil ? "swift-file-diagnostic" : "rocksdb"
    }

    var backendPath: String {
        rocks?.path ?? stateURL.path
    }

    func recordBlock(height: Int, raw: Data) throws {
        let path = blocksDir.appendingPathComponent(String(format: "block_%08d.dat", height))
        try raw.write(to: path)
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
}

enum Status {
    static func build(datadir: String, runtimeSurface: String) -> [String: Any] {
        let native = NativeReport.build()
        let state: StoreState
        var store: ChainStore?
        do {
            let opened = try ChainStore(datadir: datadir)
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
