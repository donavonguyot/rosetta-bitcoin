import Foundation

let args = Args(CommandLine.arguments)
do {
    switch args.command {
    case "status":
        let datadir = args.string("datadir", default: ProcessInfo.processInfo.environment["DATA_DIR"] ?? "./data-swift")
        try Json.write(Status.build(datadir: datadir, runtimeSurface: Constants.runtimeSurface), to: nil)
    case "native-crypto-vectors":
        try Json.write(NativeVectors.run(), to: nil)
    case "script-corpus":
        try ScriptCorpus.run(args: args)
    case "proof-local":
        try LocalReferenceProof.run(args: args)
    case "sync-supervisor":
        try SyncSupervisor.run(args: args)
    case "consensus-self-test":
        try Json.write(ConsensusSelfTest.run(), to: nil)
    case "performance-self-test":
        try Json.write(PerformanceSelfTest.run(), to: nil)
    default:
        printHelp()
    }
} catch {
    FileHandle.standardError.write(Data("swiftbitnode error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
