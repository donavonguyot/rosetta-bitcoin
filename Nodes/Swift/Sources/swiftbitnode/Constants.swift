import Foundation

enum Constants {
    static let nodeID = "swift"
    static let implementation = "SwiftNode"
    static let chain = "testnet4"
    static let runtimeSurface = ProcessInfo.processInfo.environment["SWIFTBITNODE_RUNTIME_SURFACE"] ?? "host"
    static let nativeCryptoBackend = "libsecp256k1"
    static let target5kHash = "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2"
    static let genesisHash = "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043"
    static let testnet4Magic = Data([0x1c, 0x16, 0x3f, 0x28])
}

func nowIso8601() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func printHelp() {
    print("swiftbitnode <status|native-crypto-vectors|script-corpus|proof-local> [options]")
}
