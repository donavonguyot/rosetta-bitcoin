import Foundation

enum LocalReferenceProof {
    static func run(args: Args) throws {
        let output = args.string("output", default: args.string("result-path", default: ""))
        let target = args.int("target", default: Int(ProcessInfo.processInfo.environment["TARGET_HEIGHT"] ?? "") ?? 5000)
        let peer = args.string("peer", default: ProcessInfo.processInfo.environment["PEER"] ?? "host.docker.internal:48333")
        let datadir = args.string("datadir", default: ProcessInfo.processInfo.environment["DATA_DIR"] ?? "/data")
        let started = Date()
        let store = try ChainStore(datadir: datadir)
        var timing = TimingCollector()
        var blocksFetched = 0
        var blocksConnected = 0
        var failures: [String] = []

        do {
            let fetchStart = Date()
            blocksFetched = try P2PFetcher.fetch(peer: peer, target: target) { block in
                try store.recordBlock(height: block.height, raw: block.raw)
                try store.markStored(height: block.height, hash: block.hash)
                let connectStart = Date()
                let connected = try BlockConnector.connect(raw: block.raw, height: block.height, store: store, timing: &timing)
                timing.stages["block_connect_store_commit", default: 0] += max(1, Int(Date().timeIntervalSince(connectStart) * 1000))
                if connected {
                    blocksConnected += 1
                }
                return connected
            }
            timing.stages["p2p_fetch", default: 0] += max(1, Int(Date().timeIntervalSince(fetchStart) * 1000))
        } catch {
            failures.append(error.localizedDescription)
            try? store.setBlocker(height: blocksConnected, failure: error.localizedDescription)
        }

        var status = Status.build(datadir: datadir, runtimeSurface: Constants.runtimeSurface)
        let liveState = try store.load()
        status["chainstate_backend"] = store.backendName
        status["chainstate_backend_path"] = store.backendPath
        status["chainstate_generation_id"] = liveState.generationID
        status["sync_status"] = liveState.syncStatus
        status["chainstate_status"] = liveState.chainstateStatus
        status["validated_height"] = liveState.validatedHeight
        status["validated_hash"] = liveState.validatedHash
        status["header_height"] = liveState.headerHeight
        status["header_hash"] = liveState.headerHash
        status["stored_block_height"] = liveState.storedBlockHeight
        status["stored_block_hash"] = liveState.storedBlockHash
        status["chainstate_utxo_count"] = liveState.chainstateUtxoCount
        status["current_blocker"] = liveState.currentBlocker ?? NSNull()
        status["last_error"] = liveState.lastError
        let validatedHeight = status["validated_height"] as? Int ?? -1
        let reached = validatedHeight >= target && (status["current_blocker"] is NSNull)
        if !reached && failures.isEmpty {
            failures.append("target not reached")
        }
        var stages = timing.stages
        for required in ["utxo_load", "script_verify", "utxo_apply", "commit", "block_connect_store_commit"] {
            stages[required, default: 0] += 0
        }
        let elapsedMs = max(1, Int(Date().timeIntervalSince(started) * 1000))
        let doc: [String: Any] = [
            "implementation": Constants.implementation,
            "node_id": Constants.nodeID,
            "port": Constants.nodeID,
            "chain": Constants.chain,
            "runtime_surface": Constants.runtimeSurface,
            "benchmark_contract_version": 1,
            "benchmark_gate": "supporting_5k",
            "benchmark_kind": "supporting_5k_p2p",
            "benchmark_lane": "supporting_5k_p2p",
            "target_height": target,
            "header_target_height": target,
            "target_label": target == 5000 ? "5k" : "\(target)",
            "byte_source": "local_reference_p2p",
            "proof_mode": "p2p_sync",
            "peer_mode": "local_reference",
            "peer": peer,
            "reference_start_height": 0,
            "reference_start_hash": Constants.genesisHash,
            "reference_finish_height": target,
            "reference_finish_hash": status["header_hash"] ?? "",
            "validated_height": validatedHeight,
            "validated_hash": status["validated_hash"] ?? "",
            "header_height": status["header_height"] ?? -1,
            "header_hash": status["header_hash"] ?? "",
            "stored_block_height": status["stored_block_height"] ?? -1,
            "stored_block_hash": status["stored_block_hash"] ?? "",
            "blocks_fetched": blocksFetched,
            "blocks_connected": blocksConnected,
            "current_blocker": status["current_blocker"] ?? NSNull(),
            "binary_gate_status": "not_attempted",
            "chainstate_backend": status["chainstate_backend"] ?? "missing",
            "chainstate_status": status["chainstate_status"] ?? "missing",
            "chainstate_utxo_count": status["chainstate_utxo_count"] ?? 0,
            "utxo_accounting_policy": "core_spendable_v1",
            "native_crypto_backend": Constants.nativeCryptoBackend,
            "native_crypto_available": (NativeReport.build()["native_crypto_available"] as? Bool) ?? false,
            "script_runner_mode": "serial",
            "rocksdb_wal_disabled": false,
            "prefetch_depth": 1,
            "resume_supported": false,
            "fresh_state": true,
            "result": reached ? "passed" : "failed",
            "failures": failures,
            "elapsed_ms": elapsedMs,
            "captured_at": nowIso8601(),
            "status": status,
            "stage_totals_ms": stages,
            "timing_summary": [
                "stage_totals_ms": stages,
                "total_ms": elapsedMs
            ]
        ]
        try Json.write(doc, to: output.isEmpty ? nil : output)
    }
}
