import Foundation

enum LocalReferenceProof {
    static func run(args: Args) throws {
        let output = args.string("output", default: args.string("result-path", default: ""))
        let target = args.int("target", default: Int(ProcessInfo.processInfo.environment["TARGET_HEIGHT"] ?? "") ?? 5000)
        let peer = args.string("peer", default: ProcessInfo.processInfo.environment["PEER"] ?? "host.docker.internal:48333")
        let datadir = args.string("datadir", default: ProcessInfo.processInfo.environment["DATA_DIR"] ?? "/data")
        let prefetchDepth = Int(ProcessInfo.processInfo.environment["PREFETCH_DEPTH"] ?? "") ?? 1
        let scriptRunnerMode = ProcessInfo.processInfo.environment["SCRIPT_RUNNER_MODE"] ?? "serial"
        let rocksdbWalDisabled = (ProcessInfo.processInfo.environment["ROCKSDB_WAL_DISABLED"] ?? "false").lowercased() == "true"
        let freshState = (ProcessInfo.processInfo.environment["FRESH_STATE"] ?? "true").lowercased() != "false"
        let deleteLegacyUtxoKeys = (ProcessInfo.processInfo.environment["SWIFTBITNODE_DELETE_LEGACY_UTXO_KEYS"] ?? "false").lowercased() == "true"
        let started = DispatchTime.now().uptimeNanoseconds
        let store = try ChainStore(datadir: datadir)
        let initialState = try store.load()
        var rollingState = initialState
        let startHeight = max(0, initialState.validatedHeight + 1)
        var timing = TimingCollector()
        var blocksFetched = 0
        var blocksConnected = 0
        var failures: [String] = []

        do {
            let fetchStart = DispatchTime.now().uptimeNanoseconds
            blocksFetched = try P2PFetcher.fetch(peer: peer, target: target, startHeight: startHeight, prefetchDepth: prefetchDepth) { block in
                let connectStart = DispatchTime.now().uptimeNanoseconds
                let result = try BlockConnector.connect(raw: block.raw, height: block.height, state: rollingState, store: store, timing: &timing)
                let connected = result.connected
                timing.addElapsed("block_connect_store_commit", since: connectStart)
                if connected {
                    blocksConnected += 1
                    rollingState = result.state
                }
                return connected
            }
            timing.addElapsed("p2p_fetch", since: fetchStart)
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
        let targetLabel: String
        switch target {
        case 5000:
            targetLabel = "5k"
        case 10000:
            targetLabel = "10k"
        case 50000:
            targetLabel = "50k"
        default:
            targetLabel = "\(target)"
        }
        let benchmarkGate = targetLabel == "\(target)" ? "local_reference" : "supporting_\(targetLabel)"
        let benchmarkKind = targetLabel == "\(target)" ? "local_reference_p2p" : "supporting_\(targetLabel)_p2p"
        let stages = timing.stageTotalsMs(required: ["prevout_batch_load", "utxo_load", "script_verify", "utxo_apply", "commit", "block_connect_store_commit", "p2p_fetch"])
        let elapsedMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
        let doc: [String: Any] = [
            "implementation": Constants.implementation,
            "node_id": Constants.nodeID,
            "port": Constants.nodeID,
            "chain": Constants.chain,
            "runtime_surface": Constants.runtimeSurface,
            "benchmark_contract_version": 1,
            "benchmark_gate": benchmarkGate,
            "benchmark_kind": benchmarkKind,
            "benchmark_lane": benchmarkKind,
            "target_height": target,
            "header_target_height": target,
            "target_label": targetLabel,
            "byte_source": "local_reference_p2p",
            "proof_mode": "p2p_sync",
            "peer_mode": "local_reference",
            "peer": peer,
            "reference_start_height": max(0, startHeight - 1),
            "reference_start_hash": initialState.validatedHash.isEmpty ? Constants.genesisHash : initialState.validatedHash,
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
            "script_runner_mode": scriptRunnerMode,
            "rocksdb_wal_disabled": rocksdbWalDisabled,
            "rocksdb_tuning": RocksDBNative.tuningMetadata,
            "delete_legacy_utxo_keys": deleteLegacyUtxoKeys,
            "prefetch_depth": prefetchDepth,
            "resume_supported": true,
            "fresh_state": freshState,
            "result": reached ? "passed" : "failed",
            "failures": failures,
            "elapsed_ms": elapsedMs,
            "captured_at": nowIso8601(),
            "status": status,
            "stage_totals_ms": stages,
            "timing_summary": [
                "stage_totals_ms": stages,
                "slow_blocks": timing.slowBlocksJson(),
                "script_verify_worker_cpu": timing.totalMs("script_verify_worker_cpu"),
                "total_ms": elapsedMs
            ]
        ]
        try Json.write(doc, to: output.isEmpty ? nil : output)
    }
}
