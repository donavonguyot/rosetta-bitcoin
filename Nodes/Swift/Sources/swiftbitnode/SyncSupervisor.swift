import Foundation

enum SyncSupervisor {
    static func run(args: Args) throws {
        let target = args.int("target", default: Int(ProcessInfo.processInfo.environment["TARGET_HEIGHT"] ?? "") ?? 10000)
        let chunkSize = max(1, args.int("chunk-size", default: Int(ProcessInfo.processInfo.environment["CHUNK_SIZE"] ?? "") ?? 5000))
        let maxRetries = max(0, args.int("max-retries", default: Int(ProcessInfo.processInfo.environment["MAX_RETRIES"] ?? "") ?? 3))
        let peer = args.string("peer", default: ProcessInfo.processInfo.environment["PEER"] ?? "host.docker.internal:48333")
        let datadir = args.string("datadir", default: ProcessInfo.processInfo.environment["DATA_DIR"] ?? "/data")
        let output = args.string("output", default: args.string("status-output", default: ""))
        let prefetchDepth = max(1, Int(ProcessInfo.processInfo.environment["PREFETCH_DEPTH"] ?? "") ?? args.int("prefetch-depth", default: 4))
        let started = DispatchTime.now().uptimeNanoseconds
        let store = try ChainStore(datadir: datadir)
        let stopMarker = store.datadir.appendingPathComponent(".swiftbitnode_supervisor_stop")
        var state = try store.load()
        var timing = TimingCollector()
        var chunks: [[String: Any]] = []
        var failures: [String] = []

        while state.validatedHeight < target {
            if FileManager.default.fileExists(atPath: stopMarker.path) {
                failures.append("stop marker present: \(stopMarker.path)")
                break
            }
            let startHeight = max(0, state.validatedHeight + 1)
            let chunkTarget = min(target, max(startHeight, state.validatedHeight + chunkSize))
            var attempts = 0
            var chunkConnected = 0
            var chunkFetched = 0
            var chunkDone = false

            while attempts <= maxRetries && !chunkDone {
                attempts += 1
                do {
                    chunkFetched = try P2PFetcher.fetch(
                        peer: peer,
                        target: chunkTarget,
                        startHeight: startHeight,
                        prefetchDepth: prefetchDepth,
                        advertiseHeight: state.validatedHeight
                    ) { block in
                        let connectStart = DispatchTime.now().uptimeNanoseconds
                        let result = try BlockConnector.connect(raw: block.raw, height: block.height, state: state, store: store, timing: &timing)
                        timing.addElapsed("block_connect_store_commit", since: connectStart)
                        if result.connected {
                            chunkConnected += 1
                            state = result.state
                        }
                        return result.connected
                    }
                    chunkDone = state.validatedHeight >= chunkTarget && state.currentBlocker == nil
                } catch {
                    failures.append("chunk \(startHeight)-\(chunkTarget) attempt \(attempts): \(error.localizedDescription)")
                    if attempts > maxRetries {
                        try? store.setBlocker(height: max(startHeight, state.validatedHeight + 1), failure: error.localizedDescription)
                        break
                    }
                }
            }

            chunks.append([
                "start_height": startHeight,
                "target_height": chunkTarget,
                "blocks_fetched": chunkFetched,
                "blocks_connected": chunkConnected,
                "attempts": attempts,
                "validated_height": state.validatedHeight,
                "current_blocker": state.currentBlocker ?? NSNull()
            ])
            try writeStatus(
                output: output,
                datadir: datadir,
                target: target,
                chunks: chunks,
                failures: failures,
                timing: timing,
                elapsedMs: elapsedMs(started)
            )
            if !chunkDone || state.currentBlocker != nil {
                break
            }
        }

        try writeStatus(
            output: output,
            datadir: datadir,
            target: target,
            chunks: chunks,
            failures: failures,
            timing: timing,
            elapsedMs: elapsedMs(started)
        )
    }

    private static func writeStatus(
        output: String,
        datadir: String,
        target: Int,
        chunks: [[String: Any]],
        failures: [String],
        timing: TimingCollector,
        elapsedMs: Int
    ) throws {
        let status = Status.build(datadir: datadir, runtimeSurface: Constants.runtimeSurface)
        let validatedHeight = status["validated_height"] as? Int ?? -1
        let blocker = status["current_blocker"] ?? NSNull()
        let reached = validatedHeight >= target && blocker is NSNull
        try Json.write([
            "schema": "swiftbitnode.sync_supervisor.v1",
            "implementation": Constants.implementation,
            "node_id": Constants.nodeID,
            "target_height": target,
            "validated_height": validatedHeight,
            "result": reached ? "passed" : "in_progress_or_blocked",
            "current_blocker": blocker,
            "failures": failures,
            "chunks": chunks,
            "stage_totals_ms": timing.stageTotalsMs(required: ["prevout_batch_load", "utxo_load", "script_verify", "utxo_apply", "commit", "block_connect_store_commit", "p2p_fetch"]),
            "timing_summary": [
                "stage_totals_ms": timing.stageTotalsMs(required: ["prevout_batch_load", "utxo_load", "script_verify", "utxo_apply", "commit", "block_connect_store_commit", "p2p_fetch"]),
                "slow_blocks": timing.slowBlocksJson(),
                "total_ms": elapsedMs
            ],
            "elapsed_ms": elapsedMs,
            "status": status,
            "captured_at": nowIso8601()
        ], to: output.isEmpty ? nil : output)
    }

    private static func elapsedMs(_ started: UInt64) -> Int {
        max(1, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
    }
}
