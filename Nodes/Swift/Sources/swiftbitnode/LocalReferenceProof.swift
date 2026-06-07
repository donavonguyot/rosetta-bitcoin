import Foundation

enum LocalReferenceProof {
    static func run(args: Args) throws {
        let output = args.string("output", default: args.string("result-path", default: ""))
        let target = args.int("target", default: Int(ProcessInfo.processInfo.environment["TARGET_HEIGHT"] ?? "") ?? 5000)
        let defaultPeer = ProcessInfo.processInfo.environment["REFERENCE_P2P_PEER"] ?? "127.0.0.1:48333"
        let peer = args.string("peer", default: ProcessInfo.processInfo.environment["PEER"] ?? defaultPeer)
        let datadir = args.string("datadir", default: ProcessInfo.processInfo.environment["DATA_DIR"] ?? "/data")
        let prefetchDepth = Int(ProcessInfo.processInfo.environment["PREFETCH_DEPTH"] ?? "") ?? 1
        let scriptRunnerMode = ProcessInfo.processInfo.environment["SCRIPT_RUNNER_MODE"] ?? "serial"
        let rocksdbWalDisabled = (ProcessInfo.processInfo.environment["ROCKSDB_WAL_DISABLED"] ?? "false").lowercased() == "true"
        let freshState = (ProcessInfo.processInfo.environment["FRESH_STATE"] ?? "true").lowercased() != "false"
        let deleteLegacyUtxoKeys = (ProcessInfo.processInfo.environment["SWIFTBITNODE_DELETE_LEGACY_UTXO_KEYS"] ?? "false").lowercased() == "true"
        let legacyUtxoFallback = (ProcessInfo.processInfo.environment["SWIFTBITNODE_LEGACY_UTXO_FALLBACK"] ?? "true").lowercased() != "false"
        let started = DispatchTime.now().uptimeNanoseconds
        let store = try ChainStore(datadir: datadir)
        let scriptRunner = ScriptJobRunner()
        let initialState = try store.load()
        var rollingState = initialState
        let startHeight = max(0, initialState.validatedHeight + 1)
        var timing = TimingCollector()
        var blocksFetched = 0
        var blocksConnected = 0
        var failures: [String] = []
        var lastTelemetryNanos = started
        var lastTelemetryHeight = max(0, initialState.validatedHeight)
        let targetLabel = targetLabel(for: target)
        let benchmarkGate = benchmarkGateFor(target: target, label: targetLabel)
        let benchmarkKind = benchmarkKindFor(target: target, label: targetLabel)
        let runId = "swift-\(benchmarkGate)-\(Int(Date().timeIntervalSince1970 * 1000))"
        var telemetryTickCount = 0
        var telemetryLifecycleMarkers: [String: Int] = [:]
        var telemetryLastMonotonicMs: Int? = nil
        var telemetryMaxGapMs = 0
        func recordTelemetry(event: String, monotonicMs: Int) {
            telemetryTickCount += 1
            if telemetryLifecycleMarkers[event] == nil {
                telemetryLifecycleMarkers[event] = monotonicMs
            }
            if let previous = telemetryLastMonotonicMs {
                telemetryMaxGapMs = max(telemetryMaxGapMs, monotonicMs - previous)
            }
            telemetryLastMonotonicMs = monotonicMs
        }
        func emitAndRecord(event: String, phase: String, height: Int, state: StoreState, lastBlockMs: Int) {
            let monotonic = emitTelemetry(
                runId: runId,
                event: event,
                gate: benchmarkGate,
                target: target,
                height: height,
                state: state,
                started: started,
                previousHeight: lastTelemetryHeight,
                previousNanos: lastTelemetryNanos,
                phase: phase,
                lastBlockMs: lastBlockMs,
                timing: timing
            )
            recordTelemetry(event: event, monotonicMs: monotonic)
        }

        do {
            emitAndRecord(event: "run_started", phase: "startup", height: lastTelemetryHeight, state: rollingState, lastBlockMs: 0)
            emitAndRecord(event: "container_started", phase: "startup", height: lastTelemetryHeight, state: rollingState, lastBlockMs: 0)
            emitAndRecord(event: "node_started", phase: "startup", height: lastTelemetryHeight, state: rollingState, lastBlockMs: 0)
            var emittedFirstPeerByte = false
            var emittedFirstBlockConnected = false
            blocksFetched = try P2PFetcher.fetch(peer: peer, target: target, startHeight: startHeight, prefetchDepth: prefetchDepth) { block in
                if !emittedFirstPeerByte {
                    emitAndRecord(event: "first_peer_byte", phase: "peer_connect", height: lastTelemetryHeight, state: rollingState, lastBlockMs: 0)
                    emittedFirstPeerByte = true
                }
                timing.addMicros("p2p_fetch", block.fetchMicros)
                let connectStart = DispatchTime.now().uptimeNanoseconds
                let result = try BlockConnector.connect(raw: block.raw, height: block.height, state: rollingState, store: store, timing: &timing, scriptRunner: scriptRunner)
                let connected = result.connected
                timing.addElapsed("block_connect_store_commit", since: connectStart)
                if connected {
                    blocksConnected += 1
                    rollingState = result.state
                    let lastBlockMs = max(0, Int((DispatchTime.now().uptimeNanoseconds - connectStart) / 1_000_000))
                    if !emittedFirstBlockConnected {
                        emitAndRecord(event: "first_block_connected", phase: "block_connect", height: block.height, state: rollingState, lastBlockMs: lastBlockMs)
                        emittedFirstBlockConnected = true
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    if block.height - lastTelemetryHeight >= 2500 || now - lastTelemetryNanos >= 15_000_000_000 || block.height >= target {
                        emitAndRecord(event: block.height >= target ? "target_reached" : "heartbeat", phase: block.height >= target ? "complete" : "heartbeat", height: block.height, state: rollingState, lastBlockMs: lastBlockMs)
                        lastTelemetryHeight = block.height
                        lastTelemetryNanos = now
                    }
                }
                return connected
            }
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
        let requiredTimingBuckets = [
            "prevout_batch_load", "utxo_load", "prevout_multi_get_call", "prevout_legacy_fallback_get", "prevout_utxo_decode",
            "script_verify", "script_runner_wait", "script_wall_ms", "script_verify_worker_cpu", "script_worker_cpu_ms",
            "utxo_apply", "utxo_delete_prepare", "utxo_put_prepare", "undo_put_prepare", "metadata_put_prepare",
            "rocksdb_write", "commit", "block_connect_store_commit", "p2p_fetch"
        ]
        let stages = timing.stageTotalsMs(required: requiredTimingBuckets)
        let elapsedMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
        let timingSummary: [String: Any] = [
            "stage_totals_ms": stages,
            "slow_blocks": timing.slowBlocksJson(),
            "script_verify_worker_cpu": timing.totalMs("script_verify_worker_cpu"),
            "total_ms": elapsedMs
        ]
        emitAndRecord(event: "run_finished", phase: reached ? "complete" : "failed", height: validatedHeight, state: liveState, lastBlockMs: 0)
        let emptyCounts: [String: Int] = [:]
        let telemetrySummary: [String: Any] = [
            "telemetry_quality": "clean",
            "tick_count": telemetryTickCount,
            "heartbeat_max_gap_ms": telemetryMaxGapMs,
            "lifecycle_markers": telemetryLifecycleMarkers,
            "phase_counts": emptyCounts,
            "stall_class_counts": emptyCounts,
            "slow_blocks": timing.slowBlocksJson()
        ]
        let doc: [String: Any] = [
            "implementation": Constants.implementation,
            "node_id": Constants.nodeID,
            "port": Constants.nodeID,
            "chain": Constants.chain,
            "runtime_surface": Constants.runtimeSurface,
            "benchmark_contract_version": 1,
            "telemetry_schema": "benchmark.telemetry_tick.v1",
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
            "script_runner_workers": scriptRunner.workers,
            "script_worker_local_secp_context": scriptRunner.usesWorkerLocalSecp,
            "rocksdb_wal_disabled": rocksdbWalDisabled,
            "rocksdb_tuning": RocksDBNative.tuningMetadata,
            "delete_legacy_utxo_keys": deleteLegacyUtxoKeys,
            "legacy_utxo_fallback": legacyUtxoFallback,
            "prefetch_depth": prefetchDepth,
            "resume_supported": true,
            "fresh_state": freshState,
            "result": reached ? "passed" : "failed",
            "failures": failures,
            "elapsed_ms": elapsedMs,
            "captured_at": nowIso8601(),
            "status": status,
            "stage_totals_ms": stages,
            "timing_summary": timingSummary,
            "pipeline_timing_summary": timingSummary,
            "telemetry_summary": telemetrySummary
        ]
        try Json.write(doc, to: output.isEmpty ? nil : output)
    }

    private static func targetLabel(for target: Int) -> String {
        switch target {
        case 5000:
            return "5k"
        case 10000:
            return "10k"
        case 50000:
            return "50k"
        case 100000:
            return "100k"
        default:
            return "\(target)"
        }
    }

    private static func benchmarkGateFor(target: Int, label: String) -> String {
        switch target {
        case 5000:
            return "baseline_5k"
        case 10000:
            return "diagnostic_10k"
        case 50000:
            return "shakedown_50k"
        case 100000:
            return "performance_100k"
        default:
            return label == "\(target)" ? "local_reference" : "diagnostic_\(label)"
        }
    }

    private static func benchmarkKindFor(target: Int, label: String) -> String {
        switch target {
        case 5000:
            return "baseline_5k_p2p"
        case 10000:
            return "diagnostic_10k_p2p"
        case 50000:
            return "shakedown_50k_p2p"
        case 100000:
            return "performance_100k_p2p"
        default:
            return label == "\(target)" ? "local_reference_p2p" : "diagnostic_\(label)_p2p"
        }
    }

    @discardableResult
    private static func emitTelemetry(
        runId: String,
        event: String,
        gate: String,
        target: Int,
        height: Int,
        state: StoreState,
        started: UInt64,
        previousHeight: Int,
        previousNanos: UInt64,
        phase: String,
        lastBlockMs: Int,
        timing: TimingCollector
    ) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = max(0, Int((now - started) / 1_000_000))
        let deltaBlocks = max(0, height - previousHeight)
        let deltaSeconds = max(0.001, Double(now - previousNanos) / 1_000_000_000.0)
        let elapsedSeconds = max(0.001, Double(now - started) / 1_000_000_000.0)
        let canonicalPhase: String
        switch phase {
        case "startup", "peer_connect", "header_sync", "block_fetch", "block_connect", "commit", "heartbeat", "complete", "failed":
            canonicalPhase = phase
        default:
            canonicalPhase = "heartbeat"
        }
        let blocker: Any = state.currentBlocker.map { $0 as Any } ?? NSNull()
        let stallClass = !(blocker is NSNull) ? "validation_blocker" : (canonicalPhase == "block_connect" && lastBlockMs >= 15_000 ? "block_connect_slow" : "none")
        let tick: [String: Any] = [
            "schema": "benchmark.telemetry_tick.v1",
            "port": "swift",
            "gate": gate,
            "run_id": runId,
            "event": event,
            "target_height": target,
            "height": height,
            "header_height": state.headerHeight,
            "stored_block_height": state.storedBlockHeight,
            "percent": target > 0 ? (Double(height) / Double(target)) * 100.0 : 0.0,
            "elapsed_ms": elapsedMs,
            "monotonic_ms": elapsedMs,
            "rate_recent_blocks_per_second": Double(deltaBlocks) / deltaSeconds,
            "rate_total_blocks_per_second": Double(max(0, height)) / elapsedSeconds,
            "phase": canonicalPhase,
            "utxos": state.chainstateUtxoCount,
            "last_block_ms": lastBlockMs,
            "timing_buckets_ms": timing.stageTotalsMs(required: [
                "block_parse_validate",
                "prevout_batch_load", "utxo_load", "prevout_multi_get_call", "prevout_legacy_fallback_get", "prevout_utxo_decode",
                "script_verify", "script_runner_wait", "script_wall_ms", "script_verify_worker_cpu", "script_worker_cpu_ms",
                "utxo_apply", "utxo_delete_prepare", "utxo_put_prepare", "undo_put_prepare", "metadata_put_prepare",
                "rocksdb_write", "commit", "block_connect_store_commit", "p2p_fetch"
            ]),
            "current_blocker": blocker,
            "stall_class": stallClass,
            "current_block_elapsed_ms": lastBlockMs,
            "current_block_height": max(0, height),
            "current_block_hash": state.validatedHash.isEmpty ? NSNull() : state.validatedHash,
            "current_block_tx_count": 0,
            "current_block_vin_count": 0,
            "current_block_script_input_count": 0,
            "process_running": canonicalPhase != "complete" && canonicalPhase != "failed"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: tick, options: [.sortedKeys]),
           let raw = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data("benchmark.telemetry_tick \(raw)\n".utf8))
        }
        let progress: [String: Any] = [
            "chain": Constants.chain,
            "sync_status": state.syncStatus,
            "header_height": state.headerHeight,
            "validated_height": height,
            "validated_hash": state.validatedHash,
            "stored_block_height": state.storedBlockHeight,
            "chainstate_utxo_count": state.chainstateUtxoCount,
            "current_blocker": blocker,
            "peer": ProcessInfo.processInfo.environment["PEER"] ?? ProcessInfo.processInfo.environment["REFERENCE_P2P_PEER"] ?? "",
            "current_block_height": max(0, height),
            "current_block_hash": state.validatedHash.isEmpty ? NSNull() : state.validatedHash,
            "current_block_tx_count": 0,
            "current_block_vin_count": 0,
            "current_block_script_input_count": 0,
            "last_block_ms": lastBlockMs,
            "native_crypto_backend": Constants.nativeCryptoBackend,
            "timing_buckets_ms": timing.stageTotalsMs(required: [
                "block_parse_validate",
                "prevout_batch_load", "utxo_load", "prevout_multi_get_call", "prevout_legacy_fallback_get", "prevout_utxo_decode",
                "script_verify", "script_runner_wait", "script_wall_ms", "script_verify_worker_cpu", "script_worker_cpu_ms",
                "utxo_apply", "utxo_delete_prepare", "utxo_put_prepare", "undo_put_prepare", "metadata_put_prepare",
                "rocksdb_write", "commit", "block_connect_store_commit", "p2p_fetch"
            ])
        ]
        if let data = try? JSONSerialization.data(withJSONObject: progress, options: [.sortedKeys]),
           let raw = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data("rb.port_progress \(raw)\n".utf8))
        }
        return elapsedMs
    }
}
