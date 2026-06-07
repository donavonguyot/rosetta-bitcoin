import Foundation

enum SupervisorSmoke {
    static func run(args: Args) throws {
        let datadir = args.string("datadir", default: ProcessInfo.processInfo.environment["DATA_DIR"] ?? "/data")
        let defaultPeer = ProcessInfo.processInfo.environment["REFERENCE_P2P_PEER"] ?? ""
        let peer = ProcessInfo.processInfo.environment["PEER"] ?? defaultPeer
        let peerMode = ProcessInfo.processInfo.environment["PEER_MODE"] ?? "local_reference"
        let status = Status.build(datadir: datadir, runtimeSurface: Constants.runtimeSurface)
        let blocker = status["current_blocker"] ?? NSNull()
        let payload: [String: Any] = [
            "phase": "smoke",
            "runtime_surface": Constants.runtimeSurface,
            "peer_mode": peerMode,
            "peer": peer,
            "validated_height": status["validated_height"] ?? NSNull(),
            "header_height": status["header_height"] ?? NSNull(),
            "stored_block_height": status["stored_block_height"] ?? NSNull(),
            "sync_status": status["sync_status"] ?? "unknown",
            "delta_since_last": 0,
            "process_running": false,
            "current_blocker": blocker
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let line = "AGENT_LOOP_TICK_chatreport " + String(decoding: data, as: UTF8.self) + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
